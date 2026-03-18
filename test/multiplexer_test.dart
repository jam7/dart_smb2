import 'package:test/test.dart';
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
}
