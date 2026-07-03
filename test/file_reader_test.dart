import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:dart_smb2/src/file/file_reader.dart';
import 'package:dart_smb2/src/protocol/commands.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/protocol/messages/create.dart';
import 'package:dart_smb2/src/transport/multiplexer.dart';
import 'package:dart_smb2/src/transport/sender.dart';

import 'fake_connection.dart';

const _maxReadSize = 10;

/// Encode an SMB2 Read response body carrying [data].
Uint8List _readResponseBody(Uint8List data) {
  final body = Uint8List(16 + data.length);
  final bd = ByteData.sublistView(body);
  bd.setUint16(0, 17, Endian.little); // StructureSize
  body[2] = Smb2Header.size + 16; // DataOffset (from header start)
  bd.setUint32(4, data.length, Endian.little); // DataLength
  body.setRange(16, 16 + data.length, data);
  return body;
}

/// Decode offset/length from an SMB2 Read request body.
({int offset, int length}) _parseReadRequest(Uint8List body) {
  final bd = ByteData.sublistView(body);
  return (
    length: bd.getUint32(4, Endian.little),
    offset: bd.getUint32(8, Endian.little) |
        (bd.getUint32(12, Endian.little) << 32),
  );
}

void main() {
  late FakeConnection conn;
  late Smb2Multiplexer mux;
  late Smb2Sender sender;
  final content = Uint8List.fromList([for (var i = 0; i < 100; i++) i & 0xFF]);

  setUp(() async {
    conn = FakeConnection();
    mux = Smb2Multiplexer(conn);
    sender = Smb2Sender(conn, mux);
    mux.startReceiveLoop();

    // Simulate the handshake: one request whose response grants a
    // comfortable credit balance, so read tests exercise the in-flight
    // pipeline rather than the credit ramp-up.
    final f = sender.send(Smb2Header(command: Smb2Command.echo), Uint8List(8));
    await pumpEventQueue();
    conn.pushResponse(
      responseHeader(conn.sent[0].header, credits: 256),
      Uint8List(8),
    );
    await f;
    conn.sent.clear();
  });

  tearDown(() async {
    await mux.stop();
  });

  Smb2FileReader reader({int fileSize = 100}) => Smb2FileReader(
        sender: sender,
        fileId: FileId(Uint8List(16)),
        fileSize: fileSize,
        sessionId: 1,
        treeId: 1,
        maxReadSize: _maxReadSize,
      );

  /// Auto-respond to Read requests with slices of [content].
  /// [truncateAtOffset] simulates a short read: the chunk starting at that
  /// offset returns only [truncateLength] bytes.
  /// [failAtOffset] makes that chunk fail with STATUS_ACCESS_DENIED.
  void autoRespond({int? truncateAtOffset, int truncateLength = 0, int? failAtOffset}) {
    conn.onSend = (header, body) {
      if (header.command != Smb2Command.read) return;
      final req = _parseReadRequest(body);
      if (req.offset == failAtOffset) {
        conn.pushResponse(
          responseHeader(header, status: 0xC0000022), // ACCESS_DENIED
          Uint8List(9),
        );
        return;
      }
      var end = req.offset + req.length;
      if (end > content.length) end = content.length;
      if (req.offset == truncateAtOffset) {
        end = req.offset + truncateLength;
      }
      conn.pushResponse(
        responseHeader(header),
        _readResponseBody(Uint8List.sublistView(content, req.offset, end)),
      );
    };
  }

  group('readRange (parallel split reads)', () {
    test('reassembles chunks correctly', () async {
      autoRespond();
      final data = await reader().readRange(0, 100);
      expect(data, content);
      // 100 bytes / 10-byte max read = 10 chunks
      expect(conn.sent.length, 10);
    });

    test('reassembles an unaligned sub-range', () async {
      autoRespond();
      final data = await reader().readRange(7, 55);
      expect(data, content.sublist(7, 62));
    });

    test('keeps up to readAhead requests in flight', () async {
      // Collect requests without responding.
      final pending = <Smb2Header>[];
      conn.onSend = (header, body) {
        if (header.command == Smb2Command.read) pending.add(header);
      };

      final future = reader().readRange(0, 100, readAhead: 4);
      await pumpEventQueue();
      // Pipeline is bounded by readAhead, not fully sequential (1)
      // and not unbounded (10).
      expect(pending.length, 4);

      // Responding to one lets the next chunk go out.
      conn.pushResponse(
        responseHeader(pending[0]),
        _readResponseBody(content.sublist(0, 10)),
      );
      await pumpEventQueue();
      expect(pending.length, 5);

      // Drain the rest.
      for (var i = 1; i < pending.length; i++) {
        final req = _parseReadRequest(
            conn.sent.firstWhere((p) => p.header.messageId == pending[i].messageId).body);
        conn.pushResponse(
          responseHeader(pending[i]),
          _readResponseBody(
              Uint8List.sublistView(content, req.offset, req.offset + req.length)),
        );
        await pumpEventQueue();
      }
      final data = await future;
      expect(data, content);
    });

    test('clamps to file size', () async {
      autoRespond();
      final data = await reader().readRange(90, 50);
      expect(data, content.sublist(90, 100));
    });

    test('returns empty for offset beyond file size', () async {
      autoRespond();
      final data = await reader().readRange(150, 10);
      expect(data, isEmpty);
      expect(conn.sent, isEmpty);
    });

    test('short chunk mid-range returns contiguous prefix', () async {
      // Chunk at offset 20 returns only 5 of 10 bytes.
      autoRespond(truncateAtOffset: 20, truncateLength: 5);
      final data = await reader().readRange(0, 100);
      expect(data, content.sublist(0, 25));
    });

    test('propagates a chunk error', () async {
      autoRespond(failAtOffset: 30);
      await expectLater(
        reader().readRange(0, 100),
        throwsA(isA<Smb2Exception>()),
      );
    });
  });

  group('readAll', () {
    test('streams the whole file', () async {
      autoRespond();
      final data = await reader().readAll();
      expect(data, content);
    });
  });
}
