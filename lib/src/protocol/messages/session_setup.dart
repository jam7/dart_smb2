import 'dart:typed_data';

import '../header.dart';
import '../commands.dart';
import 'negotiate.dart';

/// SMB2 Session Setup request.
///
/// ```
/// StructureSize:       2 bytes (25)
/// Flags:               1 byte
/// SecurityMode:        1 byte
/// Capabilities:        4 bytes
/// Channel:             4 bytes
/// SecurityBufferOffset:2 bytes
/// SecurityBufferLength:2 bytes
/// PreviousSessionId:   8 bytes
/// SecurityBuffer:      variable
/// ```
class SessionSetupRequest {
  static const int _bufferOffset = 24; // Offset from body start

  final int securityMode;
  final Uint8List securityBuffer;
  final int sessionId;

  SessionSetupRequest({
    this.securityMode = SecurityMode.signingEnabled,
    required this.securityBuffer,
    this.sessionId = 0,
  });

  Smb2Header buildHeader({int sessionId = 0}) {
    return Smb2Header(
      command: Smb2Command.sessionSetup,
      sessionId: sessionId,
    );
  }

  Uint8List encode() {
    final totalSize = _bufferOffset + securityBuffer.length;
    final body = Uint8List(totalSize < 25 ? 25 : totalSize);
    final data = ByteData.sublistView(body);

    data.setUint16(0, 25, Endian.little); // StructureSize (always 25)
    body[2] = 0; // Flags
    body[3] = securityMode; // SecurityMode
    data.setUint32(4, 0, Endian.little); // Capabilities
    data.setUint32(8, 0, Endian.little); // Channel
    // SecurityBufferOffset from start of SMB2 header
    data.setUint16(12, Smb2Header.size + _bufferOffset, Endian.little);
    data.setUint16(14, securityBuffer.length, Endian.little);
    data.setUint64(16, 0, Endian.little); // PreviousSessionId

    body.setRange(_bufferOffset, _bufferOffset + securityBuffer.length, securityBuffer);
    return body;
  }
}

/// Parsed SMB2 Session Setup response.
class SessionSetupResponse {
  final int sessionFlags;
  final Uint8List securityBuffer;

  SessionSetupResponse({
    required this.sessionFlags,
    required this.securityBuffer,
  });

  bool get isGuest => (sessionFlags & 0x0001) != 0;
  bool get isNull => (sessionFlags & 0x0002) != 0;

  static SessionSetupResponse decode(Uint8List body) {
    final data = ByteData.sublistView(body);
    final sessionFlags = data.getUint16(2, Endian.little);
    final securityBufferOffset = data.getUint16(4, Endian.little) - Smb2Header.size;
    final securityBufferLength = data.getUint16(6, Endian.little);

    Uint8List securityBuffer;
    if (securityBufferLength > 0 && securityBufferOffset >= 0 && securityBufferOffset + securityBufferLength <= body.length) {
      securityBuffer = Uint8List.fromList(
        body.sublist(securityBufferOffset, securityBufferOffset + securityBufferLength),
      );
    } else {
      securityBuffer = Uint8List(0);
    }

    return SessionSetupResponse(
      sessionFlags: sessionFlags,
      securityBuffer: securityBuffer,
    );
  }
}
