import 'package:test/test.dart';
import 'package:dart_smb2/src/file/smb2_file.dart';

void main() {
  group('Smb2FileInfo', () {
    test('fileTimeToDateTime converts known timestamp', () {
      // 2024-01-01 00:00:00 UTC in FILETIME
      // Unix timestamp: 1704067200 seconds
      // FILETIME offset: 11644473600 seconds
      // Total: (1704067200 + 11644473600) * 10_000_000
      const unixSeconds = 1704067200;
      const fileTimeOffset = 116444736000000000; // 11644473600 * 10^7
      const fileTime = unixSeconds * 10000000 + fileTimeOffset;

      final dt = Smb2FileInfo.fileTimeToDateTime(fileTime);
      expect(dt, isNotNull);
      expect(dt!.year, 2024);
      expect(dt.month, 1);
      expect(dt.day, 1);
      expect(dt.hour, 0);
      expect(dt.isUtc, true);
    });

    test('fileTimeToDateTime returns null for zero', () {
      expect(Smb2FileInfo.fileTimeToDateTime(0), isNull);
    });

    test('isDirectory flag', () {
      final dir = Smb2FileInfo(name: 'dir', path: 'dir', size: 0, isDirectory: true);
      final file = Smb2FileInfo(name: 'f.txt', path: 'f.txt', size: 100, isDirectory: false);

      expect(dir.isDirectory, true);
      expect(file.isDirectory, false);
    });

    test('toString includes name and size', () {
      final info = Smb2FileInfo(name: 'test.jpg', path: 'test.jpg', size: 1024, isDirectory: false);
      final str = info.toString();
      expect(str, contains('test.jpg'));
      expect(str, contains('1024'));
    });
  });
}
