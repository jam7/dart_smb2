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
    // Split compound requests (chained via NextCommand) into one
    // `sent` entry per sub-request.
    var offset = 0;
    while (true) {
      final header = Smb2Header.decode(data, offset);
      final end =
          header.nextCommand > 0 ? offset + header.nextCommand : data.length;
      final body = Uint8List.sublistView(data, offset + Smb2Header.size, end);
      sent.add((header: header, body: body));
      onSend?.call(header, body);
      if (header.nextCommand == 0) break;
      offset = end;
    }
  }

  /// Queue a response packet for the receive loop.
  void pushResponse(Smb2Header header, Uint8List body) {
    final packet = Uint8List(Smb2Header.size + body.length);
    header.encode(packet, 0);
    packet.setRange(Smb2Header.size, packet.length, body);
    _incoming.add(packet);
  }

  /// Queue several responses compounded into a single transport packet,
  /// chained via NextCommand with 8-byte alignment.
  void pushCompoundResponse(List<(Smb2Header, Uint8List)> responses) {
    final sizes = <int>[];
    var total = 0;
    for (var i = 0; i < responses.length; i++) {
      final raw = Smb2Header.size + responses[i].$2.length;
      final padded = (i == responses.length - 1) ? raw : (raw + 7) & ~7;
      sizes.add(padded);
      total += padded;
    }
    final packet = Uint8List(total);
    var offset = 0;
    for (var i = 0; i < responses.length; i++) {
      final (header, body) = responses[i];
      header.nextCommand = (i == responses.length - 1) ? 0 : sizes[i];
      header.encode(packet, offset);
      packet.setRange(offset + Smb2Header.size,
          offset + Smb2Header.size + body.length, body);
      offset += sizes[i];
    }
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
    // Cancel the iterator like the real connection cancels its reader.
    // Awaiting _incoming.close() would deadlock when undelivered events
    // remain after the receive loop has already exited: the done event
    // is never delivered, so its future never completes.
    await _iter.cancel();
    unawaited(_incoming.close());
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
