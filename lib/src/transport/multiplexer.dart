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
/// - In-flight request count is capped at [maxInflight] to prevent
///   credit exhaustion and server overload
class Smb2Multiplexer {
  static final _log = Logger('Smb2Multiplexer');
  final Smb2Connection _connection;
  final int maxInflight;
  final Map<int, _PendingRequest> _pending = {};
  int _nextMessageId = 0;
  int _availableCredits = 1; // Start with 1, server grants more
  bool _running = false;
  Completer<void>? _stopCompleter;
  final List<Completer<void>> _inflightWaiters = [];

  Smb2Multiplexer(this._connection, {this.maxInflight = 32});

  int get availableCredits => _availableCredits;
  bool get isRunning => _running;
  bool get isInflightFull => _pending.length >= maxInflight;

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

  /// Wait until in-flight count is below [maxInflight].
  /// Throws [Smb2Exception] if the receive loop has stopped.
  Future<void> acquireInflightSlot() async {
    _checkRunning();
    while (_pending.length >= maxInflight) {
      final waiter = Completer<void>();
      _inflightWaiters.add(waiter);
      await waiter.future;
      _checkRunning();
    }
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

        final header = Smb2Header.decode(packet, 0);
        final body = Uint8List.sublistView(packet, Smb2Header.size);

        // Update credits from server grant
        if (header.creditRequestResponse > 0) {
          _availableCredits += header.creditRequestResponse;
        }

        // STATUS_PENDING: don't complete yet, wait for real response
        if (header.status == NtStatus.pending) {
          continue;
        }

        final pending = _pending.remove(header.messageId);
        if (pending != null) {
          pending.completer.complete(Smb2Response(header, body));
          _notifyInflightWaiters();
        } else {
          _log.warning('Unexpected response for MessageId=${header.messageId}');
        }
      }
    } catch (e, st) {
      if (_running) {
        _log.severe('Receive loop error (mux@${hashCode.toRadixString(16)}): $e', e, st);
      }
    } finally {
      _running = false;
      // Complete all pending requests with error so callers don't hang.
      // This covers both error (connection lost) and normal exit (stop).
      if (_pending.isNotEmpty || _inflightWaiters.isNotEmpty) {
        final error = Smb2Exception(0, 'Connection closed');
        for (final pending in _pending.values) {
          if (!pending.completer.isCompleted) {
            pending.completer.completeError(error);
          }
        }
        _pending.clear();
        for (final waiter in _inflightWaiters) {
          if (!waiter.isCompleted) {
            waiter.completeError(error);
          }
        }
        _inflightWaiters.clear();
      }
      _stopCompleter?.complete();
    }
  }

  void _notifyInflightWaiters() {
    // Wake one waiter per freed slot
    if (_inflightWaiters.isNotEmpty && _pending.length < maxInflight) {
      final waiter = _inflightWaiters.removeAt(0);
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
