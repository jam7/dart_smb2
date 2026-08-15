import 'dart:typed_data';

import '../header.dart';
import '../commands.dart';
import 'create.dart';

/// SMB2 Write request.
///
/// ```
/// StructureSize:          2 bytes (49)
/// DataOffset:             2 bytes
/// Length:                 4 bytes
/// Offset:                 8 bytes
/// FileId:                 16 bytes
/// Channel:                4 bytes
/// RemainingBytes:         4 bytes
/// WriteChannelInfoOffset: 2 bytes
/// WriteChannelInfoLength: 2 bytes
/// Flags:                  4 bytes
/// Buffer:                 variable
/// ```
class WriteRequest {
  /// Everything before the data. StructureSize says 49 because the protocol
  /// counts one byte of the buffer with it.
  static const int _fixedSize = 48;

  final FileId fileId;
  final int offset;
  final Uint8List data;

  WriteRequest({
    required this.fileId,
    required this.offset,
    required this.data,
  });

  Smb2Header buildHeader({required int sessionId, required int treeId}) {
    // SMB 2.1+: CreditCharge = ceil(Length / 65536), as for Read.
    final creditCharge = (data.length + 65535) ~/ 65536;
    return Smb2Header(
      command: Smb2Command.write,
      sessionId: sessionId,
      treeId: treeId,
      creditCharge: creditCharge,
    );
  }

  Uint8List encode() {
    final body = Uint8List(_fixedSize + data.length);
    final bd = ByteData.sublistView(body);

    bd.setUint16(0, _fixedSize + 1, Endian.little); // StructureSize
    // DataOffset counts from the start of the SMB2 header, not of this body.
    bd.setUint16(2, Smb2Header.size + _fixedSize, Endian.little);
    bd.setUint32(4, data.length, Endian.little); // Length
    // Offset (64-bit)
    bd.setUint32(8, offset & 0xFFFFFFFF, Endian.little);
    bd.setUint32(12, (offset >> 32) & 0xFFFFFFFF, Endian.little);
    body.setRange(16, 32, fileId.bytes); // FileId (16 bytes)
    // Channel, RemainingBytes, WriteChannelInfoOffset/Length and Flags are
    // all zero: no RDMA channel, no hint about what follows, no flags.
    body.setRange(_fixedSize, body.length, data);

    return body;
  }
}

/// Parsed SMB2 Write response.
class WriteResponse {
  /// How many bytes the server says it took. Not assumed to equal what was
  /// sent -- this is the number a caller is told about afterwards.
  final int count;

  WriteResponse({required this.count});

  static WriteResponse decode(Uint8List body) {
    if (body.length < 8) {
      throw FormatException('WriteResponse too short: ${body.length} bytes');
    }
    final bd = ByteData.sublistView(body);
    return WriteResponse(count: bd.getUint32(4, Endian.little));
  }
}
