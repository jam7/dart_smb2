import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:dart_smb2/src/client.dart';
import 'package:dart_smb2/src/protocol/commands.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/protocol/messages/create.dart';
import 'package:dart_smb2/src/protocol/messages/query_directory.dart';
import 'package:dart_smb2/src/protocol/status.dart';
import 'package:dart_smb2/src/transport/multiplexer.dart';
import 'package:dart_smb2/src/transport/sender.dart';

import 'fake_connection.dart';

Uint8List _utf16Le(String s) {
  final bytes = Uint8List(s.codeUnits.length * 2);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < s.codeUnits.length; i++) {
    bd.setUint16(i * 2, s.codeUnits[i], Endian.little);
  }
  return bytes;
}

/// One FileBothDirectoryInformation entry. [last] leaves NextEntryOffset 0.
Uint8List _dirEntry(String name, {required bool last}) {
  final nameBytes = _utf16Le(name);
  final size = 94 + nameBytes.length;
  final entry = Uint8List(size);
  final bd = ByteData.sublistView(entry);
  bd.setUint32(0, last ? 0 : size, Endian.little); // NextEntryOffset
  bd.setUint32(60, nameBytes.length, Endian.little); // FileNameLength
  entry.setRange(94, 94 + nameBytes.length, nameBytes);
  return entry;
}

/// QueryDirectory response body wrapping [entries].
Uint8List _queryDirResponseBody(List<Uint8List> entries) {
  final buffer = entries.expand<int>((e) => e).toList();
  final body = Uint8List(8 + buffer.length);
  final bd = ByteData.sublistView(body);
  bd.setUint16(0, 9, Endian.little); // StructureSize
  bd.setUint16(2, Smb2Header.size + 8, Endian.little); // OutputBufferOffset
  bd.setUint32(4, buffer.length, Endian.little); // OutputBufferLength
  body.setRange(8, body.length, buffer);
  return body;
}

/// Minimal valid CreateResponse body (80 bytes, zeroed FileId).
Uint8List _createResponseBody() {
  final body = Uint8List(80);
  ByteData.sublistView(body).setUint16(0, 89, Endian.little); // StructureSize
  return body;
}

void main() {
  group('QueryDirectoryRequest', () {
    QueryDirectoryRequest req(int bufLen) => QueryDirectoryRequest(
          fileId: FileId(Uint8List(16)),
          outputBufferLength: bufLen,
        );

    test('creditCharge is one per started 64KB block', () {
      expect(req(65536).buildHeader(sessionId: 1, treeId: 1).creditCharge, 1);
      expect(req(65537).buildHeader(sessionId: 1, treeId: 1).creditCharge, 2);
      expect(req(1048576).buildHeader(sessionId: 1, treeId: 1).creditCharge, 16);
    });

    test('encode writes OutputBufferLength', () {
      final body = req(1048576).encode();
      expect(
        ByteData.sublistView(body).getUint32(28, Endian.little),
        1048576,
      );
    });
  });

  group('Smb2Tree.listDirectory buffer size', () {
    late FakeConnection conn;
    late Smb2Multiplexer mux;
    late Smb2Sender sender;

    setUp(() async {
      conn = FakeConnection();
      mux = Smb2Multiplexer(conn);
      sender = Smb2Sender(conn, mux);
      mux.startReceiveLoop();

      final f =
          sender.send(Smb2Header(command: Smb2Command.echo), Uint8List(8));
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

    test('uses maxTransactSize and pages until noMoreFiles', () async {
      final tree = Smb2Tree.forTesting(
        sender: sender,
        sessionId: 1,
        treeId: 1,
        maxReadSize: 65536,
        maxTransactSize: 1048576,
        shareName: 'share',
      );

      var queryCount = 0;
      conn.onSend = (header, body) {
        switch (header.command) {
          case Smb2Command.create:
            conn.pushResponse(responseHeader(header), _createResponseBody());
          case Smb2Command.queryDirectory:
            queryCount++;
            switch (queryCount) {
              case 1:
                conn.pushResponse(
                  responseHeader(header),
                  _queryDirResponseBody([
                    _dirEntry('a.jpg', last: false),
                    _dirEntry('b.jpg', last: true),
                  ]),
                );
              case 2:
                conn.pushResponse(
                  responseHeader(header),
                  _queryDirResponseBody([_dirEntry('c.jpg', last: true)]),
                );
              default:
                conn.pushResponse(
                  responseHeader(header, status: NtStatus.noMoreFiles),
                  Uint8List(9),
                );
            }
          case Smb2Command.close:
            conn.pushResponse(responseHeader(header), Uint8List(60));
        }
      };

      final entries =
          await tree.listDirectory('/').timeout(const Duration(seconds: 5));
      expect(entries.map((e) => e.name), ['a.jpg', 'b.jpg', 'c.jpg']);

      final queries = conn.sent
          .where((p) => p.header.command == Smb2Command.queryDirectory)
          .toList();
      expect(queries, hasLength(3));
      for (final q in queries) {
        expect(q.header.creditCharge, 16);
        expect(
          ByteData.sublistView(q.body).getUint32(28, Endian.little),
          1048576,
        );
      }
    });
  });
}
