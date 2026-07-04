import 'dart:typed_data';

/// Encode [s] as UTF-16LE bytes, as used for all SMB2 string fields
/// (file names, share paths, search patterns).
Uint8List encodeUtf16Le(String s) {
  final units = s.codeUnits;
  final bytes = Uint8List(units.length * 2);
  final bd = ByteData.sublistView(bytes);
  for (int i = 0; i < units.length; i++) {
    bd.setUint16(i * 2, units[i], Endian.little);
  }
  return bytes;
}
