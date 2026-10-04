import 'dart:async';

import 'package:get_ride/src/data/obd/obd_transport.dart';

/// A scripted ELM327: answers each command from [replies] (with the prompt),
/// echoing the speed it is told the car is doing.
class FakeElm implements ObdTransport {
  FakeElm({this.speed = 42});
  int speed;
  bool silent = false;
  bool refuseConnect = false;
  final written = <String>[];
  final _data = StreamController<String>.broadcast();
  bool connected = false;

  String _reply(String cmd) => switch (cmd) {
    'ATZ' => 'ELM327 v1.5',
    'ATDPN' => 'A6',
    '010D' => '41 0D ${speed.toRadixString(16).padLeft(2, '0').toUpperCase()}',
    '010C' => '41 0C 1A F8',
    '0105' => '41 05 7B',
    '01A6' => '41 A6 00 13 99 9A',
    _ when cmd.startsWith('AT') => 'OK',
    _ => 'NO DATA',
  };

  @override
  String get kind => 'wifi';

  @override
  Stream<String> get data => _data.stream;

  @override
  Future<String> connect() async {
    if (refuseConnect) throw Exception('Connection refused');
    connected = true;
    return '192.168.0.10:35000';
  }

  @override
  Future<void> write(String command) async {
    written.add(command);
    if (silent) return;
    // Replies arrive in pieces, as a socket delivers them.
    final reply = '${_reply(command)}\r\r>';
    scheduleMicrotask(() => _data.add(reply.substring(0, reply.length ~/ 2)));
    scheduleMicrotask(() => _data.add(reply.substring(reply.length ~/ 2)));
  }

  @override
  Future<void> disconnect() async => connected = false;
}
