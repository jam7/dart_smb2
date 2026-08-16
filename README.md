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

### Performance (iPad Wi-Fi, SMB 2.1)

18MB PNG file over Wi-Fi (802.11ac, iPad → Gigabit LAN server).

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

Wi-Fi latency makes read-ahead more impactful: readAhead=1→2 yields a 1.5x jump. Parallel reads saturate around 3 connections at ~90 MB/s.

### Writing (64MB, **wired** Gigabit LAN, SMB 2.1)

| | speed |
|---|---|
| write, serial, 1MB per request | **91.7 MB/s** |
| read the same file back, parallel | 105.3 MB/s |

On a wire, writing one block at a time already reaches 87% of what reading the
same file achieves in parallel, and reading is at the link's practical ceiling.

**This says nothing about Wi-Fi, which is where the client that motivated
writing actually runs.** The read figures above measure exactly that
difference: pipelining is worth 1.18x on the wire and 1.76x over Wi-Fi (50 to
88 MB/s), because what parallelism hides is round-trip latency, and a wire has
almost none to hide. Whether write blocks should be sent concurrently is
therefore still open, and needs the same measurement taken over Wi-Fi.

## Usage

```dart
import 'package:dart_smb2/dart_smb2.dart';

// Connect and authenticate
final client = await Smb2Client.connect(
  host: '192.168.99.100',
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

// Write a new file. Fails if the name is taken: there is no way from here
// to write over a file that already exists.
final writer = await tree.createNew('/vacation/notes.txt');
await writer.write(bytes);          // split for the server's limit
await writer.close();               // waits, and reports a failure
print('${writer.written} bytes reached the server');

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

## Extending the API without rewriting its callers

Two changes are foreseen, and both have a shape that costs callers nothing and
a shape that breaks every one of them. Written down because the choice arrives
long after the reasoning does.

**Telling the caller the server said it is busy.** An SMB2 server can answer a
slow request with an interim `STATUS_PENDING` before the real response; the
client extends its own deadline (see Timeouts) but nothing above hears about
it. When that is worth surfacing, add it as an **optional named argument on
the operation** — `listDirectory(path, {void Function()? onServerBusy})` —
rather than as a callback registered on the client.

Registering on the client is equally additive, and is the wrong shape: a
single connection carries many concurrent operations, so a connection-wide
callback can say that *something* is busy and never which one. Whoever wants
to say so on screen, or to extend their own patience, needs to know which
request it belongs to. The per-call argument carries that for free.

**Returning a directory as it arrives.** `listDirectory` makes one round trip
per bufferful and returns nothing until the last one lands, so a directory
large enough to need several would be silent for its whole duration. Measured
rather than assumed, that size is far off: one round trip asks for
`maxTransactSize`, which negotiates to 1MB against a NAS here and holds
several thousand entries, and a listing of 492 took two round trips and 26ms
— one for the entries, one to be told there are no more. Nothing has been
built for this, and nothing should be until a share has a directory that
shows the fault.

Were it needed, the fix would be to yield entries as they arrive — and doing
that by changing this method's return type to a `Stream` would break every
`await tree.listDirectory(...)` in existence.

**Add a second method instead** (`streamDirectory`, say) and leave
`listDirectory` as the thin wrapper that collects it. Adding a method is
invisible to callers; changing what one returns is not.

## Timeouts

The client bounds three things, following [MS-SMB2]'s Request Expiration
Timer and the values Windows ships:

| | default | what it bounds |
|---|---|---|
| `connectTimeout` | 15s | reaching the server's TCP port |
| `requestTimeout` | 60s | one request waiting for its response |
| (derived) | 4 × `requestTimeout` | a request the server answered with `STATUS_PENDING` |

Sixty seconds is Windows' `SessTimeout`, and the fourfold extension for a
pending request is what Windows does when `ExtendedSessTimeout` is not
configured.

**Expiry closes the connection**, which is what the specification calls for:
the operation is considered blocked, and once a response is missing there is
no way to know what the server still believes about MessageIds and credits.
Every request waiting on that connection fails with a reason. Callers are
expected to reconnect; nothing here retries by itself.

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
- Write, for files that are not there yet (see above)

## Testing

```bash
# Unit tests
dart test

# Integration tests (requires a real SMB server)
export PASS="your_password"
SMB_HOST=192.168.99.100 SMB_SHARE=photos SMB_USER=user SMB_PASS="$PASS" \
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
| `SMB_WRITE_DIR` | no | A directory the write tests may create files in. Without it they skip rather than write somewhere unexpected. They do not clean up after themselves, since deleting is not implemented |
| `SMB_BENCH_WRITE_MB` | no | How large a file the write benchmark creates (default: 64) |
| `SMB_LIST_DIR` | no | Which directory the listing-cost test measures (default: the share's root) |

## Benchmark

Measure single-file and parallel download throughput with different read-ahead and parallelism settings.

```bash
export PASS="your_password"

# Single file: compares readAhead=1,2,3,5,8
SMB_HOST=192.168.99.100 SMB_SHARE=photos SMB_USER=user SMB_PASS="$PASS" \
  SMB_BENCH_FILE="path/to/large_file.png" \
  dart test --reporter expanded test/integration/benchmark_test.dart

# Directory: compares parallel=1,2,3,5,8
SMB_HOST=192.168.99.100 SMB_SHARE=photos SMB_USER=user SMB_PASS="$PASS" \
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

## Scope: reading a home share quickly

This library exists to read files off a NAS on a home network as fast as the
network allows. Everything in it is shaped by that: range reads instead of
downloads, a receive loop that dispatches by MessageId so reads can overlap,
and read-ahead sized by measurement.

**Security is taken to be the network's.** The client and the server are on
the same LAN, and a share reachable from the internet is not a target. That is
a deliberate limit, not an omission waiting to be filled.

So **message signing and SMB3 encryption are not implemented and are not
planned**. Both put work on every message -- a keyed hash over the payload, or
a cipher over it -- which is precisely the cost this library was written to
avoid. A setting that needs them needs a different client.

The client sends `SMB2_NEGOTIATE_SIGNING_ENABLED` while signing nothing, which
looks like a claim it cannot back. It is not one, and it is not optional:
[MS-SMB2] defines that bit with "The server MUST ignore this bit" (2.2.3 and
2.2.5), and 3.2.4.2.2.2 requires a client that does not itself *require*
signing to set it. Sending 0 would break a MUST and change nothing the server
is allowed to notice.

A server that *requires* signing will not work here, whatever we send.

## What writing does and does not do

`createNew` puts a file on the share that was not there before. Nothing in
this library overwrites, renames or deletes, so no call it offers can destroy
a file that already exists -- refusing a taken name is the server's own answer
to FILE_CREATE, not a check this library makes and could get wrong.

A caller who wants to replace a file therefore cannot yet. The stages after
this one are, in order: making writes faster, then rename and delete (which is
what lets a caller write under another name and swap it in), then editing an
existing file. See `docs/write/` for the reasoning.

## Phase 2 (planned)

- Rename and delete
- Multi-channel

## License

This library is licensed under GPL-3.0. See [LICENSE](LICENSE).

For commercial use without GPL obligations, a separate commercial license is available. Contact the author for details.
