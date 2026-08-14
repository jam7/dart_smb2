import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Manages TCP connection to an SMB2 server.
///
/// All SMB2 packets are framed with a 4-byte NetBIOS session header:
/// ```
/// [0x00] [Length (3 bytes, big-endian)]
/// ```
class Smb2Connection {
  final StreamIterator<Uint8List> _reader;
  final void Function(Uint8List frame) _sendFrame;
  final Future<void> Function() _closeTransport;

  /// Received chunks not yet consumed. [_offsetInFirst] is the read
  /// cursor within the first chunk; [_available] is the total unread
  /// byte count across all chunks.
  final Queue<Uint8List> _chunks = Queue();
  int _offsetInFirst = 0;
  int _available = 0;
  bool _closed = false;

  Smb2Connection._(
    Stream<Uint8List> incoming,
    this._sendFrame,
    this._closeTransport,
  ) : _reader = StreamIterator(incoming);

  /// Test-only constructor: drive the connection with a scripted byte
  /// stream instead of a socket. [onSend] receives outgoing frames
  /// (including the NetBIOS header).
  Smb2Connection.forTesting(
    Stream<Uint8List> incoming, {
    void Function(Uint8List frame)? onSend,
  }) : this._(incoming, onSend ?? (_) {}, () async {});

  bool get isClosed => _closed;

  /// Connect to [host]:[port] (default 445).
  ///
  /// [timeout] bounds reaching the port, and nothing after it. A host that is
  /// off, or an address with nothing listening on a network that drops rather
  /// than refuses, otherwise waits on the operating system's own patience,
  /// which is measured in minutes.
  static Future<Smb2Connection> connect(String host,
      {int port = 445, Duration? timeout}) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return Smb2Connection._(socket, socket.add, () async {
      await socket.close();
    });
  }

  /// Send a complete SMB2 message (without NetBIOS header).
  /// Prepends the 4-byte NetBIOS session header.
  void sendRaw(Uint8List data) {
    final frame = Uint8List(4 + data.length);
    // NetBIOS session header: type=0x00, length=24-bit big-endian
    frame[0] = 0x00;
    frame[1] = (data.length >> 16) & 0xFF;
    frame[2] = (data.length >> 8) & 0xFF;
    frame[3] = data.length & 0xFF;
    frame.setRange(4, 4 + data.length, data);
    _sendFrame(frame);
  }

  /// Read exactly [length] bytes from the socket.
  ///
  /// Returns a view into the receive chunk when the range doesn't cross
  /// a chunk boundary (zero copy); otherwise assembles into a fresh
  /// buffer (one copy). Callers must not mutate the result.
  Future<Uint8List> _readExact(int length) async {
    while (_available < length) {
      if (!await _reader.moveNext()) {
        throw const SocketException('Connection closed while reading');
      }
      final chunk = _reader.current;
      if (chunk.isEmpty) continue;
      _chunks.add(chunk);
      _available += chunk.length;
    }

    final first = _chunks.first;
    if (first.length - _offsetInFirst >= length) {
      final view =
          Uint8List.sublistView(first, _offsetInFirst, _offsetInFirst + length);
      _advance(length);
      return view;
    }

    // Range spans chunks: assemble into one buffer.
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      final chunk = _chunks.first;
      final take =
          math.min(chunk.length - _offsetInFirst, length - written);
      result.setRange(written, written + take, chunk, _offsetInFirst);
      written += take;
      _advance(take);
    }
    return result;
  }

  /// Move the read cursor forward by [count] bytes within the first chunk,
  /// dropping it once fully consumed. [count] must not cross a boundary.
  void _advance(int count) {
    _offsetInFirst += count;
    _available -= count;
    if (_offsetInFirst == _chunks.first.length) {
      _chunks.removeFirst();
      _offsetInFirst = 0;
    }
  }

  /// Read one complete SMB2 message (strips NetBIOS header).
  /// Returns the raw SMB2 packet bytes.
  Future<Uint8List> readMessage() async {
    while (true) {
      // Read 4-byte NetBIOS header
      final header = await _readExact(4);

      // Skip keep-alive (0x85)
      if (header[0] == 0x85) continue;

      // Parse length (24-bit big-endian)
      final length = (header[1] << 16) | (header[2] << 8) | header[3];
      if (length == 0) {
        throw FormatException('SMB2 message with zero length');
      }
      // Guard against excessive memory allocation (max 8MB, well above
      // typical maxTransactSize/maxReadSize of 1-4MB)
      if (length > 8 * 1024 * 1024) {
        throw FormatException('SMB2 message too large: $length bytes');
      }

      return _readExact(length);
    }
  }

  /// Close the connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _reader.cancel();
    await _closeTransport();
  }
}
