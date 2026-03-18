import 'dart:io';

/// Returns true if SMB_HOST is set (i.e. integration tests should run).
bool get hasIntegrationEnv => Platform.environment['SMB_HOST']?.isNotEmpty == true;

/// Read required SMB connection settings from environment variables.
/// Fails with a clear message if any are missing.
class TestEnv {
  final String host;
  final String share;
  final String username;
  final String password;
  final int port;

  TestEnv._({
    required this.host,
    required this.share,
    required this.username,
    required this.password,
    required this.port,
  });

  static TestEnv load() {
    final env = Platform.environment;
    final missing = <String>[];

    final host = env['SMB_HOST'];
    final share = env['SMB_SHARE'];
    final username = env['SMB_USER'];
    final password = env['SMB_PASS'];
    final port = int.tryParse(env['SMB_PORT'] ?? '445') ?? 445;

    if (host == null || host.isEmpty) missing.add('SMB_HOST');
    if (share == null || share.isEmpty) missing.add('SMB_SHARE');
    if (username == null || username.isEmpty) missing.add('SMB_USER');
    if (password == null || password.isEmpty) missing.add('SMB_PASS');

    if (missing.isNotEmpty) {
      throw StateError(
        'Missing required environment variables: ${missing.join(', ')}\n'
        'Usage: SMB_HOST=192.168.1.100 SMB_SHARE=photos SMB_USER=user SMB_PASS=pass '
        'dart test --tags integration',
      );
    }

    return TestEnv._(
      host: host!,
      share: share!,
      username: username!,
      password: password!,
      port: port,
    );
  }
}
