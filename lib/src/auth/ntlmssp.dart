import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:pointycastle/export.dart';

/// NTLMSSP authentication (NTLMv2).
///
/// Implements the 3-message handshake:
/// 1. Type1 (Negotiate) → server
/// 2. Type2 (Challenge) ← server
/// 3. Type3 (Authenticate) → server
class NtlmAuth {
  final String username;
  final String password;
  final String domain;
  final String workstation;

  NtlmAuth({
    required this.username,
    required this.password,
    this.domain = '',
    this.workstation = '',
  });

  /// Generate Type1 (Negotiate) message.
  Uint8List createType1Message() {
    final msg = _NtlmMessageBuilder();
    // NTLMSSP signature
    msg.addBytes(_ntlmsspSignature);
    // MessageType = 1
    msg.addUint32(1);
    // NegotiateFlags
    final flags = _flagNtlm |
        _flagRequestTarget |
        _flagUnicode |
        _flagAlwaysSign |
        _flagNtlm2 |
        _flagVersion;
    msg.addUint32(flags);
    // DomainNameFields (Len, MaxLen, Offset) - empty
    msg.addUint16(0); // Len
    msg.addUint16(0); // MaxLen
    msg.addUint32(0); // Offset
    // WorkstationFields - empty
    msg.addUint16(0);
    msg.addUint16(0);
    msg.addUint32(0);
    // Version (8 bytes): Windows 6.1, build 0, NTLMSSP revision 15
    msg.addBytes(Uint8List.fromList([6, 1, 0, 0, 0, 0, 0, 15]));

    return msg.build();
  }

  /// Parse Type2 (Challenge) message and generate Type3 (Authenticate).
  Uint8List createType3Message(Uint8List type2Bytes) {
    final type2 = _Type2Message.parse(type2Bytes);
    final random = Random.secure();
    final clientChallenge = Uint8List(8);
    for (int i = 0; i < 8; i++) {
      clientChallenge[i] = random.nextInt(256);
    }

    // Compute NTLMv2 response
    final ntHash = _computeNtHash(password);
    final responseKeyNT = _computeResponseKeyNT(ntHash, username, domain);

    // Get timestamp from AV pairs, or use current time
    int timestamp;
    final avTimestamp = type2.findAvPair(0x0007); // MsvAvTimestamp
    if (avTimestamp != null && avTimestamp.length == 8) {
      final bd = ByteData.sublistView(avTimestamp);
      timestamp = bd.getUint32(0, Endian.little) |
          (bd.getUint32(4, Endian.little) << 32);
    } else {
      // Convert current time to FILETIME (100ns intervals since 1601-01-01)
      final now = DateTime.now().toUtc();
      final epoch = DateTime.utc(1601, 1, 1);
      timestamp = now.difference(epoch).inMicroseconds * 10;
    }

    final ntlmv2Response = _computeNtlmV2Response(
      responseKeyNT,
      type2.serverChallenge,
      clientChallenge,
      timestamp,
      type2.targetInfo,
    );

    // LMv2 response
    final lmv2Response = _computeLmV2Response(
      responseKeyNT,
      type2.serverChallenge,
      clientChallenge,
    );

    // Build Type3 message
    final domainBytes = _encodeUtf16Le(domain.toUpperCase());
    final userBytes = _encodeUtf16Le(username);
    final workstationBytes = _encodeUtf16Le(workstation);

    // Compute offsets
    final flags = type2.negotiateFlags & (_flagNtlm | _flagUnicode | _flagNtlm2 | _flagKeyExch | _flagAlwaysSign);

    // Fixed header up to Payload: 88 bytes (including MIC placeholder)
    const fixedLen = 72; // Without version and MIC
    const versionLen = 8;
    const headerLen = fixedLen + versionLen; // 80 bytes

    int payloadOffset = headerLen;
    final lmOffset = payloadOffset;
    payloadOffset += lmv2Response.length;
    final ntOffset = payloadOffset;
    payloadOffset += ntlmv2Response.length;
    final domainOffset = payloadOffset;
    payloadOffset += domainBytes.length;
    final userOffset = payloadOffset;
    payloadOffset += userBytes.length;
    final workstationOffset = payloadOffset;
    payloadOffset += workstationBytes.length;

    final msg = _NtlmMessageBuilder();
    msg.addBytes(_ntlmsspSignature);
    msg.addUint32(3); // MessageType = 3

    // LmChallengeResponseFields
    msg.addUint16(lmv2Response.length);
    msg.addUint16(lmv2Response.length);
    msg.addUint32(lmOffset);

    // NtChallengeResponseFields
    msg.addUint16(ntlmv2Response.length);
    msg.addUint16(ntlmv2Response.length);
    msg.addUint32(ntOffset);

    // DomainNameFields
    msg.addUint16(domainBytes.length);
    msg.addUint16(domainBytes.length);
    msg.addUint32(domainOffset);

    // UserNameFields
    msg.addUint16(userBytes.length);
    msg.addUint16(userBytes.length);
    msg.addUint32(userOffset);

    // WorkstationFields
    msg.addUint16(workstationBytes.length);
    msg.addUint16(workstationBytes.length);
    msg.addUint32(workstationOffset);

    // EncryptedRandomSessionKeyFields (empty for now)
    msg.addUint16(0);
    msg.addUint16(0);
    msg.addUint32(0);

    // NegotiateFlags
    msg.addUint32(flags);

    // Version
    msg.addBytes(Uint8List.fromList([6, 1, 0, 0, 0, 0, 0, 15]));

    // Payload
    msg.addBytes(lmv2Response);
    msg.addBytes(ntlmv2Response);
    msg.addBytes(domainBytes);
    msg.addBytes(userBytes);
    msg.addBytes(workstationBytes);

    return msg.build();
  }

  /// Compute NT hash: MD4(UTF-16LE(password)).
  static Uint8List _computeNtHash(String password) {
    final pwBytes = _encodeUtf16Le(password);
    final md4 = MD4Digest();
    md4.update(pwBytes, 0, pwBytes.length);
    final result = Uint8List(16);
    md4.doFinal(result, 0);
    return result;
  }

  /// Compute ResponseKeyNT = HMAC-MD5(NT_Hash, UPPERCASE(Username) + Domain).
  static Uint8List _computeResponseKeyNT(Uint8List ntHash, String username, String domain) {
    final userDomain = _encodeUtf16Le(username.toUpperCase() + domain);
    final hmac = hash.Hmac(hash.md5, ntHash);
    final digest = hmac.convert(userDomain);
    return Uint8List.fromList(digest.bytes);
  }

  /// Compute NTLMv2 response.
  static Uint8List _computeNtlmV2Response(
    Uint8List responseKeyNT,
    Uint8List serverChallenge,
    Uint8List clientChallenge,
    int timestamp,
    Uint8List? avPairs,
  ) {
    // Build client blob
    final avPairsLen = avPairs?.length ?? 0;
    final blob = Uint8List(28 + avPairsLen + 4);
    final bd = ByteData.sublistView(blob);

    // RespType = 1, HiRespType = 1
    bd.setUint32(0, 0x00000101, Endian.little);
    // Reserved = 0
    bd.setUint32(4, 0, Endian.little);
    // TimeStamp (FILETIME)
    bd.setUint32(8, timestamp & 0xFFFFFFFF, Endian.little);
    bd.setUint32(12, (timestamp >> 32) & 0xFFFFFFFF, Endian.little);
    // ClientChallenge
    blob.setRange(16, 24, clientChallenge);
    // Reserved = 0
    bd.setUint32(24, 0, Endian.little);
    // AvPairs
    if (avPairs != null) {
      blob.setRange(28, 28 + avPairsLen, avPairs);
    }
    // Trailing 4 zero bytes
    bd.setUint32(28 + avPairsLen, 0, Endian.little);

    // NTProofStr = HMAC-MD5(ResponseKeyNT, ServerChallenge + Blob)
    final hmac = hash.Hmac(hash.md5, responseKeyNT);
    final input = Uint8List(serverChallenge.length + blob.length);
    input.setRange(0, serverChallenge.length, serverChallenge);
    input.setRange(serverChallenge.length, input.length, blob);
    final ntProofStr = Uint8List.fromList(hmac.convert(input).bytes);

    // NTLMv2 Response = NTProofStr + Blob
    final result = Uint8List(ntProofStr.length + blob.length);
    result.setRange(0, ntProofStr.length, ntProofStr);
    result.setRange(ntProofStr.length, result.length, blob);
    return result;
  }

  /// Compute LMv2 response.
  static Uint8List _computeLmV2Response(
    Uint8List responseKeyNT,
    Uint8List serverChallenge,
    Uint8List clientChallenge,
  ) {
    final hmac = hash.Hmac(hash.md5, responseKeyNT);
    final input = Uint8List(serverChallenge.length + clientChallenge.length);
    input.setRange(0, serverChallenge.length, serverChallenge);
    input.setRange(serverChallenge.length, input.length, clientChallenge);
    final mac = Uint8List.fromList(hmac.convert(input).bytes);

    final result = Uint8List(24);
    result.setRange(0, 16, mac);
    result.setRange(16, 24, clientChallenge);
    return result;
  }

  /// Compute session base key = HMAC-MD5(ResponseKeyNT, NTProofStr).
  /// Used in Phase 2 for session signing.
  // ignore: unused_element
  static Uint8List _computeSessionBaseKey(Uint8List responseKeyNT, Uint8List ntlmv2Response) {
    final ntProofStr = ntlmv2Response.sublist(0, 16);
    final hmac = hash.Hmac(hash.md5, responseKeyNT);
    return Uint8List.fromList(hmac.convert(ntProofStr).bytes);
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

  // NTLMSSP signature: "NTLMSSP\0"
  static final _ntlmsspSignature = Uint8List.fromList(
    [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00],
  );

  // Negotiate flags
  static const _flagUnicode = 0x00000001;
  static const _flagRequestTarget = 0x00000004;
  static const _flagNtlm = 0x00000200;
  static const _flagAlwaysSign = 0x00008000;
  static const _flagNtlm2 = 0x00080000; // NTLMSSP_NEGOTIATE_EXTENDED_SESSIONSECURITY
  static const _flagVersion = 0x02000000;
  static const _flagKeyExch = 0x40000000;
}

/// Parsed Type2 (Challenge) message.
class _Type2Message {
  final Uint8List serverChallenge;
  final int negotiateFlags;
  final Uint8List? targetInfo;
  final List<_AvPair> avPairs;

  _Type2Message({
    required this.serverChallenge,
    required this.negotiateFlags,
    this.targetInfo,
    this.avPairs = const [],
  });

  /// Find an AV pair by type.
  Uint8List? findAvPair(int type) {
    for (final pair in avPairs) {
      if (pair.id == type) return pair.value;
    }
    return null;
  }

  static _Type2Message parse(Uint8List data) {
    // Validate signature
    for (int i = 0; i < 8; i++) {
      if (data[i] != NtlmAuth._ntlmsspSignature[i]) {
        throw FormatException('Invalid NTLMSSP signature');
      }
    }
    final bd = ByteData.sublistView(data);
    final messageType = bd.getUint32(8, Endian.little);
    if (messageType != 2) {
      throw FormatException('Expected Type2 message, got $messageType');
    }

    final negotiateFlags = bd.getUint32(20, Endian.little);
    final serverChallenge = Uint8List.fromList(data.sublist(24, 32));

    // Target info fields
    Uint8List? targetInfo;
    final avPairs = <_AvPair>[];
    if (data.length >= 48) {
      final targetInfoLen = bd.getUint16(40, Endian.little);
      final targetInfoOffset = bd.getUint32(44, Endian.little);
      if (targetInfoLen > 0 && targetInfoOffset + targetInfoLen <= data.length) {
        targetInfo = Uint8List.fromList(
          data.sublist(targetInfoOffset, targetInfoOffset + targetInfoLen),
        );
        // Parse AV pairs
        int offset = 0;
        final tiBd = ByteData.sublistView(targetInfo);
        while (offset + 4 <= targetInfo.length) {
          final id = tiBd.getUint16(offset, Endian.little);
          final len = tiBd.getUint16(offset + 2, Endian.little);
          if (id == 0) break; // MsvAvEOL
          final value = Uint8List.fromList(
            targetInfo.sublist(offset + 4, offset + 4 + len),
          );
          avPairs.add(_AvPair(id, value));
          offset += 4 + len;
        }
      }
    }

    return _Type2Message(
      serverChallenge: serverChallenge,
      negotiateFlags: negotiateFlags,
      targetInfo: targetInfo,
      avPairs: avPairs,
    );
  }
}

class _AvPair {
  final int id;
  final Uint8List value;
  _AvPair(this.id, this.value);
}

/// Helper for building NTLMSSP messages.
class _NtlmMessageBuilder {
  final _bytes = <int>[];

  void addBytes(Uint8List data) => _bytes.addAll(data);
  void addUint16(int value) {
    _bytes.add(value & 0xFF);
    _bytes.add((value >> 8) & 0xFF);
  }
  void addUint32(int value) {
    _bytes.add(value & 0xFF);
    _bytes.add((value >> 8) & 0xFF);
    _bytes.add((value >> 16) & 0xFF);
    _bytes.add((value >> 24) & 0xFF);
  }
  Uint8List build() => Uint8List.fromList(_bytes);
}
