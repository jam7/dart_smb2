import 'package:test/test.dart';
import 'package:dart_smb2/src/transport/connection.dart';
import 'package:dart_smb2/src/transport/multiplexer.dart';

// Note: Full multiplexer testing requires a real TCP connection.
// These tests cover the synchronous parts of the multiplexer.

void main() {
  group('Smb2Exception', () {
    test('toString includes status description', () {
      final ex = Smb2Exception(0xC0000022, 'Access denied');
      expect(ex.toString(), contains('STATUS_ACCESS_DENIED'));
      expect(ex.toString(), contains('Access denied'));
    });

    test('toString formats unknown status as hex', () {
      final ex = Smb2Exception(0xDEADBEEF, 'Unknown error');
      expect(ex.toString(), contains('0xDEADBEEF'));
    });
  });

  group('Smb2Multiplexer.allocateMessageId', () {
    test('increments by 1 for creditCharge=1', () {
      final mux = _createMultiplexer();
      expect(mux.allocateMessageId(), 0);
      expect(mux.allocateMessageId(), 1);
      expect(mux.allocateMessageId(), 2);
    });

    test('skips IDs for creditCharge > 1', () {
      final mux = _createMultiplexer();
      expect(mux.allocateMessageId(), 0);
      expect(mux.allocateMessageId(creditCharge: 16), 1);
      expect(mux.allocateMessageId(), 17); // 1 + 16
    });

    test('handles creditCharge=0 as 1', () {
      final mux = _createMultiplexer();
      expect(mux.allocateMessageId(creditCharge: 0), 0);
      expect(mux.allocateMessageId(), 1);
    });

    test('multiple large charges accumulate correctly', () {
      final mux = _createMultiplexer();
      expect(mux.allocateMessageId(creditCharge: 4), 0);
      expect(mux.allocateMessageId(creditCharge: 8), 4);
      expect(mux.allocateMessageId(creditCharge: 1), 12);
      expect(mux.allocateMessageId(), 13);
    });
  });
}

/// Create a Smb2Multiplexer without a real connection (for unit testing
/// synchronous methods only).
Smb2Multiplexer _createMultiplexer() {
  // Pass a null-like connection — we only test allocateMessageId which
  // doesn't touch the connection.
  return _TestableMultiplexer();
}

class _TestableMultiplexer extends Smb2Multiplexer {
  _TestableMultiplexer() : super(_FakeConnection());
}

/// Minimal fake to satisfy the constructor. Never used in these tests.
class _FakeConnection implements Smb2Connection {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
