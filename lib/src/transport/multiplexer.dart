import 'dart:async';
import 'dart:typed_data';

import '../protocol/header.dart';
import '../protocol/status.dart';
import 'connection.dart';

/// Pending request waiting for a response.
class _PendingRequest {
  final Completer<Smb2Response> completer;
  final DateTime createdAt;

  _PendingRequest(this.completer) : createdAt = DateTime.now();
}

/// A decoded SMB2 response.
class Smb2Response {
  final Smb2Header header;
  final Uint8List body; // Everything after the 64-byte header

  Smb2Response(this.header, this.body);
}

/// Exception thrown for SMB2 protocol errors.
class Smb2Exception implements Exception {
  final int status;
  final String message;
  final Smb2Header? header;

  Smb2Exception(this.status, this.message, [this.header]);

  @override
  String toString() =>
      'Smb2Exception: $message (${NtStatus.describe(status)})';
}

/// Manages MessageId-based multiplexing of SMB2 requests/responses.
///
/// - Each outgoing request is assigned a unique MessageId
/// - A dedicated receive loop reads responses and dispatches them
///   to the corresponding Completer by MessageId
class Smb2Multiplexer {
  final Smb2Connection _connection;
  final Map<int, _PendingRequest> _pending = {};
  int _nextMessageId = 0;
  int _availableCredits = 1; // Start with 1, server grants more
  bool _running = false;
  Completer<void>? _stopCompleter;

  Smb2Multiplexer(this._connection);

  int get availableCredits => _availableCredits;

  /// Allocate the next MessageId.
  int allocateMessageId() {
    return _nextMessageId++;
  }

  /// Register a pending request and return its Future.
  Future<Smb2Response> registerRequest(int messageId) {
    final completer = Completer<Smb2Response>();
    _pending[messageId] = _PendingRequest(completer);
    return completer.future;
  }

  /// Start the receive loop. Must be called once after connection.
  void startReceiveLoop() {
    if (_running) return;
    _running = true;
    _receiveLoop();
  }

  Future<void> _receiveLoop() async {
    try {
      while (_running && !_connection.isClosed) {
        final packet = await _connection.readMessage();
        if (packet.length < Smb2Header.size) {
          print('[Smb2Multiplexer] Received packet too small: ${packet.length} bytes');
          continue;
        }

        final header = Smb2Header.decode(packet, 0);
        final body = Uint8List.sublistView(packet, Smb2Header.size);

        // Update credits
        if (header.creditRequestResponse > 0) {
          _availableCredits += header.creditRequestResponse;
        }

        // STATUS_PENDING: don't complete yet, wait for real response
        if (header.status == NtStatus.pending) {
          continue;
        }

        final pending = _pending.remove(header.messageId);
        if (pending != null) {
          pending.completer.complete(Smb2Response(header, body));
        } else {
          print('[Smb2Multiplexer] Unexpected response for MessageId=${header.messageId}');
        }
      }
    } catch (e, st) {
      if (_running) {
        print('[Smb2Multiplexer] Receive loop error: $e\n$st');
      }
      // Complete all pending requests with error
      final error = Smb2Exception(0, 'Connection lost: $e');
      for (final pending in _pending.values) {
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(error);
        }
      }
      _pending.clear();
    } finally {
      _running = false;
      _stopCompleter?.complete();
    }
  }

  /// Stop the receive loop.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _stopCompleter = Completer<void>();
    await _connection.close();
    await _stopCompleter!.future;
  }

  /// Use a credit (returns false if none available).
  bool consumeCredit() {
    if (_availableCredits > 0) {
      _availableCredits--;
      return true;
    }
    return false;
  }
}
