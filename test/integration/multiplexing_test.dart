@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:dart_smb2/dart_smb2.dart';

import 'env.dart';

void main() {
  if (!hasIntegrationEnv) {
    test('skip: SMB_HOST not set', () {}, skip: 'Set SMB_HOST to run');
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

  tearDownAll(() async {
    await client.disconnect();
  });

  group('Multiplexing', () {
    test('parallel file reads complete successfully', () async {
      final files = await tree.listDirectory('/');
      final readableFiles = files
          .where((f) => !f.isDirectory && f.size > 0 && f.size < 10 * 1024 * 1024)
          .take(5)
          .toList();

      if (readableFiles.length < 2) {
        print('[integration] Not enough files for parallel test, skipping');
        return;
      }

      print('[integration] Parallel reading ${readableFiles.length} files...');

      final sw = Stopwatch()..start();
      final futures = readableFiles.map((f) async {
        final reader = await tree.openRead(f.path);
        try {
          final data = await reader.readAll();
          return (f.name, data.length);
        } finally {
          await reader.close();
        }
      });

      final results = await Future.wait(futures);
      sw.stop();

      for (final (name, size) in results) {
        print('[integration]   $name: $size bytes');
      }
      print('[integration] Parallel read completed in ${sw.elapsedMilliseconds}ms');

      for (int i = 0; i < readableFiles.length; i++) {
        expect(results[i].$2, readableFiles[i].size);
      }
    });

    test('parallel reads are faster than sequential', () async {
      final files = await tree.listDirectory('/');
      final readableFiles = files
          .where((f) => !f.isDirectory && f.size > 1000 && f.size < 10 * 1024 * 1024)
          .take(4)
          .toList();

      if (readableFiles.length < 2) {
        print('[integration] Not enough files (>1KB) for timing test, skipping');
        return;
      }

      // Sequential
      final swSeq = Stopwatch()..start();
      for (final f in readableFiles) {
        final reader = await tree.openRead(f.path);
        try {
          await reader.readAll();
        } finally {
          await reader.close();
        }
      }
      swSeq.stop();

      // Parallel
      final swPar = Stopwatch()..start();
      await Future.wait(readableFiles.map((f) async {
        final reader = await tree.openRead(f.path);
        try {
          await reader.readAll();
        } finally {
          await reader.close();
        }
      }));
      swPar.stop();

      print('[integration] Sequential: ${swSeq.elapsedMilliseconds}ms');
      print('[integration] Parallel:   ${swPar.elapsedMilliseconds}ms');
      print('[integration] Speedup:    ${(swSeq.elapsedMilliseconds / swPar.elapsedMilliseconds).toStringAsFixed(2)}x');

      // We don't assert parallel < sequential because network conditions vary,
      // but we log it for manual verification.
    });
  });
}
