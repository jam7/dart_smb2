import 'dart:async';
import 'dart:typed_data';

import '../protocol/commands.dart';
import '../protocol/header.dart';
import 'connection.dart';
import 'multiplexer.dart';

/// Serializes outgoing SMB2 messages through a mutex.
///
/// Only one send can happen at a time (TCP socket write protection),
/// but multiple requests can be in-flight simultaneously thanks to
/// the multiplexer dispatching responses by MessageId.
class Smb2Sender {
  final Smb2Connection _connection;
  final Smb2Multiplexer _multiplexer;
  bool _sending = false;
  final List<Completer<void>> _sendQueue = [];

  Smb2Sender(this._connection, this._multiplexer);

  /// Send an SMB2 request and return a Future that completes
  /// when the response arrives (via the multiplexer).
  ///
  /// [header] is the SMB2 header (will be assigned a MessageId).
  /// [body] is the command-specific payload after the header.
  Future<Smb2Response> send(Smb2Header header, Uint8List body) async {
    // Request credits
    if (header.creditRequestResponse == 0) {
      header.creditRequestResponse = 32; // Request 32 credits
    }
    if (header.creditCharge == 0) {
      header.creditCharge = 1;
    }

    // Acquire send lock, then reserve budget + allocate + register + write
    // atomically (no yield points between them).
    // If the budget (in-flight slot or credits) is exhausted, release the
    // lock, wait for a response to free budget, and retry.
    late final Future<Smb2Response> responseFuture;
    while (true) {
      await _acquireSendLock();
      if (!_multiplexer.tryReserveBudget(header.creditCharge)) {
        _releaseSendLock();
        await _multiplexer.waitForBudget();
        continue;
      }
      try {
        final messageId = _multiplexer.allocateMessageId(creditCharge: header.creditCharge);
        header.messageId = messageId;
        responseFuture = _multiplexer.registerRequest(messageId);

        final packet = Uint8List(Smb2Header.size + body.length);
        header.encode(packet, 0);
        packet.setRange(Smb2Header.size, packet.length, body);
        _connection.sendRaw(packet);
      } finally {
        _releaseSendLock();
      }
      break;
    }

    return responseFuture;
  }

  /// Send several requests as one compound (related operations) packet
  /// and return one response future per request, in order.
  ///
  /// The RELATED_OPERATIONS flag is set on every request after the first,
  /// so they inherit the preceding Create's FileId; callers put
  /// [FileId.related] sentinels in those requests. Budget (in-flight
  /// slots and credits) is reserved for the whole chain atomically.
  Future<List<Future<Smb2Response>>> sendCompound(
      List<(Smb2Header, Uint8List)> requests) async {
    if (requests.isEmpty || requests.length > _multiplexer.maxInflight) {
      throw ArgumentError('Compound of ${requests.length} requests '
          '(maxInflight: ${_multiplexer.maxInflight})');
    }

    var totalCharge = 0;
    for (final (header, _) in requests) {
      if (header.creditRequestResponse == 0) {
        header.creditRequestResponse = 32;
      }
      if (header.creditCharge == 0) {
        header.creditCharge = 1;
      }
      totalCharge += header.creditCharge;
    }

    while (true) {
      await _acquireSendLock();
      if (!_multiplexer.tryReserveBudget(totalCharge,
          slots: requests.length)) {
        _releaseSendLock();
        await _multiplexer.waitForBudget();
        continue;
      }
      try {
        // Each request except the last is padded to an 8-byte boundary;
        // NextCommand is the padded distance to the next header.
        final sizes = <int>[];
        var total = 0;
        for (var i = 0; i < requests.length; i++) {
          final raw = Smb2Header.size + requests[i].$2.length;
          final padded =
              (i == requests.length - 1) ? raw : (raw + 7) & ~7;
          sizes.add(padded);
          total += padded;
        }

        final packet = Uint8List(total);
        final futures = <Future<Smb2Response>>[];
        var offset = 0;
        for (var i = 0; i < requests.length; i++) {
          final (header, body) = requests[i];
          header.messageId = _multiplexer.allocateMessageId(
              creditCharge: header.creditCharge);
          if (i > 0) {
            header.flags |= Smb2Flags.relatedOperations;
          }
          header.nextCommand = (i == requests.length - 1) ? 0 : sizes[i];
          futures.add(_multiplexer.registerRequest(header.messageId));
          header.encode(packet, offset);
          packet.setRange(offset + Smb2Header.size,
              offset + Smb2Header.size + body.length, body);
          offset += sizes[i];
        }
        _connection.sendRaw(packet);
        return futures;
      } finally {
        _releaseSendLock();
      }
    }
  }

  Future<void> _acquireSendLock() async {
    if (!_sending) {
      _sending = true;
      return;
    }
    final waiter = Completer<void>();
    _sendQueue.add(waiter);
    await waiter.future;
  }

  void _releaseSendLock() {
    if (_sendQueue.isNotEmpty) {
      // Wake exactly one waiter (FIFO)
      _sendQueue.removeAt(0).complete();
    } else {
      _sending = false;
    }
  }
}
