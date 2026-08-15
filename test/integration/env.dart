import 'dart:io';

/// Returns true if SMB_HOST is set (i.e. integration tests should run).
bool get hasIntegrationEnv => Platform.environment['SMB_HOST']?.isNotEmpty == true;

/// Returns true if a directory has been set aside for tests that write.
bool get hasWriteDir =>
    Platform.environment['SMB_WRITE_DIR']?.isNotEmpty == true;

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
        'Usage: SMB_HOST=192.168.99.100 SMB_SHARE=photos SMB_USER=user SMB_PASS=pass '
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

  /// Where the write tests may create files. Guarded by [hasWriteDir], which
  /// is what those tests check before they run: a test that writes should
  /// skip rather than guess at a directory on somebody's share.
  String get writeDir => Platform.environment['SMB_WRITE_DIR']!;

  /// Tells one run's files from the last one's. Files are left behind for
  /// now (deleting them needs an operation this stage does not have), so
  /// without this a second run would collide with the first.
  String get runTag => pid.toString();

  /// Which directory a test that needs a big one should list.
  ///
  /// Kept out of the source because what is large differs per share, and the
  /// paths on a real one are nobody's business but its owner's.
  String get listDir => Platform.environment['SMB_LIST_DIR'] ?? '/';
}
