import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:meta/meta.dart';
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
    msg.addSecurityBuffer(0, 0); // DomainNameFields - empty
    msg.addSecurityBuffer(0, 0); // WorkstationFields - empty
    msg.addBytes(_version);

    return msg.build();
  }

  /// Parse Type2 (Challenge) message and generate Type3 (Authenticate).
  Uint8List createType3Message(Uint8List type2Bytes) {
    final type2 = _Type2Message.parse(type2Bytes);
    final clientChallenge = _randomBytes(8);

    // Compute NTLMv2 response
    final ntHash = _computeNtHash(password);
    final responseKeyNT = computeResponseKeyNT(ntHash, username, domain);

    // The server's own clock if it sent one, so a skewed client does not fail
    // the timestamp check.
    final avTimestamp = type2.findAvPair(_avTimestamp);
    final timestamp = avTimestamp != null && avTimestamp.length == 8
        ? _readUint64Le(ByteData.sublistView(avTimestamp), 0)
        : _filetimeNow();

    final blob = _clientBlob(timestamp, clientChallenge, type2.targetInfo);
    final ntlmv2Response = _computeNtlmV2Response(
      responseKeyNT,
      type2.serverChallenge,
      blob,
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

    // Fixed header: signature(8) + type(4) + 6 security buffers(48) +
    // flags(4) + version(8) = 72 bytes
    const headerLen = 72;

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

    msg.addSecurityBuffer(lmv2Response.length, lmOffset);
    msg.addSecurityBuffer(ntlmv2Response.length, ntOffset);
    msg.addSecurityBuffer(domainBytes.length, domainOffset);
    msg.addSecurityBuffer(userBytes.length, userOffset);
    msg.addSecurityBuffer(workstationBytes.length, workstationOffset);
    msg.addSecurityBuffer(0, 0); // EncryptedRandomSessionKey - empty for now

    msg.addUint32(flags);
    msg.addBytes(_version);

    // Payload, in the order the buffers above point at it
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

  /// Compute ResponseKeyNT = HMAC-MD5(NT_Hash, UPPERCASE(Username) + UPPERCASE(Domain)).
  @visibleForTesting
  static Uint8List computeResponseKeyNT(Uint8List ntHash, String username, String domain) {
    final userDomain = _encodeUtf16Le(username.toUpperCase() + domain.toUpperCase());
    final hmac = hash.Hmac(hash.md5, ntHash);
    final digest = hmac.convert(userDomain);
    return Uint8List.fromList(digest.bytes);
  }

  /// The blob the NTLMv2 response is computed over and then carries: what
  /// this client contributed to the exchange, in the layout the spec gives.
  static Uint8List _clientBlob(
    int timestamp,
    Uint8List clientChallenge,
    Uint8List? avPairs,
  ) {
    final avPairsLen = avPairs?.length ?? 0;
    final blob = Uint8List(28 + avPairsLen + 4);
    final bd = ByteData.sublistView(blob);

    // RespType = 1, HiRespType = 1
    bd.setUint32(0, 0x00000101, Endian.little);
    // Reserved = 0
    bd.setUint32(4, 0, Endian.little);
    _writeUint64Le(bd, 8, timestamp);
    blob.setRange(16, 24, clientChallenge);
    // Reserved = 0
    bd.setUint32(24, 0, Endian.little);
    if (avPairs != null) {
      blob.setRange(28, 28 + avPairsLen, avPairs);
    }
    // Trailing 4 zero bytes
    bd.setUint32(28 + avPairsLen, 0, Endian.little);
    return blob;
  }

  /// Compute NTLMv2 response: proof that we hold the key, plus the blob the
  /// proof was taken over so the server can repeat the calculation.
  static Uint8List _computeNtlmV2Response(
    Uint8List responseKeyNT,
    Uint8List serverChallenge,
    Uint8List blob,
  ) {
    final ntProofStr =
        _hmacMd5(responseKeyNT, _concat(serverChallenge, blob));
    return _concat(ntProofStr, blob);
  }

  /// Compute LMv2 response.
  static Uint8List _computeLmV2Response(
    Uint8List responseKeyNT,
    Uint8List serverChallenge,
    Uint8List clientChallenge,
  ) {
    final mac =
        _hmacMd5(responseKeyNT, _concat(serverChallenge, clientChallenge));
    return _concat(mac, clientChallenge); // 16 + 8 = the fixed 24 bytes
  }

  /// Compute session base key = HMAC-MD5(ResponseKeyNT, NTProofStr).
  /// Used in Phase 2 for session signing.
  // ignore: unused_element
  static Uint8List _computeSessionBaseKey(Uint8List responseKeyNT, Uint8List ntlmv2Response) {
    return _hmacMd5(responseKeyNT, ntlmv2Response.sublist(0, 16));
  }

  static Uint8List _hmacMd5(Uint8List key, Uint8List data) =>
      Uint8List.fromList(hash.Hmac(hash.md5, key).convert(data).bytes);

  static Uint8List _concat(Uint8List a, Uint8List b) {
    final result = Uint8List(a.length + b.length);
    result.setRange(0, a.length, a);
    result.setRange(a.length, result.length, b);
    return result;
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
        List.generate(length, (_) => random.nextInt(256)));
  }

  /// Read and write 64-bit values as two 32-bit halves: [ByteData]'s 64-bit
  /// accessors throw on the web, where there is no 64-bit integer.
  static int _readUint64Le(ByteData bd, int offset) =>
      bd.getUint32(offset, Endian.little) |
      (bd.getUint32(offset + 4, Endian.little) << 32);

  static void _writeUint64Le(ByteData bd, int offset, int value) {
    bd.setUint32(offset, value & 0xFFFFFFFF, Endian.little);
    bd.setUint32(offset + 4, (value >> 32) & 0xFFFFFFFF, Endian.little);
  }

  /// Now as a FILETIME: 100ns intervals since 1601-01-01.
  static int _filetimeNow() {
    final now = DateTime.now().toUtc();
    final epoch = DateTime.utc(1601, 1, 1);
    return now.difference(epoch).inMicroseconds * 10;
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

  // Version (8 bytes): Windows 6.1, build 0, NTLMSSP revision 15
  static final _version = Uint8List.fromList([6, 1, 0, 0, 0, 0, 0, 15]);

  // AV pair ids
  static const _avTimestamp = 0x0007; // MsvAvTimestamp

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
    if (data.length < 32) {
      throw FormatException('Type2 message too short: ${data.length} bytes');
    }
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
          if (offset + 4 + len > targetInfo.length) break;
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

  /// A (Len, MaxLen, Offset) triple: how every variable-length part of an
  /// NTLMSSP message is pointed at from the fixed header. MaxLen is what the
  /// field could hold and Len what it does; nothing here ever reserves spare
  /// room, so the two are the same.
  void addSecurityBuffer(int length, int offset) {
    addUint16(length);
    addUint16(length);
    addUint32(offset);
  }

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
