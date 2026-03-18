import 'dart:async';
import 'dart:typed_data';

import '../protocol/messages/close.dart';
import '../protocol/messages/create.dart';
import '../protocol/messages/read.dart';
import '../protocol/status.dart';
import '../transport/multiplexer.dart';
import '../transport/sender.dart';

/// Reads a file from an SMB2 share as a byte stream.
///
/// Supports streaming reads with configurable block size,
/// leveraging the multiplexer for parallel operations.
class Smb2FileReader {
  final Smb2Sender _sender;
  final FileId _fileId;
  final int _fileSize;
  final int _sessionId;
  final int _treeId;
  final int _maxReadSize;

  Smb2FileReader({
    required Smb2Sender sender,
    required FileId fileId,
    required int fileSize,
    required int sessionId,
    required int treeId,
    required int maxReadSize,
  })  : _sender = sender,
        _fileId = fileId,
        _fileSize = fileSize,
        _sessionId = sessionId,
        _treeId = treeId,
        _maxReadSize = maxReadSize;

  int get fileSize => _fileSize;
  FileId get fileId => _fileId;

  /// Close the file handle. Must be called when done reading.
  Future<void> close() async {
    final req = CloseRequest(fileId: _fileId);
    final header = req.buildHeader(sessionId: _sessionId, treeId: _treeId);
    try {
      await _sender.send(header, req.encode());
    } catch (e, st) {
      print('[Smb2FileReader] Close error: $e\n$st');
    }
  }

  /// Read a range of bytes from the file.
  ///
  /// Returns up to [length] bytes, but may return fewer if [length] exceeds
  /// the server's max read size (typically 1MB). Check the returned
  /// [Uint8List.length] for the actual number of bytes read.
  /// Use [readStream] or [readAll] for complete file reads.
  Future<Uint8List> readRange(int offset, int length) async {
    final readLen = length.clamp(0, _fileSize - offset);
    if (readLen <= 0) return Uint8List(0);

    final actualLen = readLen > _maxReadSize ? _maxReadSize : readLen;
    final req = ReadRequest(
      fileId: _fileId,
      offset: offset,
      length: actualLen,
    );
    final header = req.buildHeader(sessionId: _sessionId, treeId: _treeId);
    final response = await _sender.send(header, req.encode());

    if (NtStatus.isError(response.header.status) &&
        response.header.status != NtStatus.endOfFile) {
      throw Smb2Exception(
        response.header.status,
        'Read failed at offset $offset',
      );
    }

    if (response.header.status == NtStatus.endOfFile || response.body.isEmpty) {
      return Uint8List(0);
    }

    return ReadResponse.decode(response.body).data;
  }

  /// Read entire file as a byte stream.
  Stream<Uint8List> readStream({int blockSize = 0}) {
    final effectiveBlockSize = blockSize > 0
        ? (blockSize > _maxReadSize ? _maxReadSize : blockSize)
        : _maxReadSize;

    return _streamRead(effectiveBlockSize);
  }

  Stream<Uint8List> _streamRead(int blockSize) async* {
    int offset = 0;
    while (offset < _fileSize) {
      final chunk = await readRange(offset, blockSize);
      if (chunk.isEmpty) break;
      yield chunk;
      offset += chunk.length;
    }
  }

  /// Read the entire file into memory.
  Future<Uint8List> readAll() async {
    final chunks = <Uint8List>[];
    int totalLen = 0;
    await for (final chunk in readStream()) {
      chunks.add(chunk);
      totalLen += chunk.length;
    }
    final result = Uint8List(totalLen);
    int offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }
}
