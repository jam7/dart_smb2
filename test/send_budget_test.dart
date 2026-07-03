import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/transport/multiplexer.dart';
import 'package:dart_smb2/src/transport/sender.dart';

import 'fake_connection.dart';

void main() {
  late FakeConnection conn;
  late Smb2Multiplexer mux;
  late Smb2Sender sender;

  setUp(() {
    conn = FakeConnection();
    mux = Smb2Multiplexer(conn);
    sender = Smb2Sender(conn, mux);
    mux.startReceiveLoop();
  });

  tearDown(() async {
    await mux.stop();
  });

  /// Send a request with [charge] and return its response future.
  Future<Smb2Response> send({int charge = 0}) {
    final header = Smb2Header(command: 0x0D, creditCharge: charge);
    return sender.send(header, Uint8List(8));
  }

  /// Respond to the [index]-th sent request, granting [credits].
  void respond(int index, {int credits = 32, int status = 0}) {
    conn.pushResponse(
      responseHeader(conn.sent[index].header, credits: credits, status: status),
      Uint8List(8),
    );
  }

  group('credit gating', () {
    test('request waits until a response grants credits', () async {
      // Initial credit balance is 1: the first request consumes it.
      final f1 = send();
      await pumpEventQueue();
      expect(conn.sent.length, 1);
      expect(mux.availableCredits, 0);

      // Second request: 0 credits and one request in flight -> must wait.
      final f2 = send();
      await pumpEventQueue();
      expect(conn.sent.length, 1);

      // Response to the first grants credits -> second goes out.
      respond(0, credits: 10);
      await f1;
      await pumpEventQueue();
      expect(conn.sent.length, 2);
      expect(mux.availableCredits, 9); // 10 granted - 1 charged

      respond(1);
      await f2;
    });

    test('large request waits while smaller grants accumulate', () async {
      // Build up a balance first: 1 request, response grants 40.
      final f0 = send();
      await pumpEventQueue();
      respond(0, credits: 40);
      await f0;

      // Two charge-1 requests in flight: balance 40 - 2 = 38.
      final f1 = send();
      final f2 = send();
      await pumpEventQueue();
      expect(conn.sent.length, 3);
      expect(mux.availableCredits, 38);

      // Charge-50 request: insufficient balance, requests in flight -> waits.
      final f3 = send(charge: 50);
      await pumpEventQueue();
      expect(conn.sent.length, 3);

      // First response grants 2: balance 40, still < 50, one still in
      // flight -> keeps waiting.
      respond(1, credits: 2);
      await f1;
      await pumpEventQueue();
      expect(conn.sent.length, 3);

      // Second response grants 20: balance 60 >= 50 -> goes out.
      respond(2, credits: 20);
      await f2;
      await pumpEventQueue();
      expect(conn.sent.length, 4);
      expect(mux.availableCredits, 10);

      respond(3);
      await f3;
    });

    test('liveness fallback: sends despite insufficient credits when '
        'nothing is in flight', () async {
      // Balance is 1, charge is 16, nothing in flight -> send anyway.
      final f = send(charge: 16);
      await pumpEventQueue();
      expect(conn.sent.length, 1);
      expect(mux.availableCredits, 0); // clamped, not negative

      respond(0);
      await f;
    });

    test('interim STATUS_PENDING response grants credits to waiters',
        () async {
      final f1 = send();
      var f1Done = false;
      f1.whenComplete(() => f1Done = true).ignore();
      await pumpEventQueue();
      final f2 = send(charge: 5);
      await pumpEventQueue();
      expect(conn.sent.length, 1);

      // Interim response: grants credits but doesn't complete the request.
      conn.pushResponse(
        responseHeader(conn.sent[0].header, credits: 10, status: 0x00000103),
        Uint8List(8),
      );
      await pumpEventQueue();
      expect(conn.sent.length, 2); // waiter woken by the interim grant
      expect(f1Done, isFalse); // f1 itself is still pending

      respond(0);
      respond(1);
      await f1;
      await f2;
    });
  });

  group('in-flight cap', () {
    test('caps concurrent requests at maxInflight', () async {
      // Grant plenty of credits first.
      final f0 = send();
      await pumpEventQueue();
      respond(0, credits: 1000);
      await f0;

      final futures = [for (var i = 0; i < 40; i++) send()];
      await pumpEventQueue();
      // 1 handshake + 32 in flight (maxInflight), 8 waiting.
      expect(conn.sent.length, 33);

      respond(1);
      await pumpEventQueue();
      expect(conn.sent.length, 34);

      for (var i = 2; i < conn.sent.length; i++) {
        respond(i);
        await pumpEventQueue();
      }
      await Future.wait(futures);
      expect(conn.sent.length, 41);
    });
  });

  group('shutdown', () {
    test('budget waiters fail when the connection closes', () async {
      final f1 = send();
      await pumpEventQueue();
      final f2 = send(); // waiting for credits
      await pumpEventQueue();
      expect(conn.sent.length, 1);

      // Attach error expectations before stop() so the completeError
      // doesn't count as an unhandled async error.
      final expect1 = expectLater(f1, throwsA(isA<Smb2Exception>()));
      final expect2 = expectLater(f2, throwsA(isA<Smb2Exception>()));
      await mux.stop();
      await expect1;
      await expect2;
    });
  });
}
