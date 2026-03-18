/// SMB2/2.1/3.0 client library with true message multiplexing.
///
/// Unlike `smb_connect` which serializes all send/receive through a single
/// mutex, this library uses MessageId-based multiplexing: sends are serialized
/// (protecting the socket), but a dedicated receive loop dispatches responses
/// to the correct caller by MessageId. This enables true parallel file reads.
library dart_smb2;

export 'src/client.dart' show Smb2Client, Smb2Tree;
export 'src/file/smb2_file.dart' show Smb2FileInfo;
export 'src/file/file_reader.dart' show Smb2FileReader;
export 'src/transport/multiplexer.dart' show Smb2Exception;
export 'src/protocol/status.dart' show NtStatus;
export 'src/protocol/messages/negotiate.dart' show Smb2Dialect;
