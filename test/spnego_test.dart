import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dart_smb2/src/auth/ntlmssp.dart';
import 'package:dart_smb2/src/auth/spnego.dart';

void main() {
  group('SpnegoAuth', () {
    test('wrapType1 produces valid ASN.1 with SPNEGO OID', () {
      final auth = NtlmAuth(username: 'user', password: 'pass');
      final type1 = auth.createType1Message();
      final wrapped = SpnegoAuth.wrapType1(type1);

      // Should start with Application tag 0x60
      expect(wrapped[0], 0x60);

      // Should contain SPNEGO OID (1.3.6.1.5.5.2)
      // DER: 06 06 2B 06 01 05 05 02
      expect(_containsBytes(wrapped, [0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02]), true);

      // Should contain NTLMSSP OID (1.3.6.1.4.1.311.2.2.10)
      expect(_containsBytes(wrapped, [0x06, 0x0A]), true);
    });

    test('wrapType1 embeds NTLMSSP token', () {
      final auth = NtlmAuth(username: 'user', password: 'pass');
      final type1 = auth.createType1Message();
      final wrapped = SpnegoAuth.wrapType1(type1);

      // The wrapped token should contain the NTLMSSP signature
      expect(
        _containsBytes(wrapped, [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]),
        true,
      );
    });

    test('wrapType3 produces context tag 0xA1', () {
      final type3 = Uint8List.fromList([
        0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00, // NTLMSSP\0
        0x03, 0x00, 0x00, 0x00, // Type 3
        ...List.filled(20, 0), // Padding
      ]);
      final wrapped = SpnegoAuth.wrapType3(type3);

      // Should start with context tag 0xA1
      expect(wrapped[0], 0xA1);
    });

    test('unwrapType2 extracts NTLMSSP token from SPNEGO', () {
      // Build a wrapped Type2 message (NegTokenTarg with NTLMSSP Type2 inside)
      final type2Bytes = _buildRawType2();
      final wrapped = _wrapInNegTokenTarg(type2Bytes);

      final extracted = SpnegoAuth.unwrapType2(wrapped);

      // Should start with NTLMSSP signature
      expect(extracted.sublist(0, 8), [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
      // Should be Type2
      final bd = ByteData.sublistView(extracted);
      expect(bd.getUint32(8, Endian.little), 2);
    });

    test('unwrapType2 uses fallback scan when ASN.1 parsing fails', () {
      // Just put NTLMSSP signature somewhere in garbage data
      final type2 = _buildRawType2();
      final garbage = Uint8List.fromList([
        0xFF, 0xFF, 0xFF, // Garbage
        ...type2,
      ]);

      final extracted = SpnegoAuth.unwrapType2(garbage);
      expect(extracted.sublist(0, 8), [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
    });

    test('unwrapType2 throws when no NTLMSSP found', () {
      final garbage = Uint8List.fromList(List.filled(32, 0xFF));
      expect(() => SpnegoAuth.unwrapType2(garbage), throwsFormatException);
    });

    test('roundtrip: wrap Type1 then unwrap finds NTLMSSP', () {
      final auth = NtlmAuth(username: 'user', password: 'pass');
      final type1 = auth.createType1Message();
      final wrapped = SpnegoAuth.wrapType1(type1);

      // unwrapType2 should find the NTLMSSP token even though it's Type1
      // (it just looks for the signature)
      final extracted = SpnegoAuth.unwrapType2(wrapped);
      expect(extracted.sublist(0, 8), [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
    });
  });
}

bool _containsBytes(Uint8List data, List<int> pattern) {
  for (int i = 0; i <= data.length - pattern.length; i++) {
    bool match = true;
    for (int j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Build a minimal raw NTLMSSP Type2 message.
Uint8List _buildRawType2() {
  final msg = Uint8List(56);
  final bd = ByteData.sublistView(msg);
  msg.setRange(0, 8, [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
  bd.setUint32(8, 2, Endian.little); // MessageType = 2
  // Rest is zeros (minimal valid)
  return msg;
}

/// Wrap raw bytes in a minimal ASN.1 NegTokenTarg structure.
Uint8List _wrapInNegTokenTarg(Uint8List token) {
  // Build: A1 { SEQUENCE { A2 { OCTET STRING { token } } } }
  // This is a simplified manual ASN.1 encoding

  // OCTET STRING
  final octetTag = 0x04;
  final octetLen = token.length;
  final octet = Uint8List(2 + octetLen);
  octet[0] = octetTag;
  octet[1] = octetLen;
  octet.setRange(2, 2 + octetLen, token);

  // A2 context
  final a2 = Uint8List(2 + octet.length);
  a2[0] = 0xA2;
  a2[1] = octet.length;
  a2.setRange(2, 2 + octet.length, octet);

  // SEQUENCE
  final seq = Uint8List(2 + a2.length);
  seq[0] = 0x30;
  seq[1] = a2.length;
  seq.setRange(2, 2 + a2.length, a2);

  // A1 context
  final result = Uint8List(2 + seq.length);
  result[0] = 0xA1;
  result[1] = seq.length;
  result.setRange(2, 2 + seq.length, seq);

  return result;
}
