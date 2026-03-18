import 'dart:async';
import 'dart:typed_data';

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

    // Acquire send lock, then check in-flight + allocate + register + write
    // atomically (no yield points between them).
    // If in-flight is full, release lock, wait, and retry.
    late final Future<Smb2Response> responseFuture;
    while (true) {
      await _acquireSendLock();
      if (_multiplexer.isInflightFull) {
        _releaseSendLock();
        await _multiplexer.acquireInflightSlot();
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
