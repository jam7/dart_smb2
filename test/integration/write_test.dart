// ignore_for_file: avoid_print
//
// print is the output of this file, not a leftover from debugging it. The
// same declaration as the other integration tests -- see
// file_operations_test.dart for what ban this suspends and why it is per
// file.

@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:dart_smb2/dart_smb2.dart';

import 'env.dart';

/// Writing against a real server, which is the only place it can be checked.
///
/// A scripted server can be told to accept anything, so the unit tests can
/// only pin what went on the wire. Whether the bytes are *there afterwards*
/// is a question for a share: every test here writes something and reads it
/// back.
///
/// Needs `SMB_WRITE_DIR` on top of the usual environment (see the README): a
/// directory the tests may create and delete files in. Without it they skip
/// rather than write somewhere unexpected.
void main() {
  if (!hasIntegrationEnv) {
    test('skip: SMB_HOST not set', () {}, skip: 'Set SMB_HOST to run');
    return;
  }
  if (!hasWriteDir) {
    test('skip: SMB_WRITE_DIR not set', () {},
        skip: 'Set SMB_WRITE_DIR to a directory these tests may write into');
    return;
  }

  late TestEnv env;
  late Smb2Client client;
  late Smb2Tree tree;

  setUpAll(() async {
    env = TestEnv.load();
    client = await Smb2Client.connect(
      host: env.host,
      port: env.port,
      username: env.username,
      password: env.password,
    );
    tree = await client.connectTree(env.share);
  });

  tearDownAll(() async => client.disconnect());

  /// A name nothing else is using, inside the directory set aside for this.
  ///
  /// The counter keeps two tests in one run apart; the run's own tag keeps
  /// this run apart from the last one, whose files cannot be deleted yet
  /// (delete arrives in a later stage, so these are left behind on purpose
  /// and the directory is expected to be one that can be swept by hand).
  var _n = 0;
  String aFreshName() => '${env.writeDir}/write-test-${env.runTag}-${_n++}.bin';

  Uint8List pattern(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = (i * 31 + 7) & 0xFF;
    }
    return bytes;
  }

  Future<void> writeThenExpect(String path, List<Uint8List> parts) async {
    final writer = await tree.createNew(path);
    for (final part in parts) {
      await writer.write(part);
    }
    await writer.close();

    final expected = <int>[for (final part in parts) ...part];
    final read = await tree.readFile(path);
    expect(read.length, expected.length, reason: 'the file is the right size');
    expect(read, expected, reason: 'and holds what was handed over');
    expect(writer.written, expected.length);
  }

  // T-14: S-02 the bytes are there afterwards, in order
  test('what was written comes back the same', () async {
    final path = aFreshName();
    await writeThenExpect(path, [pattern(1000), pattern(2000), pattern(3)]);
    print('[integration] wrote and verified 3003 bytes at $path');
  });

  // T-15: S-02 an empty file is a file
  test('a file with nothing in it is created all the same', () async {
    final path = aFreshName();
    final writer = await tree.createNew(path);
    await writer.close();

    final read = await tree.readFile(path);
    expect(read, isEmpty);
    expect(writer.written, 0);
  });

  // T-16: S-03 the server's limit is crossed without the caller doing anything
  test('a buffer larger than one request survives the crossing', () async {
    final path = aFreshName();
    // Two megabytes: over the 1MB ceiling a request is held to, so this has
    // to become more than one Write and come back as one file.
    final big = pattern(2 * 1024 * 1024);

    await writeThenExpect(path, [big]);
    print('[integration] wrote and verified ${big.length} bytes at $path');
  });

  // T-17: S-01 a name already in use is refused, and nothing is disturbed
  test('writing to a name that exists changes nothing', () async {
    final path = aFreshName();
    final first = pattern(500);
    await writeThenExpect(path, [first]);

    await expectLater(tree.createNew(path), throwsA(isA<Smb2Exception>()));

    final read = await tree.readFile(path);
    expect(read, first, reason: 'the file that was there is untouched');
  });

  // T-18: S-06 reading and writing share a connection without disturbing
  // each other
  test('a read between two writes finds what the first one wrote', () async {
    final path = aFreshName();
    final writer = await tree.createNew(path);
    await writer.write(pattern(100));

    final listing = await tree.listDirectory(env.writeDir);
    expect(listing.map((f) => f.name), contains(path.split('/').last));

    await writer.write(pattern(100));
    await writer.close();

    final read = await tree.readFile(path);
    expect(read.length, 200);
  });
}
