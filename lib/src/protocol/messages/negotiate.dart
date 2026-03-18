import 'dart:typed_data';

import '../header.dart';
import '../commands.dart';

/// SMB2 dialect versions.
class Smb2Dialect {
  static const int smb202 = 0x0202;
  static const int smb210 = 0x0210;
  static const int smb300 = 0x0300;

  static String describe(int dialect) {
    switch (dialect) {
      case smb202: return 'SMB 2.0.2';
      case smb210: return 'SMB 2.1';
      case smb300: return 'SMB 3.0';
      default: return '0x${dialect.toRadixString(16)}';
    }
  }
}

/// Security mode flags for Negotiate.
class SecurityMode {
  static const int signingEnabled = 0x0001;
  static const int signingRequired = 0x0002;
}

/// Build an SMB2 Negotiate request.
///
/// ```
/// StructureSize:   2 bytes (36)
/// DialectCount:    2 bytes
/// SecurityMode:    2 bytes
/// Reserved:        2 bytes
/// Capabilities:    4 bytes
/// ClientGuid:      16 bytes
/// ClientStartTime: 8 bytes
/// Dialects:        2 * DialectCount bytes
/// ```
class NegotiateRequest {
  static const int _fixedSize = 36;

  final List<int> dialects;
  final int securityMode;
  final Uint8List clientGuid;

  NegotiateRequest({
    this.dialects = const [Smb2Dialect.smb202, Smb2Dialect.smb210, Smb2Dialect.smb300],
    this.securityMode = SecurityMode.signingEnabled,
    Uint8List? clientGuid,
  }) : clientGuid = clientGuid ?? Uint8List(16);

  Smb2Header buildHeader() {
    return Smb2Header(
      command: Smb2Command.negotiate,
      creditCharge: 0,
      creditRequestResponse: 1,
    );
  }

  Uint8List encode() {
    final body = Uint8List(_fixedSize + dialects.length * 2);
    final data = ByteData.sublistView(body);
    data.setUint16(0, _fixedSize, Endian.little); // StructureSize
    data.setUint16(2, dialects.length, Endian.little); // DialectCount
    data.setUint16(4, securityMode, Endian.little); // SecurityMode
    data.setUint16(6, 0, Endian.little); // Reserved
    data.setUint32(8, 0, Endian.little); // Capabilities
    body.setRange(12, 28, clientGuid); // ClientGuid (16 bytes)
    data.setUint64(28, 0, Endian.little); // ClientStartTime

    for (int i = 0; i < dialects.length; i++) {
      data.setUint16(_fixedSize + i * 2, dialects[i], Endian.little);
    }
    return body;
  }
}

/// Parsed SMB2 Negotiate response.
class NegotiateResponse {
  final int securityMode;
  final int dialectRevision;
  final Uint8List serverGuid;
  final int capabilities;
  final int maxTransactSize;
  final int maxReadSize;
  final int maxWriteSize;
  final Uint8List securityBuffer;

  NegotiateResponse({
    required this.securityMode,
    required this.dialectRevision,
    required this.serverGuid,
    required this.capabilities,
    required this.maxTransactSize,
    required this.maxReadSize,
    required this.maxWriteSize,
    required this.securityBuffer,
  });

  /// Decode from response body (after 64-byte header).
  static NegotiateResponse decode(Uint8List body) {
    final data = ByteData.sublistView(body);
    final securityMode = data.getUint16(2, Endian.little);
    final dialectRevision = data.getUint16(4, Endian.little);
    final serverGuid = Uint8List.fromList(body.sublist(8, 24));
    final capabilities = data.getUint32(24, Endian.little);
    final maxTransactSize = data.getUint32(28, Endian.little);
    final maxReadSize = data.getUint32(32, Endian.little);
    final maxWriteSize = data.getUint32(36, Endian.little);
    // SecurityBufferOffset is from start of SMB2 header
    final securityBufferOffset = data.getUint16(56, Endian.little) - Smb2Header.size;
    final securityBufferLength = data.getUint16(58, Endian.little);

    Uint8List securityBuffer;
    if (securityBufferLength > 0 && securityBufferOffset >= 0 && securityBufferOffset + securityBufferLength <= body.length) {
      securityBuffer = Uint8List.fromList(
        body.sublist(securityBufferOffset, securityBufferOffset + securityBufferLength),
      );
    } else {
      securityBuffer = Uint8List(0);
    }

    return NegotiateResponse(
      securityMode: securityMode,
      dialectRevision: dialectRevision,
      serverGuid: serverGuid,
      capabilities: capabilities,
      maxTransactSize: maxTransactSize,
      maxReadSize: maxReadSize,
      maxWriteSize: maxWriteSize,
      securityBuffer: securityBuffer,
    );
  }
}
