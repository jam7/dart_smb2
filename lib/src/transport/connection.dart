import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Manages TCP connection to an SMB2 server.
///
/// All SMB2 packets are framed with a 4-byte NetBIOS session header:
/// ```
/// [0x00] [Length (3 bytes, big-endian)]
/// ```
class Smb2Connection {
  final Socket _socket;
  final StreamIterator<Uint8List> _reader;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int _bufferLength = 0;
  bool _closed = false;

  Smb2Connection._(this._socket) : _reader = StreamIterator(_socket);

  bool get isClosed => _closed;

  /// Connect to [host]:[port] (default 445).
  static Future<Smb2Connection> connect(String host, {int port = 445}) async {
    final socket = await Socket.connect(host, port);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return Smb2Connection._(socket);
  }

  /// Send a complete SMB2 message (without NetBIOS header).
  /// Prepends the 4-byte NetBIOS session header.
  void sendRaw(Uint8List data) {
    final frame = Uint8List(4 + data.length);
    final bd = ByteData.sublistView(frame);
    // NetBIOS session header: type=0x00, length=24-bit big-endian
    frame[0] = 0x00;
    bd.setUint16(1, (data.length >> 8) & 0xFFFF, Endian.big);
    frame[3] = data.length & 0xFF;
    frame.setRange(4, 4 + data.length, data);
    _socket.add(frame);
  }

  /// Read exactly [length] bytes from the socket.
  Future<Uint8List> _readExact(int length) async {
    while (_bufferLength < length) {
      final hasMore = await _reader.moveNext();
      if (!hasMore) {
        throw SocketException('Connection closed while reading');
      }
      final chunk = _reader.current;
      _buffer.add(chunk);
      _bufferLength += chunk.length;
    }
    // Take all buffered bytes, then split at [length]
    final all = _buffer.takeBytes();
    _bufferLength = 0;
    if (all.length == length) {
      return all;
    }
    // Put remainder back
    _buffer.add(Uint8List.sublistView(all, length));
    _bufferLength = all.length - length;
    return Uint8List.sublistView(all, 0, length);
  }

  /// Read one complete SMB2 message (strips NetBIOS header).
  /// Returns the raw SMB2 packet bytes.
  Future<Uint8List> readMessage() async {
    // Read 4-byte NetBIOS header
    final header = await _readExact(4);

    // Skip keep-alive (0x85)
    if (header[0] == 0x85) {
      return readMessage();
    }

    // Parse length (24-bit big-endian)
    final length = (header[1] << 16) | (header[2] << 8) | header[3];
    if (length == 0) {
      throw FormatException('SMB2 message with zero length');
    }

    return _readExact(length);
  }

  /// Close the connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _reader.cancel();
    await _socket.close();
  }
}
