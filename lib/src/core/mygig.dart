// myGiG (migration 0329): a passenger waves down a driver who isn't TEKSI,
// the driver enters the trip, the server prices it and the passenger
// accepts that fixed price before the trip starts. This is the app's half:
// what the server's JSON means, the words the screens show, and the small
// sums the screens preview (the server decides every charge). Pure.
library;

import 'format.dart';

/// Admin page id for myGiG (settings, access, places), grantable to sub-admins.
const mygigAdminPage = 'admin-mygig';

/// The Family module key (family_register_module('mygig', 'myGiG')).
const familyModuleMygig = 'mygig';

/// Stops a myGiG trip may have (as a booked ride, ride_stops.dart).
const mygigMaxStops = 4;

double _d(Object? v, [double fallback = 0]) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? fallback;
int _i(Object? v, [int fallback = 0]) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
bool _b(Object? v, [bool fallback = false]) => v is bool ? v : (v == null ? fallback : '$v' == 'true');
String? _s(Object? v) {
  final s = v is String ? v.trim() : (v == null ? '' : '$v'.trim());
  return s.isEmpty ? null : s;
}

Map<String, dynamic> _m(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};

/// RM12.30.
String mygigMoney(double v) => 'RM${v.toStringAsFixed(2)}';

/// How get.ride charges a driver for myGiG.
enum MygigFeeMode { none, trip, day, week, month, half, year }

class MygigFee {
  const MygigFee({this.mode = MygigFeeMode.none, this.amount = 0, this.percent = false, this.own = false});

  factory MygigFee.fromJson(Object? raw) {
    final j = _m(raw);
    return MygigFee(
      mode: MygigFeeMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => MygigFeeMode.none),
      amount: _d(j['amount']),
      percent: j['unit'] == '%',
      own: _b(j['own']),
    );
  }

  final MygigFeeMode mode;
  final double amount;

  /// A % of the fare (per trip only), else RM.
  final bool percent;

  /// A charge get.ride set for this driver alone.
  final bool own;

  bool get isPeriod => mode != MygigFeeMode.none && mode != MygigFeeMode.trip;

  Map<String, dynamic> toJson() => {'mode': mode.name, 'amount': amount, 'unit': percent ? '%' : 'RM'};

  MygigFee copyWith({MygigFeeMode? mode, double? amount, bool? percent}) =>
      MygigFee(mode: mode ?? this.mode, amount: amount ?? this.amount, percent: percent ?? this.percent, own: own);

  /// "No charge", "RM1.00 a trip", "5% of each fare", "RM30.00 a month".
  String get text => switch (mode) {
    MygigFeeMode.none => 'No charge',
    MygigFeeMode.trip => percent ? '${_trim(amount)}% of each fare' : '${mygigMoney(amount)} a trip',
    _ => '${mygigMoney(amount)} ${mygigPeriodText(mode)}',
  };

  /// The per-trip fee on a fare of [total].
  double tripFeeOn(double total) {
    if (mode != MygigFeeMode.trip) return 0;
    return percent ? (total * amount / 100 * 100).roundToDouble() / 100 : amount;
  }
}

String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// "a day", "a week", "every 6 months".
String mygigPeriodText(MygigFeeMode m) => switch (m) {
  MygigFeeMode.day => 'a day',
  MygigFeeMode.week => 'a week',
  MygigFeeMode.month => 'a month',
  MygigFeeMode.half => 'every 6 months',
  MygigFeeMode.year => 'a year',
  _ => '',
};

/// "today", "1 week", "6 months": how long a pass lasts.
String mygigPassLength(MygigFeeMode m) => switch (m) {
  MygigFeeMode.day => 'today',
  MygigFeeMode.week => '1 week',
  MygigFeeMode.month => '1 month',
  MygigFeeMode.half => '6 months',
  MygigFeeMode.year => '1 year',
  _ => '',
};

/// The fee modes as the admin picks them.
const mygigFeeModeLabels = <MygigFeeMode, String>{
  MygigFeeMode.none: 'No charge',
  MygigFeeMode.trip: 'Per trip',
  MygigFeeMode.day: 'Per day',
  MygigFeeMode.week: 'Per week',
  MygigFeeMode.month: 'Per month',
  MygigFeeMode.half: 'Every 6 months',
  MygigFeeMode.year: 'Per year',
};

class MygigPass {
  const MygigPass({required this.mode, required this.amount, required this.endsAt});

  static MygigPass? fromJson(Object? raw) {
    final j = _m(raw);
    final ends = DateTime.tryParse('${j['endsAt'] ?? ''}');
    if (ends == null) return null;
    return MygigPass(
      mode: MygigFeeMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => MygigFeeMode.month),
      amount: _d(j['amount']),
      endsAt: ends.toLocal(),
    );
  }

  final MygigFeeMode mode;
  final double amount;
  final DateTime endsAt;
}

/// The line under the myGiG sheet and in myGiG settings.
String mygigPlanLine(MygigFee fee, MygigPass? pass) {
  if (fee.mode == MygigFeeMode.none) return 'No myGiG charge for you.';
  if (fee.mode == MygigFeeMode.trip) return 'myGiG fee: ${fee.text}, from your GET.credit when each ride ends.';
  return pass != null ? 'myGiG pass active until ${formatDayDate(pass.endsAt)}.' : 'myGiG pass needed: ${fee.text}.';
}

/// Thu 30 Oct 2026.
String formatDayDate(DateTime d) {
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${wd[d.weekday - 1]} ${d.day} ${mo[d.month - 1]} ${d.year}';
}

/// The settings that hold where the driver is (mygig_settings_at).
class MygigSettings {
  const MygigSettings(this.raw);
  final Map<String, dynamic> raw;

  static const fallback = MygigSettings({});

  Map<String, dynamic> _o(String k) => _m(raw[k]);

  bool get enabled => _b(raw['enabled'], true);
  bool get qrChoice => _b(raw['qrChoice'], true);
  bool get phoneRequired => _b(raw['phoneRequired']);
  String get nameMode => _s(raw['nameMode']) ?? 'partial';
  String get idMode => _s(raw['idMode']) ?? 'last4';
  bool wayOn(String w) => _b(_o('ways')[w], true);
  int get acceptWaitSec => _i(raw['acceptWaitSec'], 120);
  MygigFareCard get fare => MygigFareCard.fromJson(raw['fare']);
  bool get allowOwnFare => _b(raw['allowOwnFare'], true);
  Map<String, dynamic> get ownFareLimits => _o('ownFareLimits');
  int get maxBags => _i(_o('luggage')['maxBags'], 5);
  double get maxPerBag => _d(_o('luggage')['maxPerBag'], 10);
  bool get approachAllowed => _b(_o('approach')['allowed'], true);
  double get approachMaxPerKm => _d(_o('approach')['maxPerKm'], 5);
  double get approachMaxPerRide => _d(_o('approach')['maxPerRide'], 30);
  bool get busyAllowed => _b(_o('busy')['allowed'], true);
  String get nightFrom => _s(_o('busy')['nightFrom']) ?? '00:00';
  String get nightTo => _s(_o('busy')['nightTo']) ?? '06:00';
  String get peakFrom => _s(_o('busy')['peakFrom']) ?? '17:00';
  String get peakTo => _s(_o('busy')['peakTo']) ?? '20:00';
  double get busyMaxPct => _d(_o('busy')['maxPct'], 50);
  double get busyMaxPeak => _d(_o('busy')['maxPeak'], 10);
  bool get waitingOn => _b(_o('waiting')['on'], true);
  int get waitFreeMin => _i(_o('waiting')['freeMin'], 3);
  double get waitPerMin => _d(_o('waiting')['perMin'], 0.3);
  bool get waitAllowOwn => _b(_o('waiting')['allowOwn'], true);
  double get waitMaxPerMin => _d(_o('waiting')['maxPerMin'], 2);
  bool get cancelOn => _b(_o('cancel')['on'], true);
  int get cancelFreeMin => _i(_o('cancel')['freeMin'], 2);
  double get cancelMax => _d(_o('cancel')['max'], 10);
  bool get noShowOn => _b(_o('noShow')['on'], true);
  double get noShowMax => _d(_o('noShow')['max'], 10);
  int get dailyLimit => _i(raw['dailyLimit'], 10);
  double get guard => _d(raw['guard'], 1.5);
}

class MygigFareCard {
  const MygigFareCard({this.base = 4, this.perKm = 0.95, this.perMin = 0.25, this.min = 8});

  factory MygigFareCard.fromJson(Object? raw) {
    final j = _m(raw);
    return MygigFareCard(
      base: _d(j['base'], 4),
      perKm: _d(j['perKm'], 0.95),
      perMin: _d(j['perMin'], 0.25),
      min: _d(j['min'], 8),
    );
  }

  final double base, perKm, perMin, min;

  Map<String, dynamic> toJson() => {'base': base, 'perKm': perKm, 'perMin': perMin, 'min': min};

  MygigFareCard copyWith({double? base, double? perKm, double? perMin, double? min}) => MygigFareCard(
    base: base ?? this.base, perKm: perKm ?? this.perKm, perMin: perMin ?? this.perMin, min: min ?? this.min);

  /// The fare for [km] and [minutes], at least the minimum.
  double fareFor(double km, double minutes) {
    final f = base + perKm * km + perMin * minutes;
    return _cents(f < min ? min : f);
  }

  /// RM4.00 + RM0.95/km + RM0.25/min, min. RM8.00
  String get text => '${mygigMoney(base)} + ${mygigMoney(perKm)}/km + ${mygigMoney(perMin)}/min, min. ${mygigMoney(min)}';
}

double _cents(double v) => (v * 100).roundToDouble() / 100;

/// The driver's own myGiG settings (mygig_prefs_normalize keeps them within
/// the admin's limits on save).
class MygigPrefs {
  const MygigPrefs(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> _o(String k) => _m(raw[k]);

  bool get ownFare => _b(raw['ownFare']);
  MygigFareCard get fare => MygigFareCard.fromJson(raw['fare']);
  double lug(String size) => _d(_o('lug')[size], size == 'small' ? 0 : size == 'medium' ? 2 : 4);
  int get freeBags => _i(raw['freeBags']);
  bool get showTax => _b(raw['showTax'], true);
  bool get roundUp => _b(raw['roundUp']);
  String get approachMode => _s(_o('approach')['mode']) ?? 'off';
  double get approachPerKm => _d(_o('approach')['perKm'], 1);
  double get approachFixed => _d(_o('approach')['fixed'], 5);
  double get approachFreeKm => _d(_o('approach')['freeKm'], 1);
  bool get busyOn => _b(_o('busy')['on']);
  double get busyNight => _d(_o('busy')['night'], 20);
  double get busyPeak => _d(_o('busy')['peak'], 2);
  double get busyWeekend => _d(_o('busy')['weekend'], 10);
  bool get waitOn => _b(_o('wait')['on'], true);
  bool get waitOwn => _b(_o('wait')['own']);
  int get waitFree => _i(_o('wait')['free'], 5);
  double get waitPerMin => _d(_o('wait')['perMin'], 0.4);
  bool get noShowOn => _b(_o('noShow')['on']);
  double get noShowAmount => _d(_o('noShow')['amount'], 5);
  bool get cancelOn => _b(_o('cancel')['on']);
  double get cancelAmount => _d(_o('cancel')['amount'], 5);

  /// A copy with [path] (dotted, `busy.on`) set to [value].
  MygigPrefs set(String path, Object? value) {
    final out = <String, dynamic>{for (final e in raw.entries) e.key: e.value is Map ? Map<String, dynamic>.from(e.value) : e.value};
    final parts = path.split('.');
    if (parts.length == 1) {
      out[parts.first] = value;
    } else {
      final inner = Map<String, dynamic>.from(_m(out[parts.first]));
      inner[parts[1]] = value;
      out[parts.first] = inner;
    }
    return MygigPrefs(out);
  }

  /// The live example in myGiG settings: [km] and [minutes] with this fare
  /// card, the tax at [taxPct] and the rounding. {fare, tax, rounded, total}.
  ({double fare, double tax, double rounded, double total}) example(MygigSettings s,
      {double km = 6.6, double minutes = 16, double taxPct = 0, bool wholeFare = false}) {
    final card = ownFare && s.allowOwnFare ? fare : s.fare;
    final f = card.fareFor(km, minutes);
    final tax = _cents(f * taxPct / 100);
    final exact = _cents(f + tax);
    final total = roundUp || wholeFare ? (exact - 1e-9).ceilToDouble() : exact;
    return (fare: f, tax: tax, rounded: _cents(total - exact), total: total);
  }
}

/// The driver's state for myGiG (mygig_config).
class MygigConfig {
  const MygigConfig({
    this.ok = false,
    this.code,
    this.message,
    this.online = false,
    this.today = 0,
    this.limit = 0,
    this.fee = const MygigFee(),
    this.pass,
    this.settings = MygigSettings.fallback,
    this.prefs = const MygigPrefs({}),
    this.blocked = const [],
    this.taxName,
    this.taxPct = 0,
    this.wholeFare = false,
  });

  factory MygigConfig.fromJson(Map<String, dynamic> j) {
    final pricing = _m(j['pricing']);
    return MygigConfig(
      ok: _b(j['ok']),
      code: _s(j['code']),
      message: _s(j['message']),
      online: _b(j['online']),
      today: _i(j['today']),
      limit: _i(j['limit']),
      fee: MygigFee.fromJson(j['fee']),
      pass: MygigPass.fromJson(j['pass']),
      settings: MygigSettings(_m(j['settings'])),
      prefs: MygigPrefs(_m(j['prefs'])),
      blocked: [for (final b in (j['blocked'] is List ? j['blocked'] as List : const [])) '$b'],
      taxName: _s(pricing['taxName']),
      taxPct: pricing['taxKind'] == 'fixed' ? 0 : _d(pricing['taxValue']),
      wholeFare: _b(pricing['wholeFare']),
    );
  }

  static const none = MygigConfig(code: 'TYPE');

  final bool ok;
  final String? code;
  final String? message;
  final bool online;
  final int today;
  final int limit;
  final MygigFee fee;
  final MygigPass? pass;
  final MygigSettings settings;
  final MygigPrefs prefs;
  final List<String> blocked;
  final String? taxName;
  final double taxPct;
  final bool wholeFare;

  /// The myGiG button shows: the driver's type allows it here (a refusal
  /// for any other reason still shows it, to explain).
  bool get offered => code != 'TYPE' && code != 'NOT_DRIVER' && code != 'OFF_HERE';

  bool get atLimit => code == 'LIMIT';
  bool get needsPass => code == 'PASS_NEEDED';

  /// Off for this driver (nobody, not selected, blocked): the button explains.
  bool get offForDriver => code == 'NOBODY' || code == 'NOT_SELECTED' || code == 'BLOCKED';

  /// "myGiG today: 3 of 10" (no limit: just the count).
  String get todayText => limit > 0 ? 'myGiG today: $today of $limit' : 'myGiG today: $today';
}

/// What a typed number is (mygig_lookup_phone).
enum MygigLookupState { short, latest, old, none, blocked }

class MygigLookup {
  const MygigLookup({
    this.state = MygigLookupState.short,
    this.name,
    this.idType,
    this.id,
    this.version,
    this.latest,
    this.familyHost,
    this.familyLeft,
    this.businesses = const [],
    this.repeat = 0,
    this.flagged = false,
  });

  factory MygigLookup.fromJson(Map<String, dynamic> j) {
    final fam = _m(j['family']);
    return MygigLookup(
      state: MygigLookupState.values.firstWhere((s) => s.name == j['state'], orElse: () => MygigLookupState.none),
      name: _s(j['name']),
      idType: _s(j['idType']),
      id: _s(j['id']),
      version: _s(j['version']),
      latest: _s(j['latest']),
      familyHost: fam.isEmpty ? null : _s(fam['host']) ?? 'Family host',
      familyLeft: fam.isEmpty ? null : _d(fam['left']),
      businesses: [
        for (final b in (j['businesses'] is List ? j['businesses'] as List : const []))
          if (b is Map) (id: '${b['id']}', name: '${b['name']}'),
      ],
      repeat: _i(j['repeat']),
      flagged: _b(j['flagged']),
    );
  }

  final MygigLookupState state;
  final String? name;
  final String? idType;
  final String? id;
  final String? version;
  final String? latest;
  final String? familyHost;
  final double? familyLeft;
  final List<({String id, String name})> businesses;
  final int repeat;
  final bool flagged;

  bool get registered => state == MygigLookupState.latest || state == MygigLookupState.old;
  bool get needsName => state == MygigLookupState.none;

  /// "MyKad •••• 5678".
  String? get idLine => id == null ? null : '${idType ?? 'ID'} $id';

  /// The line under the phone box.
  String get note => switch (state) {
    MygigLookupState.latest =>
      'Registered · get.ride ${version ?? ''} (latest). No name needed. You can send the fare to their app.'.replaceAll('  ', ' '),
    MygigLookupState.old =>
      'Registered · get.ride ${version ?? 'an older version'}, not the latest${latest == null ? '' : ' ($latest)'}. No name needed. Send the trip link by WhatsApp or SMS.',
    MygigLookupState.none => 'Enter their name. Send the trip link by WhatsApp or SMS.',
    MygigLookupState.blocked => 'Unblock it in myGiG settings to take rides from it again.',
    MygigLookupState.short => 'Checking when the number is complete…',
  };
}

/// The digits of a Malaysian number as typed after +60 (12 345 6789,
/// 012-345 6789): 60123456789; null when there is nothing.
String? mygigPhoneDigits(String typed) {
  var d = typed.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return null;
  if (d.startsWith('0')) return '60${d.substring(1)}';
  if (d.length <= 10 && !d.startsWith('60')) return '60$d';
  return d;
}

/// The number is long enough to look up (9 digits after +60).
bool mygigPhoneComplete(String typed) => (mygigPhoneDigits(typed)?.length ?? 0) >= 11;

/// +60 12 345 6789 from 60123456789.
String mygigPhoneText(String digits) {
  final d = digits.replaceAll(RegExp(r'\D'), '');
  if (!d.startsWith('60') || d.length < 10) return '+$d';
  final n = d.substring(2);
  return '+60 ${n.substring(0, 2)} ${n.substring(2, 5)} ${n.substring(5)}';
}

/// How the passenger accepts the fare.
enum MygigWay { app, whatsapp, sms, here }

extension MygigWayText on MygigWay {
  String get label => switch (this) {
    MygigWay.app => 'Send to their app',
    MygigWay.whatsapp => 'Send a WhatsApp link',
    MygigWay.sms => 'Send an SMS link',
    MygigWay.here => 'Show on this phone',
  };

  String get sub => switch (this) {
    MygigWay.app => 'They accept in get.ride and follow the ride there',
    MygigWay.whatsapp || MygigWay.sms => 'Trip link to accept the fare and follow the ride',
    MygigWay.here => 'Turn your phone to the passenger',
  };
}

MygigWay? mygigWayFrom(Object? v) => MygigWay.values.where((w) => w.name == v).firstOrNull;

/// The ways the admin allows for what the number is (mygig_ways).
List<MygigWay> mygigWays(MygigSettings s, MygigLookupState state, {required bool hasPhone}) => [
  if (state == MygigLookupState.latest && s.wayOn('app')) MygigWay.app,
  if (hasPhone && state != MygigLookupState.blocked && s.wayOn('whatsapp')) MygigWay.whatsapp,
  if (hasPhone && state != MygigLookupState.blocked && s.wayOn('sms')) MygigWay.sms,
  if (state != MygigLookupState.blocked && s.wayOn('here')) MygigWay.here,
];

/// How the passenger pays.
enum MygigPay { cash, wallet, link, family, business }

extension MygigPayText on MygigPay {
  /// Paid in the app: the only ways a fee after the fact can be charged.
  bool get inApp => this == MygigPay.wallet || this == MygigPay.family || this == MygigPay.business;
}

MygigPay mygigPayFrom(Object? v) => MygigPay.values.firstWhere((p) => p.name == v, orElse: () => MygigPay.cash);

/// The ways to pay for what the number is: cash and a link for anyone;
/// GET.wallet, Family and business for a registered passenger who has them.
List<MygigPay> mygigPayOptions(MygigLookup l) => [
  MygigPay.cash,
  if (l.registered) MygigPay.wallet,
  MygigPay.link,
  if (l.registered && l.familyHost != null) MygigPay.family,
  if (l.registered && l.businesses.isNotEmpty) MygigPay.business,
];

String mygigPayName(MygigPay p, {String? familyHost, String? business}) => switch (p) {
  MygigPay.cash => 'Cash',
  MygigPay.wallet => 'GET.wallet',
  MygigPay.link => 'Pay by link',
  MygigPay.family => 'Family · ${familyHost ?? 'host'}’s GET.wallet',
  MygigPay.business => 'Business · ${business ?? 'account'}',
};

/// The line under Payment: whether a cancellation or no-show fee can apply.
/// Only a registered passenger paying in the app can be charged after the
/// fact (owner's rule).
String? mygigFeeNote(MygigLookup l, MygigPay pay, {required double cancelFee, required double noShowFee, required int freeMin}) {
  if (l.state == MygigLookupState.short || l.state == MygigLookupState.blocked) return null;
  if (!l.registered) {
    return 'Not registered: cash or pay by link. No cancellation or no-show fee for this ride: there is no account to charge after the fact.';
  }
  if (!pay.inApp) {
    return 'Paying by ${pay == MygigPay.cash ? 'cash' : 'link'}: no cancellation or no-show fee. Choose GET.wallet'
        '${l.familyHost != null ? ', Family' : ''}${l.businesses.isNotEmpty ? ', business' : ''} to cover them.';
  }
  final cx = cancelFee > 0 ? '${mygigMoney(cancelFee)} cancellation fee' : 'no cancellation fee';
  final ns = noShowFee > 0 ? '${mygigMoney(noShowFee)} no-show fee' : 'no no-show fee';
  return 'If they cancel after accepting (after $freeMin min) or don’t come: $cx, $ns.';
}

/// One line of a price.
typedef MygigLine = ({String label, double amount, bool fee, bool struck, double? was});

/// The server's price for a trip (mygig_price), as the screens show it.
class MygigQuote {
  const MygigQuote(this.raw);
  final Map<String, dynamic> raw;

  static MygigQuote? fromJson(Object? v) => v is Map ? MygigQuote(Map<String, dynamic>.from(v)) : null;

  double get km => _d(raw['km']);
  int get minutes => _i(raw['min']);
  double get fare => _d(raw['fare']);
  double get busy => _d(raw['busy']);
  String? get busyLabel => _s(raw['busyLabel']);
  double get luggage => _d(raw['luggage']);
  double get approach => _d(raw['approach']);
  double get approachFull => _d(raw['approachFull']);
  double get approachKm => _d(raw['approachKm']);
  bool get approachWaived => _b(raw['approachWaived']);
  double get pickupFee => _d(raw['pickupFee']);
  double get dropFee => _d(raw['dropFee']);
  String? get pickupFeeName => _s(raw['pickupFeeName']);
  String? get dropFeeName => _s(raw['dropFeeName']);
  double get tax => _d(raw['tax']);
  String? get taxName => _s(raw['taxName']);
  bool get showTax => _b(raw['showTax'], true);
  double get rounded => _d(raw['rounded']);
  double get total => _d(raw['total']);
  double get appPrice => _d(raw['appPrice']);
  bool get guard => _b(raw['guard']);
  bool get ownFare => _b(raw['ownFare']);
  Map<String, dynamic> get problem => _m(raw['problem']);
  Map<String, dynamic> get terms => _m(raw['terms']);
  double get cancelFee => _d(terms['cancelFee']);
  double get noShowFee => _d(terms['noShowFee']);
  bool get canCharge => _b(terms['canCharge']);

  /// The lines, as the driver set the price to show.
  List<MygigLine> lines({required String what, Map<String, int> bags = const {}}) => [
    (label: 'Fare · $what · ${km.toStringAsFixed(1)} km', amount: fare, fee: false, struck: false, was: null),
    if (busy > 0) (label: 'Busy time · ${busyLabel ?? ''}'.trim(), amount: busy, fee: false, struck: false, was: null),
    if (luggage > 0) (label: 'Luggage · ${mygigBagsText(bags)}', amount: luggage, fee: false, struck: false, was: null),
    if (approachFull > 0)
      (
        label: 'Coming to the pickup · ${approachKm.toStringAsFixed(1)} km${approachWaived ? ' (waived)' : ''}',
        amount: approach,
        fee: false,
        struck: approachWaived,
        was: approachWaived ? approachFull : null,
      ),
    if (pickupFee > 0) (label: '${pickupFeeName ?? 'Place fee'} · pickup', amount: pickupFee, fee: true, struck: false, was: null),
    if (dropFee > 0) (label: '${dropFeeName ?? 'Place fee'} · drop-off', amount: dropFee, fee: true, struck: false, was: null),
    if (showTax && tax > 0) (label: taxName ?? 'Service tax', amount: tax, fee: false, struck: false, was: null),
    if (rounded > 0) (label: 'Rounded up', amount: rounded, fee: false, struck: false, was: null),
  ];

  /// Under the lines when the tax is in one price.
  String? get taxNote => !showTax && tax > 0 ? 'Price includes service tax' : null;
}

/// "1 small, 2 medium bags" / "No luggage".
String mygigBagsText(Map<String, int> bags) {
  final parts = [
    for (final s in const ['small', 'medium', 'large'])
      if ((bags[s] ?? 0) > 0) '${bags[s]} $s',
  ];
  if (parts.isEmpty) return 'No luggage';
  final n = bags.values.fold<int>(0, (a, b) => a + b);
  return '${parts.join(', ')} ${n == 1 ? 'bag' : 'bags'}';
}

/// The luggage sizes.
const mygigBagSizes = <(String, String, String)>[
  ('small', 'Small', 'Backpack, handbag'),
  ('medium', 'Medium', 'Cabin bag up to 56 cm'),
  ('large', 'Large', 'Check-in suitcase, box'),
];

/// A myGiG ride's terms (ride_requests.mygig).
class MygigRide {
  const MygigRide(this.raw);
  final Map<String, dynamic> raw;

  static MygigRide? of(Map<String, dynamic> row) => row['mygig'] is Map ? MygigRide(Map<String, dynamic>.from(row['mygig'])) : null;

  MygigWay get way => mygigWayFrom(raw['way']) ?? MygigWay.here;
  MygigPay get pay => mygigPayFrom(raw['pay']);
  bool get registered => _b(raw['registered']);
  String? get phone => _s(raw['phone']);
  String? get shownName => _s(raw['shownName']);
  MygigQuote get quote => MygigQuote(_m(raw['quote']));
  Map<String, dynamic> get terms => _m(raw['terms']);
  bool get canCharge => _b(terms['canCharge']);
  double get noShowFee => _d(terms['noShowFee']);
  double get cancelFee => _d(terms['cancelFee']);
  int get cancelFreeMin => _i(terms['cancelFreeMin'], 2);
  Map<String, dynamic> get wait => _m(_m(raw['quote'])['wait']);
  bool get waitOn => _b(wait['on'], true);
  int get waitFreeMin => _i(wait['freeMin'], 3);
  double get waitPerMin => _d(wait['perMin'], 0.3);
  int get stopWaitMin => _i(raw['stopWaitMin']);
  DateTime? get stopWaitSince => DateTime.tryParse('${raw['stopWaitSince'] ?? ''}')?.toLocal();
  double get stopWaitCharge => _d(raw['stopWaitCharge']);
  MygigFee get tripFee => MygigFee.fromJson(raw['tripFee']);
  double get tripFeeAmount => _d(raw['tripFeeAmount']);
  String? get payUrl => _s(raw['payUrl']);
  bool get linkUnpaid => _b(raw['linkUnpaid']);

  /// No losses (owner's rule): what a pay-by-link passenger paid by link,
  /// and the cash the driver confirmed.
  double get linkPaid => _d(raw['linkPaid']);
  double get cashPaid => _d(raw['cashPaid']);
  bool get approachCashTaken => raw['approachCashAt'] != null;
  Map<String, dynamic> get pendingFinal => _m(raw['pendingFinal']);
  double get refundDue => _d(raw['refundDue']);

  /// What a pay-by-link passenger owes now (the server's mygig_owed before
  /// the end): the agreed price, or the end total waiting at Complete, less
  /// what was paid.
  double get owed {
    if (pay != MygigPay.link) return 0;
    final target = pendingFinal.isNotEmpty ? _d(pendingFinal['due']) : quote.total;
    final o = target - linkPaid - cashPaid;
    return o > 0.004 ? (o * 100).roundToDouble() / 100 : 0;
  }

  /// A cash passenger pays for coming to the pickup before Start trip.
  double get approachCashDue => pay == MygigPay.cash && !approachCashTaken ? quote.approach : 0;

  /// "Following in their app" and so on, on the driver's trip screen.
  String get following => switch (way) {
    MygigWay.app => 'Following in their app',
    MygigWay.here => phone == null ? 'Not shared' : 'Trip link sent',
    _ => 'Following on the trip link',
  };
}

/// The waiting charge so far at the pickup: [minutes] waited past [free],
/// at [perMin].
({int over, double charge}) mygigWaitCharge(int minutes, int free, double perMin) {
  final over = minutes - free;
  if (over <= 0) return (over: 0, charge: 0);
  return (over: over, charge: _cents(over * perMin));
}

/// Why the server refused (its MYGIG_* code), in words when it gave none.
String mygigRefusalText(String code) => switch (code) {
  'MYGIG_NOBODY' => 'get.ride has switched myGiG off for now. You can still take ride requests as usual.',
  'MYGIG_NOT_SELECTED' => 'myGiG is open to selected drivers only. Contact get.ride support to ask for it.',
  'MYGIG_BLOCKED' => 'get.ride has turned off myGiG for your account. Contact support to find out why.',
  'MYGIG_LIMIT' => 'You reached today’s myGiG limit.',
  'MYGIG_PASS_NEEDED' => 'Get a myGiG pass to take myGiG rides.',
  'MYGIG_OFFLINE' => 'Go online to take a myGiG ride.',
  'MYGIG_ENDED' => 'This request has ended. Send it again.',
  _ => 'myGiG isn’t available right now.',
};

/// The dialog title and text when the myGiG button can't go on.
({String title, String message})? mygigBlockedDialog(MygigConfig c) {
  if (c.offForDriver) return (title: 'myGiG is off for you', message: c.message ?? mygigRefusalText('MYGIG_${c.code}'));
  if (c.atLimit) return (title: 'Daily myGiG limit reached', message: c.message ?? mygigRefusalText('MYGIG_LIMIT'));
  if (c.code == 'ACTIVE_TRIP') return (title: 'You are on a ride', message: c.message ?? 'Finish the ride you are on first.');
  return null;
}

/// The money line for a ride's total.
String mygigTotalText(double v) => formatMoney(v, 'MYR');

// ---- Admin › myGiG settings ------------------------------------------------------------------------

/// The parts of the myGiG settings a region rule switches on or off, each
/// with the top-level keys it sets (mygig_defaults on the server).
const mygigParts = <(String, String, List<String>)>[
  ('access', 'Access and the passenger', ['enabled', 'qrChoice', 'phoneRequired', 'nameMode', 'idMode', 'ways',
      'acceptWaitSec', 'linkExpiryHours']),
  ('fare', 'Fare', ['fare', 'allowOwnFare', 'ownFareLimits']),
  ('luggage', 'Luggage', ['luggage']),
  ('approach', 'Coming to the pickup', ['approach']),
  ('busy', 'Busy times', ['busy']),
  ('waiting', 'Waiting', ['waiting']),
  ('fees', 'Cancellation and no-show', ['cancel', 'noShow']),
  ('limits', 'Limits and the price guard', ['dailyLimit', 'guard', 'maxKm', 'repeatFlag', 'lookupPer10Min']),
];

enum MygigFieldKind { toggle, number, whole, choice, time }

class MygigField {
  const MygigField(this.part, this.path, this.label, this.kind, {this.choices = const [], this.hint});
  final String part;

  /// Dotted, `fare.perKm`.
  final String path;
  final String label;
  final MygigFieldKind kind;
  final List<(String, String)> choices;
  final String? hint;
}

const mygigFields = <MygigField>[
  MygigField('access', 'enabled', 'myGiG on here', MygigFieldKind.toggle),
  MygigField('access', 'qrChoice', 'Offer "Yes, show my booking QR"', MygigFieldKind.toggle),
  MygigField('access', 'phoneRequired', 'Passenger phone required', MygigFieldKind.toggle),
  MygigField('access', 'nameMode', 'A registered passenger\'s name', MygigFieldKind.choice,
      choices: [('full', 'Full'), ('partial', 'Partly hidden'), ('hide', 'Hidden')]),
  MygigField('access', 'idMode', 'Their ID or passport number', MygigFieldKind.choice,
      choices: [('full', 'Full'), ('last4', 'Last 4'), ('hide', 'Hidden')]),
  MygigField('access', 'ways.app', 'Accept in their app', MygigFieldKind.toggle),
  MygigField('access', 'ways.whatsapp', 'Accept on a WhatsApp link', MygigFieldKind.toggle),
  MygigField('access', 'ways.sms', 'Accept on an SMS link', MygigFieldKind.toggle),
  MygigField('access', 'ways.here', 'Accept on the driver\'s phone', MygigFieldKind.toggle),
  MygigField('access', 'acceptWaitSec', 'Wait for an answer (seconds)', MygigFieldKind.whole,
      hint: 'Unanswered, the request ends and nothing is saved'),
  MygigField('access', 'linkExpiryHours', 'Trip link works after the trip (hours)', MygigFieldKind.whole),
  MygigField('fare', 'fare.base', 'Base fare (RM)', MygigFieldKind.number),
  MygigField('fare', 'fare.perKm', 'Per km (RM)', MygigFieldKind.number),
  MygigField('fare', 'fare.perMin', 'Per minute (RM)', MygigFieldKind.number),
  MygigField('fare', 'fare.min', 'Minimum fare (RM)', MygigFieldKind.number),
  MygigField('fare', 'allowOwnFare', 'Drivers may set their own fare', MygigFieldKind.toggle),
  MygigField('fare', 'ownFareLimits.baseMax', 'Own fare: highest base (RM)', MygigFieldKind.number),
  MygigField('fare', 'ownFareLimits.perKmMin', 'Own fare: lowest per km (RM)', MygigFieldKind.number),
  MygigField('fare', 'ownFareLimits.perKmMax', 'Own fare: highest per km (RM)', MygigFieldKind.number),
  MygigField('fare', 'ownFareLimits.perMinMax', 'Own fare: highest per minute (RM)', MygigFieldKind.number),
  MygigField('fare', 'ownFareLimits.minMax', 'Own fare: highest minimum (RM)', MygigFieldKind.number),
  MygigField('luggage', 'luggage.maxBags', 'Most bags', MygigFieldKind.whole),
  MygigField('luggage', 'luggage.maxPerBag', 'Most a driver charges a bag (RM)', MygigFieldKind.number),
  MygigField('approach', 'approach.allowed', 'Drivers may charge for coming to the pickup', MygigFieldKind.toggle),
  MygigField('approach', 'approach.maxPerKm', 'Most per km (RM)', MygigFieldKind.number),
  MygigField('approach', 'approach.maxPerRide', 'Most per ride (RM)', MygigFieldKind.number),
  MygigField('busy', 'busy.allowed', 'Drivers may add a busy-time extra', MygigFieldKind.toggle),
  MygigField('busy', 'busy.nightFrom', 'Night from', MygigFieldKind.time),
  MygigField('busy', 'busy.nightTo', 'Night until', MygigFieldKind.time),
  MygigField('busy', 'busy.peakFrom', 'Peak from', MygigFieldKind.time),
  MygigField('busy', 'busy.peakTo', 'Peak until', MygigFieldKind.time),
  MygigField('busy', 'busy.maxPct', 'Most night or weekend extra (%)', MygigFieldKind.number),
  MygigField('busy', 'busy.maxPeak', 'Most peak extra (RM)', MygigFieldKind.number),
  MygigField('waiting', 'waiting.on', 'Waiting charge', MygigFieldKind.toggle),
  MygigField('waiting', 'waiting.freeMin', 'Free minutes', MygigFieldKind.whole),
  MygigField('waiting', 'waiting.perMin', 'Then per minute (RM)', MygigFieldKind.number),
  MygigField('waiting', 'waiting.allowOwn', 'Drivers may set their own waiting charge', MygigFieldKind.toggle),
  MygigField('waiting', 'waiting.maxPerMin', 'Own charge: most per minute (RM)', MygigFieldKind.number),
  MygigField('waiting', 'waiting.cap', 'Most waiting charge a ride (RM)', MygigFieldKind.number),
  MygigField('fees', 'cancel.on', 'Cancellation fee after accepting', MygigFieldKind.toggle,
      hint: 'Registered passengers paying in the app only'),
  MygigField('fees', 'cancel.freeMin', 'Free to cancel for (min)', MygigFieldKind.whole),
  MygigField('fees', 'cancel.max', 'Most cancellation fee (RM)', MygigFieldKind.number),
  MygigField('fees', 'noShow.on', 'No-show fee', MygigFieldKind.toggle, hint: 'Registered passengers paying in the app only'),
  MygigField('fees', 'noShow.max', 'Most no-show fee (RM)', MygigFieldKind.number),
  MygigField('limits', 'dailyLimit', 'Daily limit per driver (0: none)', MygigFieldKind.whole),
  MygigField('limits', 'guard', 'Price guard: times the app price (0: off)', MygigFieldKind.number),
  MygigField('limits', 'maxKm', 'Longest myGiG trip (km, 0: no limit)', MygigFieldKind.number),
  MygigField('limits', 'repeatFlag', 'Flag a number after this many rides a week', MygigFieldKind.whole),
  MygigField('limits', 'lookupPer10Min', 'Phone checks per driver in 10 minutes', MygigFieldKind.whole),
];

/// The value at a dotted [path] of [m].
Object? mygigGet(Map<String, dynamic> m, String path) {
  Object? v = m;
  for (final k in path.split('.')) {
    v = v is Map ? v[k] : null;
  }
  return v;
}

/// A copy of [m] with [path] set to [value].
Map<String, dynamic> mygigPut(Map<String, dynamic> m, String path, Object? value) {
  final parts = path.split('.');
  final out = Map<String, dynamic>.from(m);
  if (parts.length == 1) {
    out[parts.first] = value;
    return out;
  }
  final inner = out[parts.first] is Map ? Map<String, dynamic>.from(out[parts.first] as Map) : <String, dynamic>{};
  out[parts.first] = mygigPut(inner, parts.skip(1).join('.'), value);
  return out;
}

/// Deep merge as the server's mygig_merge: objects key by key, null keeps.
Map<String, dynamic> mygigMerge(Map<String, dynamic> a, Map<String, dynamic> b) {
  final out = Map<String, dynamic>.from(a);
  for (final e in b.entries) {
    if (e.value == null) continue;
    final was = out[e.key];
    out[e.key] = was is Map && e.value is Map
        ? mygigMerge(Map<String, dynamic>.from(was), Map<String, dynamic>.from(e.value as Map))
        : e.value;
  }
  return out;
}

/// Whether a region rule's [settings] set [part].
bool mygigPartSet(Map<String, dynamic> settings, String part) =>
    mygigParts.firstWhere((p) => p.$1 == part).$3.any(settings.containsKey);

/// [settings] with [part] set from [from] (on) or left to the place above (off).
Map<String, dynamic> mygigSetPart(Map<String, dynamic> settings, String part, {required bool on, required Map<String, dynamic> from}) {
  final out = Map<String, dynamic>.from(settings);
  for (final k in mygigParts.firstWhere((p) => p.$1 == part).$3) {
    if (on) {
      out[k] = from[k];
    } else {
      out.remove(k);
    }
  }
  return out;
}

/// "23:00" is a time of day.
bool mygigTimeOk(Object? v) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch('$v');
  return m != null && int.parse(m.group(1)!) < 24 && int.parse(m.group(2)!) < 60;
}
