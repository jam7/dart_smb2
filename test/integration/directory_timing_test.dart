// ignore_for_file: avoid_print
//
// print is the output of this file, not a leftover from debugging it. This
// one exists to report numbers to a person, so the numbers are the output.
// The same declaration as the other integration tests -- see
// file_operations_test.dart for what ban this suspends and why it is per
// file.

@Tags(['integration'])
library;

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:dart_smb2/dart_smb2.dart';

import 'env.dart';

/// Where a listing's time goes: many round trips, or one slow one.
///
/// Two fixes have been proposed for "a big directory shows nothing until it
/// is all there", and they repair different faults. Handing back partial
/// results helps when there are many round trips. Passing the server's
/// "still working" to the caller helps when one round trip takes seconds.
/// Neither helps the other case, and nobody has measured which one this is.
///
/// Runs on the same environment as the other integration tests (see the
/// README), with one more: `SMB_LIST_DIR` names the directory to list, and
/// should be the largest one there is. Without it the share's root is listed,
/// which asks the same question of a smaller sample.
void main() {
  if (!hasIntegrationEnv) {
    test('skip: SMB_HOST not set', () {}, skip: 'Set SMB_HOST to run');
    return;
  }

  late TestEnv env;
  late Smb2Client client;
  late Smb2Tree tree;

  setUpAll(() async {
    // The per-trip lines are FINE, being of interest only while a question
    // like this one is open.
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((r) {
      if (r.message.contains('ueryDirectory') ||
          r.message.contains('listDirectory')) {
        print('[timing] ${r.message}');
      }
    });

    env = TestEnv.load();
    client = await Smb2Client.connect(
      host: env.host,
      port: env.port,
      username: env.username,
      password: env.password,
    );
    tree = await client.connectTree(env.share);
  });

  tearDownAll(() async {
    await client.disconnect();
  });

  test('a listing reports its round trips and their cost', () async {
    final where = env.listDir;
    final wall = Stopwatch()..start();
    final files = await tree.listDirectory(where);
    wall.stop();

    print('[timing] ${files.length} entries in ${wall.elapsedMilliseconds}ms '
        'for the whole call');
    if (files.length < 200) {
      print('[timing] NOTE: this directory is small, so it cannot show the '
          'fault being investigated. Set SMB_LIST_DIR to the largest one '
          'there is.');
    }

    expect(files, isNotEmpty,
        reason: 'an empty directory measures nothing; pick another');
  });
}
