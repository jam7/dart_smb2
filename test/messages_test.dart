import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/protocol/commands.dart';
import 'package:dart_smb2/src/protocol/messages/negotiate.dart';
import 'package:dart_smb2/src/protocol/messages/session_setup.dart';
import 'package:dart_smb2/src/protocol/messages/tree_connect.dart';
import 'package:dart_smb2/src/protocol/messages/create.dart';
import 'package:dart_smb2/src/protocol/messages/read.dart';
import 'package:dart_smb2/src/protocol/messages/close.dart';
import 'package:dart_smb2/src/protocol/messages/query_directory.dart';

void main() {
  group('NegotiateRequest', () {
    test('encodes correct StructureSize (36)', () {
      final req = NegotiateRequest();
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(0, Endian.little), 36);
    });

    test('encodes correct dialect count', () {
      final req = NegotiateRequest(
        dialects: [Smb2Dialect.smb202, Smb2Dialect.smb210, Smb2Dialect.smb300],
      );
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(2, Endian.little), 3);
    });

    test('encodes dialect values correctly', () {
      final req = NegotiateRequest(
        dialects: [Smb2Dialect.smb202, Smb2Dialect.smb210],
      );
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(36, Endian.little), 0x0202);
      expect(bd.getUint16(38, Endian.little), 0x0210);
    });

    test('body size = 36 + 2 * dialectCount', () {
      final req = NegotiateRequest(dialects: [Smb2Dialect.smb202]);
      expect(req.encode().length, 38); // 36 + 2

      final req3 = NegotiateRequest();
      expect(req3.encode().length, 42); // 36 + 6
    });

    test('buildHeader sets negotiate command', () {
      final req = NegotiateRequest();
      final header = req.buildHeader();
      expect(header.command, Smb2Command.negotiate);
    });
  });

  group('NegotiateResponse', () {
    test('decode extracts dialect and max sizes', () {
      final body = _buildNegotiateResponse(
        dialect: Smb2Dialect.smb210,
        maxReadSize: 1048576,
        maxWriteSize: 1048576,
        maxTransactSize: 65536,
      );
      final resp = NegotiateResponse.decode(body);

      expect(resp.dialectRevision, Smb2Dialect.smb210);
      expect(resp.maxReadSize, 1048576);
      expect(resp.maxWriteSize, 1048576);
      expect(resp.maxTransactSize, 65536);
    });

    test('decode extracts empty security buffer when length=0', () {
      final body = _buildNegotiateResponse(
        dialect: Smb2Dialect.smb202,
        securityBufferLength: 0,
      );
      final resp = NegotiateResponse.decode(body);
      expect(resp.securityBuffer, isEmpty);
    });
  });

  group('SessionSetupRequest', () {
    test('encodes StructureSize = 25', () {
      final req = SessionSetupRequest(securityBuffer: Uint8List(10));
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(0, Endian.little), 25);
    });

    test('encodes security buffer length', () {
      final secBuf = Uint8List(100);
      final req = SessionSetupRequest(securityBuffer: secBuf);
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(14, Endian.little), 100);
    });

    test('security buffer is placed at correct offset', () {
      final secBuf = Uint8List.fromList([0xAA, 0xBB, 0xCC]);
      final req = SessionSetupRequest(securityBuffer: secBuf);
      final body = req.encode();

      // Buffer at offset 24 from body start
      expect(body[24], 0xAA);
      expect(body[25], 0xBB);
      expect(body[26], 0xCC);
    });
  });

  group('TreeConnectRequest', () {
    test('encodes StructureSize = 9', () {
      final req = TreeConnectRequest(path: '\\\\server\\share');
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(0, Endian.little), 9);
    });

    test('encodes path as UTF-16LE', () {
      final req = TreeConnectRequest(path: 'AB');
      final body = req.encode();
      // Path starts at offset 8
      // 'A' = 0x41, 'B' = 0x42 in UTF-16LE
      expect(body[8], 0x41);
      expect(body[9], 0x00);
      expect(body[10], 0x42);
      expect(body[11], 0x00);
    });

    test('encodes path length in bytes (UTF-16)', () {
      final req = TreeConnectRequest(path: 'ABC');
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(6, Endian.little), 6); // 3 chars * 2 bytes
    });
  });

  group('CreateRequest', () {
    test('encodes StructureSize = 57', () {
      final req = CreateRequest(fileName: 'test.txt');
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(0, Endian.little), 57);
    });

    test('encodes desired access', () {
      final req = CreateRequest(
        fileName: 'test.txt',
        desiredAccess: AccessMask.genericRead,
      );
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint32(24, Endian.little), AccessMask.genericRead);
    });

    test('encodes file name as UTF-16LE', () {
      final req = CreateRequest(fileName: 'a');
      final body = req.encode();
      // Name at offset 56
      expect(body[56], 0x61); // 'a'
      expect(body[57], 0x00);
    });

    test('encodes name length correctly', () {
      final req = CreateRequest(fileName: 'test');
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(46, Endian.little), 8); // 4 chars * 2 bytes
    });
  });

  group('CreateResponse', () {
    test('decode extracts fileId and endOfFile', () {
      final body = _buildCreateResponse(
        endOfFile: 1048576,
        fileId: List.generate(16, (i) => i + 0x10),
      );
      final resp = CreateResponse.decode(body);
      expect(resp.endOfFile, 1048576);
      expect(resp.fileId.bytes, List.generate(16, (i) => i + 0x10));
    });
  });

  group('ReadRequest', () {
    test('encodes StructureSize = 49', () {
      final req = ReadRequest(
        fileId: FileId(Uint8List(16)),
        offset: 0,
        length: 65536,
      );
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(0, Endian.little), 49);
    });

    test('encodes offset and length correctly', () {
      final req = ReadRequest(
        fileId: FileId(Uint8List(16)),
        offset: 1000,
        length: 2000,
      );
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint32(4, Endian.little), 2000); // Length
      expect(bd.getUint32(8, Endian.little), 1000); // Offset low
    });

    test('encodes fileId', () {
      final fid = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final req = ReadRequest(
        fileId: FileId(fid),
        offset: 0,
        length: 100,
      );
      final body = req.encode();
      expect(body.sublist(16, 32), fid);
    });
  });

  group('CloseRequest', () {
    test('encodes StructureSize = 24', () {
      final req = CloseRequest(fileId: FileId(Uint8List(16)));
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(0, Endian.little), 24);
    });

    test('encodes fileId at offset 8', () {
      final fid = Uint8List.fromList(List.generate(16, (i) => 0xAA));
      final req = CloseRequest(fileId: FileId(fid));
      final body = req.encode();
      expect(body.sublist(8, 24), fid);
    });
  });

  group('QueryDirectoryRequest', () {
    test('encodes StructureSize = 33', () {
      final req = QueryDirectoryRequest(fileId: FileId(Uint8List(16)));
      final body = req.encode();
      final bd = ByteData.sublistView(body);
      expect(bd.getUint16(0, Endian.little), 33);
    });

    test('default pattern is * encoded as UTF-16LE', () {
      final req = QueryDirectoryRequest(fileId: FileId(Uint8List(16)));
      final body = req.encode();
      // Pattern at offset 32
      expect(body[32], 0x2A); // '*'
      expect(body[33], 0x00);
    });
  });

  group('QueryDirectoryResponse', () {
    test('parses single FileBothDirectoryInformation entry', () {
      final buffer = _buildDirectoryEntries([
        ('hello.txt', 12345, 0x20), // Archive file
      ]);
      final responseBody = _wrapQueryDirResponse(buffer);
      final entries = QueryDirectoryResponse.decode(responseBody);

      expect(entries.length, 1);
      expect(entries[0].fileName, 'hello.txt');
      expect(entries[0].endOfFile, 12345);
      expect(entries[0].isDirectory, false);
    });

    test('parses multiple entries', () {
      final buffer = _buildDirectoryEntries([
        ('file1.jpg', 100, 0x20),
        ('file2.png', 200, 0x20),
        ('subdir', 0, 0x10), // Directory
      ]);
      final responseBody = _wrapQueryDirResponse(buffer);
      final entries = QueryDirectoryResponse.decode(responseBody);

      expect(entries.length, 3);
      expect(entries[0].fileName, 'file1.jpg');
      expect(entries[1].fileName, 'file2.png');
      expect(entries[2].fileName, 'subdir');
      expect(entries[2].isDirectory, true);
    });

    test('detects hidden files', () {
      final buffer = _buildDirectoryEntries([
        ('.hidden', 0, 0x02), // Hidden
      ]);
      final responseBody = _wrapQueryDirResponse(buffer);
      final entries = QueryDirectoryResponse.decode(responseBody);

      expect(entries[0].isHidden, true);
    });
  });

  group('FileId', () {
    test('requires exactly 16 bytes', () {
      expect(() => FileId(Uint8List(15)), throwsArgumentError);
      expect(() => FileId(Uint8List(17)), throwsArgumentError);
      expect(FileId(Uint8List(16)).bytes.length, 16);
    });
  });
}

/// Build a synthetic Negotiate response body.
Uint8List _buildNegotiateResponse({
  int dialect = Smb2Dialect.smb210,
  int maxReadSize = 65536,
  int maxWriteSize = 65536,
  int maxTransactSize = 65536,
  int securityBufferLength = 0,
}) {
  // Minimum response body size: 65 bytes
  final secBufOffset = Smb2Header.size + 64; // After header + fixed fields
  final body = Uint8List(64 + securityBufferLength);
  final bd = ByteData.sublistView(body);

  bd.setUint16(0, 65, Endian.little); // StructureSize
  bd.setUint16(2, 0x0001, Endian.little); // SecurityMode
  bd.setUint16(4, dialect, Endian.little); // DialectRevision
  // ServerGUID at 8..24 (zeros)
  bd.setUint32(24, 0, Endian.little); // Capabilities
  bd.setUint32(28, maxTransactSize, Endian.little);
  bd.setUint32(32, maxReadSize, Endian.little);
  bd.setUint32(36, maxWriteSize, Endian.little);
  // SystemTime at 40..48 (zeros)
  // ServerStartTime at 48..56 (zeros)
  bd.setUint16(56, secBufOffset, Endian.little); // SecurityBufferOffset
  bd.setUint16(58, securityBufferLength, Endian.little);

  return body;
}

/// Build a synthetic Create response body.
Uint8List _buildCreateResponse({
  required int endOfFile,
  required List<int> fileId,
}) {
  final body = Uint8List(88); // StructureSize=89, but we need at least 84
  final bd = ByteData.sublistView(body);

  bd.setUint16(0, 89, Endian.little); // StructureSize
  // createAction at 4
  // times at 8..40 (zeros)
  // allocationSize at 40..48
  // endOfFile at 48..56
  bd.setUint32(48, endOfFile & 0xFFFFFFFF, Endian.little);
  bd.setUint32(52, (endOfFile >> 32) & 0xFFFFFFFF, Endian.little);
  // fileAttributes at 56
  // FileId at 64..80
  body.setRange(64, 80, fileId);

  return body;
}

/// Build FileBothDirectoryInformation entries.
Uint8List _buildDirectoryEntries(List<(String name, int size, int attrs)> entries) {
  final buffers = <Uint8List>[];

  for (int i = 0; i < entries.length; i++) {
    final (name, size, attrs) = entries[i];
    final nameUtf16 = _utf16le(name);
    // Fixed part: 94 bytes, then fileName
    final entrySize = 94 + nameUtf16.length;
    // Align to 8 bytes
    final alignedSize = (entrySize + 7) & ~7;
    final entry = Uint8List(alignedSize);
    final ebd = ByteData.sublistView(entry);

    // NextEntryOffset (0 for last)
    if (i < entries.length - 1) {
      ebd.setUint32(0, alignedSize, Endian.little);
    }
    // FileIndex at 4
    // CreationTime at 8
    // LastAccessTime at 16
    // LastWriteTime at 24
    // ChangeTime at 32
    // EndOfFile at 40
    ebd.setUint32(40, size & 0xFFFFFFFF, Endian.little);
    ebd.setUint32(44, (size >> 32) & 0xFFFFFFFF, Endian.little);
    // AllocationSize at 48
    // FileAttributes at 56
    ebd.setUint32(56, attrs, Endian.little);
    // FileNameLength at 60
    ebd.setUint32(60, nameUtf16.length, Endian.little);
    // EaSize at 64
    // ShortNameLength at 68 (1 byte)
    // Reserved at 69 (1 byte)
    // ShortName at 70 (24 bytes)
    // FileName at 94
    entry.setRange(94, 94 + nameUtf16.length, nameUtf16);

    buffers.add(entry);
  }

  // Concatenate
  final total = buffers.fold<int>(0, (sum, b) => sum + b.length);
  final result = Uint8List(total);
  int offset = 0;
  for (final buf in buffers) {
    result.setRange(offset, offset + buf.length, buf);
    offset += buf.length;
  }
  return result;
}

/// Wrap raw directory entries in a QueryDirectory response body.
Uint8List _wrapQueryDirResponse(Uint8List entries) {
  // StructureSize(2) + OutputBufferOffset(2) + OutputBufferLength(4) + entries
  final outputOffset = Smb2Header.size + 8; // Header + fixed fields
  final body = Uint8List(8 + entries.length);
  final bd = ByteData.sublistView(body);

  bd.setUint16(0, 9, Endian.little); // StructureSize
  bd.setUint16(2, outputOffset, Endian.little); // OutputBufferOffset
  bd.setUint32(4, entries.length, Endian.little); // OutputBufferLength
  body.setRange(8, 8 + entries.length, entries);

  return body;
}

Uint8List _utf16le(String s) {
  final bytes = Uint8List(s.length * 2);
  final bd = ByteData.sublistView(bytes);
  for (int i = 0; i < s.length; i++) {
    bd.setUint16(i * 2, s.codeUnitAt(i), Endian.little);
  }
  return bytes;
}
