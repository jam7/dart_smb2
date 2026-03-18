import 'dart:typed_data';

import '../header.dart';
import '../commands.dart';
import 'create.dart';

/// File information class for QueryDirectory.
class FileInformationClass {
  static const int fileBothDirectoryInformation = 0x03;
  static const int fileIdBothDirectoryInformation = 0x25;
}

/// QueryDirectory flags.
class QueryDirectoryFlags {
  static const int restartScans = 0x01;
  static const int returnSingleEntry = 0x02;
  static const int indexSpecified = 0x04;
  static const int reopen = 0x10;
}

/// SMB2 QueryDirectory request.
class QueryDirectoryRequest {
  static const int _fileNameOffset = 32;

  final FileId fileId;
  final String pattern;
  final int fileInformationClass;
  final int flags;
  final int outputBufferLength;

  QueryDirectoryRequest({
    required this.fileId,
    this.pattern = '*',
    this.fileInformationClass = FileInformationClass.fileBothDirectoryInformation,
    this.flags = 0,
    this.outputBufferLength = 65536,
  });

  Smb2Header buildHeader({required int sessionId, required int treeId}) {
    return Smb2Header(
      command: Smb2Command.queryDirectory,
      sessionId: sessionId,
      treeId: treeId,
    );
  }

  Uint8List encode() {
    final patternBytes = _encodeUtf16Le(pattern);
    final totalSize = _fileNameOffset + (patternBytes.isEmpty ? 1 : patternBytes.length);
    final body = Uint8List(totalSize);
    final data = ByteData.sublistView(body);

    data.setUint16(0, 33, Endian.little); // StructureSize
    body[2] = fileInformationClass; // FileInformationClass
    body[3] = flags; // Flags
    data.setUint32(4, 0, Endian.little); // FileIndex
    body.setRange(8, 24, fileId.bytes); // FileId (16 bytes)
    data.setUint16(24, Smb2Header.size + _fileNameOffset, Endian.little); // FileNameOffset
    data.setUint16(26, patternBytes.length, Endian.little); // FileNameLength
    data.setUint32(28, outputBufferLength, Endian.little); // OutputBufferLength

    if (patternBytes.isNotEmpty) {
      body.setRange(_fileNameOffset, _fileNameOffset + patternBytes.length, patternBytes);
    }
    return body;
  }

  static Uint8List _encodeUtf16Le(String s) {
    final units = s.codeUnits;
    final bytes = Uint8List(units.length * 2);
    final bd = ByteData.sublistView(bytes);
    for (int i = 0; i < units.length; i++) {
      bd.setUint16(i * 2, units[i], Endian.little);
    }
    return bytes;
  }
}

/// A single entry from FileBothDirectoryInformation.
class DirectoryEntry {
  final String fileName;
  final int fileAttributes;
  final int endOfFile;
  final int allocationSize;
  final int creationTime;
  final int lastAccessTime;
  final int lastWriteTime;
  final int changeTime;

  DirectoryEntry({
    required this.fileName,
    required this.fileAttributes,
    required this.endOfFile,
    required this.allocationSize,
    required this.creationTime,
    required this.lastAccessTime,
    required this.lastWriteTime,
    required this.changeTime,
  });

  bool get isDirectory => (fileAttributes & 0x10) != 0;
  bool get isHidden => (fileAttributes & 0x02) != 0;
}

/// Parse QueryDirectory response.
class QueryDirectoryResponse {
  static List<DirectoryEntry> decode(Uint8List body) {
    final data = ByteData.sublistView(body);
    // StructureSize(2) + OutputBufferOffset(2) + OutputBufferLength(4)
    final outputBufferOffset = data.getUint16(2, Endian.little) - Smb2Header.size;
    final outputBufferLength = data.getUint32(4, Endian.little);

    if (outputBufferLength == 0 || outputBufferOffset < 0) {
      return [];
    }

    return _parseEntries(
      Uint8List.sublistView(body, outputBufferOffset, outputBufferOffset + outputBufferLength),
    );
  }

  /// Parse FileBothDirectoryInformation entries from buffer.
  static List<DirectoryEntry> _parseEntries(Uint8List buffer) {
    final entries = <DirectoryEntry>[];
    int offset = 0;

    while (offset < buffer.length) {
      final data = ByteData.sublistView(buffer);
      final nextEntryOffset = data.getUint32(offset, Endian.little);

      final creationTime = _readUint64(data, offset + 8);
      final lastAccessTime = _readUint64(data, offset + 16);
      final lastWriteTime = _readUint64(data, offset + 24);
      final changeTime = _readUint64(data, offset + 32);
      final endOfFile = _readUint64(data, offset + 40);
      final allocationSize = _readUint64(data, offset + 48);
      final fileAttributes = data.getUint32(offset + 56, Endian.little);
      final fileNameLength = data.getUint32(offset + 60, Endian.little);
      // EaSize at offset+64 (4 bytes)
      // ShortNameLength at offset+68 (1 byte)
      // Reserved at offset+69 (1 byte)
      // ShortName at offset+70 (24 bytes)
      final fileNameStart = offset + 94; // 70 + 24

      String fileName = '';
      if (fileNameLength > 0 && fileNameStart + fileNameLength <= buffer.length) {
        fileName = _decodeUtf16Le(buffer, fileNameStart, fileNameLength);
      }

      entries.add(DirectoryEntry(
        fileName: fileName,
        fileAttributes: fileAttributes,
        endOfFile: endOfFile,
        allocationSize: allocationSize,
        creationTime: creationTime,
        lastAccessTime: lastAccessTime,
        lastWriteTime: lastWriteTime,
        changeTime: changeTime,
      ));

      if (nextEntryOffset == 0) break;
      offset += nextEntryOffset;
    }

    return entries;
  }

  static String _decodeUtf16Le(Uint8List buffer, int offset, int byteLength) {
    final data = ByteData.sublistView(buffer);
    final charCount = byteLength ~/ 2;
    final chars = <int>[];
    for (int i = 0; i < charCount; i++) {
      chars.add(data.getUint16(offset + i * 2, Endian.little));
    }
    return String.fromCharCodes(chars);
  }

  static int _readUint64(ByteData data, int offset) {
    return data.getUint32(offset, Endian.little) |
        (data.getUint32(offset + 4, Endian.little) << 32);
  }
}
