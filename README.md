# dart_smb2

SMB2/2.1/3.0 client library for Dart with true message multiplexing.

## Why not smb_connect?

`smb_connect` serializes all send/receive through a single mutex, making parallel file reads effectively sequential. `dart_smb2` uses MessageId-based multiplexing: sends are serialized (protecting the socket), but a dedicated receive loop dispatches responses by MessageId, enabling true parallel I/O.

## Usage

```dart
import 'package:dart_smb2/dart_smb2.dart';

// Connect and authenticate
final client = await Smb2Client.connect(
  host: '192.168.1.100',
  username: 'user',
  password: 'pass',
);

// Connect to a share
final tree = await client.connectTree('photos');

// List directory
final files = await tree.listDirectory('/vacation');

// Read a file (streaming)
final reader = await tree.openRead('/vacation/photo.jpg');
await for (final chunk in reader.readStream()) {
  // process chunk
}

// Parallel reads (true multiplexing)
final futures = files
    .where((f) => !f.isDirectory)
    .map((f) => tree.openRead(f.path));
final readers = await Future.wait(futures);

// Disconnect
await client.disconnect();
```

## Phase 1 (current)

- TCP connection (port 445)
- SMB2 Negotiate (dialects 0x0202, 0x0210, 0x0300)
- NTLMSSP authentication (NTLMv2)
- Tree Connect/Disconnect
- Create (open file/directory)
- Read (streaming, up to 1MB blocks)
- QueryDirectory (file listing)
- Close
- MessageId-based multiplexing

## Testing

```bash
# Unit tests
dart test

# Integration tests (requires a real SMB server)
SMB_HOST=192.168.1.100 SMB_SHARE=photos SMB_USER=user SMB_PASS=pass \
  dart test --reporter expanded test/integration/
```

Integration tests are skipped automatically when `SMB_HOST` is not set.

| Variable | Required | Description |
|----------|----------|-------------|
| `SMB_HOST` | yes | SMB server IP or hostname |
| `SMB_SHARE` | yes | Share name |
| `SMB_USER` | yes | Username |
| `SMB_PASS` | yes | Password |
| `SMB_PORT` | no | Port (default: 445) |

## Phase 2 (planned)

- Write, file creation, delete, rename
- SMB3 encryption & signing
- Multi-channel
