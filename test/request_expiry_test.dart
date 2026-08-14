import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/protocol/status.dart';
import 'package:dart_smb2/src/transport/multiplexer.dart';
import 'package:dart_smb2/src/transport/sender.dart';

import 'fake_connection.dart';

/// What happens when a server stops answering.
///
/// [MS-SMB2]'s Request Expiration Timer says the client fails the request and
/// disconnects, because an unanswered request means the connection's state is
/// no longer known. These pin that, and pin the exception to it: a server that
/// says STATUS_PENDING is working, not silent, and must not be cut off.
///
/// The clock is virtual. The real limit is a minute, and shortening it for a
/// test would only turn the wait into a race with whatever else the machine
/// is doing (TEST-1).
void main() {
  const limit = Duration(seconds: 60);

  /// Run [body] with a mux whose requests expire after [limit], inside a
  /// virtual clock. Returns nothing: everything is asserted inside.
  void withMux(void Function(FakeAsync clock, FakeConnection conn,
          Smb2Multiplexer mux, Smb2Sender sender)
      body) {
    fakeAsync((clock) {
      final conn = FakeConnection();
      final mux = Smb2Multiplexer(conn, requestTimeout: limit);
      final sender = Smb2Sender(conn, mux);
      mux.startReceiveLoop();
      body(clock, conn, mux, sender);
      clock.flushMicrotasks();
    });
  }

  Future<Smb2Response> send(Smb2Sender sender) =>
      sender.send(Smb2Header(command: 0x0E), Uint8List(8));

  test('a request nobody answers fails, and says it was the waiting', () {
    withMux((clock, conn, mux, sender) {
      Object? failure;
      send(sender).catchError((Object e) {
        failure = e;
        return Smb2Response(Smb2Header(command: 0), Uint8List(0));
      });
      clock.elapse(limit - const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(failure, isNull, reason: 'gave up before the limit');

      clock.elapse(const Duration(seconds: 2));
      clock.flushMicrotasks();
      expect(failure, isA<Smb2TimeoutException>());
    });
  });

  test('giving up takes the connection with it', () {
    withMux((clock, conn, mux, sender) {
      send(sender).catchError((Object e) =>
          Smb2Response(Smb2Header(command: 0), Uint8List(0)));
      clock.elapse(limit + const Duration(seconds: 1));
      clock.flushMicrotasks();

      expect(conn.isClosed, isTrue);
      expect(mux.isRunning, isFalse);
    });
  });

  test('everything else in flight is told, rather than left waiting', () {
    withMux((clock, conn, mux, sender) {
      Object? second;
      send(sender).catchError((Object e) =>
          Smb2Response(Smb2Header(command: 0), Uint8List(0)));
      clock.flushMicrotasks();
      // The first response grants credits so the second can go out.
      conn.pushResponse(
          responseHeader(conn.sent[0].header, credits: 32), Uint8List(8));
      clock.flushMicrotasks();
      send(sender).catchError((Object e) {
        second = e;
        return Smb2Response(Smb2Header(command: 0), Uint8List(0));
      });
      clock.elapse(const Duration(seconds: 30));
      clock.flushMicrotasks();

      // The second request expires 30s after the first response arrived.
      clock.elapse(limit);
      clock.flushMicrotasks();
      expect(second, isNotNull);
    });
  });

  test('a server that says it is working keeps its connection', () {
    withMux((clock, conn, mux, sender) {
      Object? outcome;
      send(sender).then((r) => outcome = r).catchError((Object e) {
        outcome = e;
        return Smb2Response(Smb2Header(command: 0), Uint8List(0));
      });
      clock.elapse(const Duration(seconds: 30));
      clock.flushMicrotasks();

      conn.pushResponse(
        responseHeader(conn.sent[0].header, status: NtStatus.pending),
        Uint8List(8),
      );
      clock.flushMicrotasks();

      // Past the plain limit, and still waiting: the interim response moved
      // the deadline out to four times the limit, as Windows does.
      clock.elapse(limit + const Duration(seconds: 30));
      clock.flushMicrotasks();
      expect(outcome, isNull);
      expect(conn.isClosed, isFalse);

      conn.pushResponse(
          responseHeader(conn.sent[0].header), Uint8List(8));
      clock.flushMicrotasks();
      expect(outcome, isA<Smb2Response>());
    });
  });

  test('a pending request is not waited on forever either', () {
    withMux((clock, conn, mux, sender) {
      Object? failure;
      send(sender).catchError((Object e) {
        failure = e;
        return Smb2Response(Smb2Header(command: 0), Uint8List(0));
      });
      clock.flushMicrotasks();
      conn.pushResponse(
        responseHeader(conn.sent[0].header, status: NtStatus.pending),
        Uint8List(8),
      );
      clock.flushMicrotasks();

      clock.elapse(limit * 4 + const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(failure, isA<Smb2TimeoutException>());
    });
  });
}
