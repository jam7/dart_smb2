import 'dart:typed_data';

import '../header.dart';
import '../commands.dart';

/// Access mask flags.
class AccessMask {
  static const int fileReadData = 0x00000001;
  static const int fileWriteData = 0x00000002;
  static const int fileReadAttributes = 0x00000080;
  static const int fileWriteAttributes = 0x00000100;
  static const int readControl = 0x00020000;
  static const int synchronize = 0x00100000;
  static const int genericRead = 0x80000000;
  static const int genericAll = 0x10000000;

  /// Standard read access.
  static const int read = fileReadData | fileReadAttributes | readControl | synchronize;

  /// Maximum allowed access.
  static const int maximumAllowed = 0x02000000;
}

/// File attribute flags.
class FileAttributes {
  static const int normal = 0x00000080;
  static const int directory = 0x00000010;
}

/// Share access flags.
class ShareAccess {
  static const int read = 0x00000001;
  static const int write = 0x00000002;
  static const int delete = 0x00000004;
  static const int all = read | write | delete;
}

/// Create disposition values.
class CreateDisposition {
  static const int fileSupersede = 0x00000000;
  static const int fileOpen = 0x00000001;
  static const int fileCreate = 0x00000002;
  static const int fileOpenIf = 0x00000003;
  static const int fileOverwrite = 0x00000004;
  static const int fileOverwriteIf = 0x00000005;
}

/// Create options flags.
class CreateOptions {
  static const int directoryFile = 0x00000001;
  static const int nonDirectoryFile = 0x00000040;
}

/// 16-byte file ID returned by Create.
class FileId {
  final Uint8List bytes;

  FileId(this.bytes) {
    if (bytes.length != 16) {
      throw ArgumentError('FileId must be 16 bytes');
    }
  }

  @override
  String toString() => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// SMB2 Create (open file/directory) request.
class CreateRequest {
  static const int _nameOffset = 56;

  final String fileName;
  final int desiredAccess;
  final int fileAttributes;
  final int shareAccess;
  final int createDisposition;
  final int createOptions;

  CreateRequest({
    required this.fileName,
    this.desiredAccess = AccessMask.read,
    this.fileAttributes = FileAttributes.normal,
    this.shareAccess = ShareAccess.all,
    this.createDisposition = CreateDisposition.fileOpen,
    this.createOptions = 0,
  });

  Smb2Header buildHeader({required int sessionId, required int treeId}) {
    return Smb2Header(
      command: Smb2Command.create,
      sessionId: sessionId,
      treeId: treeId,
    );
  }

  Uint8List encode() {
    final nameBytes = _encodeUtf16Le(fileName);
    // If name is empty, still need at least 1 byte for buffer
    final bufferLen = nameBytes.isEmpty ? 0 : nameBytes.length;
    final totalSize = _nameOffset + (bufferLen == 0 ? 1 : bufferLen);
    final body = Uint8List(totalSize);
    final data = ByteData.sublistView(body);

    data.setUint16(0, 57, Endian.little); // StructureSize
    body[2] = 0; // SecurityFlags
    body[3] = 0; // RequestedOplockLevel (none)
    data.setUint32(4, 0x00000002, Endian.little); // ImpersonationLevel (Impersonation)
    data.setUint64(8, 0, Endian.little); // SmbCreateFlags
    data.setUint64(16, 0, Endian.little); // Reserved
    data.setUint32(24, desiredAccess, Endian.little); // DesiredAccess
    data.setUint32(28, fileAttributes, Endian.little); // FileAttributes
    data.setUint32(32, shareAccess, Endian.little); // ShareAccess
    data.setUint32(36, createDisposition, Endian.little); // CreateDisposition
    data.setUint32(40, createOptions, Endian.little); // CreateOptions
    data.setUint16(44, Smb2Header.size + _nameOffset, Endian.little); // NameOffset
    data.setUint16(46, nameBytes.length, Endian.little); // NameLength
    data.setUint32(48, 0, Endian.little); // CreateContextsOffset
    data.setUint32(52, 0, Endian.little); // CreateContextsLength

    if (nameBytes.isNotEmpty) {
      body.setRange(_nameOffset, _nameOffset + nameBytes.length, nameBytes);
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

/// Parsed SMB2 Create response.
class CreateResponse {
  final int createAction;
  final int creationTime;
  final int lastAccessTime;
  final int lastWriteTime;
  final int changeTime;
  final int allocationSize;
  final int endOfFile;
  final int fileAttributes;
  final FileId fileId;

  CreateResponse({
    required this.createAction,
    required this.creationTime,
    required this.lastAccessTime,
    required this.lastWriteTime,
    required this.changeTime,
    required this.allocationSize,
    required this.endOfFile,
    required this.fileAttributes,
    required this.fileId,
  });

  static CreateResponse decode(Uint8List body) {
    final data = ByteData.sublistView(body);
    return CreateResponse(
      createAction: data.getUint32(4, Endian.little),
      creationTime: _readUint64(data, 8),
      lastAccessTime: _readUint64(data, 16),
      lastWriteTime: _readUint64(data, 24),
      changeTime: _readUint64(data, 32),
      allocationSize: _readUint64(data, 40),
      endOfFile: _readUint64(data, 48),
      fileAttributes: data.getUint32(56, Endian.little),
      fileId: FileId(Uint8List.fromList(body.sublist(64, 80))),
    );
  }

  static int _readUint64(ByteData data, int offset) {
    return data.getUint32(offset, Endian.little) |
        (data.getUint32(offset + 4, Endian.little) << 32);
  }
}
