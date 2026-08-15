# SMB2 Protocol Implementation Status

dart_smb2 is a read-only SMB 2.0/2.1 client library for Dart.
The full Negotiate → Authentication → TreeConnect → QueryDirectory → Create → Read path is implemented, with message multiplexing and read-ahead pipelining for optimized throughput.

## Implemented

### Negotiate

- Dialects: SMB 2.0.2 (0x0202), 2.1 (0x0210), 3.0 (0x0300)
- Parses server capabilities, max read/write sizes, server GUID
- Read size capped to 1MB for practical use (even if server offers larger)

### Authentication (NTLMv2)

- NTLMSSP + SPNEGO wrapping
- 3-message handshake (Type1 → Type2 → Type3)
- NTLMv2 response (HMAC-MD5)
- AV pair parsing with timestamp extraction for replay protection
- Session base key computation exists (for signing, currently unused)

### Session Management

- Session Setup (2-message SPNEGO exchange)
- Logoff (sent on disconnect)
- State tracking via SessionId

### Tree Operations

- Tree Connect / Disconnect
- Share type detection: DISK (0x01), PIPE (0x02), PRINT (0x03)

### File Operations

| Command | Status | Notes |
|---|---|---|
| Create | Implemented | Open files and directories (read access) |
| Close | Implemented | |
| Read | Implemented | Multi-block, read-ahead pipelining (readStream) and parallel split reads (readRange), up to 1MB/block |

### Directory Operations

- QueryDirectory: FileBothDirectoryInformation (0x03), FileIdBothDirectoryInformation (0x25)
- Parses file attributes, timestamps (creation/access/write/change), size
- Handles `.` / `..` entries
- Pagination until STATUS_NO_MORE_FILES

### Message Multiplexing

- MessageId-based concurrent requests (up to 32, configurable)
- Dedicated receive loop with MessageId dispatch
- FIFO send lock (serialized socket writes)
- In-flight request tracking and cancellation

### Credit Management

- Tracks server-granted credits and enforces the credit window on send:
  a request waits until the balance covers its credit charge
- Liveness fallback: when nothing is in flight (so no response can
  replenish credits), a request is sent despite an insufficient balance
  and a warning is logged
- Credit charge calculation for large reads: `ceil(length / 65536)`
- In-flight cap of 32 concurrent requests (configurable)

### Protocol Infrastructure

- SMB2 header: full 64-byte encode/decode
- All 19 SMB2 command constants defined
- Common NT status code definitions
- NetBIOS framing (4-byte session header, keep-alive)

## Not Implemented

### Write Operations

| Command | Notes |
|---|---|
| Write | Read-only library by design |
| Flush | Same |
| Lock | Same |
| SetInfo | File attribute modification |

### Security

| Feature | Notes |
|---|---|
| Message Signing | Not computed, and not planned (see the README's Scope section). The header has the field and the session key derivation exists. Requests carry `SMB2_NEGOTIATE_SIGNING_ENABLED` because [MS-SMB2] 3.2.4.2.2.2 requires a client that does not *require* signing to set it, and 2.2.3 / 2.2.5 require the server to ignore it. A server that *requires* signing announces it in its NEGOTIATE response, which this client does not yet read |
| SMB3 Encryption | AES-CCM/GCM. Not planned, same reason |
| Kerberos | NTLMv2 only. Kerberos preferred for Active Directory environments |

### Advanced Protocol Features

| Feature | Notes |
|---|---|
| Named Pipes / RPC | IPC$ connection, SRVSVC (NetShareEnumAll = listShares), etc. Required for automatic share enumeration |
| Compound Requests | Batching multiple requests in one packet. Reduces round-trips for Create+Read, etc. |
| ChangeNotify | File change notifications |
| QueryInfo | Per-file info queries (currently extracted from Create/QueryDirectory responses only) |
| Ioctl | Device control. FSCTL_DFS_GET_REFERRALS, etc. |
| Cancel / Echo | Request cancellation, connection health check |
| OplockBreak / Leases | File lock and lease management |
| DFS | Distributed File System referrals |
| Multichannel | Multiple TCP connections for bandwidth aggregation (SMB 3.0) |
| Reparse Points | Symbolic links, junctions |

## Impact of Unimplemented Features

| User Scenario | Required Feature |
|---|---|
| Automatic share enumeration | Named Pipes + SRVSVC RPC |
| Connecting to servers requiring signing | Message Signing |
| Active Directory environments | Kerberos authentication |
| File write / delete | Write, SetInfo |
| Following symbolic links | Reparse Points, Ioctl |
| Secure connections over VPN | SMB3 Encryption |
