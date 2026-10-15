// EV profiles for the OBD-II reader (migration 0202). Pure: the reader
// session (data/obd/obd_session.dart) sends the commands through an
// [EvSend] and feeds the replies through these parsers.
//
// Most electric cars answer nothing on standard OBD-II: battery, range and
// odometer sit behind maker-specific requests to one ECU (UDS service 0x22
// "read data by identifier", or similar). Those requests are not published,
// so the app ships none: an admin builds a profile from real captures
// ([evCaptureScript], recorded by drivers with "Record for support"), and a
// profile names, per value, which ECU to ask ([EvSignal.header]), what to
// ask ([EvSignal.request]) and where the value sits in the answer.
//
// An ELM327 answers with headers off and CAN auto-formatting on (the app's
// init, see obd.dart): a single frame is one line of hex; a longer answer is
// a byte count line ("00A") and numbered lines ("0:", "1:", …). With headers
// on (ATH1, as the capture script asks) each line is one raw ISO-TP frame
// after the CAN id that sent it. Both are read here.

/// The values a profile can read.
const evSignalKeys = <String>[
  'soc',
  'range_km',
  'odometer_km',
  'soh',
  'aux_voltage',
  'charging',
  'speed_kmh',
  'battery_temp_c',
  'hv_voltage',
  'hv_current',
];

/// What the driver sees each value called.
const evSignalLabels = <String, String>{
  'soc': 'Battery',
  'range_km': 'Range',
  'odometer_km': 'Odometer',
  'soh': 'Battery health',
  'aux_voltage': '12 V battery',
  'charging': 'Charging',
  'speed_kmh': 'Speed',
  'battery_temp_c': 'Battery temperature',
  'hv_voltage': 'High-voltage battery',
  'hv_current': 'Battery current',
};

/// The unit each value is shown in when the profile names none.
const evSignalUnits = <String, String>{
  'soc': '%',
  'range_km': 'km',
  'odometer_km': 'km',
  'soh': '%',
  'aux_voltage': 'V',
  'charging': '',
  'speed_kmh': 'km/h',
  'battery_temp_c': '°C',
  'hv_voltage': 'V',
  'hv_current': 'A',
};

final _atCommand = RegExp(r'^AT[A-Z0-9 ]{1,20}$');
final _hexRequest = RegExp(r'^(?:[0-9A-F]{2}){1,8}$');
final _hexPrefix = RegExp(r'^(?:[0-9A-F]{2}){1,16}$');
final _canHeader = RegExp(r'^(?:[0-9A-F]{3}|[0-9A-F]{8})$');

/// Upper-case hex with the spaces taken out ("22 01 05" → "220105").
String normalizeHex(String? s) => (s ?? '').replaceAll(RegExp(r'\s+'), '').toUpperCase();

/// An AT command (normalised to upper case, inner spaces kept) or a hex request.
String normalizeEvCommand(String s) {
  final t = s.trim().toUpperCase();
  return t.startsWith('AT') ? t.replaceAll(RegExp(r'\s+'), ' ') : normalizeHex(t);
}

/// An init entry: an AT setup command (`ATSP6`, `ATSH7E4`) or a hex request (`1003`).
bool isEvInitCommand(String s) => _atCommand.hasMatch(s) || _hexRequest.hasMatch(s);

/// A request to the vehicle: 1 to 8 bytes of hex (`220105`).
bool isEvHexRequest(String s) => _hexRequest.hasMatch(s);

/// A reply prefix: 1 to 16 bytes of hex.
bool isEvHexPrefix(String s) => _hexPrefix.hasMatch(s);

/// A CAN id: 11-bit (`7E4`) or 29-bit (`18DADBF1`).
bool isCanHeader(String s) => _canHeader.hasMatch(s);

/// The commands that address [header]: `ATSH7E4` for an 11-bit id;
/// `ATCP18` (priority) and `ATSHDADBF1` for a 29-bit one.
List<String> evHeaderCommands(String header) {
  final h = normalizeHex(header);
  if (h.length == 8) return ['ATCP${h.substring(0, 2)}', 'ATSH${h.substring(2)}'];
  return ['ATSH$h'];
}

/// The protocol a header needs when none was set by hand: ISO 15765-4 CAN
/// at 500 kbps, 11-bit (`ATSP6`) or 29-bit (`ATSP7`).
String evProtocolFor(String header) => normalizeHex(header).length == 8 ? 'ATSP7' : 'ATSP6';

/// The positive answer to [request]: its service + 0x40, then the rest of
/// the request echoed (`220105` → `620105`, `010D` → `410D`).
String positiveReplyPrefix(String request) {
  final r = normalizeHex(request);
  if (r.length < 2) return r;
  final service = int.tryParse(r.substring(0, 2), radix: 16);
  if (service == null) return r;
  return ((service + 0x40) & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase() + r.substring(2);
}

/// Restores what the app's own sweep expects after a profile or a capture
/// changed the reader's settings: defaults (ATD clears a set header and
/// priority), then the app's init (echo, linefeeds, spaces and headers off,
/// automatic protocol).
const evRestoreCommands = ['ATD', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0'];

double? _num(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v.trim()) : null);
int? _int(Object? v) {
  final n = _num(v);
  return n == null || n != n.roundToDouble() ? null : n.toInt();
}

String? _text(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

/// One value a profile reads: which ECU, what to ask, and where the value
/// sits in the answer.
class EvSignal {
  const EvSignal({
    required this.key,
    required this.header,
    required this.request,
    this.reply,
    this.start = 0,
    this.length = 1,
    this.signed = false,
    this.scale = 1,
    this.offset = 0,
    this.unit,
    this.bit,
  });

  /// One of [evSignalKeys].
  final String key;

  /// The ECU's CAN id (`7E4`, `18DADBF1`).
  final String header;

  /// The request, in hex (`220105`).
  final String request;

  /// The prefix a good answer starts with; by default the positive response
  /// ([positiveReplyPrefix]).
  final String? reply;

  /// The first byte of the value, counted from the end of the reply prefix.
  final int start;

  /// 1 to 4 bytes, big-endian.
  final int length;

  /// Two's complement.
  final bool signed;
  final double scale;
  final double offset;
  final String? unit;

  /// When set, the value is this bit (0-7) of the byte at [start] (a flag
  /// such as charging) instead of the whole bytes.
  final int? bit;

  String get expectedReply => reply ?? positiveReplyPrefix(request);

  String get unitOrDefault => unit ?? evSignalUnits[key] ?? '';

  static EvSignal? fromJson(Object? json) {
    if (json is! Map) return null;
    return EvSignal(
      key: '${json['key'] ?? ''}'.trim(),
      header: normalizeHex('${json['header'] ?? ''}'),
      request: normalizeHex('${json['request'] ?? ''}'),
      reply: _text(json['reply']) == null ? null : normalizeHex(json['reply'] as String),
      start: _int(json['start']) ?? 0,
      length: _int(json['length']) ?? 1,
      signed: json['signed'] == true,
      scale: _num(json['scale']) ?? 1,
      offset: _num(json['offset']) ?? 0,
      unit: _text(json['unit']),
      bit: _int(json['bit']),
    );
  }

  Map<String, Object?> toJson() => {
    'key': key,
    'header': header,
    'request': request,
    if (reply != null) 'reply': reply,
    'start': start,
    'length': length,
    'signed': signed,
    'scale': scale,
    'offset': offset,
    if (unit != null) 'unit': unit,
    if (bit != null) 'bit': bit,
  };

  /// What is wrong with it (the server checks the same), plainly; empty when
  /// nothing is.
  List<String> problems() => [
    if (!evSignalKeys.contains(key)) 'Choose which value this is.',
    if (!isCanHeader(header)) 'The ECU header must be a CAN id such as 7E4 or 18DADBF1.',
    if (!isEvHexRequest(request)) 'The request must be hex, 1 to 8 bytes, e.g. 220105.',
    if (reply != null && !isEvHexPrefix(reply!)) 'The reply prefix must be hex.',
    if (start < 0 || start > 255) 'The start byte must be from 0 to 255.',
    if (length < 1 || length > 4) 'The length must be 1 to 4 bytes.',
    if (bit != null && (bit! < 0 || bit! > 7)) 'The bit must be from 0 to 7.',
    if (!scale.isFinite || !offset.isFinite) 'Scale and offset must be numbers.',
    if ((unit ?? '').length > 12) 'The unit must be short.',
  ];

  EvSignal copyWith({
    String? key,
    String? header,
    String? request,
    String? Function()? reply,
    int? start,
    int? length,
    bool? signed,
    double? scale,
    double? offset,
    String? Function()? unit,
    int? Function()? bit,
  }) => EvSignal(
    key: key ?? this.key,
    header: header ?? this.header,
    request: request ?? this.request,
    reply: reply == null ? this.reply : reply(),
    start: start ?? this.start,
    length: length ?? this.length,
    signed: signed ?? this.signed,
    scale: scale ?? this.scale,
    offset: offset ?? this.offset,
    unit: unit == null ? this.unit : unit(),
    bit: bit == null ? this.bit : bit(),
  );

  @override
  bool operator ==(Object other) =>
      other is EvSignal &&
      other.key == key &&
      other.header == header &&
      other.request == request &&
      other.reply == reply &&
      other.start == start &&
      other.length == length &&
      other.signed == signed &&
      other.scale == scale &&
      other.offset == offset &&
      other.unit == unit &&
      other.bit == bit;

  @override
  int get hashCode => Object.hash(key, header, request, reply, start, length, signed, scale, offset, unit, bit);
}

/// The one request that tells this car apart: the first active profile
/// whose answer starts with [expect] (by default the positive response) is
/// the car's.
class EvDetect {
  const EvDetect({required this.request, this.header, this.expect});

  final String request;
  final String? header;
  final String? expect;

  String get expectedReply => expect ?? positiveReplyPrefix(request);

  static EvDetect? fromJson(Object? json) {
    if (json is! Map) return null;
    final request = normalizeHex('${json['request'] ?? ''}');
    if (request.isEmpty) return null;
    final header = _text(json['header']), expect = _text(json['expect']);
    return EvDetect(
      request: request,
      header: header == null ? null : normalizeHex(header),
      expect: expect == null ? null : normalizeHex(expect),
    );
  }

  Map<String, Object?> toJson() => {
    'request': request,
    if (header != null) 'header': header,
    if (expect != null) 'expect': expect,
  };

  List<String> problems() => [
    if (!isEvHexRequest(request)) 'The detect request must be hex, 1 to 8 bytes, e.g. 22F190.',
    if (header != null && !isCanHeader(header!)) 'The detect header must be a CAN id such as 7E4 or 18DADBF1.',
    if (expect != null && !isEvHexPrefix(expect!)) 'The expected reply must be hex.',
  ];

  @override
  bool operator ==(Object other) =>
      other is EvDetect && other.request == request && other.header == header && other.expect == expect;

  @override
  int get hashCode => Object.hash(request, header, expect);
}

/// One car (or family of cars) the app can read battery, range and odometer from.
class EvProfile {
  const EvProfile({
    this.id,
    required this.make,
    required this.model,
    this.years,
    this.label,
    this.active = false,
    this.verified = false,
    this.init = const [],
    this.detect,
    this.signals = const [],
    this.notes,
    this.updatedAt,
  });

  /// Null until saved.
  final String? id;
  final String make;
  final String model;

  /// e.g. `2024-2025`.
  final String? years;
  final String? label;

  /// Offered to the app.
  final bool active;

  /// Checked against a real car: only a verified profile's speed may bill.
  final bool verified;

  /// Sent once before the profile is used, in order.
  final List<String> init;
  final EvDetect? detect;
  final List<EvSignal> signals;
  final String? notes;
  final String? updatedAt;

  /// What the driver sees: the label, or make, model and years.
  String get title {
    final l = label?.trim() ?? '';
    if (l.isNotEmpty) return l;
    final y = years?.trim() ?? '';
    return [make, model, if (y.isNotEmpty) '($y)'].where((s) => s.trim().isNotEmpty).join(' ');
  }

  bool reads(String key) => signals.any((s) => s.key == key);

  static EvProfile? fromJson(Object? json) {
    if (json is! Map) return null;
    final make = _text(json['make']), model = _text(json['model']);
    if (make == null || model == null) return null;
    final init = json['init'], signals = json['signals'];
    return EvProfile(
      id: _text(json['id']),
      make: make,
      model: model,
      years: _text(json['years']),
      label: _text(json['label']),
      active: json['active'] == true,
      verified: json['verified'] == true,
      init: init is List
          ? [
              for (final c in init)
                if (c is String && c.trim().isNotEmpty) normalizeEvCommand(c),
            ]
          : const [],
      detect: EvDetect.fromJson(json['detect']),
      signals: signals is List ? signals.map(EvSignal.fromJson).whereType<EvSignal>().toList() : const [],
      notes: _text(json['notes']),
      updatedAt: _text(json['updated_at']),
    );
  }

  /// The row as saved: no id when new, nothing the server sets.
  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    'make': make,
    'model': model,
    'years': years,
    'label': label,
    'active': active,
    'verified': verified,
    'init': init,
    'detect': detect?.toJson(),
    'signals': [for (final s in signals) s.toJson()],
    'notes': notes,
    if (updatedAt != null) 'updated_at': updatedAt,
  };

  /// What is wrong with it, plainly; empty when it can be saved.
  List<String> problems() => [
    if (make.trim().isEmpty) 'Enter the make.',
    if (model.trim().isEmpty) 'Enter the model.',
    if (init.length > 20) 'At most 20 setup commands.',
    for (final c in init)
      if (!isEvInitCommand(c)) '"$c" is not an AT command (e.g. ATSP6) or a hex request.',
    ...?detect?.problems(),
    if (active && detect == null) 'An active profile needs a detect request.',
    if (active && signals.isEmpty) 'An active profile needs at least one signal.',
    if (signals.length > 40) 'At most 40 signals.',
    for (var i = 0; i < signals.length; i++)
      for (final p in signals[i].problems()) 'Signal ${i + 1}: $p',
  ];

  EvProfile copyWith({
    String? Function()? id,
    String? make,
    String? model,
    String? Function()? years,
    String? Function()? label,
    bool? active,
    bool? verified,
    List<String>? init,
    EvDetect? Function()? detect,
    List<EvSignal>? signals,
    String? Function()? notes,
  }) => EvProfile(
    id: id == null ? this.id : id(),
    make: make ?? this.make,
    model: model ?? this.model,
    years: years == null ? this.years : years(),
    label: label == null ? this.label : label(),
    active: active ?? this.active,
    verified: verified ?? this.verified,
    init: init ?? this.init,
    detect: detect == null ? this.detect : detect(),
    signals: signals ?? this.signals,
    notes: notes == null ? this.notes : notes(),
    updatedAt: updatedAt,
  );
}

/// A list of profiles from JSON (the app's RPC or the device cache).
List<EvProfile> parseEvProfiles(Object? json) =>
    json is List ? json.map(EvProfile.fromJson).whereType<EvProfile>().toList() : const [];

/* ------------------------------------------------------------------ *
 * Replies
 * ------------------------------------------------------------------ */

/// One message in a reply: its bytes and, with headers on, the CAN id that sent it.
class EvMessage {
  const EvMessage(this.bytes, {this.from});
  final List<int> bytes;
  final String? from;
}

/// What an ELM327 said to one request: the messages it carried, or why
/// there were none.
class EvReply {
  const EvReply({this.messages = const [], this.problem});

  final List<EvMessage> messages;

  /// `NO DATA`, `?`, `CAN ERROR`, `STOPPED`, … when nothing came back.
  final String? problem;

  /// The ECU's negative response code (`7F service code`), when it refused.
  int? get negativeCode {
    for (final m in messages) {
      if (m.bytes.length >= 3 && m.bytes[0] == 0x7F) return m.bytes[2];
    }
    return null;
  }

  /// The bytes after [prefix] in the first message that starts with it (or,
  /// failing that, carries it on a byte boundary); null when none does.
  List<int>? dataAfter(String prefix) {
    final want = _hexBytes(normalizeHex(prefix));
    if (want == null || want.isEmpty) return null;
    for (final exact in [true, false]) {
      for (final m in messages) {
        final b = m.bytes;
        for (var i = 0; i + want.length <= b.length; i++) {
          if (exact && i > 0) break;
          var match = true;
          for (var j = 0; j < want.length && match; j++) {
            match = b[i + j] == want[j];
          }
          if (match) return b.sublist(i + want.length);
        }
      }
    }
    return null;
  }

  /// Who answered, when headers were on (`7EC`, `18DAF1DB`), once each.
  List<String> get senders => {for (final m in messages) ?m.from}.toList();
}

const _problemTokens = {
  'NODATA': 'NO DATA',
  '?': '?',
  'CANERROR': 'CAN ERROR',
  'STOPPED': 'STOPPED',
  'UNABLETOCONNECT': 'UNABLE TO CONNECT',
  'BUFFERFULL': 'BUFFER FULL',
  'BUSERROR': 'BUS ERROR',
  'BUSBUSY': 'BUS BUSY',
  'FBERROR': 'FB ERROR',
  'DATAERROR': 'DATA ERROR',
  'ERROR': 'ERROR',
  '<RXERROR': 'RX ERROR',
  'ACTALERT': 'ACT ALERT',
  'LVRESET': 'LV RESET',
};

List<int>? _hexBytes(String hex) {
  if (hex.length.isOdd || !RegExp(r'^[0-9A-F]*$').hasMatch(hex)) return null;
  return [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
}

/// Reads an ELM327 reply ([raw], prompt and all). [request] drops its echo
/// when echo was left on.
EvReply parseElmReply(String raw, {String? request}) {
  final echo = request == null ? null : normalizeEvCommand(request).replaceAll(' ', '');
  final lines = raw
      .replaceAll('>', '')
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.replaceAll(RegExp(r'\s+'), '').toUpperCase())
      .where((l) => l.isNotEmpty)
      .toList();
  final messages = <EvMessage>[];
  String? problem;

  // Headers off, auto-formatting on: "00A", "0:…", "1:…".
  List<int>? multi;
  int? multiLength;
  void flushMulti() {
    final m = multi;
    if (m != null && m.isNotEmpty) {
      messages.add(EvMessage(multiLength != null && m.length > multiLength! ? m.sublist(0, multiLength) : m));
    }
    multi = null;
    multiLength = null;
  }

  // Headers on: raw ISO-TP frames per sender.
  final firstFrames = <String, List<int>>{};
  final wanted = <String, int>{};

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (echo != null && line == echo) continue;
    if (line.startsWith('SEARCHING') || line.startsWith('BUSINIT') || line == 'OK') continue;
    if (line.startsWith('ELM327') || line.startsWith('STN') || line.startsWith('OBDLINK')) continue;
    final token = _problemTokens[line] ?? (line.contains('ERROR') ? 'ERROR' : null);
    if (token != null) {
      problem ??= token;
      continue;
    }
    final numbered = RegExp(r'^([0-9A-F]):([0-9A-F]*)$').firstMatch(line);
    if (numbered != null) {
      final index = int.parse(numbered.group(1)!, radix: 16);
      final bytes = _hexBytes(numbered.group(2)!) ?? const <int>[];
      if (index == 0 || multi == null) {
        final length = multiLength;
        flushMulti();
        multiLength = length;
        multi = [...bytes];
      } else {
        multi!.addAll(bytes);
      }
      continue;
    }
    if (RegExp(r'^[0-9A-F]{3}$').hasMatch(line)) {
      // The byte count before a numbered answer.
      flushMulti();
      multiLength = int.parse(line, radix: 16);
      continue;
    }
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(line)) continue;
    flushMulti();
    // A frame after the CAN id that sent it: 11-bit ids make the line odd.
    String? from;
    String body = line;
    if (line.length.isOdd && line.length >= 7) {
      from = line.substring(0, 3);
      body = line.substring(3);
    } else if (line.length >= 12 && (line.startsWith('18DA') || line.startsWith('18DB'))) {
      from = line.substring(0, 8);
      body = line.substring(8);
    }
    final bytes = _hexBytes(body);
    if (bytes == null || bytes.isEmpty) continue;
    if (from == null) {
      messages.add(EvMessage(bytes));
      continue;
    }
    final pci = bytes[0] >> 4;
    switch (pci) {
      case 0:
        final n = bytes[0] & 0x0F;
        messages.add(EvMessage(bytes.sublist(1, (1 + n).clamp(1, bytes.length)), from: from));
      case 1 when bytes.length >= 2:
        wanted[from] = ((bytes[0] & 0x0F) << 8) | bytes[1];
        firstFrames[from] = bytes.sublist(2);
        _completeFrames(firstFrames, wanted, from, messages);
      case 2:
        final buf = firstFrames[from];
        if (buf == null) continue;
        buf.addAll(bytes.sublist(1));
        _completeFrames(firstFrames, wanted, from, messages);
      default:
      // Flow control (3x) or something unknown: no data.
    }
  }
  flushMulti();
  // An answer cut short still carries its first bytes.
  for (final MapEntry(key: from, value: buf) in firstFrames.entries) {
    messages.add(EvMessage(buf, from: from));
  }
  return EvReply(messages: messages, problem: messages.isEmpty ? (problem ?? 'NO DATA') : null);
}

void _completeFrames(Map<String, List<int>> frames, Map<String, int> wanted, String from, List<EvMessage> out) {
  final buf = frames[from]!, want = wanted[from] ?? 0;
  if (buf.length < want) return;
  out.add(EvMessage(buf.sublist(0, want), from: from));
  frames.remove(from);
  wanted.remove(from);
}

/// The value of [s] in [data] (the bytes after the reply prefix), or null
/// when the answer is too short.
double? evSignalValue(EvSignal s, List<int> data) {
  if (s.start < 0 || s.length < 1 || s.length > 4) return null;
  double raw;
  if (s.bit != null) {
    if (data.length <= s.start) return null;
    raw = ((data[s.start] >> s.bit!) & 1).toDouble();
  } else {
    if (data.length < s.start + s.length) return null;
    // Multiplication, not shifts: four bytes stay exact on the web too.
    var v = 0.0;
    for (var i = 0; i < s.length; i++) {
      v = v * 256 + data[s.start + i];
    }
    if (s.signed) {
      var full = 1.0;
      for (var i = 0; i < s.length; i++) {
        full *= 256;
      }
      if (v >= full / 2) v -= full;
    }
    raw = v;
  }
  final value = raw * s.scale + s.offset;
  return value.isFinite ? value : null;
}

/// The value of [s] in [raw] (a whole ELM327 reply), or null when the car
/// did not give it (NO DATA, a refusal, an answer too short).
double? decodeEvSignal(EvSignal s, String raw) {
  final data = parseElmReply(raw, request: s.request).dataAfter(s.expectedReply);
  return data == null ? null : evSignalValue(s, data);
}

/* ------------------------------------------------------------------ *
 * Snapshot
 * ------------------------------------------------------------------ */

/// The latest values an EV profile read.
class EvSnapshot {
  const EvSnapshot({this.values = const {}, this.at, this.profileId});

  /// Per [evSignalKeys] key.
  final Map<String, double> values;

  /// Epoch ms.
  final int? at;
  final String? profileId;

  /// Battery, %.
  double? get soc => values['soc'];
  double? get rangeKm => values['range_km'];
  double? get odometerKm => values['odometer_km'];

  /// Battery health, %.
  double? get soh => values['soh'];
  double? get auxVoltage => values['aux_voltage'];
  bool? get charging => values['charging'] == null ? null : values['charging'] != 0;
  double? get speedKmh => values['speed_kmh'];
  double? get batteryTempC => values['battery_temp_c'];
  double? get hvVoltage => values['hv_voltage'];
  double? get hvCurrent => values['hv_current'];

  bool get isEmpty => values.isEmpty;
}

String _grouped(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// One value as the driver reads it (`80 %`, `312 km`, `12,345.6 km`, `Yes`).
String formatEvValue(String key, double value, {String? unit}) {
  final u = unit ?? evSignalUnits[key] ?? '';
  final text = switch (key) {
    'charging' => value != 0 ? 'Yes' : 'No',
    'odometer_km' => '${_grouped((value * 10).round() ~/ 10)}.${(value * 10).round().abs() % 10}',
    'soc' || 'soh' || 'range_km' || 'speed_kmh' => _grouped(value.round()),
    _ => value.toStringAsFixed(1),
  };
  return key == 'charging' || u.isEmpty ? text : '$text $u';
}

/// The values the driver looks for first, in this order.
const evHeadlineKeys = ['soc', 'range_km', 'odometer_km'];

/// "Battery 80 % · Range 312 km · Odometer 12,345.6 km", for the values read.
String evSummary(EvSnapshot s, {List<String> keys = evHeadlineKeys}) => [
  for (final k in keys)
    if (s.values[k] != null) '${evSignalLabels[k]} ${formatEvValue(k, s.values[k]!)}',
].join(' · ');

/* ------------------------------------------------------------------ *
 * Talking to the reader
 * ------------------------------------------------------------------ */

/// Sends one command and answers the raw reply (the session's queue).
typedef EvSend = Future<String> Function(String command);

/// Sends commands to one ECU after another, setting the header only when it
/// changes (each ATSH is a round trip).
class EvBus {
  EvBus(this.send);
  final EvSend send;
  String? _header;
  String? _protocol;

  /// Forgets the header and protocol set, after something else changed them.
  void forget() {
    _header = null;
    _protocol = null;
  }

  /// Notes a protocol set by a profile's own init, so it is not set again.
  void protocolSet(String atsp) => _protocol = atsp;

  Future<void> address(String header, {bool setProtocol = false}) async {
    final h = normalizeHex(header);
    if (setProtocol) {
      final p = evProtocolFor(h);
      if (_protocol != p) {
        await send(p);
        _protocol = p;
      }
    }
    if (_header == h) return;
    for (final c in evHeaderCommands(h)) {
      await send(c);
    }
    _header = h;
  }

  /// Asks [header] for [request].
  Future<String> ask(String header, String request, {bool setProtocol = false}) async {
    await address(header, setProtocol: setProtocol);
    return send(normalizeHex(request));
  }
}

/// Sends a profile's init, in order; notes a protocol it sets.
Future<void> sendEvInit(EvBus bus, EvProfile p) async {
  for (final c in p.init) {
    await bus.send(c);
    if (c.startsWith('ATSP')) bus.protocolSet(c.replaceAll(' ', ''));
  }
}

/// Whether the car answers [p]'s detect request as expected.
Future<bool> evProfileDetects(EvBus bus, EvProfile p) async {
  final d = p.detect;
  if (d == null) return false;
  try {
    bus.forget();
    await sendEvInit(bus, p);
    final raw = d.header == null ? await bus.send(d.request) : await bus.ask(d.header!, d.request);
    return parseElmReply(raw, request: d.request).dataAfter(d.expectedReply) != null;
  } catch (_) {
    return false;
  }
}

/// The profiles whose detect request the car answers, in the order given.
Future<List<EvProfile>> detectEvProfiles(EvBus bus, List<EvProfile> profiles, {bool Function()? shouldContinue}) async {
  final out = <EvProfile>[];
  for (final p in profiles) {
    if (shouldContinue != null && !shouldContinue()) break;
    if (await evProfileDetects(bus, p)) out.add(p);
  }
  return out;
}

/// One pass over [p]'s signals: each request asked once, however many
/// values share it. A request that fails leaves its values out.
Future<EvSnapshot> readEvSnapshot(EvBus bus, EvProfile p, {required int at, bool Function()? shouldContinue}) async {
  final values = <String, double>{};
  final asked = <String, String?>{};
  for (final s in p.signals) {
    if (shouldContinue != null && !shouldContinue()) break;
    final id = '${s.header}|${s.request}';
    if (!asked.containsKey(id)) {
      try {
        asked[id] = await bus.ask(s.header, s.request);
      } catch (_) {
        asked[id] = null;
      }
    }
    final raw = asked[id];
    if (raw == null) continue;
    final v = decodeEvSignal(s, raw);
    if (v != null) values[s.key] = v;
  }
  return EvSnapshot(values: values, at: at, profileId: p.id);
}

/* ------------------------------------------------------------------ *
 * Capture for support
 * ------------------------------------------------------------------ */

/// One request of the capture script.
class EvCaptureStep {
  const EvCaptureStep(this.header, this.request);
  final String header;
  final String request;
}

/// What the reader answered to one step.
class EvCaptureEntry {
  const EvCaptureEntry({required this.header, required this.request, required this.reply, required this.ms});

  final String header;
  final String request;

  /// The reply as the reader sent it (trimmed), or `TIMEOUT`.
  final String reply;
  final int ms;

  static EvCaptureEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    return EvCaptureEntry(
      header: '${json['header'] ?? ''}',
      request: '${json['request'] ?? ''}',
      reply: '${json['reply'] ?? ''}',
      ms: _int(json['ms']) ?? 0,
    );
  }

  Map<String, Object?> toJson() => {'header': header, 'request': request, 'reply': reply, 'ms': ms};

  /// The car answered it with data.
  bool get answered => parseElmReply(reply, request: request).dataAfter(positiveReplyPrefix(request)) != null;

  /// An ECU refused it (7F): the ECU is there, the question is not one it takes.
  bool get refused => !answered && parseElmReply(reply, request: request).negativeCode != null;
}

/// The standard and generic diagnostic identifiers the capture asks for —
/// the same for every car, nothing maker-specific: supported PIDs (0100),
/// speed (010D), odometer (01A6), VIN (0902), and the UDS identifiers for
/// VIN (22F190) and ECU serial number (22F18C).
const evCaptureRequests = ['0100', '010D', '01A6', '0902', '22F190', '22F18C'];

/// The ECU addresses the capture asks: the 11-bit broadcast (7DF), each
/// standard 11-bit ECU (7E0-7E7), and the 29-bit broadcast (18DB33F1).
const evCaptureHeaders = ['7DF', '7E0', '7E1', '7E2', '7E3', '7E4', '7E5', '7E6', '7E7', '18DB33F1'];

/// The most identifiers one range scan asks for.
const evMaxRangeScan = 512;

/// A scan of one ECU's identifiers (UDS 0x22) from [from] to [to].
class EvRangeScan {
  const EvRangeScan({required this.header, required this.from, required this.to});
  final String header;
  final int from;
  final int to;

  /// Null when it can be run, else why not.
  String? get problem {
    if (!isCanHeader(normalizeHex(header))) return 'The ECU header must be a CAN id such as 7E4 or 18DADBF1.';
    if (from < 0 || to > 0xFFFF || from > to) return 'The identifiers must run from low to high, 0000 to FFFF.';
    if (to - from + 1 > evMaxRangeScan) return 'At most $evMaxRangeScan identifiers in one scan.';
    return null;
  }

  List<EvCaptureStep> get steps => [
    for (var did = from; did <= to; did++)
      EvCaptureStep(normalizeHex(header), '22${did.toRadixString(16).padLeft(4, '0').toUpperCase()}'),
  ];
}

/// The capture script: [evCaptureRequests] to every [evCaptureHeaders]
/// address, then [range] when given.
List<EvCaptureStep> evCaptureScript({EvRangeScan? range}) => [
  for (final h in evCaptureHeaders)
    for (final r in evCaptureRequests) EvCaptureStep(h, r),
  if (range != null && range.problem == null) ...range.steps,
];

/// Runs [steps] with headers on (so each answer says which ECU sent it) and
/// restores the reader's settings afterwards. A step that times out is
/// recorded and the capture goes on; [shouldContinue] false stops it
/// (cancelled). Throws only when the reader itself is gone.
Future<List<EvCaptureEntry>> runEvCapture(
  EvSend send,
  List<EvCaptureStep> steps, {
  void Function(int done, int total, EvCaptureStep step)? onProgress,
  bool Function()? shouldContinue,
  int Function()? now,
}) async {
  final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
  final bus = EvBus(send);
  final out = <EvCaptureEntry>[];
  try {
    await send('ATH1');
    for (var i = 0; i < steps.length; i++) {
      if (shouldContinue != null && !shouldContinue()) break;
      final step = steps[i];
      onProgress?.call(i, steps.length, step);
      final started = clock();
      String reply;
      try {
        reply = await bus.ask(step.header, step.request, setProtocol: true);
      } on StateError {
        rethrow;
      } catch (_) {
        // Unanswered: the next step sets its header again.
        bus.forget();
        reply = 'TIMEOUT';
      }
      out.add(
        EvCaptureEntry(
          header: step.header,
          request: step.request,
          reply: reply.replaceAll('>', '').trim(),
          ms: clock() - started,
        ),
      );
    }
    onProgress?.call(steps.length, steps.length, steps.isEmpty ? const EvCaptureStep('', '') : steps.last);
  } finally {
    for (final c in evRestoreCommands) {
      try {
        await send(c);
      } catch (_) {}
    }
  }
  return out;
}

/// How a capture went: answered, refused by an ECU, or nothing back.
({int answered, int refused, int silent}) summarizeEvCapture(List<EvCaptureEntry> entries) {
  var answered = 0, refused = 0;
  for (final e in entries) {
    if (e.answered) {
      answered++;
    } else if (e.refused) {
      refused++;
    }
  }
  return (answered: answered, refused: refused, silent: entries.length - answered - refused);
}

/// A capture as stored (`obd_captures`).
class EvCapture {
  const EvCapture({
    this.id,
    this.profileId,
    required this.vehicle,
    this.batteryHint,
    this.reader,
    this.appVersion,
    this.entries = const [],
    this.createdAt,
  });

  final String? id;
  final String? profileId;
  final String vehicle;
  final String? batteryHint;
  final String? reader;
  final String? appVersion;
  final List<EvCaptureEntry> entries;
  final String? createdAt;

  static EvCapture? fromJson(Object? json) {
    if (json is! Map) return null;
    final entries = json['entries'];
    return EvCapture(
      id: _text(json['id']),
      profileId: _text(json['profile_id']),
      vehicle: _text(json['vehicle']) ?? '',
      batteryHint: _text(json['battery_hint']),
      reader: _text(json['reader']),
      appVersion: _text(json['app_version']),
      entries: entries is List ? entries.map(EvCaptureEntry.fromJson).whereType<EvCaptureEntry>().toList() : const [],
      createdAt: _text(json['created_at']),
    );
  }

  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    if (profileId != null) 'profile_id': profileId,
    'vehicle': vehicle,
    'battery_hint': batteryHint,
    'reader': reader,
    'app_version': appVersion,
    'entries': [for (final e in entries) e.toJson()],
    if (createdAt != null) 'created_at': createdAt,
  };
}
