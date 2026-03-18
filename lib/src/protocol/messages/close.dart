import 'dart:typed_data';

import '../header.dart';
import '../commands.dart';
import 'create.dart';

/// SMB2 Close request.
class CloseRequest {
  final FileId fileId;

  CloseRequest({required this.fileId});

  Smb2Header buildHeader({required int sessionId, required int treeId}) {
    return Smb2Header(
      command: Smb2Command.close,
      sessionId: sessionId,
      treeId: treeId,
    );
  }

  Uint8List encode() {
    final body = Uint8List(24);
    final data = ByteData.sublistView(body);
    data.setUint16(0, 24, Endian.little); // StructureSize
    data.setUint16(2, 0, Endian.little); // Flags
    data.setUint32(4, 0, Endian.little); // Reserved
    body.setRange(8, 24, fileId.bytes); // FileId
    return body;
  }
}
