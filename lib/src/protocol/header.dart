import 'dart:typed_data';

import 'commands.dart';

/// 64-byte SMB2 packet header.
///
/// ```
/// Offset  Size  Field
/// 0-3     4     ProtocolId (0xFE 'S' 'M' 'B')
/// 4-5     2     StructureSize (64)
/// 6-7     2     CreditCharge
/// 8-11    4     Status (ChannelSequence + Reserved on request)
/// 12-13   2     Command
/// 14-15   2     CreditRequest / CreditResponse
/// 16-19   4     Flags
/// 20-23   4     NextCommand
/// 24-31   8     MessageId
/// 32-35   4     Reserved (sync) / AsyncId high (async)
/// 36-39   4     TreeId (sync) / AsyncId low (async)
/// 40-47   8     SessionId
/// 48-63   16    Signature
/// ```
class Smb2Header {
  static const int size = 64;
  static const List<int> protocolId = [0xFE, 0x53, 0x4D, 0x42]; // 0xFE 'SMB'

  int creditCharge;
  int status;
  int command;
  int creditRequestResponse;
  int flags;
  int nextCommand;
  int messageId;
  int treeId;
  int sessionId;
  Uint8List signature;

  Smb2Header({
    this.creditCharge = 0,
    this.status = 0,
    this.command = 0,
    this.creditRequestResponse = 0,
    this.flags = 0,
    this.nextCommand = 0,
    this.messageId = 0,
    this.treeId = 0,
    this.sessionId = 0,
    Uint8List? signature,
  }) : signature = signature ?? Uint8List(16);

  bool get isResponse => (flags & Smb2Flags.serverToRedir) != 0;
  bool get isAsync => (flags & Smb2Flags.asyncCommand) != 0;

  /// Encode header into [dst] at [offset]. Returns 64.
  int encode(Uint8List dst, int offset) {
    final data = ByteData.sublistView(dst);
    // Protocol ID
    dst[offset] = 0xFE;
    dst[offset + 1] = 0x53; // S
    dst[offset + 2] = 0x4D; // M
    dst[offset + 3] = 0x42; // B
    // StructureSize = 64
    data.setUint16(offset + 4, 64, Endian.little);
    data.setUint16(offset + 6, creditCharge, Endian.little);
    data.setUint32(offset + 8, status, Endian.little);
    data.setUint16(offset + 12, command, Endian.little);
    data.setUint16(offset + 14, creditRequestResponse, Endian.little);
    data.setUint32(offset + 16, flags, Endian.little);
    data.setUint32(offset + 20, nextCommand, Endian.little);
    // MessageId (64-bit)
    data.setUint32(offset + 24, messageId & 0xFFFFFFFF, Endian.little);
    data.setUint32(offset + 28, (messageId >> 32) & 0xFFFFFFFF, Endian.little);
    // Reserved + TreeId (sync mode)
    data.setUint32(offset + 32, 0, Endian.little);
    data.setUint32(offset + 36, treeId, Endian.little);
    // SessionId (64-bit)
    data.setUint32(offset + 40, sessionId & 0xFFFFFFFF, Endian.little);
    data.setUint32(offset + 44, (sessionId >> 32) & 0xFFFFFFFF, Endian.little);
    // Signature
    dst.setRange(offset + 48, offset + 64, signature);
    return size;
  }

  /// Decode header from [src] at [offset].
  static Smb2Header decode(Uint8List src, int offset) {
    final data = ByteData.sublistView(src);
    // Validate protocol ID
    if (src[offset] != 0xFE ||
        src[offset + 1] != 0x53 ||
        src[offset + 2] != 0x4D ||
        src[offset + 3] != 0x42) {
      throw FormatException(
        'Invalid SMB2 protocol ID: '
        '${src.sublist(offset, offset + 4)}',
      );
    }
    final header = Smb2Header(
      creditCharge: data.getUint16(offset + 6, Endian.little),
      status: data.getUint32(offset + 8, Endian.little),
      command: data.getUint16(offset + 12, Endian.little),
      creditRequestResponse: data.getUint16(offset + 14, Endian.little),
      flags: data.getUint32(offset + 16, Endian.little),
      nextCommand: data.getUint32(offset + 20, Endian.little),
      messageId: data.getUint32(offset + 24, Endian.little) |
          (data.getUint32(offset + 28, Endian.little) << 32),
      treeId: data.getUint32(offset + 36, Endian.little),
      sessionId: data.getUint32(offset + 40, Endian.little) |
          (data.getUint32(offset + 44, Endian.little) << 32),
      signature: Uint8List.fromList(src.sublist(offset + 48, offset + 64)),
    );
    return header;
  }
}
