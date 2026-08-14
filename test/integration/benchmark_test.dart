// ignore_for_file: avoid_print
//
// print is the output of this file, not a leftover from debugging it. An
// integration run reports what it found -- which server, how many files, how
// fast -- and `dart test` shows exactly that. Routing it through
// package:logging would put a handler in the middle whose only job is to
// print it again.
//
// The ban this suspends (CLAUDE.md, avoid_print) is about the library and the
// app, where output has one sink and it is configured elsewhere. It still
// applies there, which is why this is declared per file rather than turned
// off for the package.

@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:dart_smb2/dart_smb2.dart';

import 'env.dart';

/// Performance benchmark for tuning read-ahead and parallelism.
///
/// Environment variables:
///   SMB_HOST, SMB_SHARE, SMB_USER, SMB_PASS  (required)
///   SMB_BENCH_FILE       - single file path to benchmark (e.g. "photos/large.png")
///   SMB_BENCH_DIR        - directory path to benchmark parallel reads (e.g. "photos")
///   SMB_BENCH_READAHEAD  - read-ahead count for streaming (default: 3)
///   SMB_BENCH_PARALLEL   - parallel download count (default: 3)
///   SMB_BENCH_MAX_FILES  - max files to read from directory (default: 20)
///
/// Example:
///   SMB_HOST=192.168.99.100 SMB_SHARE=photos SMB_USER=user SMB_PASS=xxx \
///     SMB_BENCH_FILE="photo.png" SMB_BENCH_READAHEAD=5 \
///     dart test --reporter expanded test/integration/benchmark_test.dart
void main() {
  if (!hasIntegrationEnv) {
    test('skip: SMB_HOST not set', () {}, skip: 'Set SMB_HOST to run');
    return;
  }

  final processEnv = Platform.environment;
  final benchFile = processEnv['SMB_BENCH_FILE'];
  final benchDir = processEnv['SMB_BENCH_DIR'];
  final readAhead = int.tryParse(processEnv['SMB_BENCH_READAHEAD'] ?? '') ?? 3;
  final parallel = int.tryParse(processEnv['SMB_BENCH_PARALLEL'] ?? '') ?? 3;
  final maxFiles = int.tryParse(processEnv['SMB_BENCH_MAX_FILES'] ?? '') ?? 20;

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

  if (benchFile != null && benchFile.isNotEmpty) {
    test('single file benchmark', () async {
      print('[bench] File: $benchFile');

      // Warm up
      final warmReader = await tree.openRead(benchFile);
      final fileSize = warmReader.fileSize;
      await warmReader.close();
      print('[bench] File size: ${(fileSize / 1024).toStringAsFixed(0)} KB');

      for (final ra in [1, 2, 3, 5, 8]) {
        final sw = Stopwatch()..start();
        final reader = await tree.openRead(benchFile);
        int totalBytes = 0;
        await for (final chunk in reader.readStream(readAhead: ra)) {
          totalBytes += chunk.length;
        }
        await reader.close();
        sw.stop();

        final seconds = sw.elapsedMilliseconds / 1000;
        final speed = seconds > 0 ? (totalBytes / 1024 / seconds).toStringAsFixed(0) : '?';
        print('[bench] readAhead=$ra: ${(totalBytes / 1024).toStringAsFixed(0)} KB '
            'in ${seconds.toStringAsFixed(3)}s ($speed KB/s)');
      }
    }, timeout: Timeout(Duration(minutes: 2)));
  }

  if (benchDir != null && benchDir.isNotEmpty) {
    test('parallel directory benchmark', () async {
      print('[bench] Dir: $benchDir, parallel: $parallel, readAhead: $readAhead, maxFiles: $maxFiles');

      final files = await tree.listDirectory(benchDir);
      final readableFiles = files
          .where((f) => !f.isDirectory && f.size > 0)
          .take(maxFiles)
          .toList();

      print('[bench] Found ${readableFiles.length} files');
      if (readableFiles.isEmpty) return;

      final totalSize = readableFiles.fold<int>(0, (sum, f) => sum + f.size);
      print('[bench] Total size: ${(totalSize / 1024).toStringAsFixed(0)} KB');

      for (final par in [1, 2, 3, 5, 8]) {
        final sw = Stopwatch()..start();
        int downloaded = 0;

        for (int i = 0; i < readableFiles.length; i += par) {
          final end = (i + par).clamp(0, readableFiles.length);
          final batch = readableFiles.sublist(i, end);
          await Future.wait(batch.map((f) async {
            final reader = await tree.openRead(f.path);
            try {
              await for (final chunk in reader.readStream(readAhead: readAhead)) {
                downloaded += chunk.length;
              }
            } finally {
              await reader.close();
            }
          }));
        }

        sw.stop();
        final seconds = sw.elapsedMilliseconds / 1000;
        final speed = seconds > 0 ? (downloaded / 1024 / seconds).toStringAsFixed(0) : '?';
        print('[bench] parallel=$par: ${(downloaded / 1024).toStringAsFixed(0)} KB '
            'in ${seconds.toStringAsFixed(3)}s ($speed KB/s)');
      }
    }, timeout: Timeout(Duration(minutes: 5)));
  }

  if ((benchFile == null || benchFile.isEmpty) && (benchDir == null || benchDir.isEmpty)) {
    test('no benchmark target', () {
      print('[bench] Set SMB_BENCH_FILE or SMB_BENCH_DIR to run benchmarks');
    });
  }
}
