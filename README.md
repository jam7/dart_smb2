# dart_smb2

SMB2/2.1/3.0 client library for Dart with true message multiplexing.

## Why not smb_connect?

`smb_connect` serializes all send/receive through a single mutex, making parallel file reads effectively sequential. `dart_smb2` uses MessageId-based multiplexing: sends are serialized (protecting the socket), but a dedicated receive loop dispatches responses by MessageId, enabling true parallel I/O.

### Performance (18MB file, Gigabit LAN, SMB 2.1)

| | smb_connect | dart_smb2 |
|---|---|---|
| Single file | 14 MB/s | **112 MB/s** (8x) |
| 18 thumbnails (sequential vs 3-parallel) | ~23s | **~2s** |

#### Single file read-ahead comparison

| readAhead | Speed |
|---|---|
| 1 | 96 MB/s |
| 2 | 109 MB/s |
| 3 | 113 MB/s |
| 5 | 112 MB/s |
| 8 | 113 MB/s |

#### Parallel directory download (20 files, 196MB total)

| parallel | Speed |
|---|---|
| 1 | 110 MB/s |
| 2 | 112 MB/s |
| 3 | 116 MB/s |
| 5 | 116 MB/s |
| 8 | 115 MB/s |

Network-saturated at ~113 MB/s (Gigabit LAN limit). Read-ahead=2 is sufficient for single-file throughput.

### Performance (iPad WiFi, SMB 2.1)

18MB PNG file over WiFi (802.11ac, iPad → Gigabit LAN server).

#### Single file read-ahead comparison

| readAhead | Speed |
|---|---|
| 1 | 50 MB/s |
| 2 | 76 MB/s |
| 3 | 77 MB/s |
| 5 | 80 MB/s |
| 8 | 88 MB/s |

#### Parallel directory download (20 files, 230MB total)

| parallel | Speed |
|---|---|
| 1 | 79 MB/s |
| 2 | 86 MB/s |
| 3 | 90 MB/s |
| 5 | 91 MB/s |
| 8 | 92 MB/s |

WiFi latency makes read-ahead more impactful: readAhead=1→2 yields a 1.5x jump. Parallel reads saturate around 3 connections at ~90 MB/s.

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

## Architecture

### Multiplexing

SMB2 assigns each request a unique MessageId. The server includes the same MessageId in its response, allowing multiple requests to be in-flight simultaneously on a single TCP connection.

```
Client                          Server
  ├─ Send Read(MsgId=1) ──────→  ├─ Process 1
  ├─ Send Read(MsgId=2) ──────→  ├─ Process 2
  ├─ Send Read(MsgId=3) ──────→  ├─ Process 3
  │                              │
  ├─ Recv Response(MsgId=2) ←──  │  (2 finished first)
  ├─ Recv Response(MsgId=1) ←──  │
  └─ Recv Response(MsgId=3) ←──  │
```

Sends are serialized through a FIFO mutex (protecting the TCP socket), while a dedicated receive loop dispatches responses to the correct caller by MessageId.

### Read pipelining

For single-file reads, `readStream` sends multiple Read requests before waiting for the first response (read-ahead). This hides network round-trip latency by keeping the server's disk I/O busy.

```
readAhead=3:
  Send Read(0-1MB) → Send Read(1-2MB) → Send Read(2-3MB)
    → Recv 0-1MB → Send Read(3-4MB) → Recv 1-2MB → ...
```

### Flow control

SMB2 uses a credit system: the server grants credits in each response, and the client must not send more requests than it has credits for. Instead of tracking individual credits (which requires careful bookkeeping), dart_smb2 caps the number of concurrent in-flight requests at 32 (configurable). Since servers typically grant 32 credits per response, this keeps the client well within budget while being simple to reason about.

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
export PASS="your_password"
SMB_HOST=192.168.1.100 SMB_SHARE=photos SMB_USER=user SMB_PASS="$PASS" \
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

## Benchmark

Measure single-file and parallel download throughput with different read-ahead and parallelism settings.

```bash
export PASS="your_password"

# Single file: compares readAhead=1,2,3,5,8
SMB_HOST=192.168.1.100 SMB_SHARE=photos SMB_USER=user SMB_PASS="$PASS" \
  SMB_BENCH_FILE="path/to/large_file.png" \
  dart test --reporter expanded test/integration/benchmark_test.dart

# Directory: compares parallel=1,2,3,5,8
SMB_HOST=192.168.1.100 SMB_SHARE=photos SMB_USER=user SMB_PASS="$PASS" \
  SMB_BENCH_DIR="path/to/directory" \
  dart test --reporter expanded test/integration/benchmark_test.dart
```

| Variable | Default | Description |
|----------|---------|-------------|
| `SMB_BENCH_FILE` | - | Single file path to benchmark |
| `SMB_BENCH_DIR` | - | Directory path for parallel read benchmark |
| `SMB_BENCH_READAHEAD` | 3 | Read-ahead count for streaming |
| `SMB_BENCH_PARALLEL` | 3 | Parallel download count |
| `SMB_BENCH_MAX_FILES` | 20 | Max files to read from directory |

## Phase 2 (planned)

- Write, file creation, delete, rename
- SMB3 encryption & signing
- Multi-channel

## License

This library is licensed under GPL-3.0. See [LICENSE](LICENSE).

For commercial use without GPL obligations, a separate commercial license is available. Contact the author for details.
