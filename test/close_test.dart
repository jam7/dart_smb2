import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:dart_smb2/src/client.dart';
import 'package:dart_smb2/src/file/file_reader.dart';
import 'package:dart_smb2/src/protocol/commands.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/protocol/messages/create.dart';
import 'package:dart_smb2/src/protocol/status.dart';
import 'package:dart_smb2/src/transport/multiplexer.dart';
import 'package:dart_smb2/src/transport/sender.dart';

import 'fake_connection.dart';

/// Minimal valid CreateResponse body (80 bytes, zeroed FileId).
Uint8List _createResponseBody() {
  final body = Uint8List(80);
  ByteData.sublistView(body).setUint16(0, 89, Endian.little); // StructureSize
  return body;
}

void main() {
  late FakeConnection conn;
  late Smb2Multiplexer mux;
  late Smb2Sender sender;

  setUp(() async {
    conn = FakeConnection();
    mux = Smb2Multiplexer(conn);
    sender = Smb2Sender(conn, mux);
    mux.startReceiveLoop();

    // Simulate the handshake: one request whose response grants a
    // comfortable credit balance.
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

  Smb2FileReader reader() => Smb2FileReader(
        sender: sender,
        fileId: FileId(Uint8List(16)),
        fileSize: 100,
        sessionId: 1,
        treeId: 1,
        maxReadSize: 65536,
      );

  group('Smb2FileReader.close (fire-and-forget)', () {
    test('completes without waiting for the Close response', () async {
      // No response is ever pushed; close() must complete anyway.
      await reader().close().timeout(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(conn.sent, hasLength(1));
      expect(conn.sent[0].header.command, Smb2Command.close);
    });

    test('error response is logged, not thrown or unhandled', () async {
      await reader().close();
      await pumpEventQueue();
      conn.pushResponse(
        responseHeader(conn.sent[0].header, status: NtStatus.accessDenied),
        Uint8List(8),
      );
      // An unhandled async error would fail the test via the test zone.
      await pumpEventQueue();
    });

    test('connection loss after close() causes no unhandled error', () async {
      await reader().close();
      await pumpEventQueue();
      expect(conn.sent, hasLength(1));
      // Receive loop exit completes the pending Close with an error,
      // which must be absorbed by close()'s error handler.
      await mux.stop();
      await pumpEventQueue();
    });
  });

  group('Smb2Tree.listDirectory (fire-and-forget close)', () {
    test('returns entries without waiting for the Close response', () async {
      final tree = Smb2Tree.forTesting(
        sender: sender,
        sessionId: 1,
        treeId: 1,
        maxReadSize: 65536,
        shareName: 'share',
      );
      conn.onSend = (header, body) {
        switch (header.command) {
          case Smb2Command.create:
            conn.pushResponse(responseHeader(header), _createResponseBody());
          case Smb2Command.queryDirectory:
            conn.pushResponse(
              responseHeader(header, status: NtStatus.noMoreFiles),
              Uint8List(9),
            );
          case Smb2Command.close:
            break; // Never respond: listDirectory must not wait for it.
        }
      };

      final entries =
          await tree.listDirectory('/').timeout(const Duration(seconds: 5));
      expect(entries, isEmpty);
      expect(conn.sent.last.header.command, Smb2Command.close);
    });
  });
}
