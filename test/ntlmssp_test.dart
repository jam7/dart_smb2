import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dart_smb2/src/auth/ntlmssp.dart';

void main() {
  group('NtlmAuth', () {
    test('Type1 message starts with NTLMSSP signature', () {
      final auth = NtlmAuth(username: 'user', password: 'pass');
      final type1 = auth.createType1Message();

      // "NTLMSSP\0"
      expect(type1.sublist(0, 8), [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
    });

    test('Type1 message has MessageType = 1', () {
      final auth = NtlmAuth(username: 'user', password: 'pass');
      final type1 = auth.createType1Message();

      final bd = ByteData.sublistView(type1);
      expect(bd.getUint32(8, Endian.little), 1);
    });

    test('Type1 message includes NTLM flag', () {
      final auth = NtlmAuth(username: 'user', password: 'pass');
      final type1 = auth.createType1Message();

      final bd = ByteData.sublistView(type1);
      final flags = bd.getUint32(12, Endian.little);
      // NTLMSSP_NEGOTIATE_NTLM = 0x00000200
      expect(flags & 0x00000200, isNonZero);
    });

    test('Type1 message includes Unicode flag', () {
      final auth = NtlmAuth(username: 'user', password: 'pass');
      final type1 = auth.createType1Message();

      final bd = ByteData.sublistView(type1);
      final flags = bd.getUint32(12, Endian.little);
      // NTLMSSP_NEGOTIATE_UNICODE = 0x00000001
      expect(flags & 0x00000001, isNonZero);
    });

    test('Type1 message includes version field', () {
      final auth = NtlmAuth(username: 'user', password: 'pass');
      final type1 = auth.createType1Message();

      // Version flag = 0x02000000
      final bd = ByteData.sublistView(type1);
      final flags = bd.getUint32(12, Endian.little);
      expect(flags & 0x02000000, isNonZero);

      // Version bytes should be at offset 32 (after DomainFields and WorkstationFields)
      // Version: 6.1.0.0, NTLMSSP revision 15
      expect(type1[32], 6); // Major
      expect(type1[33], 1); // Minor
      expect(type1[39], 15); // NTLMSSP revision
    });

    test('Type3 generation from synthetic Type2', () {
      // Build a minimal valid Type2 message
      final type2 = _buildMinimalType2();
      final auth = NtlmAuth(
        username: 'testuser',
        password: 'testpass',
        domain: 'WORKGROUP',
      );

      final type3 = auth.createType3Message(type2);

      // Should start with NTLMSSP signature
      expect(type3.sublist(0, 8), [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);

      // MessageType = 3
      final bd = ByteData.sublistView(type3);
      expect(bd.getUint32(8, Endian.little), 3);
    });

    test('Type3 contains non-empty LM and NT responses', () {
      final type2 = _buildMinimalType2();
      final auth = NtlmAuth(
        username: 'testuser',
        password: 'testpass',
        domain: 'WORKGROUP',
      );

      final type3 = auth.createType3Message(type2);
      final bd = ByteData.sublistView(type3);

      // LmChallengeResponse length (offset 12)
      final lmLen = bd.getUint16(12, Endian.little);
      expect(lmLen, greaterThan(0));

      // NtChallengeResponse length (offset 20)
      final ntLen = bd.getUint16(20, Endian.little);
      expect(ntLen, greaterThan(0));
    });

    test('different passwords produce different Type3 messages', () {
      final type2 = _buildMinimalType2();

      final auth1 = NtlmAuth(username: 'user', password: 'pass1');
      final auth2 = NtlmAuth(username: 'user', password: 'pass2');

      final t3a = auth1.createType3Message(type2);
      final t3b = auth2.createType3Message(type2);

      // NT responses should differ
      expect(t3a, isNot(equals(t3b)));
    });

    test('createType3Message rejects invalid Type2 signature', () {
      final badType2 = Uint8List(56);
      badType2[0] = 0xFF; // Wrong signature

      final auth = NtlmAuth(username: 'user', password: 'pass');
      expect(() => auth.createType3Message(badType2), throwsFormatException);
    });

    test('createType3Message rejects wrong message type', () {
      // Build Type2-like but with MessageType=1
      final badType2 = Uint8List(56);
      // NTLMSSP\0
      badType2.setRange(0, 8, [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
      // MessageType = 1 (wrong, should be 2)
      final bd = ByteData.sublistView(badType2);
      bd.setUint32(8, 1, Endian.little);

      final auth = NtlmAuth(username: 'user', password: 'pass');
      expect(() => auth.createType3Message(badType2), throwsFormatException);
    });
  });
}

/// Build a minimal but valid NTLMSSP Type2 (Challenge) message for testing.
Uint8List _buildMinimalType2() {
  // Minimal Type2: signature(8) + type(4) + targetName fields(8) +
  // flags(4) + challenge(8) + reserved(8) + targetInfo fields(8) + targetInfo
  final targetInfo = _buildTargetInfo();
  final targetInfoOffset = 48;
  final totalSize = targetInfoOffset + targetInfo.length;
  final msg = Uint8List(totalSize);
  final bd = ByteData.sublistView(msg);

  // NTLMSSP\0
  msg.setRange(0, 8, [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
  // MessageType = 2
  bd.setUint32(8, 2, Endian.little);
  // TargetNameFields (Len=0, MaxLen=0, Offset=0)
  bd.setUint16(12, 0, Endian.little);
  bd.setUint16(14, 0, Endian.little);
  bd.setUint32(16, 0, Endian.little);
  // NegotiateFlags
  final flags = 0x00000001 | // UNICODE
      0x00000200 | // NTLM
      0x00080000; // Extended Session Security
  bd.setUint32(20, flags, Endian.little);
  // ServerChallenge (8 bytes of test data)
  for (int i = 0; i < 8; i++) {
    msg[24 + i] = 0x11 + i;
  }
  // Reserved (8 bytes zero)
  // TargetInfoFields
  bd.setUint16(40, targetInfo.length, Endian.little);
  bd.setUint16(42, targetInfo.length, Endian.little);
  bd.setUint32(44, targetInfoOffset, Endian.little);
  // TargetInfo data
  msg.setRange(targetInfoOffset, targetInfoOffset + targetInfo.length, targetInfo);

  return msg;
}

/// Build minimal AV_PAIR list with MsvAvEOL terminator.
Uint8List _buildTargetInfo() {
  // MsvAvNbDomainName (type=2, value="WORKGROUP" in UTF-16LE)
  final domain = 'WORKGROUP';
  final domainUtf16 = Uint8List(domain.length * 2);
  final dbd = ByteData.sublistView(domainUtf16);
  for (int i = 0; i < domain.length; i++) {
    dbd.setUint16(i * 2, domain.codeUnitAt(i), Endian.little);
  }

  // type(2) + len(2) + data + EOL(4)
  final info = Uint8List(4 + domainUtf16.length + 4);
  final ibd = ByteData.sublistView(info);
  // MsvAvNbDomainName = 0x0002
  ibd.setUint16(0, 0x0002, Endian.little);
  ibd.setUint16(2, domainUtf16.length, Endian.little);
  info.setRange(4, 4 + domainUtf16.length, domainUtf16);
  // MsvAvEOL = 0x0000, length = 0
  ibd.setUint16(4 + domainUtf16.length, 0, Endian.little);
  ibd.setUint16(4 + domainUtf16.length + 2, 0, Endian.little);

  return info;
}
