import 'dart:math' as math;
import 'dart:typed_data';

import '../protocol/messages/close.dart';
import '../protocol/messages/create.dart';
import '../protocol/messages/write.dart';
import '../transport/sender.dart';

/// Writes to one file that has just been created on the share.
///
/// Handed out by `Smb2Tree.createNew`, which is what decides the file may be
/// created at all. This side only puts bytes in it: there is no way here to
/// reach a file that already existed.
class Smb2FileWriter {
  final Smb2Sender _sender;
  final FileId _fileId;
  final int _sessionId;
  final int _treeId;
  final int _maxWriteSize;

  /// Where the next [write] will start. Claimed before anything is sent --
  /// see [write].
  int _position = 0;
  int _written = 0;
  bool _closed = false;
  bool _broken = false;

  Smb2FileWriter({
    required Smb2Sender sender,
    required FileId fileId,
    required int sessionId,
    required int treeId,
    required int maxWriteSize,
  })  : _sender = sender,
        _fileId = fileId,
        _sessionId = sessionId,
        _treeId = treeId,
        _maxWriteSize = maxWriteSize;

  /// How many bytes the server has said it took, across every [write].
  ///
  /// Readable after a failure as well, and that is what it is for: it is the
  /// length of what is on the share, so a caller can tell how far a broken
  /// write got.
  int get written => _written;

  /// Append [bytes] to the file.
  ///
  /// The region this call occupies is claimed **before the first await**, so
  /// that two writes issued without awaiting the first cannot land on top of
  /// each other. Nothing about that is needed while blocks go out one at a
  /// time, and everything about it is needed the day they do not.
  Future<void> write(Uint8List bytes) {
    if (_closed) {
      throw StateError('write after close');
    }
    if (_broken) {
      throw StateError('write after a failed write; this file has a hole');
    }
    final at = _position;
    _position += bytes.length;
    return _sendBlocks(at, bytes);
  }

  /// Send [bytes] as however many requests the server's limit allows,
  /// starting at [at].
  Future<void> _sendBlocks(int at, Uint8List bytes) async {
    var sent = 0;
    while (sent < bytes.length) {
      final length = math.min(_maxWriteSize, bytes.length - sent);
      final block = Uint8List.sublistView(bytes, sent, sent + length);
      final int taken;
      try {
        taken = await _writeOnce(at + sent, block);
      } catch (_) {
        // Whatever went wrong, this file now has a gap where this block
        // should be. Refusing the rest is what keeps [written] equal to the
        // file's length.
        _broken = true;
        rethrow;
      }
      if (taken <= 0) {
        // A server that accepts a write and then says it took nothing would
        // otherwise be looped over for ever, one empty round trip at a time.
        _broken = true;
        throw StateError('the server took none of ${block.length} bytes '
            'at ${at + sent}');
      }
      // Advance by what was taken, not by what was offered: a server may
      // take less than it was given, and the rest has to go out again from
      // where it stopped rather than be skipped.
      _written += taken;
      sent += taken;
    }
  }

  /// One Write request. [block] must not exceed the server's limit.
  Future<int> _writeOnce(int offset, Uint8List block) async {
    final req = WriteRequest(fileId: _fileId, offset: offset, data: block);
    final header = req.buildHeader(sessionId: _sessionId, treeId: _treeId);
    final response = await _sender.send(header, req.encode());
    response.checkStatus('Write ${block.length} bytes at $offset');
    return WriteResponse.decode(response.body).count;
  }

  /// Close the file. Calling it twice does nothing the second time.
  ///
  /// Unlike [Smb2FileReader.close], this waits for the server's answer and
  /// reports a failure. Closing a file that was read changes nothing about
  /// the bytes already in hand; closing one that was written is the claim
  /// that it is finished, and a swallowed failure there would hand back an
  /// unfinished file as a success.
  Future<void> close() async {
    if (_closed) return;
    // Set before sending: whether or not the server answers, this handle is
    // not to be used again, and a caller who retries close should not send a
    // second Close for a handle the server may already have released.
    _closed = true;
    final req = CloseRequest(fileId: _fileId);
    final header = req.buildHeader(sessionId: _sessionId, treeId: _treeId);
    final response = await _sender.send(header, req.encode());
    response.checkStatus('Close');
  }
}
