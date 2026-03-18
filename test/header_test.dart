import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dart_smb2/src/protocol/header.dart';
import 'package:dart_smb2/src/protocol/commands.dart';

void main() {
  group('Smb2Header', () {
    test('encode produces 64 bytes with correct protocol ID', () {
      final header = Smb2Header(command: Smb2Command.negotiate);
      final buf = Uint8List(64);
      final written = header.encode(buf, 0);

      expect(written, 64);
      // 0xFE 'S' 'M' 'B'
      expect(buf[0], 0xFE);
      expect(buf[1], 0x53);
      expect(buf[2], 0x4D);
      expect(buf[3], 0x42);
    });

    test('encode sets StructureSize to 64', () {
      final header = Smb2Header();
      final buf = Uint8List(64);
      header.encode(buf, 0);

      final data = ByteData.sublistView(buf);
      expect(data.getUint16(4, Endian.little), 64);
    });

    test('encode/decode roundtrip preserves all fields', () {
      final original = Smb2Header(
        creditCharge: 3,
        status: 0xC000006D, // STATUS_LOGON_FAILURE
        command: Smb2Command.sessionSetup,
        creditRequestResponse: 32,
        flags: Smb2Flags.signed,
        nextCommand: 0,
        messageId: 42,
        treeId: 7,
        sessionId: 0x123456789ABC,
        signature: Uint8List.fromList(List.generate(16, (i) => i + 1)),
      );

      final buf = Uint8List(64);
      original.encode(buf, 0);
      final decoded = Smb2Header.decode(buf, 0);

      expect(decoded.creditCharge, original.creditCharge);
      expect(decoded.status, original.status);
      expect(decoded.command, original.command);
      expect(decoded.creditRequestResponse, original.creditRequestResponse);
      expect(decoded.flags, original.flags);
      expect(decoded.nextCommand, original.nextCommand);
      expect(decoded.messageId, original.messageId);
      expect(decoded.treeId, original.treeId);
      expect(decoded.sessionId, original.sessionId);
      expect(decoded.signature, original.signature);
    });

    test('decode throws on invalid protocol ID', () {
      final buf = Uint8List(64);
      buf[0] = 0xFF; // Wrong

      expect(() => Smb2Header.decode(buf, 0), throwsFormatException);
    });

    test('isResponse flag works correctly', () {
      final request = Smb2Header(flags: 0);
      expect(request.isResponse, false);

      final response = Smb2Header(flags: Smb2Flags.serverToRedir);
      expect(response.isResponse, true);
    });

    test('encode with non-zero offset', () {
      final header = Smb2Header(command: Smb2Command.read, messageId: 99);
      final buf = Uint8List(128);
      header.encode(buf, 64);

      // Protocol ID at offset 64
      expect(buf[64], 0xFE);
      expect(buf[65], 0x53);

      final decoded = Smb2Header.decode(buf, 64);
      expect(decoded.command, Smb2Command.read);
      expect(decoded.messageId, 99);
    });

    test('64-bit sessionId roundtrip', () {
      final header = Smb2Header(sessionId: 0x7FFFFFFFFFFFFFFF);
      final buf = Uint8List(64);
      header.encode(buf, 0);
      final decoded = Smb2Header.decode(buf, 0);
      expect(decoded.sessionId, 0x7FFFFFFFFFFFFFFF);
    });

    test('64-bit messageId roundtrip', () {
      final header = Smb2Header(messageId: 0x7FFFFFFFFFFFFFFF);
      final buf = Uint8List(64);
      header.encode(buf, 0);
      final decoded = Smb2Header.decode(buf, 0);
      expect(decoded.messageId, 0x7FFFFFFFFFFFFFFF);
    });
  });
}
