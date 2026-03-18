/// Represents a file or directory entry from an SMB2 share.
class Smb2FileInfo {
  final String name;
  final String path;
  final int size;
  final bool isDirectory;
  final bool isHidden;
  final DateTime? creationTime;
  final DateTime? lastWriteTime;
  final DateTime? lastAccessTime;

  Smb2FileInfo({
    required this.name,
    required this.path,
    required this.size,
    required this.isDirectory,
    this.isHidden = false,
    this.creationTime,
    this.lastWriteTime,
    this.lastAccessTime,
  });

  /// Convert FILETIME (100ns intervals since 1601-01-01) to DateTime.
  static DateTime? fileTimeToDateTime(int fileTime) {
    if (fileTime == 0) return null;
    // FILETIME epoch: 1601-01-01
    // Unix epoch:     1970-01-01
    // Difference: 11644473600 seconds = 116444736000000000 * 100ns
    const fileTimeToUnixDiff = 116444736000000000;
    final microseconds = (fileTime - fileTimeToUnixDiff) ~/ 10;
    if (microseconds < 0) return null;
    return DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);
  }

  @override
  String toString() =>
      'Smb2FileInfo(name: $name, size: $size, isDirectory: $isDirectory)';
}
