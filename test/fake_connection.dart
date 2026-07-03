import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/transport/connection.dart';

/// A scripted in-memory connection for testing the transport stack
/// (multiplexer + sender + readers) without a real server.
class FakeConnection implements Smb2Connection {
  final _incoming = StreamController<Uint8List>();
  late final StreamIterator<Uint8List> _iter = StreamIterator(_incoming.stream);
  bool _closed = false;

  /// All packets sent by the client, decoded into header + body.
  final sent = <({Smb2Header header, Uint8List body})>[];

  /// Called synchronously for each sent packet. Use to auto-respond.
  void Function(Smb2Header header, Uint8List body)? onSend;

  @override
  bool get isClosed => _closed;

  @override
  void sendRaw(Uint8List data) {
    final header = Smb2Header.decode(data, 0);
    final body = Uint8List.sublistView(data, Smb2Header.size);
    sent.add((header: header, body: body));
    onSend?.call(header, body);
  }

  /// Queue a response packet for the receive loop.
  void pushResponse(Smb2Header header, Uint8List body) {
    final packet = Uint8List(Smb2Header.size + body.length);
    header.encode(packet, 0);
    packet.setRange(Smb2Header.size, packet.length, body);
    _incoming.add(packet);
  }

  @override
  Future<Uint8List> readMessage() async {
    if (!await _iter.moveNext()) {
      throw const SocketException('Connection closed');
    }
    return _iter.current;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}

/// Build a response header for [request] granting [credits].
Smb2Header responseHeader(
  Smb2Header request, {
  int credits = 32,
  int status = 0,
}) {
  return Smb2Header(
    command: request.command,
    messageId: request.messageId,
    creditRequestResponse: credits,
    status: status,
  );
}
