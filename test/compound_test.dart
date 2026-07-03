import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:dart_smb2/src/client.dart';
import 'package:dart_smb2/src/protocol/commands.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/protocol/status.dart';
import 'package:dart_smb2/src/transport/multiplexer.dart';
import 'package:dart_smb2/src/transport/sender.dart';

import 'fake_connection.dart';

/// Minimal valid CreateResponse body (80 bytes, zeroed FileId).
Uint8List _createResponseBody({int endOfFile = 1000}) {
  final body = Uint8List(80);
  final bd = ByteData.sublistView(body);
  bd.setUint16(0, 89, Endian.little); // StructureSize
  bd.setUint32(48, endOfFile, Endian.little); // EndOfFile
  return body;
}

/// SMB2 Read response body carrying [data].
Uint8List _readResponseBody(List<int> data) {
  final body = Uint8List(16 + data.length);
  final bd = ByteData.sublistView(body);
  bd.setUint16(0, 17, Endian.little); // StructureSize
  body[2] = Smb2Header.size + 16; // DataOffset (from header start)
  bd.setUint32(4, data.length, Endian.little); // DataLength
  body.setRange(16, body.length, data);
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

  Smb2Tree tree({int maxReadSize = 65536}) => Smb2Tree.forTesting(
        sender: sender,
        sessionId: 1,
        treeId: 1,
        maxReadSize: maxReadSize,
        shareName: 'share',
      );

  /// Auto-respond to the compound create/read/close, each as its own
  /// packet. Read returns [data]; [status] overrides all three when set.
  void autoRespond(List<int> data, {int? status}) {
    conn.onSend = (header, body) {
      final st = status ?? 0;
      switch (header.command) {
        case Smb2Command.create:
          conn.pushResponse(
              responseHeader(header, status: st), _createResponseBody());
        case Smb2Command.read:
          conn.pushResponse(
              responseHeader(header, status: st), _readResponseBody(data));
        case Smb2Command.close:
          conn.pushResponse(responseHeader(header, status: st), Uint8List(60));
      }
    };
  }

  group('Smb2Tree.readRange compound', () {
    test('wire format: related chain with sentinel FileIds', () async {
      autoRespond([1, 2, 3]);
      await tree().readRange('f.bin', offset: 0, length: 3);

      expect(conn.sent, hasLength(3));
      final (create, read, close) =
          (conn.sent[0], conn.sent[1], conn.sent[2]);

      expect(create.header.command, Smb2Command.create);
      expect(read.header.command, Smb2Command.read);
      expect(close.header.command, Smb2Command.close);

      // Related flag on everything after the first request.
      expect(create.header.flags & Smb2Flags.relatedOperations, 0);
      expect(read.header.flags & Smb2Flags.relatedOperations, isNot(0));
      expect(close.header.flags & Smb2Flags.relatedOperations, isNot(0));

      // NextCommand: 8-byte aligned chain, 0 on the last.
      expect(create.header.nextCommand % 8, 0);
      expect(create.header.nextCommand,
          greaterThanOrEqualTo(Smb2Header.size + create.body.length));
      expect(read.header.nextCommand % 8, 0);
      expect(close.header.nextCommand, 0);

      // MessageIds: consecutive, spaced by each request's creditCharge.
      expect(read.header.messageId,
          create.header.messageId + create.header.creditCharge);
      expect(close.header.messageId,
          read.header.messageId + read.header.creditCharge);

      // Read/Close carry the all-0xFF sentinel FileId.
      expect(read.body.sublist(16, 32), List.filled(16, 0xFF));
      expect(close.body.sublist(8, 24), List.filled(16, 0xFF));
    });

    test('returns data when responses arrive separately', () async {
      autoRespond([10, 20, 30, 40]);
      final data = await tree().readRange('f.bin', offset: 4, length: 4);
      expect(data, [10, 20, 30, 40]);
    });

    test('returns data when responses arrive compounded', () async {
      final requests = <Smb2Header>[];
      conn.onSend = (header, body) {
        requests.add(header);
        if (header.command == Smb2Command.close) {
          conn.pushCompoundResponse([
            (responseHeader(requests[0]), _createResponseBody()),
            (responseHeader(requests[1]), _readResponseBody([5, 6])),
            (responseHeader(requests[2]), Uint8List(60)),
          ]);
        }
      };
      final data = await tree().readRange('f.bin', offset: 0, length: 2);
      expect(data, [5, 6]);
    });

    test('throws on Create failure without unhandled errors', () async {
      autoRespond([], status: NtStatus.accessDenied);
      expect(
        () => tree().readRange('f.bin', offset: 0, length: 3),
        throwsA(isA<Smb2Exception>()
            .having((e) => e.status, 'status', NtStatus.accessDenied)),
      );
      await pumpEventQueue();
    });

    test('read at EOF returns empty data', () async {
      conn.onSend = (header, body) {
        switch (header.command) {
          case Smb2Command.create:
            conn.pushResponse(responseHeader(header), _createResponseBody());
          case Smb2Command.read:
            conn.pushResponse(
                responseHeader(header, status: NtStatus.endOfFile),
                Uint8List(16));
          case Smb2Command.close:
            conn.pushResponse(responseHeader(header), Uint8List(60));
        }
      };
      final data = await tree().readRange('f.bin', offset: 999, length: 4);
      expect(data, isEmpty);
    });

    test('ranges above maxReadSize use the non-compound path', () async {
      // maxReadSize=8, length=20: expect a plain Create (no related flag,
      // NextCommand=0) followed by split reads and a close.
      conn.onSend = (header, body) {
        switch (header.command) {
          case Smb2Command.create:
            conn.pushResponse(responseHeader(header), _createResponseBody());
          case Smb2Command.read:
            final len = ByteData.sublistView(body).getUint32(4, Endian.little);
            conn.pushResponse(responseHeader(header),
                _readResponseBody(List.filled(len, 7)));
          case Smb2Command.close:
            conn.pushResponse(responseHeader(header), Uint8List(60));
        }
      };
      final data =
          await tree(maxReadSize: 8).readRange('f.bin', offset: 0, length: 20);
      expect(data, List.filled(20, 7));
      expect(conn.sent[0].header.command, Smb2Command.create);
      expect(conn.sent[0].header.nextCommand, 0);
      expect(
        conn.sent.any(
            (p) => p.header.flags & Smb2Flags.relatedOperations != 0),
        isFalse,
      );
    });
  });

  group('sendCompound budget', () {
    test('waits until the credit balance covers the total charge', () async {
      // Fresh transport without the generous handshake grant.
      final conn2 = FakeConnection();
      final mux2 = Smb2Multiplexer(conn2);
      final sender2 = Smb2Sender(conn2, mux2);
      mux2.startReceiveLoop();

      // One in-flight request consumes the initial single credit.
      final echoF =
          sender2.send(Smb2Header(command: Smb2Command.echo), Uint8List(8));
      await pumpEventQueue();
      expect(conn2.sent, hasLength(1));

      // Compound (total charge 3) must wait: balance 0, one in flight.
      final tree2 = Smb2Tree.forTesting(
        sender: sender2,
        sessionId: 1,
        treeId: 1,
        maxReadSize: 65536,
        shareName: 'share',
      );
      conn2.onSend = (header, body) {
        switch (header.command) {
          case Smb2Command.create:
            conn2.pushResponse(responseHeader(header), _createResponseBody());
          case Smb2Command.read:
            conn2.pushResponse(
                responseHeader(header), _readResponseBody([1]));
          case Smb2Command.close:
            conn2.pushResponse(responseHeader(header), Uint8List(60));
        }
      };
      final rangeF = tree2.readRange('f.bin', offset: 0, length: 1);
      await pumpEventQueue();
      expect(conn2.sent, hasLength(1),
          reason: 'compound must not send with zero credit balance');

      // The echo response grants credits and unblocks the compound.
      conn2.pushResponse(
          responseHeader(conn2.sent[0].header, credits: 32), Uint8List(8));
      await echoF;
      expect(await rangeF, [1]);
      expect(conn2.sent, hasLength(4));

      await mux2.stop();
    });
  });
}
