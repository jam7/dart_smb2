import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:dart_smb2/src/client.dart';
import 'package:dart_smb2/src/protocol/commands.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/protocol/status.dart';
import 'package:dart_smb2/src/transport/multiplexer.dart';
import 'package:dart_smb2/src/transport/sender.dart';

import 'fake_connection.dart';

/// Telling the caller that the server said it is still working.
///
/// The interim STATUS_PENDING already moved this request's deadline out (see
/// request_expiry_test.dart). What is pinned here is the other half: that the
/// news reaches whoever asked, and reaches nobody else. One connection
/// carries many operations at once, so "something is busy" would be useless
/// -- the caller has to know it is *their* request that is waiting.
void main() {
  const limit = Duration(seconds: 60);

  void withMux(
      void Function(FakeAsync clock, FakeConnection conn, Smb2Sender sender)
          body) {
    fakeAsync((clock) {
      final conn = FakeConnection();
      final mux = Smb2Multiplexer(conn, requestTimeout: limit);
      final sender = Smb2Sender(conn, mux);
      mux.startReceiveLoop();
      body(clock, conn, sender);
      clock.flushMicrotasks();
    });
  }

  Future<Smb2Response> send(Smb2Sender sender, {void Function()? onServerBusy}) =>
      sender.send(Smb2Header(command: 0x0E), Uint8List(8),
          onServerBusy: onServerBusy);

  /// Answer the request sent [nth] with an interim "still working".
  void serverSaysItIsBusy(FakeAsync clock, FakeConnection conn, int nth) {
    conn.pushResponse(
      responseHeader(conn.sent[nth].header, status: NtStatus.pending),
      Uint8List(8),
    );
    clock.flushMicrotasks();
  }

  test('the caller hears that the server is working on it', () {
    withMux((clock, conn, sender) {
      var told = 0;
      send(sender, onServerBusy: () => told++);
      clock.flushMicrotasks();
      expect(told, 0, reason: 'nothing has been said yet');

      serverSaysItIsBusy(clock, conn, 0);

      expect(told, 1);
    });
  });

  test('and hears again if the server says it twice', () {
    withMux((clock, conn, sender) {
      var told = 0;
      send(sender, onServerBusy: () => told++);
      clock.flushMicrotasks();

      serverSaysItIsBusy(clock, conn, 0);
      serverSaysItIsBusy(clock, conn, 0);

      expect(told, 2);
    });
  });

  test('only the request the server meant is told', () {
    withMux((clock, conn, sender) {
      // A connection starts with one credit, which one request spends, so a
      // second would queue rather than fly alongside it. Spend a throwaway
      // request first and let the answer grant the credits that let both of
      // the requests under test be in flight together -- which is the whole
      // point of asking who the server meant.
      send(sender);
      clock.flushMicrotasks();
      conn.pushResponse(responseHeader(conn.sent[0].header), Uint8List(8));
      clock.flushMicrotasks();

      var first = 0;
      var second = 0;
      send(sender, onServerBusy: () => first++);
      send(sender, onServerBusy: () => second++);
      clock.flushMicrotasks();
      expect(conn.sent.length, 3, reason: 'both are in flight at once');

      serverSaysItIsBusy(clock, conn, 2);

      expect(second, 1);
      expect(first, 0, reason: 'this one was never mentioned');
    });
  });

  test('a caller that throws does not take the connection down with it', () {
    withMux((clock, conn, sender) {
      Object? outcome;
      send(sender, onServerBusy: () => throw StateError('a bad listener'))
          .then((r) => outcome = r);
      clock.flushMicrotasks();

      serverSaysItIsBusy(clock, conn, 0);

      expect(conn.isClosed, isFalse);

      // And the request it belonged to still completes, since the throw was
      // in the telling and not in the work.
      conn.pushResponse(responseHeader(conn.sent[0].header), Uint8List(8));
      clock.flushMicrotasks();
      expect(outcome, isA<Smb2Response>());
    });
  });

  test('an operation hands its own argument down to the wire', () async {
    // The rest of this file works one message at a time, which is where the
    // routing lives. This one goes in by the front door instead: a caller
    // asks a named operation, and the argument has to survive every layer
    // between it and the response that triggers it.
    final conn = FakeConnection();
    final mux = Smb2Multiplexer(conn, requestTimeout: limit);
    final sender = Smb2Sender(conn, mux);
    mux.startReceiveLoop();
    addTearDown(mux.stop);

    final tree = Smb2Tree.forTesting(
      sender: sender,
      sessionId: 1,
      treeId: 1,
      maxReadSize: 65536,
      shareName: 'share',
    );

    var told = 0;
    conn.onSend = (header, body) {
      if (header.command == Smb2Command.create) {
        // Working on it, then the answer: the shape a slow open takes.
        conn.pushResponse(
            responseHeader(header, status: NtStatus.pending), Uint8List(8));
      }
      conn.pushResponse(
          responseHeader(header, status: NtStatus.accessDenied), Uint8List(9));
    };

    await expectLater(
        tree.listDirectory('/', onServerBusy: () => told++), throwsA(anything));
    expect(told, 1, reason: 'the argument reached the request that was made');
  });

  test('asking for no callback is still allowed', () {
    withMux((clock, conn, sender) {
      Object? outcome;
      send(sender).then((r) => outcome = r);
      clock.flushMicrotasks();

      serverSaysItIsBusy(clock, conn, 0);
      conn.pushResponse(responseHeader(conn.sent[0].header), Uint8List(8));
      clock.flushMicrotasks();

      expect(outcome, isA<Smb2Response>());
    });
  });
}
