// What someone holding a dispatch role (a stand admin, stand staff, a fleet
// owner) does when they sign in (migration 0281): set their PIN, take a live
// selfie, upload their ID, take a selfie again on a new phone, then wait for
// the ID to be approved. The server decides (dispatch_my_checks) and holds the
// role shut until then; this reads its answer, picks the step to show and
// words it. Also the admin's switches, the reasons a photo or an ID is
// rejected, and reading a MyKad or passport photo's text. Pure, so it is
// tested without a database or a camera.
library;

/// One thing still to do, as dispatch_my_checks names it.
enum CheckNeed {
  pin,
  selfie,
  recheck,
  id,
  pending;

  static CheckNeed? parse(Object? v) => values.where((n) => n.name == v).firstOrNull;
}

/// A photo or ID's state on record.
enum RecordState {
  ok,
  received,
  renew,
  pending,
  rejected,
  expired,
  missing;

  static RecordState parse(Object? v) => values.firstWhere((s) => s.name == v, orElse: () => missing);
}

/// Why an admin rejected a photo or an ID, in the order the admin picks from.
const rejectReasons = <String, String>{
  'blurry': 'Photo blurry',
  'face_unclear': 'Face not clear',
  'name_mismatch': "Name doesn't match",
  'expired': 'Expired',
  'wrong_document': 'Wrong document',
  'other': 'Other',
};

/// "Photo blurry: Use better light", or the note alone, or null.
String? rejectReasonText(Object? reason, [Object? note]) {
  final r = rejectReasons['${reason ?? ''}'];
  final n = '${note ?? ''}'.trim();
  if (r == null && n.isEmpty) return null;
  if (r == null || (reason == 'other' && n.isNotEmpty)) return n;
  return n.isEmpty ? r : '$r: $n';
}

/// The reviewer notes written on a partner or vehicle document when it is
/// rejected with a reason from the list: the reason, then the note.
String rejectNotes(String reason, String note) => rejectReasonText(reason, note) ?? note.trim();

/// The admin's choice for one rejection.
typedef RejectChoice = ({String reason, String note});

/// Null when [choice] may be sent, else what to say: Other needs a note.
String? rejectChoiceProblem(String? reason, String note) {
  if (reason == null || !rejectReasons.containsKey(reason)) return 'Pick why.';
  if (reason == 'other' && note.trim().isEmpty) return 'Say why in the note.';
  return null;
}

/// A photo's or an ID's state with the admin's reason.
class RecordInfo {
  const RecordInfo({this.state = RecordState.missing, this.reason, this.note, this.expiry, this.renewing = false});

  factory RecordInfo.fromJson(Object? v) {
    final m = v is Map ? v : const {};
    return RecordInfo(
      state: RecordState.parse(m['state']),
      reason: m['reason'] as String?,
      note: m['note'] as String?,
      expiry: DateTime.tryParse('${m['expiry'] ?? ''}'),
      renewing: m['renewing'] == true,
    );
  }

  final RecordState state;
  final String? reason;
  final String? note;
  final DateTime? expiry;

  /// A newer ID waits for review while the old one is still good.
  final bool renewing;

  /// The admin's reason when it was rejected (or a renewal was), else null.
  String? get rejection => rejectReasonText(reason, note);
}

/// The step the phone shows.
enum SignInStep { pin, selfie, id, pending, done }

/// dispatch_my_checks' answer.
class DispatchChecks {
  const DispatchChecks({
    this.holds = false,
    this.kinds = const [],
    this.needs = const {},
    this.asksSelfie = false,
    this.asksId = false,
    this.selfie = const RecordInfo(),
    this.id = const RecordInfo(),
    this.deadline,
    this.paused = false,
    this.renewDays = 30,
  });

  /// Nobody's role is held up: a database before 0281, no signal, no role.
  static const none = DispatchChecks();

  factory DispatchChecks.fromJson(Object? v) {
    final m = v is Map ? v : const {};
    return DispatchChecks(
      holds: m['holds'] == true,
      kinds: [for (final k in (m['kinds'] as List?) ?? const []) '$k'],
      needs: {
        for (final n in (m['needs'] as List?) ?? const []) ?CheckNeed.parse(n),
      },
      asksSelfie: m['asks_selfie'] == true,
      asksId: m['asks_id'] == true,
      selfie: RecordInfo.fromJson(m['selfie']),
      id: RecordInfo.fromJson(m['id']),
      deadline: DateTime.tryParse('${m['deadline'] ?? ''}'),
      paused: m['paused'] == true,
      renewDays: (m['renew_days'] as num?)?.toInt() ?? 30,
    );
  }

  final bool holds;
  final List<String> kinds;
  final Set<CheckNeed> needs;
  final bool asksSelfie;
  final bool asksId;
  final RecordInfo selfie;
  final RecordInfo id;
  final DateTime? deadline;
  final bool paused;
  final int renewDays;

  /// Whether the role is shut until something is done.
  bool get blocked => holds && needs.isNotEmpty;

  /// The selfie asked: none yet or rejected, or this phone is new.
  bool get needsSelfie => needs.contains(CheckNeed.selfie) || needs.contains(CheckNeed.recheck);

  /// Only the new phone asks for it.
  bool get recheckOnly => needs.contains(CheckNeed.recheck) && !needs.contains(CheckNeed.selfie);

  /// The ID runs out soon: asked for a new one, the role still open.
  bool get renewDue => holds && asksId && id.state == RecordState.renew;

  /// One step at a time: the PIN, the selfie, the ID, then waiting.
  SignInStep get step {
    if (!holds) return SignInStep.done;
    if (needs.contains(CheckNeed.pin)) return SignInStep.pin;
    if (needsSelfie) return SignInStep.selfie;
    if (needs.contains(CheckNeed.id)) return SignInStep.id;
    if (needs.contains(CheckNeed.pending)) return SignInStep.pending;
    return SignInStep.done;
  }

  /// Days left to finish, when there is a deadline still ahead.
  int? daysLeft(DateTime now) {
    final d = deadline;
    if (d == null || !d.isAfter(now)) return null;
    return (d.difference(now).inHours / 24).ceil();
  }
}

/// What the role is called, for the phone's words.
String roleWord(List<String> kinds) {
  if (kinds.contains('stand_admin')) return 'stand admin';
  if (kinds.contains('fleet_owner')) return 'fleet owner';
  if (kinds.contains('staff')) return 'stand staff';
  return 'dispatch';
}

/// The waiting page's lines: each thing sent and where it stands.
List<({String label, String state, bool done})> waitingLines(DispatchChecks c) => [
  if (c.asksId)
    switch (c.id.state) {
      RecordState.ok || RecordState.renew => (label: 'ID', state: 'Approved', done: true),
      RecordState.pending => (label: 'ID', state: 'Waiting for review', done: false),
      _ => (label: 'ID', state: 'Not sent', done: false),
    },
  if (c.asksSelfie || c.selfie.state != RecordState.missing)
    switch (c.selfie.state) {
      RecordState.ok => (label: 'Photo', state: 'Approved', done: true),
      RecordState.received => (label: 'Photo', state: 'Received', done: true),
      RecordState.rejected => (label: 'Photo', state: 'Not accepted', done: false),
      _ => (label: 'Photo', state: 'Not sent', done: false),
    },
];

// ---- The admin's switches ---------------------------------------------------------------------

/// What a grant asks when they sign in (dispatch_grant's p_perms keys).
class SignInAsks {
  const SignInAsks({this.selfie = false, this.id = false, this.days});

  factory SignInAsks.fromJson(Object? v) {
    final m = v is Map ? v : const {};
    return SignInAsks(selfie: m['selfie'] == true, id: m['id'] == true, days: (m['days'] as num?)?.toInt());
  }

  final bool selfie;
  final bool id;

  /// "Finish within X days"; null: no deadline.
  final int? days;

  bool get any => selfie || id;

  SignInAsks copyWith({bool? selfie, bool? id, int? Function()? days}) =>
      SignInAsks(selfie: selfie ?? this.selfie, id: id ?? this.id, days: days == null ? this.days : days());

  /// For dispatch_grant / the dispatch-account function. A deadline only
  /// when something is asked.
  Map<String, Object?> toJson() => {
    'verify_selfie': selfie,
    'verify_id': id,
    'verify_days': any ? days : null,
  };

  @override
  bool operator ==(Object other) =>
      other is SignInAsks && other.selfie == selfie && other.id == id && other.days == days;

  @override
  int get hashCode => Object.hash(selfie, id, days);
}

/// The typed number of days: null when blank; 'bad' when not 1 to 365.
({int? days, bool bad}) parseDeadlineDays(String s) {
  final t = s.trim();
  if (t.isEmpty) return (days: null, bad: false);
  final n = int.tryParse(t);
  return n == null || n < 1 || n > 365 ? (days: null, bad: true) : (days: n, bad: false);
}

/// The admin's word for an account's checks (dispatch_accounts' `verify`),
/// or null when nothing is left.
String? verifyStatus(Object? verify) {
  final m = verify is Map ? verify : const {};
  final needs = {for (final n in (m['needs'] as List?) ?? const []) '$n'};
  if (m['paused'] == true) return 'Paused: not verified';
  if (needs.isEmpty) return null;
  final todo = [
    if (needs.contains('pin')) 'PIN',
    if (needs.contains('selfie') || needs.contains('recheck')) needs.contains('recheck') ? 'selfie (new phone)' : 'selfie',
    if (needs.contains('id')) 'ID',
  ];
  if (todo.isEmpty) return 'Waiting for approval';
  return 'To do: ${todo.join(', ')}';
}

/// The checks in a line: "Asks for a selfie and ID, within 7 days".
String? asksText(SignInAsks a) {
  if (!a.any) return null;
  final what = [if (a.selfie) 'a selfie', if (a.id) 'ID'].join(' and ');
  return 'Asks for $what${a.days == null ? '' : ', within ${a.days} days'}';
}

// ---- Reading the ID -------------------------------------------------------------------------------

/// What the phone read off an ID photo.
typedef CardRead = ({String? name, String? ic, DateTime? expiry});

const _notNames = {
  'KAD', 'PENGENALAN', 'MALAYSIA', 'MYKAD', 'IDENTITY', 'CARD', 'WARGANEGARA', 'LELAKI', 'PEREMPUAN', 'ISLAM',
  'PASPORT', 'PASSPORT', 'JALAN', 'TAMAN', 'LORONG', 'KAMPUNG', 'NO', 'KUALA', 'LUMPUR', 'SELANGOR', 'JOHOR',
  'PULAU', 'PINANG', 'PERAK', 'KEDAH', 'KELANTAN', 'TERENGGANU', 'PAHANG', 'MELAKA', 'SABAH', 'SARAWAK',
  'NEGERI', 'SEMBILAN', 'PERLIS', 'LABUAN', 'PUTRAJAYA', 'BANDAR', 'MYS', 'TYPE', 'JENIS',
};

final _ic = RegExp(r'\b(\d{6})\s*-?\s*(\d{2})\s*-?\s*(\d{4})\b');

/// A MyKad's IC number as printed ("880202-10-1234"), and the name under it;
/// a passport's name, expiry and (a Malaysian one's) IC from its machine
/// lines. Nulls for what can't be read.
CardRead readCard(String text) {
  final lines = [
    for (final l in text.split(RegExp(r'[\r\n]+'))) l.trim(),
  ].where((l) => l.isNotEmpty).toList();
  final mrz = _readMrz(lines);
  if (mrz != null) return mrz;
  String? ic;
  var icLine = -1;
  for (var i = 0; i < lines.length && ic == null; i++) {
    final m = _ic.firstMatch(lines[i]);
    if (m != null) {
      ic = '${m[1]}-${m[2]}-${m[3]}';
      icLine = i;
    }
  }
  String? name;
  for (var i = icLine + 1; i < lines.length && name == null; i++) {
    final l = lines[i];
    if (!RegExp(r"^[A-Z][A-Z '@./-]+$").hasMatch(l)) continue;
    final words = l.split(RegExp(r'\s+'));
    if (words.length < 2 || words.any((w) => _notNames.contains(w.replaceAll(RegExp(r'[^A-Z]'), '')))) continue;
    name = l.replaceAll(RegExp(r'\s+'), ' ');
  }
  return (name: name, ic: ic, expiry: null);
}

/// The two machine lines of a passport (ICAO 9303, 44 characters each).
CardRead? _readMrz(List<String> lines) {
  final clean = [for (final l in lines) l.replaceAll(' ', '').toUpperCase()];
  for (var i = 0; i + 1 < clean.length; i++) {
    final a = clean[i], b = clean[i + 1];
    if (!a.startsWith('P') || a.length < 40 || b.length < 40 || !RegExp(r'^[A-Z0-9<]+$').hasMatch(b)) continue;
    final names = a.substring(5).split('<<');
    final surname = names.first.replaceAll('<', ' ').trim();
    final given = names.length > 1 ? names[1].replaceAll('<', ' ').trim() : '';
    final name = [given, surname].where((s) => s.isNotEmpty).join(' ');
    final expiry = _mrzDate(b.substring(21, 27), future: true);
    final personal = b.length >= 42 ? b.substring(28, 42).replaceAll('<', '') : '';
    final ic = RegExp(r'^\d{12}$').hasMatch(personal)
        ? '${personal.substring(0, 6)}-${personal.substring(6, 8)}-${personal.substring(8)}'
        : null;
    return (name: name.isEmpty ? null : name, ic: ic, expiry: expiry);
  }
  return null;
}

DateTime? _mrzDate(String yymmdd, {required bool future}) {
  if (!RegExp(r'^\d{6}$').hasMatch(yymmdd)) return null;
  final yy = int.parse(yymmdd.substring(0, 2)), mm = int.parse(yymmdd.substring(2, 4));
  final dd = int.parse(yymmdd.substring(4, 6));
  if (mm < 1 || mm > 12 || dd < 1 || dd > 31) return null;
  // An expiry is this century; a passport lasts ten years at most.
  final year = future ? 2000 + yy : (yy > 50 ? 1900 + yy : 2000 + yy);
  return DateTime(year, mm, dd);
}

/// What was read against the profile, as the server checks it: a name
/// neither of which contains the other, a different IC number.
List<String> cardMismatch(CardRead read, {String? profileName, String? profileIc}) {
  String letters(String? s) => (s ?? '').toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  String digits(String? s) => (s ?? '').toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '');
  final rn = letters(read.name), pn = letters(profileName);
  final ri = digits(read.ic), pi = digits(profileIc);
  return [
    if (rn.isNotEmpty && pn.isNotEmpty && !rn.contains(pn) && !pn.contains(rn)) 'name',
    if (ri.isNotEmpty && pi.isNotEmpty && ri != pi) 'ic',
  ];
}

/// The admin's warning for a check's `mismatch`, or null.
String? mismatchWarning(Object? mismatch) {
  final m = {for (final x in (mismatch as List?) ?? const []) '$x'};
  if (m.isEmpty) return null;
  final what = [if (m.contains('name')) 'name', if (m.contains('ic')) 'IC number'].join(' and ');
  return "The $what read from the card doesn't match the profile.";
}

/// The admin's word for a face match.
String faceMatchText(Object? state, Object? score) {
  final s = (score as num?)?.toDouble();
  return switch (state) {
    'match' => 'Same person likely (${s?.toStringAsFixed(0) ?? '?'}%)',
    'no_match' => 'Faces differ (${s?.toStringAsFixed(0) ?? '0'}%)',
    'no_face' => 'No face found in one of the photos',
    'error' => "Couldn't check",
    _ => 'Not checked',
  };
}

/// The admin's word for a selfie's live check.
String livenessText(Object? liveness, [Object? detail]) => switch (liveness) {
  'passed' => switch (detail) {
    'blink' => 'Live: blinked',
    'turn' => 'Live: turned head',
    _ => 'Live',
  },
  _ => 'Live check: not checked',
};
