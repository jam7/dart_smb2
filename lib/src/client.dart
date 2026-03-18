import 'dart:async';
import 'dart:typed_data';

import 'auth/ntlmssp.dart';
import 'auth/spnego.dart';
import 'file/file_reader.dart';
import 'file/smb2_file.dart';
import 'protocol/commands.dart';
import 'protocol/header.dart';
import 'protocol/messages/close.dart';
import 'protocol/messages/create.dart';
import 'protocol/messages/negotiate.dart';
import 'protocol/messages/query_directory.dart';
import 'protocol/messages/session_setup.dart';
import 'protocol/messages/tree_connect.dart';
import 'protocol/status.dart';
import 'transport/connection.dart';
import 'transport/multiplexer.dart';
import 'transport/sender.dart';

/// A connected SMB2 tree (share).
///
/// Provides file operations on a specific share.
/// All operations use the multiplexer for true parallel I/O.
class Smb2Tree {
  final Smb2Sender _sender;
  final int _sessionId;
  final int _treeId;
  final int _maxReadSize;
  final String _shareName;

  Smb2Tree._({
    required Smb2Sender sender,
    required int sessionId,
    required int treeId,
    required int maxReadSize,
    required String shareName,
  })  : _sender = sender,
        _sessionId = sessionId,
        _treeId = treeId,
        _maxReadSize = maxReadSize,
        _shareName = shareName;

  String get shareName => _shareName;
  int get treeId => _treeId;

  /// List directory contents.
  Future<List<Smb2FileInfo>> listDirectory(String path) async {
    // Normalize path: remove leading/trailing slashes, use backslash
    final normalizedPath = _normalizePath(path);

    // Open directory
    final createReq = CreateRequest(
      fileName: normalizedPath,
      desiredAccess: AccessMask.read,
      fileAttributes: FileAttributes.directory,
      shareAccess: ShareAccess.all,
      createDisposition: CreateDisposition.fileOpen,
      createOptions: CreateOptions.directoryFile,
    );
    final createHeader = createReq.buildHeader(
      sessionId: _sessionId,
      treeId: _treeId,
    );
    final createResp = await _sender.send(createHeader, createReq.encode());
    _checkStatus(createResp, 'Open directory "$normalizedPath"');
    final createResult = CreateResponse.decode(createResp.body);
    final fileId = createResult.fileId;

    try {
      // Query directory entries
      final entries = <Smb2FileInfo>[];
      bool firstQuery = true;

      while (true) {
        final queryReq = QueryDirectoryRequest(
          fileId: fileId,
          pattern: '*',
          flags: firstQuery ? QueryDirectoryFlags.restartScans : 0,
        );
        final queryHeader = queryReq.buildHeader(
          sessionId: _sessionId,
          treeId: _treeId,
        );
        final queryResp = await _sender.send(queryHeader, queryReq.encode());

        if (queryResp.header.status == NtStatus.noMoreFiles) {
          break;
        }
        _checkStatus(queryResp, 'QueryDirectory "$normalizedPath"');

        final dirEntries = QueryDirectoryResponse.decode(queryResp.body);
        for (final entry in dirEntries) {
          // Skip . and ..
          if (entry.fileName == '.' || entry.fileName == '..') continue;
          final entryPath = normalizedPath.isEmpty
              ? entry.fileName
              : '$normalizedPath\\${entry.fileName}';
          entries.add(Smb2FileInfo(
            name: entry.fileName,
            path: entryPath,
            size: entry.endOfFile,
            isDirectory: entry.isDirectory,
            isHidden: entry.isHidden,
            creationTime: Smb2FileInfo.fileTimeToDateTime(entry.creationTime),
            lastWriteTime: Smb2FileInfo.fileTimeToDateTime(entry.lastWriteTime),
            lastAccessTime: Smb2FileInfo.fileTimeToDateTime(entry.lastAccessTime),
          ));
        }
        firstQuery = false;
      }

      return entries;
    } finally {
      await _closeFile(fileId);
    }
  }

  /// Open a file for reading and return a reader.
  Future<Smb2FileReader> openRead(String path) async {
    final normalizedPath = _normalizePath(path);
    final createReq = CreateRequest(
      fileName: normalizedPath,
      desiredAccess: AccessMask.read,
      shareAccess: ShareAccess.all,
      createDisposition: CreateDisposition.fileOpen,
      createOptions: CreateOptions.nonDirectoryFile,
    );
    final createHeader = createReq.buildHeader(
      sessionId: _sessionId,
      treeId: _treeId,
    );
    final createResp = await _sender.send(createHeader, createReq.encode());
    _checkStatus(createResp, 'Open file "$normalizedPath"');
    final createResult = CreateResponse.decode(createResp.body);

    return Smb2FileReader(
      sender: _sender,
      fileId: createResult.fileId,
      fileSize: createResult.endOfFile,
      sessionId: _sessionId,
      treeId: _treeId,
      maxReadSize: _maxReadSize,
    );
  }

  /// Read a range of bytes from a file.
  Future<Uint8List> readRange(String path, {required int offset, required int length}) async {
    final reader = await openRead(path);
    try {
      return await reader.readRange(offset, length);
    } finally {
      await reader.close();
    }
  }

  /// Read an entire file.
  Future<Uint8List> readFile(String path) async {
    final reader = await openRead(path);
    try {
      return await reader.readAll();
    } finally {
      await reader.close();
    }
  }

  /// Close a file by ID.
  Future<void> _closeFile(FileId fileId) async {
    final closeReq = CloseRequest(fileId: fileId);
    final closeHeader = closeReq.buildHeader(
      sessionId: _sessionId,
      treeId: _treeId,
    );
    try {
      await _sender.send(closeHeader, closeReq.encode());
    } catch (e, st) {
      print('[Smb2Tree] Close file error: $e\n$st');
    }
  }

  String _normalizePath(String path) {
    var p = path.replaceAll('/', '\\');
    while (p.startsWith('\\')) {
      p = p.substring(1);
    }
    while (p.endsWith('\\')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  void _checkStatus(Smb2Response response, String operation) {
    if (NtStatus.isError(response.header.status)) {
      throw Smb2Exception(
        response.header.status,
        '$operation failed: ${NtStatus.describe(response.header.status)}',
        response.header,
      );
    }
  }
}

/// SMB2 client with true message multiplexing.
///
/// Usage:
/// ```dart
/// final client = await Smb2Client.connect(
///   host: '192.168.1.100',
///   username: 'user',
///   password: 'pass',
/// );
/// final tree = await client.connectTree('photos');
/// final files = await tree.listDirectory('/');
/// await client.disconnect();
/// ```
class Smb2Client {
  final Smb2Multiplexer _multiplexer;
  final Smb2Sender _sender;
  final String _host;
  int _sessionId = 0;
  int _maxReadSize = 65536;
  int _maxWriteSize = 65536;
  int _dialectRevision = 0;
  final List<Smb2Tree> _trees = [];

  Smb2Client._({
    required Smb2Multiplexer multiplexer,
    required Smb2Sender sender,
    required String host,
  })  : _multiplexer = multiplexer,
        _sender = sender,
        _host = host;

  int get sessionId => _sessionId;
  int get dialectRevision => _dialectRevision;
  int get maxReadSize => _maxReadSize;

  /// Connect to an SMB2 server and authenticate.
  static Future<Smb2Client> connect({
    required String host,
    required String username,
    required String password,
    String domain = '',
    int port = 445,
  }) async {
    final connection = await Smb2Connection.connect(host, port: port);
    final multiplexer = Smb2Multiplexer(connection);
    final sender = Smb2Sender(connection, multiplexer);
    final client = Smb2Client._(
      multiplexer: multiplexer,
      sender: sender,
      host: host,
    );

    try {
      // Start receive loop
      multiplexer.startReceiveLoop();

      // Step 1: Negotiate
      await client._negotiate();

      // Step 2: Authenticate
      await client._authenticate(username, password, domain);

      return client;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  Future<void> _negotiate() async {
    final req = NegotiateRequest();
    final header = req.buildHeader();
    final response = await _sender.send(header, req.encode());

    if (NtStatus.isError(response.header.status)) {
      throw Smb2Exception(
        response.header.status,
        'Negotiate failed: ${NtStatus.describe(response.header.status)}',
      );
    }

    final negotiateResp = NegotiateResponse.decode(response.body);
    _dialectRevision = negotiateResp.dialectRevision;
    _maxReadSize = negotiateResp.maxReadSize;
    _maxWriteSize = negotiateResp.maxWriteSize;

    // Cap read size to 1MB for practical use
    if (_maxReadSize > 1048576) _maxReadSize = 1048576;

    print('[Smb2Client] Negotiated dialect: ${Smb2Dialect.describe(_dialectRevision)}, '
        'maxRead: $_maxReadSize, maxWrite: $_maxWriteSize');
  }

  Future<void> _authenticate(String username, String password, String domain) async {
    final ntlm = NtlmAuth(
      username: username,
      password: password,
      domain: domain,
    );

    // Step 1: Send Type1 (wrapped in SPNEGO)
    final type1 = ntlm.createType1Message();
    final spnegoType1 = SpnegoAuth.wrapType1(type1);

    final setupReq1 = SessionSetupRequest(securityBuffer: spnegoType1);
    final header1 = setupReq1.buildHeader();
    final response1 = await _sender.send(header1, setupReq1.encode());

    if (response1.header.status != NtStatus.moreProcessingRequired) {
      if (NtStatus.isError(response1.header.status)) {
        throw Smb2Exception(
          response1.header.status,
          'Session setup step 1 failed: ${NtStatus.describe(response1.header.status)}',
        );
      }
    }

    _sessionId = response1.header.sessionId;
    final setupResp1 = SessionSetupResponse.decode(response1.body);

    // Extract Type2 from SPNEGO
    final type2Bytes = SpnegoAuth.unwrapType2(setupResp1.securityBuffer);

    // Step 2: Send Type3 (wrapped in SPNEGO)
    final type3 = ntlm.createType3Message(type2Bytes);
    final spnegoType3 = SpnegoAuth.wrapType3(type3);

    final setupReq2 = SessionSetupRequest(securityBuffer: spnegoType3);
    final header2 = setupReq2.buildHeader(sessionId: _sessionId);
    final response2 = await _sender.send(header2, setupReq2.encode());

    if (NtStatus.isError(response2.header.status)) {
      throw Smb2Exception(
        response2.header.status,
        'Authentication failed: ${NtStatus.describe(response2.header.status)}',
      );
    }

    print('[Smb2Client] Authenticated as "$username", sessionId=0x${_sessionId.toRadixString(16)}');
  }

  /// Connect to a share and return an Smb2Tree for file operations.
  Future<Smb2Tree> connectTree(String shareName) async {
    final path = '\\\\$_host\\$shareName';
    final req = TreeConnectRequest(path: path);
    final header = req.buildHeader(sessionId: _sessionId);
    final response = await _sender.send(header, req.encode());

    if (NtStatus.isError(response.header.status)) {
      throw Smb2Exception(
        response.header.status,
        'Tree connect to "$shareName" failed: ${NtStatus.describe(response.header.status)}',
      );
    }

    final treeId = response.header.treeId;
    final treeResp = TreeConnectResponse.decode(response.body);

    print('[Smb2Client] Connected to share "$shareName", treeId=$treeId, '
        'type=${treeResp.shareType == ShareType.disk ? "DISK" : treeResp.shareType}');

    final tree = Smb2Tree._(
      sender: _sender,
      sessionId: _sessionId,
      treeId: treeId,
      maxReadSize: _maxReadSize,
      shareName: shareName,
    );
    _trees.add(tree);
    return tree;
  }

  /// Disconnect a tree.
  Future<void> disconnectTree(Smb2Tree tree) async {
    final req = TreeDisconnectRequest();
    final header = req.buildHeader(sessionId: _sessionId, treeId: tree.treeId);
    try {
      await _sender.send(header, req.encode());
    } catch (e, st) {
      print('[Smb2Client] Tree disconnect error: $e\n$st');
    }
    _trees.remove(tree);
  }

  /// Disconnect from the server.
  Future<void> disconnect() async {
    // Disconnect all trees
    for (final tree in List.of(_trees)) {
      await disconnectTree(tree);
    }

    // Logoff
    try {
      final header = Smb2Header(
        command: Smb2Command.logoff,
        sessionId: _sessionId,
      );
      final body = Uint8List(4);
      ByteData.sublistView(body).setUint16(0, 4, Endian.little); // StructureSize
      await _sender.send(header, body);
    } catch (e, st) {
      print('[Smb2Client] Logoff error: $e\n$st');
    }

    await _multiplexer.stop();
    print('[Smb2Client] Disconnected');
  }
}
