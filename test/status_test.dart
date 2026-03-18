import 'package:test/test.dart';
import 'package:dart_smb2/src/protocol/status.dart';

void main() {
  group('NtStatus', () {
    test('isSuccess for STATUS_SUCCESS', () {
      expect(NtStatus.isSuccess(NtStatus.success), true);
    });

    test('isSuccess for STATUS_PENDING', () {
      expect(NtStatus.isSuccess(NtStatus.pending), true);
    });

    test('isError for STATUS_ACCESS_DENIED', () {
      expect(NtStatus.isError(NtStatus.accessDenied), true);
    });

    test('isError for STATUS_LOGON_FAILURE', () {
      expect(NtStatus.isError(NtStatus.logonFailure), true);
    });

    test('isWarning for STATUS_NO_MORE_FILES', () {
      expect(NtStatus.isWarning(NtStatus.noMoreFiles), true);
      expect(NtStatus.isError(NtStatus.noMoreFiles), false);
    });

    test('isWarning for STATUS_BUFFER_OVERFLOW', () {
      expect(NtStatus.isWarning(NtStatus.bufferOverflow), true);
    });

    test('SUCCESS is not error or warning', () {
      expect(NtStatus.isError(NtStatus.success), false);
      expect(NtStatus.isWarning(NtStatus.success), false);
    });

    test('describe returns readable names', () {
      expect(NtStatus.describe(NtStatus.success), 'STATUS_SUCCESS');
      expect(NtStatus.describe(NtStatus.accessDenied), 'STATUS_ACCESS_DENIED');
      expect(NtStatus.describe(NtStatus.logonFailure), 'STATUS_LOGON_FAILURE');
    });

    test('describe returns hex for unknown status', () {
      expect(NtStatus.describe(0x12345678), '0x12345678');
    });
  });
}
