import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:dart_smb2/src/client.dart';
import 'package:dart_smb2/src/protocol/commands.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/protocol/messages/create.dart';
import 'package:dart_smb2/src/protocol/messages/write.dart';
import 'package:dart_smb2/src/protocol/status.dart';
import 'package:dart_smb2/src/transport/multiplexer.dart';
import 'package:dart_smb2/src/transport/sender.dart';

import 'fake_connection.dart';

/// Putting a new file on a share, against a scripted server.
///
/// What a fake server cannot say is whether the bytes really arrived; that
/// belongs to the integration test, which reads the file back. What it can
/// say is what went on the wire -- which disposition was asked for, where
/// each block was addressed, how many there were -- and those are the
/// decisions this file pins.
Uint8List _createResponseBody() {
  final body = Uint8List(80);
  ByteData.sublistView(body).setUint16(0, 89, Endian.little); // StructureSize
  return body;
}

/// A Write response saying [count] bytes were taken.
Uint8List _writeResponseBody(int count) {
  final body = Uint8List(16);
  final bd = ByteData.sublistView(body);
  bd.setUint16(0, 17, Endian.little); // StructureSize
  bd.setUint32(4, count, Endian.little); // Count
  return body;
}

void main() {
  const maxWrite = 1024;

  late FakeConnection conn;
  late Smb2Multiplexer mux;
  late Smb2Tree tree;

  /// The Write requests that reached the wire, decoded into what they say
  /// about themselves.
  List<({int offset, int length})> writes() => conn.sent
      .where((p) => p.header.command == Smb2Command.write)
      .map((p) {
        final bd = ByteData.sublistView(p.body);
        return (
          offset: bd.getUint32(8, Endian.little),
          length: bd.getUint32(4, Endian.little),
        );
      })
      .toList();

  setUp(() {
    conn = FakeConnection();
    mux = Smb2Multiplexer(conn, requestTimeout: const Duration(seconds: 60));
    final sender = Smb2Sender(conn, mux);
    mux.startReceiveLoop();
    tree = Smb2Tree.forTesting(
      sender: sender,
      sessionId: 1,
      treeId: 1,
      maxReadSize: 65536,
      maxWriteSize: maxWrite,
      shareName: 'share',
    );
  });

  tearDown(() async => mux.stop());

  /// A server that agrees to everything, taking every byte it is offered.
  void serverAgrees() {
    conn.onSend = (header, body) {
      switch (header.command) {
        case Smb2Command.create:
          conn.pushResponse(responseHeader(header), _createResponseBody());
        case Smb2Command.write:
          final asked = ByteData.sublistView(body).getUint32(4, Endian.little);
          conn.pushResponse(responseHeader(header), _writeResponseBody(asked));
        case Smb2Command.close:
          conn.pushResponse(responseHeader(header), Uint8List(60));
      }
    };
  }

  Uint8List bytes(int length, {int fill = 0xAB}) =>
      Uint8List.fromList(List.filled(length, fill));

  // T-01: S-01 the create asks for a file that is not there
  test('creating asks the server to fail if the name is taken', () async {
    serverAgrees();

    await tree.createNew('books/vol2.zip');

    final create =
        conn.sent.firstWhere((p) => p.header.command == Smb2Command.create);
    final bd = ByteData.sublistView(create.body);

    expect(bd.getUint32(36, Endian.little), CreateDisposition.fileCreate,
        reason: 'anything else could open or overwrite what is there');
    expect(bd.getUint32(32, Endian.little), ShareAccess.read,
        reason: 'others may read it while it is being written, nothing more');
  });

  // T-02: S-01, S-04 a refused create throws, carrying the reason
  test('a name already taken comes back as the collision it was', () async {
    conn.onSend = (header, body) => conn.pushResponse(
        responseHeader(header, status: NtStatus.objectNameCollision),
        Uint8List(80));

    await expectLater(
      tree.createNew('books/vol2.zip'),
      throwsA(isA<Smb2Exception>()
          .having((e) => e.status, 'status', NtStatus.objectNameCollision)),
    );
  });

  // T-03: S-02 what is handed over lands in order, end to end
  test('three writes land one after another', () async {
    serverAgrees();
    final w = await tree.createNew('books/vol2.zip');

    await w.write(bytes(10));
    await w.write(bytes(20));
    await w.write(bytes(30));

    expect(writes(), [
      (offset: 0, length: 10),
      (offset: 10, length: 20),
      (offset: 30, length: 30),
    ]);
  });

  // T-04: S-02 a file with nothing in it is still a file
  test('closing without writing sends no write at all', () async {
    serverAgrees();
    final w = await tree.createNew('books/vol2.zip');

    await w.close();

    expect(writes(), isEmpty);
    expect(conn.sent.where((p) => p.header.command == Smb2Command.close).length,
        1);
  });

  // T-05: S-02 an empty write is not a write
  test('an empty buffer moves nothing', () async {
    serverAgrees();
    final w = await tree.createNew('books/vol2.zip');

    await w.write(bytes(10));
    await w.write(Uint8List(0));
    await w.write(bytes(10));

    expect(writes(), [(offset: 0, length: 10), (offset: 10, length: 10)]);
  });

  // T-06: S-02 the file is finished when it is closed
  test('writing after close is refused', () async {
    serverAgrees();
    final w = await tree.createNew('books/vol2.zip');
    await w.close();

    expect(() => w.write(bytes(10)), throwsStateError);
    expect(writes(), isEmpty);
  });

  // T-07: S-02 closing twice is not an error
  test('closing twice sends one close', () async {
    serverAgrees();
    final w = await tree.createNew('books/vol2.zip');

    await w.close();
    await w.close();

    expect(conn.sent.where((p) => p.header.command == Smb2Command.close).length,
        1);
  });

  // T-08: S-03 one byte over the limit is two requests, not one
  test('a buffer over the limit is split, and the pieces join up', () async {
    serverAgrees();
    final w = await tree.createNew('books/vol2.zip');

    await w.write(bytes(maxWrite + 1));

    expect(writes(), [
      (offset: 0, length: maxWrite),
      (offset: maxWrite, length: 1),
    ]);
  });

  // T-09: S-03 exactly the limit is one request -- the other end of T-08
  test('a buffer exactly at the limit is one request', () async {
    serverAgrees();
    final w = await tree.createNew('books/vol2.zip');

    await w.write(bytes(maxWrite));

    expect(writes(), [(offset: 0, length: maxWrite)]);
  });

  // T-10: S-05 the count is what the server admitted to
  test('what was written is the sum of what the server took', () async {
    serverAgrees();
    final w = await tree.createNew('books/vol2.zip');

    await w.write(bytes(10));
    await w.write(bytes(maxWrite + 5));
    await w.close();

    expect(w.written, 10 + maxWrite + 5);
  });

  // T-11: S-05, D-05 a broken write stops there, and says where it stopped
  test('a failed block leaves the count at what got through', () async {
    var writesSeen = 0;
    conn.onSend = (header, body) {
      switch (header.command) {
        case Smb2Command.create:
          conn.pushResponse(responseHeader(header), _createResponseBody());
        case Smb2Command.write:
          writesSeen++;
          final asked = ByteData.sublistView(body).getUint32(4, Endian.little);
          // The second block is refused: the file now has a hole.
          conn.pushResponse(
              responseHeader(header,
                  status: writesSeen == 2 ? NtStatus.accessDenied : 0),
              _writeResponseBody(writesSeen == 2 ? 0 : asked));
        case Smb2Command.close:
          conn.pushResponse(responseHeader(header), Uint8List(60));
      }
    };
    final w = await tree.createNew('books/vol2.zip');

    await expectLater(w.write(bytes(maxWrite * 2)), throwsA(isA<Smb2Exception>()));

    expect(w.written, maxWrite, reason: 'the first block, and only that');
    expect(() => w.write(bytes(10)), throwsStateError,
        reason: 'writing on would put bytes after a gap');
    expect(writes().length, 2, reason: 'the refused write was not retried');
  });

  // T-19: S-02, S-05 a server that takes less than it was offered
  test('what a server did not take is sent again, not skipped', () async {
    // Takes half of whatever it is given, twice, then all of it. A server
    // may do this; the writer must not treat the missing half as written.
    var writesSeen = 0;
    conn.onSend = (header, body) {
      switch (header.command) {
        case Smb2Command.create:
          conn.pushResponse(responseHeader(header), _createResponseBody());
        case Smb2Command.write:
          final asked = ByteData.sublistView(body).getUint32(4, Endian.little);
          writesSeen++;
          final takes = writesSeen <= 2 ? asked ~/ 2 : asked;
          conn.pushResponse(responseHeader(header), _writeResponseBody(takes));
        case Smb2Command.close:
          conn.pushResponse(responseHeader(header), Uint8List(60));
      }
    };
    final w = await tree.createNew('books/vol2.zip');

    await w.write(bytes(100));

    expect(writes(), [
      (offset: 0, length: 100),
      (offset: 50, length: 50),
      (offset: 75, length: 25),
    ], reason: 'each retry starts where the last one really stopped');
    expect(w.written, 100, reason: 'and every byte is accounted for once');
  });

  // T-20: S-05, D-05 a server that takes nothing is not looped over
  test('a server that takes nothing stops the writer', () async {
    conn.onSend = (header, body) {
      switch (header.command) {
        case Smb2Command.create:
          conn.pushResponse(responseHeader(header), _createResponseBody());
        case Smb2Command.write:
          conn.pushResponse(responseHeader(header), _writeResponseBody(0));
        case Smb2Command.close:
          conn.pushResponse(responseHeader(header), Uint8List(60));
      }
    };
    final w = await tree.createNew('books/vol2.zip');

    await expectLater(w.write(bytes(100)), throwsStateError);

    expect(writes().length, 1, reason: 'it was not asked a second time');
    expect(w.written, 0);
    expect(() => w.write(bytes(10)), throwsStateError);
  });

  // T-12: D-02 the request says where its data starts, counted from the header
  test('the data offset is measured from the start of the header', () {
    final req = WriteRequest(
        fileId: FileId(Uint8List(16)), offset: 0, data: bytes(4));

    final bd = ByteData.sublistView(req.encode());

    expect(bd.getUint16(0, Endian.little), 49, reason: 'StructureSize');
    expect(bd.getUint16(2, Endian.little), Smb2Header.size + 48,
        reason: 'DataOffset counts the header too');
  });

  // T-13: D-02 a big write costs credits by the block it starts
  test('one credit is charged per started 64KB', () {
    WriteRequest req(int length) => WriteRequest(
        fileId: FileId(Uint8List(16)), offset: 0, data: bytes(length));

    expect(req(65536).buildHeader(sessionId: 1, treeId: 1).creditCharge, 1);
    expect(req(65537).buildHeader(sessionId: 1, treeId: 1).creditCharge, 2);
  });
}
