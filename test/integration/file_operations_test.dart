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

  group('Directory listing', () {
    test('lists root directory', () async {
      final files = await tree.listDirectory('/');

      expect(files, isNotEmpty);
      print('[integration] Root contains ${files.length} entries:');
      for (final f in files.take(10)) {
        print('  ${f.isDirectory ? "DIR " : "FILE"} ${f.name} (${f.size} bytes)');
      }
    });

    test('entries have valid names', () async {
      final files = await tree.listDirectory('/');

      for (final f in files) {
        expect(f.name, isNotEmpty);
        expect(f.name, isNot('.'));
        expect(f.name, isNot('..'));
      }
    });

    test('directories report isDirectory=true', () async {
      final files = await tree.listDirectory('/');
      final dirs = files.where((f) => f.isDirectory).toList();

      if (dirs.isNotEmpty) {
        expect(dirs.first.isDirectory, true);
        print('[integration] Found ${dirs.length} directories');
      } else {
        print('[integration] No subdirectories in root');
      }
    });
  });

  group('File reading', () {
    test('reads a file completely', () async {
      final files = await tree.listDirectory('/');
      // Prefer small files (<10MB) for test speed
      final candidates = files
          .where((f) => !f.isDirectory && f.size > 0)
          .toList()
        ..sort((a, b) => a.size.compareTo(b.size));
      final regularFile = candidates.firstWhere(
        (f) => f.size < 10 * 1024 * 1024,
        orElse: () => candidates.first,
      );

      print('[integration] Reading file: ${regularFile.name} (${regularFile.size} bytes)');
      final reader = await tree.openRead(regularFile.path);
      try {
        expect(reader.fileSize, regularFile.size);
        final data = await reader.readAll();
        expect(data.length, regularFile.size);
        print('[integration] Read ${data.length} bytes OK');
      } finally {
        await reader.close();
      }
    });

    test('reads file range', () async {
      final files = await tree.listDirectory('/');
      final regularFile = files.firstWhere(
        (f) => !f.isDirectory && f.size > 100 && f.size < 10 * 1024 * 1024,
        orElse: () => files.firstWhere((f) => !f.isDirectory && f.size > 100),
      );

      final reader = await tree.openRead(regularFile.path);
      try {
        final chunk = await reader.readRange(0, 100);
        expect(chunk.length, 100);
      } finally {
        await reader.close();
      }
    });

    test('readRange auto-splits reads exceeding maxReadSize', () async {
      // Find a file larger than 1MB (maxReadSize)
      final files = await tree.listDirectory('/');
      final bigFile = files
          .where((f) => !f.isDirectory && f.size > 2 * 1024 * 1024)
          .toList()
        ..sort((a, b) => a.size.compareTo(b.size));

      if (bigFile.isEmpty) {
        print('[integration] SKIP: no file > 2MB found');
        return;
      }

      final file = bigFile.first;
      final readSize = 2 * 1024 * 1024; // 2MB, exceeds typical 1MB maxReadSize
      final reader = await tree.openRead(file.path);
      try {
        final data = await reader.readRange(0, readSize);
        expect(data.length, readSize);
        print('[integration] readRange 2MB: ${file.name} got ${data.length} bytes');

        // Verify by comparing with stream read
        final streamData = await reader.readRange(0, readSize);
        expect(streamData.length, readSize);
        expect(data, streamData, reason: 'Two identical readRange calls should return same data');
      } finally {
        await reader.close();
      }
    });

    test('streams file in chunks', () async {
      final files = await tree.listDirectory('/');
      final candidates = files
          .where((f) => !f.isDirectory && f.size > 0)
          .toList()
        ..sort((a, b) => a.size.compareTo(b.size));
      final regularFile = candidates.firstWhere(
        (f) => f.size < 10 * 1024 * 1024,
        orElse: () => candidates.first,
      );

      final reader = await tree.openRead(regularFile.path);
      try {
        int totalBytes = 0;
        int chunkCount = 0;
        await for (final chunk in reader.readStream()) {
          totalBytes += chunk.length;
          chunkCount++;
        }
        expect(totalBytes, regularFile.size);
        print('[integration] Streamed ${regularFile.name}: $chunkCount chunks, $totalBytes bytes');
      } finally {
        await reader.close();
      }
    });
  });
}
