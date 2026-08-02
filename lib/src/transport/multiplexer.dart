import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../protocol/header.dart';
import '../protocol/status.dart';
import 'connection.dart';

/// Pending request waiting for a response.
class _PendingRequest {
  final Completer<Smb2Response> completer;
  final DateTime createdAt;

  _PendingRequest(this.completer) : createdAt = DateTime.now();
}

/// A decoded SMB2 response.
class Smb2Response {
  final Smb2Header header;
  final Uint8List body; // Everything after the 64-byte header

  Smb2Response(this.header, this.body);

  /// Throw unless the server reported success.
  ///
  /// [allow] is a status that the protocol calls an error and this exchange
  /// does not: the "more to come" of a session setup, the end of file of a
  /// read past the end. Without somewhere to say that, five callers wrote
  /// their own version of this check, and each one that did forgot to carry
  /// the header — which is the part that says which request failed.
  ///
  /// Not every send is checked. The ones that are not are teardown, and say
  /// so by name; see `_ignoringOutcome` in the client.
  void checkStatus(String operation, {int? allow}) {
    final status = header.status;
    if (allow != null && status == allow) return;
    if (!NtStatus.isError(status)) return;
    throw Smb2Exception(
      status,
      '$operation failed: ${NtStatus.describe(status)}',
      header,
    );
  }
}

/// Await the closing half of an exchange: a response whose status changes
/// nothing, because there is nothing left to do with the thing being closed.
///
/// The status is deliberately not read, and the name is how that is said out
/// loud. A send with neither this nor [Smb2Response.checkStatus] beside it is
/// an unexamined answer, which used to take counting the two against each
/// other to notice. [what] names the operation for the log; [log] is the
/// caller's, so the line still says which layer it came from.
Future<void> ignoringOutcome(
    Future<Smb2Response> response, String what, Logger log) async {
  try {
    await response;
  } catch (e, st) {
    log.warning('$what error: $e', e, st);
  }
}

/// Exception thrown for SMB2 protocol errors.
class Smb2Exception implements Exception {
  final int status;
  final String message;
  final Smb2Header? header;

  Smb2Exception(this.status, this.message, [this.header]);

  @override
  String toString() =>
      'Smb2Exception: $message (${NtStatus.describe(status)})';
}

/// Manages MessageId-based multiplexing of SMB2 requests/responses.
///
/// - Each outgoing request is assigned a unique MessageId
/// - A dedicated receive loop reads responses and dispatches them
///   to the corresponding Completer by MessageId
/// - Send budget (in-flight slots + credit window) is enforced via
///   [tryReserveBudget] / [waitForBudget] to prevent credit exhaustion
///   and server overload
class Smb2Multiplexer {
  static final _log = Logger('Smb2Multiplexer');
  final Smb2Connection _connection;
  final int maxInflight;
  final Map<int, _PendingRequest> _pending = {};
  int _nextMessageId = 0;
  int _availableCredits = 1; // Start with 1, server grants more
  bool _running = false;
  Completer<void>? _stopCompleter;
  final List<Completer<void>> _budgetWaiters = [];

  Smb2Multiplexer(this._connection, {this.maxInflight = 32});

  int get availableCredits => _availableCredits;
  bool get isRunning => _running;

  /// Allocate the next MessageId, reserving [creditCharge] consecutive IDs.
  /// SMB 2.1+: a request with CreditCharge=N consumes MessageIds [mid, mid+N-1].
  int allocateMessageId({int creditCharge = 1}) {
    final mid = _nextMessageId;
    _nextMessageId += creditCharge < 1 ? 1 : creditCharge;
    return mid;
  }

  /// Register a pending request and return its Future.
  /// Throws [Smb2Exception] if the receive loop has stopped.
  Future<Smb2Response> registerRequest(int messageId) {
    _checkRunning();
    final completer = Completer<Smb2Response>();
    _pending[messageId] = _PendingRequest(completer);
    return completer.future;
  }

  /// Try to reserve send budget: [slots] in-flight slots plus
  /// [creditCharge] credits (the total across a compound). Synchronous,
  /// so the caller can send without yield points between reservation and
  /// the actual write.
  ///
  /// Returns false if the budget is exhausted (or the receive loop has
  /// stopped); the caller should [waitForBudget] and retry.
  ///
  /// Liveness fallback: when nothing is in flight, no future response can
  /// replenish credits, so the send is allowed even with an insufficient
  /// balance (same behavior as before credit enforcement existed).
  bool tryReserveBudget(int creditCharge, {int slots = 1}) {
    if (!_running) return false;
    if (_pending.length + slots > maxInflight) return false;
    if (_availableCredits < creditCharge) {
      if (_pending.isNotEmpty) return false;
      _log.warning('Sending with insufficient credits: '
          'available=$_availableCredits, charge=$creditCharge');
      _availableCredits = 0;
    } else {
      _availableCredits -= creditCharge;
    }
    return true;
  }

  /// Wait until send budget may be available again (a response arrived).
  /// Throws [Smb2Exception] if the receive loop has stopped.
  Future<void> waitForBudget() async {
    _checkRunning();
    final waiter = Completer<void>();
    _budgetWaiters.add(waiter);
    await waiter.future;
    _checkRunning();
  }

  void _checkRunning() {
    if (!_running) {
      throw Smb2Exception(0, 'Connection is closed');
    }
  }

  /// Start the receive loop. Must be called once after connection.
  void startReceiveLoop() {
    if (_running) return;
    _running = true;
    _receiveLoop();
  }

  Future<void> _receiveLoop() async {
    try {
      while (_running && !_connection.isClosed) {
        final packet = await _connection.readMessage();
        if (packet.length < Smb2Header.size) {
          _log.warning('Received packet too small: ${packet.length} bytes');
          continue;
        }

        // A transport message may carry several compounded responses,
        // chained via NextCommand. Dispatch each by its own MessageId.
        // A malformed chain means the MessageIds of the remaining
        // sub-responses can't be located, so protocol sync is lost:
        // throw to tear the connection down, which completes every
        // pending request with an error instead of leaving the
        // un-dispatched ones hanging until the caller's timeout.
        var offset = 0;
        while (true) {
          if (packet.length - offset < Smb2Header.size) {
            throw FormatException('Compound response truncated at offset '
                '$offset (packet: ${packet.length} bytes)');
          }
          final header = Smb2Header.decode(packet, offset);
          final next = header.nextCommand;
          final end = next > 0 ? offset + next : packet.length;
          if (next > 0 &&
              (end > packet.length || next < Smb2Header.size)) {
            throw FormatException('Invalid NextCommand=$next at offset '
                '$offset (packet: ${packet.length} bytes)');
          }
          final body =
              Uint8List.sublistView(packet, offset + Smb2Header.size, end);
          _dispatchResponse(header, body);
          if (next == 0) break;
          offset = end;
        }
      }
    } catch (e, st) {
      if (_running) {
        _log.severe('Receive loop error (mux@${hashCode.toRadixString(16)}): $e', e, st);
      }
    } finally {
      _running = false;
      // Close the transport so the socket doesn't linger when the loop
      // exits on a protocol error (desync). Idempotent: no-op when stop()
      // or the peer already closed it.
      try {
        await _connection.close();
      } catch (e, st) {
        _log.warning('Connection close error: $e', e, st);
      }
      _failEveryoneWaiting();
      _stopCompleter?.complete();
    }
  }

  /// Nobody is left waiting on a multiplexer that has stopped.
  ///
  /// Two kinds wait: a request that was sent and will now never be answered,
  /// and a send held back for credit that will now never be granted. Both have
  /// to be told, and this is the only place that tells them — a caller whose
  /// completer is quietly dropped waits for its own timeout, or forever if it
  /// has none. Runs on the way out whether that is an error or a stop().
  void _failEveryoneWaiting() {
    if (_pending.isEmpty && _budgetWaiters.isEmpty) return;
    final error = Smb2Exception(0, 'Connection closed');
    for (final pending in _pending.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pending.clear();
    for (final waiter in _budgetWaiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(error);
      }
    }
    _budgetWaiters.clear();
  }

  void _dispatchResponse(Smb2Header header, Uint8List body) {
    // Update credits from server grant
    if (header.creditRequestResponse > 0) {
      _availableCredits += header.creditRequestResponse;
    }

    // STATUS_PENDING: don't complete yet, wait for real response.
    // The interim response still carries a credit grant.
    if (header.status == NtStatus.pending) {
      _notifyBudgetWaiters();
      return;
    }

    final pending = _pending.remove(header.messageId);
    if (pending != null) {
      pending.completer.complete(Smb2Response(header, body));
    } else {
      _log.warning('Unexpected response for MessageId=${header.messageId}');
    }
    _notifyBudgetWaiters();
  }

  void _notifyBudgetWaiters() {
    // Wake all waiters and let each re-check via tryReserveBudget.
    // Required credits differ per waiter, so waking just one could leave
    // a satisfiable small request stuck behind an unsatisfiable large one.
    if (_budgetWaiters.isEmpty) return;
    final waiters = List.of(_budgetWaiters);
    _budgetWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  /// Stop the receive loop.
  Future<void> stop() async {
    if (!_running) return;
    _stopCompleter = Completer<void>();
    _running = false;
    await _connection.close();
    await _stopCompleter!.future;
  }
}
