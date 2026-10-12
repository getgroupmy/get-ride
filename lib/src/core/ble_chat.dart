// Chat over Bluetooth when there's no signal (reliability Phase D3; the
// server half is migration 0155). A chat message that can't reach the server
// goes phone to phone as one small frame, signed with a key only the two
// phones on the ride hold. Pure.
//
//   message: 0x01 | client_msg_id (16) | sent at, unix seconds (4) | text (UTF-8) | mac (8)
//   ack:     0x02 | client_msg_id (16) | mac (8)
//
// mac = the first 8 bytes of HMAC-SHA256(chat key, everything before it).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'ride_chat.dart';

/// The largest frame sent: what fits one write at the MTU phones settle on
/// (185, less the 3-byte ATT header, less margin).
const bleChatMaxFrame = 180;

const _kindMessage = 0x01;
const _kindAck = 0x02;
const _idLen = 16;
const _macLen = 8;
const _headerLen = 1 + _idLen + 4;

/// How many bytes of text a frame can carry.
const bleChatMaxTextBytes = bleChatMaxFrame - _headerLen - _macLen;

/// A message older than this is not shown when it arrives: a "I'm at the
/// gate" from an hour ago only confuses (the chat outbox gives up at 30 min).
const bleChatMaxAge = Duration(minutes: 30);

/// The GATT service the driver's phone serves, and its two characteristics:
/// the rider's phone writes to rx and is notified on tx. "get.ride" + "chat".
const bleChatServiceUuid = '6765742e-7269-6465-6368-617400000000';
const bleChatRxUuid = '6765742e-7269-6465-6368-617400000001';
const bleChatTxUuid = '6765742e-7269-6465-6368-617400000002';

sealed class BleChatFrame {
  const BleChatFrame(this.clientMsgId);
  final String clientMsgId;
}

class BleChatMessage extends BleChatFrame {
  const BleChatMessage(super.clientMsgId, {required this.text, required this.sentAt});
  final String text;
  final DateTime sentAt;
}

class BleChatAck extends BleChatFrame {
  const BleChatAck(super.clientMsgId);
}

/// The chat key as the server hands it over (64 hex digits); null when it isn't.
Uint8List? bleChatKey(String? hex) {
  final h = (hex ?? '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) return null;
  return Uint8List.fromList([for (var i = 0; i < 64; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
}

/// Whether [text] fits one frame.
bool bleChatFits(String text) => text.isNotEmpty && utf8.encode(text).length <= bleChatMaxTextBytes;

Uint8List? _idBytes(String uuid) {
  final h = uuid.replaceAll('-', '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(h)) return null;
  return Uint8List.fromList([for (var i = 0; i < 32; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
}

String _idString(List<int> b) {
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

List<int> _mac(Uint8List key, List<int> body) => Hmac(sha256, key).convert(body).bytes.sublist(0, _macLen);

Uint8List _sign(Uint8List key, List<int> body) => Uint8List.fromList([...body, ..._mac(key, body)]);

/// A message frame; null when it can't be one (bad id, empty, too long).
Uint8List? encodeBleChatMessage(Uint8List key, String clientMsgId, String text, DateTime sentAt) {
  final id = _idBytes(clientMsgId);
  final t = utf8.encode(text);
  if (id == null || t.isEmpty || t.length > bleChatMaxTextBytes) return null;
  final secs = sentAt.toUtc().millisecondsSinceEpoch ~/ 1000;
  final ts = ByteData(4)..setUint32(0, secs);
  return _sign(key, [_kindMessage, ...id, ...ts.buffer.asUint8List(), ...t]);
}

/// An ack frame for [clientMsgId]; null for a bad id.
Uint8List? encodeBleChatAck(Uint8List key, String clientMsgId) {
  final id = _idBytes(clientMsgId);
  return id == null ? null : _sign(key, [_kindAck, ...id]);
}

/// The frame [bytes] carries, if it is well formed and signed with [key];
/// null for anything else (another ride's phone, a stranger, noise). A
/// message older than [bleChatMaxAge] (or from the future) is dropped too.
BleChatFrame? decodeBleChatFrame(Uint8List key, List<int> bytes, {required DateTime now}) {
  if (bytes.length < 1 + _idLen + _macLen || bytes.length > bleChatMaxFrame) return null;
  final body = bytes.sublist(0, bytes.length - _macLen);
  final mac = bytes.sublist(bytes.length - _macLen);
  final want = _mac(key, body);
  var diff = 0;
  for (var i = 0; i < _macLen; i++) {
    diff |= mac[i] ^ want[i];
  }
  if (diff != 0) return null;
  final id = _idString(body.sublist(1, 1 + _idLen));
  switch (body[0]) {
    case _kindAck:
      return body.length == 1 + _idLen ? BleChatAck(id) : null;
    case _kindMessage:
      if (body.length <= _headerLen) return null;
      final secs = ByteData.sublistView(Uint8List.fromList(body.sublist(1 + _idLen, _headerLen))).getUint32(0);
      final sentAt = DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
      final age = now.toUtc().difference(sentAt);
      if (age > bleChatMaxAge || age < const Duration(minutes: -5)) return null;
      final String text;
      try {
        text = utf8.decode(body.sublist(_headerLen));
      } on FormatException {
        return null;
      }
      return BleChatMessage(id, text: text, sentAt: sentAt);
    default:
      return null;
  }
}

/// A message that arrived over Bluetooth, as the thread shows it until the
/// server has its own copy (same client_msg_id).
RideMessage bleChatToMessage(
  BleChatMessage m, {
  required String requestId,
  required String senderId,
  required RideChatRole senderRole,
}) => RideMessage(
  id: 'ble-${m.clientMsgId}',
  requestId: requestId,
  senderId: senderId,
  senderRole: senderRole,
  body: m.text,
  createdAt: m.sentAt.toLocal(),
  clientMsgId: m.clientMsgId,
  viaBluetooth: true,
);

/// The thread with what arrived over Bluetooth, minus anything the server
/// (or this phone's own queue) already shows under the same id; oldest first.
List<RideMessage> withBluetoothMessages(List<RideMessage> thread, Iterable<RideMessage> received) {
  final shown = {for (final m in thread) ?m.clientMsgId};
  final extra = [
    for (final m in received)
      if (!shown.contains(m.clientMsgId)) m,
  ];
  if (extra.isEmpty) return thread;
  final all = [...thread, ...extra];
  all.sort((a, b) => (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)));
  return all;
}
