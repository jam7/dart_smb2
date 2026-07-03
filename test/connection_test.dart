import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:dart_smb2/src/transport/connection.dart';

/// Wrap [payload] in a NetBIOS session frame.
Uint8List _frame(List<int> payload) {
  final frame = Uint8List(4 + payload.length);
  frame[1] = (payload.length >> 16) & 0xFF;
  frame[2] = (payload.length >> 8) & 0xFF;
  frame[3] = payload.length & 0xFF;
  frame.setRange(4, frame.length, payload);
  return frame;
}

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  group('Smb2Connection.readMessage', () {
    test('two messages in one chunk', () async {
      final ctrl = StreamController<Uint8List>();
      final conn = Smb2Connection.forTesting(ctrl.stream);
      ctrl.add(_bytes([..._frame([1, 2, 3]), ..._frame([4, 5])]));

      expect(await conn.readMessage(), [1, 2, 3]);
      expect(await conn.readMessage(), [4, 5]);
    });

    test('message split across chunks (mid-header and mid-body)', () async {
      final ctrl = StreamController<Uint8List>();
      final conn = Smb2Connection.forTesting(ctrl.stream);
      final whole = _frame(List.generate(10, (i) => i));
      // Split inside the NetBIOS header and inside the body.
      ctrl.add(Uint8List.sublistView(whole, 0, 2));
      ctrl.add(Uint8List.sublistView(whole, 2, 7));
      ctrl.add(Uint8List.sublistView(whole, 7));

      expect(await conn.readMessage(), List.generate(10, (i) => i));
    });

    test('skips NetBIOS keep-alive frames', () async {
      final ctrl = StreamController<Uint8List>();
      final conn = Smb2Connection.forTesting(ctrl.stream);
      ctrl.add(_bytes([0x85, 0, 0, 0, ..._frame([9, 9])]));

      expect(await conn.readMessage(), [9, 9]);
    });

    test('throws SocketException when the stream ends mid-message', () async {
      final ctrl = StreamController<Uint8List>();
      final conn = Smb2Connection.forTesting(ctrl.stream);
      ctrl.add(Uint8List.sublistView(_frame([1, 2, 3, 4]), 0, 5));
      unawaited(ctrl.close());

      expect(conn.readMessage(), throwsA(isA<SocketException>()));
    });

    test('throws FormatException on zero-length message', () async {
      final ctrl = StreamController<Uint8List>();
      final conn = Smb2Connection.forTesting(ctrl.stream);
      ctrl.add(_bytes([0, 0, 0, 0]));

      expect(conn.readMessage(), throwsA(isA<FormatException>()));
    });

    test('large message assembled from many small chunks', () async {
      final ctrl = StreamController<Uint8List>();
      final conn = Smb2Connection.forTesting(ctrl.stream);
      final payload = List.generate(100000, (i) => i & 0xFF);
      final whole = _frame(payload);
      for (var i = 0; i < whole.length; i += 1000) {
        final end = (i + 1000 > whole.length) ? whole.length : i + 1000;
        ctrl.add(Uint8List.sublistView(whole, i, end));
      }

      expect(await conn.readMessage(), payload);
    });

    test('sendRaw prepends the NetBIOS header', () async {
      final sent = <Uint8List>[];
      final conn = Smb2Connection.forTesting(
        const Stream.empty(),
        onSend: sent.add,
      );
      conn.sendRaw(_bytes([7, 8, 9]));

      expect(sent.single, [0, 0, 0, 3, 7, 8, 9]);
    });
  });
}
