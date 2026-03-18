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

  setUpAll(() {
    env = TestEnv.load();
  });

  group('Connect and authenticate', () {
    test('connects and negotiates SMB2', () async {
      client = await Smb2Client.connect(
        host: env.host,
        port: env.port,
        username: env.username,
        password: env.password,
      );

      expect(client.sessionId, isNonZero);
      expect(client.dialectRevision, isIn([
        Smb2Dialect.smb202,
        Smb2Dialect.smb210,
        Smb2Dialect.smb300,
      ]));

      await client.disconnect();
    });

    test('rejects wrong password', () async {
      expect(
        () => Smb2Client.connect(
          host: env.host,
          port: env.port,
          username: env.username,
          password: 'wrong_password_12345',
        ),
        throwsA(isA<Smb2Exception>()),
      );
    });
  });
}
