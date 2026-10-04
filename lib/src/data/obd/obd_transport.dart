import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/obd.dart';

/// A duplex link to an ELM327 adapter (Expo `CanTransport`). The session
/// client only depends on this, so it does not care whether the bytes travel
/// over Wi-Fi, Bluetooth or USB.
abstract class ObdTransport {
  /// `wifi` | `bluetooth` | `mfi` | `usb`.
  String get kind;

  /// Opens the link; answers the reader's name as shown to the driver.
  Future<String> connect();

  /// Sends one command (the carriage return is added here).
  Future<void> write(String command);

  /// Inbound ASCII text, in whatever chunks the link delivers.
  Stream<String> get data;

  Future<void> disconnect();
}

/// The usual Wi-Fi ELM327: a TCP socket to the dongle's own access point
/// (192.168.0.10:35000 unless the reader says otherwise). Uses Dart's own
/// sockets, so there is no native module to be missing on Android, iOS or
/// desktop; a browser cannot open raw sockets at all.
class WifiObdTransport implements ObdTransport {
  WifiObdTransport(this.host, this.port, {this.connectTimeout = const Duration(seconds: 15)});

  final String host;
  final int port;
  final Duration connectTimeout;

  Socket? _socket;
  StreamSubscription<List<int>>? _sub;
  final _data = StreamController<String>.broadcast();

  @override
  String get kind => 'wifi';

  @override
  Stream<String> get data => _data.stream;

  @override
  Future<String> connect() async {
    if (kIsWeb) {
      throw UnsupportedError('A browser cannot connect to a Wi-Fi OBD-II reader. Use the phone app.');
    }
    await _release();
    final socket = await Socket.connect(host, port, timeout: connectTimeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    // ELM327 speaks plain ASCII; latin1 never throws on a stray byte.
    _sub = socket.listen((bytes) => _data.add(latin1.decode(bytes)), onError: (_) {}, cancelOnError: false);
    return '$host:$port';
  }

  @override
  Future<void> write(String command) async {
    final s = _socket;
    if (s == null) throw StateError('not connected');
    s.add(ascii.encode('$command$elmCr'));
    await s.flush();
  }

  Future<void> _release() async {
    await _sub?.cancel();
    _sub = null;
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
  }

  @override
  Future<void> disconnect() => _release();
}
