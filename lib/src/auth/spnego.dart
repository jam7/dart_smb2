import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';

/// SPNEGO (Simple and Protected GSS-API Negotiation) wrapper for NTLMSSP.
///
/// Wraps NTLMSSP tokens in ASN.1 structures for SMB2 session setup.
class SpnegoAuth {
  // OID: 1.3.6.1.5.5.2 (SPNEGO)
  static final _spnegoOid = ASN1ObjectIdentifier.fromComponents([1, 3, 6, 1, 5, 5, 2]);
  // OID: 1.3.6.1.4.1.311.2.2.10 (NTLMSSP)
  static final _ntlmsspOid = ASN1ObjectIdentifier.fromComponents([1, 3, 6, 1, 4, 1, 311, 2, 2, 10]);

  /// Wrap a Type1 NTLMSSP message in a SPNEGO NegTokenInit.
  static Uint8List wrapType1(Uint8List ntlmType1) {
    // MechanismList: SEQUENCE { OID(NTLMSSP) }
    final mechList = ASN1Sequence();
    mechList.add(_ntlmsspOid);

    // MechTypes: context[0] { mechList }
    final mechTypes = ASN1Sequence(tag: 0xA0);
    mechTypes.add(mechList);

    // MechToken: context[2] { OCTET STRING(ntlmType1) }
    final mechToken = ASN1Sequence(tag: 0xA2);
    mechToken.add(ASN1OctetString(ntlmType1));

    // NegTokenInit: SEQUENCE { mechTypes, mechToken }
    final negTokenInit = ASN1Sequence();
    negTokenInit.add(mechTypes);
    negTokenInit.add(mechToken);

    // Wrap in context[0] for NegotiationToken choice
    final negTokenInitContext = ASN1Sequence(tag: 0xA0);
    negTokenInitContext.add(negTokenInit);

    // Application[0] { OID(SPNEGO), NegTokenInit }
    final app = ASN1Sequence(tag: 0x60);
    app.add(_spnegoOid);
    app.add(negTokenInitContext);

    return Uint8List.fromList(app.encodedBytes);
  }

  /// Wrap a Type3 NTLMSSP message in a SPNEGO NegTokenTarg.
  static Uint8List wrapType3(Uint8List ntlmType3) {
    // ResponseToken: context[2] { OCTET STRING(ntlmType3) }
    final responseToken = ASN1Sequence(tag: 0xA2);
    responseToken.add(ASN1OctetString(ntlmType3));

    // NegTokenTarg: SEQUENCE { responseToken }
    final negTokenTarg = ASN1Sequence();
    negTokenTarg.add(responseToken);

    // Wrap in context[1] for NegotiationToken choice
    final result = ASN1Sequence(tag: 0xA1);
    result.add(negTokenTarg);

    return Uint8List.fromList(result.encodedBytes);
  }

  /// Extract the NTLMSSP token from a SPNEGO response (NegTokenTarg).
  /// Returns the raw NTLMSSP bytes (Type2 message).
  static Uint8List unwrapType2(Uint8List spnegoToken) {
    // Try to find NTLMSSP signature in the raw bytes as a fallback
    final ntlmssSignature = [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00];

    try {
      final parser = ASN1Parser(spnegoToken);

      // The top-level could be:
      // 1. Application[0] { OID, NegTokenInit } (NegTokenInit from server)
      // 2. Context[1] { NegTokenTarg } (NegTokenTarg)
      final topLevel = parser.nextObject();

      return _findNtlmToken(topLevel, ntlmssSignature);
    } on Object {
      // ASN.1 parse failed (FormatException, RangeError, ASN1Exception etc.)
      // Fallback to raw byte scan
      return _scanForNtlmssp(spnegoToken, ntlmssSignature);
    }
  }

  static Uint8List _findNtlmToken(ASN1Object obj, List<int> signature) {
    // If this is an octet string, check if it contains NTLMSSP
    if (obj is ASN1OctetString) {
      final bytes = obj.valueBytes();
      if (bytes.length >= 8 && _startsWith(bytes, signature)) {
        return Uint8List.fromList(bytes);
      }
    }

    // Recurse into sequences
    if (obj is ASN1Sequence) {
      for (final child in obj.elements) {
        try {
          return _findNtlmToken(child, signature);
        } on FormatException {
          continue; // This child doesn't contain the token
        }
      }
    }

    // Try to parse sub-elements (may throw various exceptions from asn1lib)
    if (obj.valueBytes().length > 2) {
      try {
        final subParser = ASN1Parser(obj.valueBytes());
        while (subParser.hasNext()) {
          final sub = subParser.nextObject();
          try {
            return _findNtlmToken(sub, signature);
          } on FormatException {
            continue; // This sub-element doesn't contain the token
          }
        }
      } on Object {
        // asn1lib throws RangeError, ASN1Exception etc. for unparseable data
      }
    }

    throw FormatException('NTLMSSP token not found in ASN.1 structure');
  }

  static Uint8List _scanForNtlmssp(Uint8List data, List<int> signature) {
    for (int i = 0; i <= data.length - 8; i++) {
      if (_startsWith(Uint8List.sublistView(data, i), signature)) {
        return Uint8List.fromList(data.sublist(i));
      }
    }
    throw FormatException('NTLMSSP signature not found in SPNEGO token');
  }

  static bool _startsWith(Uint8List data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }
}
