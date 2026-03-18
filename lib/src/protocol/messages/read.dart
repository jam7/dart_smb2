import 'dart:typed_data';

import '../header.dart';
import '../commands.dart';
import 'create.dart';

/// SMB2 Read request.
///
/// ```
/// StructureSize: 2 bytes (49)
/// Padding:       1 byte
/// Flags:         1 byte
/// Length:        4 bytes
/// Offset:        8 bytes
/// FileId:        16 bytes
/// MinimumCount:  4 bytes
/// Channel:       4 bytes
/// RemainingBytes:4 bytes
/// ReadChannelInfoOffset: 2 bytes
/// ReadChannelInfoLength: 2 bytes
/// Buffer:        1 byte
/// ```
class ReadRequest {
  final FileId fileId;
  final int offset;
  final int length;

  ReadRequest({
    required this.fileId,
    required this.offset,
    required this.length,
  });

  Smb2Header buildHeader({required int sessionId, required int treeId}) {
    // SMB 2.1+: CreditCharge = ceil(Length / 65536)
    final creditCharge = (length + 65535) ~/ 65536;
    return Smb2Header(
      command: Smb2Command.read,
      sessionId: sessionId,
      treeId: treeId,
      creditCharge: creditCharge,
    );
  }

  Uint8List encode() {
    final body = Uint8List(49);
    final data = ByteData.sublistView(body);

    data.setUint16(0, 49, Endian.little); // StructureSize
    body[2] = 0x50; // Padding (offset to data, 0x50 = 80 = header(64) + 16)
    body[3] = 0; // Flags
    data.setUint32(4, length, Endian.little); // Length
    // Offset (64-bit)
    data.setUint32(8, offset & 0xFFFFFFFF, Endian.little);
    data.setUint32(12, (offset >> 32) & 0xFFFFFFFF, Endian.little);
    // FileId (16 bytes)
    body.setRange(16, 32, fileId.bytes);
    data.setUint32(32, 0, Endian.little); // MinimumCount
    data.setUint32(36, 0, Endian.little); // Channel
    data.setUint32(40, 0, Endian.little); // RemainingBytes
    data.setUint16(44, 0, Endian.little); // ReadChannelInfoOffset
    data.setUint16(46, 0, Endian.little); // ReadChannelInfoLength
    body[48] = 0; // Buffer

    return body;
  }
}

/// Parsed SMB2 Read response.
class ReadResponse {
  final Uint8List data;

  ReadResponse({required this.data});

  static ReadResponse decode(Uint8List body) {
    final bd = ByteData.sublistView(body);
    final dataOffset = body[2] - Smb2Header.size; // DataOffset is from header start
    final dataLength = bd.getUint32(4, Endian.little);

    Uint8List data;
    if (dataLength > 0 && dataOffset >= 0 && dataOffset + dataLength <= body.length) {
      data = Uint8List.fromList(body.sublist(dataOffset, dataOffset + dataLength));
    } else {
      data = Uint8List(0);
    }

    return ReadResponse(data: data);
  }
}
