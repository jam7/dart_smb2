import 'dart:typed_data';

import '../header.dart';
import '../commands.dart';

/// Share types returned in Tree Connect response.
class ShareType {
  static const int disk = 0x01;
  static const int pipe = 0x02;
  static const int print = 0x03;
}

/// SMB2 Tree Connect request.
class TreeConnectRequest {
  static const int _pathOffset = 8;

  final String path; // e.g., "\\\\server\\share"

  TreeConnectRequest({required this.path});

  Smb2Header buildHeader({required int sessionId}) {
    return Smb2Header(
      command: Smb2Command.treeConnect,
      sessionId: sessionId,
    );
  }

  Uint8List encode() {
    final pathBytes = _encodeUtf16Le(path);
    final totalSize = _pathOffset + pathBytes.length;
    final body = Uint8List(totalSize < 9 ? 9 : totalSize);
    final data = ByteData.sublistView(body);

    data.setUint16(0, 9, Endian.little); // StructureSize (always 9)
    data.setUint16(2, 0, Endian.little); // Flags (reserved)
    data.setUint16(4, Smb2Header.size + _pathOffset, Endian.little); // PathOffset
    data.setUint16(6, pathBytes.length, Endian.little); // PathLength

    body.setRange(_pathOffset, _pathOffset + pathBytes.length, pathBytes);
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

/// Parsed SMB2 Tree Connect response.
class TreeConnectResponse {
  final int shareType;
  final int shareFlags;
  final int capabilities;
  final int maximalAccess;

  TreeConnectResponse({
    required this.shareType,
    required this.shareFlags,
    required this.capabilities,
    required this.maximalAccess,
  });

  static TreeConnectResponse decode(Uint8List body) {
    if (body.length < 16) {
      throw FormatException('TreeConnectResponse too short: ${body.length} bytes');
    }
    final data = ByteData.sublistView(body);
    return TreeConnectResponse(
      shareType: body[2],
      shareFlags: data.getUint32(4, Endian.little),
      capabilities: data.getUint32(8, Endian.little),
      maximalAccess: data.getUint32(12, Endian.little),
    );
  }
}

/// SMB2 Tree Disconnect request.
class TreeDisconnectRequest {
  Smb2Header buildHeader({required int sessionId, required int treeId}) {
    return Smb2Header(
      command: Smb2Command.treeDisconnect,
      sessionId: sessionId,
      treeId: treeId,
    );
  }

  Uint8List encode() {
    final body = Uint8List(4);
    final data = ByteData.sublistView(body);
    data.setUint16(0, 4, Endian.little); // StructureSize
    data.setUint16(2, 0, Endian.little); // Reserved
    return body;
  }
}
