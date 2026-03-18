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
  Completer<void>? _sendLock;

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

    // Wait for in-flight slot to prevent credit exhaustion
    await _multiplexer.acquireInflightSlot();

    // Allocate MessageId (reserves creditCharge consecutive IDs for SMB 2.1+)
    final messageId = _multiplexer.allocateMessageId(creditCharge: header.creditCharge);
    header.messageId = messageId;

    // Register before sending to avoid race
    final responseFuture = _multiplexer.registerRequest(messageId);

    // Serialize socket writes
    await _acquireSendLock();
    try {
      final packet = Uint8List(Smb2Header.size + body.length);
      header.encode(packet, 0);
      packet.setRange(Smb2Header.size, packet.length, body);
      _connection.sendRaw(packet);
    } finally {
      _releaseSendLock();
    }

    return responseFuture;
  }

  Future<void> _acquireSendLock() async {
    while (_sendLock != null) {
      await _sendLock!.future;
    }
    _sendLock = Completer<void>();
  }

  void _releaseSendLock() {
    final lock = _sendLock;
    _sendLock = null;
    lock?.complete();
  }
}
