// myGiG part C (migration 0331): reassigning a ride or booking to another
// driver (acknowledged by the new driver and the passenger), hotspots, the
// passenger's extras after the trip (receipt, rating, tip, split, e-Invoice,
// book again), the driver's quick trips and regulars, and the admin's
// dashboard. Pure logic: the server decides and charges; this reads what it
// sends and words it.
import 'mygig.dart' show MygigFee, mygigMoney;

double _d(Object? v, [double fallback = 0]) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? fallback;
int _i(Object? v, [int fallback = 0]) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
bool _b(Object? v, [bool fallback = false]) => v is bool ? v : (v == null ? fallback : '$v' == 'true');
String? _s(Object? v) {
  final s = v?.toString().trim();
  return s == null || s.isEmpty || s == 'null' ? null : s;
}

Map<String, dynamic> _m(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};
List<Map<String, dynamic>> _l(Object? v) => [for (final x in (v is List ? v : const [])) if (x is Map) Map<String, dynamic>.from(x)];

// ---- Settings ------------------------------------------------------------------------------------------

/// When drivers may reassign: scheduled bookings only, also before pickup,
/// or also during the trip.
enum MygigReassignWhen { scheduled, before, during }

/// The admin's reassign rule where the driver is (settings.reassign).
class MygigReassignRule {
  const MygigReassignRule(this.raw);
  final Map<String, dynamic> raw;

  factory MygigReassignRule.of(Map<String, dynamic> settings) => MygigReassignRule(_m(settings['reassign']));

  bool get enabled => _b(raw['enabled'], true);
  MygigReassignWhen get when =>
      MygigReassignWhen.values.firstWhere((w) => w.name == raw['when'], orElse: () => MygigReassignWhen.before);
  int get answerMin => _i(raw['answerMin'], 10);
  bool get keepOnNoAnswer => (_s(raw['noAnswer']) ?? 'keep') == 'keep';
  bool get sameOrBigger => _b(raw['sameOrBigger'], true);

  /// Whether a ride in [status] (accepted, arrived, on_trip) may be
  /// reassigned; [booked] for a booking or a booked day's ride.
  bool allows({required String status, bool booked = false}) {
    if (!enabled) return false;
    if (status == 'on_trip') return when == MygigReassignWhen.during;
    if (booked) return true;
    if (status != 'accepted' && status != 'arrived') return false;
    return when != MygigReassignWhen.scheduled;
  }
}

/// The button on the driver's trip screen.
String mygigReassignLabel({required bool onTrip}) => onTrip ? 'Hand over to another driver' : 'Reassign to another driver';

/// What happens when the passenger doesn't answer, in words.
String mygigNoAnswerText({required bool keep, String kept = 'the first driver keeps the ride'}) =>
    keep ? kept : 'the ride is cancelled with no charge';

// ---- Reassign -------------------------------------------------------------------------------------------

/// A driver as the other side sees them: first name, rating, car, plate.
class MygigDriverCard {
  const MygigDriverCard(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id'] ?? ''}';
  String get name => _s(raw['name']) ?? 'Driver';
  double get rating => _d(raw['rating'], 5);
  String? get vehicle => _s(raw['vehicle']);
  String? get plate => _s(raw['plate']);
  String? get colour => _s(raw['colour']);
  String? get type => _s(raw['type']);

  /// "Toyota Innova · VBC 7720".
  String get carText => [vehicle, if (colour != null && !(vehicle ?? '').toLowerCase().contains(colour!.toLowerCase())) colour, plate]
      .whereType<String>()
      .join(' · ');

  /// "★ 4.9", or nothing when there is no rating yet.
  String get ratingText => rating > 0 ? '★ ${rating.toStringAsFixed(1)}' : 'New';
}

/// A nearby driver the first driver may choose, and why not when they can't.
class MygigCandidate extends MygigDriverCard {
  const MygigCandidate(super.raw);

  double get km => _d(raw['km']);
  String? get why => _s(raw['why']);
  bool get eligible => why == null;
}

/// What the first driver chooses from (mygig_reassign_options).
class MygigReassignOptions {
  const MygigReassignOptions(this.raw);
  final Map<String, dynamic> raw;

  List<String> get reasons => [for (final r in (raw['reasons'] is List ? raw['reasons'] as List : const [])) '$r'];
  List<MygigCandidate> get drivers => [for (final d in _l(raw['drivers'])) MygigCandidate(d)];
  bool get during => _b(raw['during']);
  bool get booking => _b(raw['booking']);
  String get way => _s(raw['way']) ?? 'here';
  int get answerMin => _i(raw['answerMin'], 10);
  bool get keepOnNoAnswer => (_s(raw['noAnswer']) ?? 'keep') == 'keep';
  bool get sameOrBigger => _b(raw['sameOrBigger'], true);
  double get nearKm => _d(raw['nearKm'], 10);
}

/// Where a reassign is: the new driver deciding, the passenger confirming,
/// or ended.
enum MygigReassignStage { driver, passenger, done, declined, kept, cancelled, expired, stopped }

MygigReassignStage mygigReassignStageFrom(Object? v) =>
    MygigReassignStage.values.firstWhere((s) => s.name == '$v', orElse: () => MygigReassignStage.expired);

/// A reassign as each side reads it (mygig_reassign_json).
class MygigReassign {
  const MygigReassign(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id'] ?? ''}';
  String? get rideId => _s(raw['rideId']);
  String? get bookingId => _s(raw['bookingId']);
  MygigReassignStage get stage => mygigReassignStageFrom(raw['stage']);
  bool get open => stage == MygigReassignStage.driver || stage == MygigReassignStage.passenger;
  String get reason => _s(raw['reason']) ?? 'Other';
  bool get during => _b(raw['during']);

  /// How the passenger confirms: app, sms, whatsapp or here (the first driver's phone).
  String get way => _s(raw['way']) ?? 'here';
  DateTime? get answerBy => DateTime.tryParse('${raw['answerBy'] ?? ''}')?.toLocal();
  String get kindName => _s(raw['kindName']) ?? 'myGiG ride';
  String get kind => _s(raw['kind']) ?? 'trip';
  String get when => _s(raw['when']) ?? 'now';
  Map<String, dynamic> get trip => _m(raw['trip']);
  String get pickupName => _s(_m(trip['pickup'])['name']) ?? 'the pickup';
  String get dropName => _b(trip['directed']) ? 'As directed' : _s(_m(trip['drop'])['name']) ?? 'the drop-off';
  List<String> get stopNames => [for (final s in _l(trip['stops'])) _s(s['name']) ?? 'Stop'];
  int get pax => _i(raw['pax'], 1);
  int get bags => _m(raw['bags']).values.fold<int>(0, (a, v) => a + _i(v));
  double get total => _d(raw['total']);
  String get pay => _s(raw['pay']) ?? 'cash';
  double get paidMoves => _d(raw['paidMoves']);
  double get moved => _d(raw['moved']);
  double get kept => _d(raw['kept']);
  int? get days => raw['days'] is num ? _i(raw['days']) : null;
  int? get daysLeft => raw['daysLeft'] is num ? _i(raw['daysLeft']) : null;
  bool get keepOnNoAnswer => (_s(raw['noAnswer']) ?? 'keep') == 'keep';
  MygigDriverCard get from => MygigDriverCard(_m(raw['from']));
  MygigDriverCard get to => MygigDriverCard(_m(raw['to']));
  String? get passenger => _s(raw['passenger']);
  bool get registered => _b(raw['registered']);
  MygigFee? get plan => raw['plan'] is Map ? MygigFee.fromJson(raw['plan']) : null;
  List<Map<String, dynamic>> get steps => _l(raw['steps']);

  /// Who is reading: to (the new driver), from (the first), passenger, admin.
  String get me => _s(raw['me']) ?? 'passenger';

  /// "Now", "Now, meet Hafiz on the way to swap cars", or the booking's time.
  String get whenText => switch (when) {
    'now' => 'Now',
    'during' => 'Now: meet ${from.name} on the way to swap cars',
    _ => when,
  };

  /// "1 passenger · 2 bags".
  String get whoText => '$pax passenger${pax == 1 ? '' : 's'} · ${bags == 0 ? 'no luggage' : '$bags bag${bags == 1 ? '' : 's'}'}';

  /// How it is paid, in words.
  String get payName => switch (pay) {
    'wallet' => 'GET.wallet',
    'family' => 'Family (GET.wallet)',
    'business' => 'Business account',
    'link' => 'Pay by link',
    _ => 'Cash',
  };

  /// The money line the new driver reads.
  String get moneyLine => paidMoves > 0
      ? 'Payment: $payName; ${mygigMoney(paidMoves)} already paid moves to you.'
      : 'Payment: $payName.';

  /// The same, as the passenger reads it.
  String passengerMoneyLine() => paidMoves > 0
      ? '$payName. The ${mygigMoney(paidMoves)} you paid moves to ${to.name}. Nothing else changes.'
      : '$payName. Nothing else changes.';
}

/// What the first driver's waiting card says at each stage.
String mygigReassignStatusText(MygigReassign r) => switch (r.stage) {
  MygigReassignStage.driver => 'Sent to ${r.to.name}. They see the trip and the same price, ${mygigMoney(r.total)}, and must '
      'tick that they accept it at the agreed price.',
  MygigReassignStage.passenger => '${r.to.name} accepted. Waiting for the passenger: ${mygigReassignReach(r.way)}. They confirm '
      '${r.to.name}, keep you, or cancel free.',
  MygigReassignStage.done => 'Handed over to ${r.to.name}.${r.kept > 0 ? ' You keep ${mygigMoney(r.kept)} for coming to the pickup.' : ''}',
  MygigReassignStage.declined => '${r.to.name} can’t take it. The ride is still yours.',
  MygigReassignStage.kept => 'The passenger keeps you. Nothing has changed.',
  MygigReassignStage.cancelled => 'Cancelled with no charge to the passenger.',
  MygigReassignStage.expired => 'No answer in time. The ride is still yours.',
  MygigReassignStage.stopped => 'You stopped reassigning. The ride is still yours.',
};

/// Where the passenger is asked.
String mygigReassignReach(String way) => switch (way) {
  'app' => 'in their get.ride app',
  'sms' => 'on the link sent by SMS',
  'whatsapp' => 'on the WhatsApp link you send',
  _ => 'on your phone (show it to them)',
};

/// A step of a reassign's history, in words (Admin and the first driver).
String mygigReassignStepText(Map<String, dynamic> s) {
  final what = (_s(s['what']) ?? '').replaceFirst('reassign_', '');
  return switch (what) {
    'asked' => 'Asked ${_s(s['to']) ?? 'a driver'} (${_s(s['reason']) ?? 'no reason'})',
    'new_driver_accepted' => 'New driver accepted at the agreed price',
    'done' => 'Passenger confirmed the new driver',
    'declined' => 'New driver declined',
    'kept' => _s(s['by']) == 'rule' ? 'No answer: the first driver kept it' : 'Passenger kept the first driver',
    'cancelled' => _s(s['by']) == 'rule' ? 'No answer: cancelled with no charge' : 'Passenger cancelled with no charge',
    'expired' => 'New driver didn’t answer in time',
    'stopped' => 'First driver stopped it',
    'split' => 'Fare split ${_i(s['parts'], 2)} ways',
    _ => what.replaceAll('_', ' '),
  };
}

// ---- Hotspots -------------------------------------------------------------------------------------------

class MygigHotspotArea {
  const MygigHotspotArea(this.raw);
  final Map<String, dynamic> raw;

  String get name => _s(raw['name']) ?? 'Area near you';
  double get lat => _d(raw['lat']);
  double get lng => _d(raw['lng']);
  int get count => _i(raw['count']);
  int get nowCount => _i(raw['nowCount']);
  double get km => _d(raw['km']);
}

class MygigHotspots {
  const MygigHotspots(this.raw);
  final Map<String, dynamic> raw;

  bool get enabled => _b(raw['enabled'], true);
  int get weeks => _i(raw['weeks'], 4);
  int get hourNow => _i(raw['hourNow']);
  List<MygigHotspotArea> get areas => [for (final a in _l(raw['areas'])) MygigHotspotArea(a)];

  /// Rides by hour of the day (0 to 23) on this weekday.
  List<int> get hours {
    final out = List<int>.filled(24, 0);
    for (final h in _l(raw['hours'])) {
      final i = _i(h['hour'], -1);
      if (i >= 0 && i < 24) out[i] = _i(h['count']);
    }
    return out;
  }

  bool get hasHours => hours.any((c) => c > 0);
}

/// "6 pm", "12 am".
String mygigHourLabel(int h) {
  final x = h % 24;
  final n = x % 12 == 0 ? 12 : x % 12;
  return '$n ${x < 12 ? 'am' : 'pm'}';
}

/// The busiest hours, most first (at most [n]), skipping hours with none.
List<int> mygigBestHours(List<int> counts, {int n = 3}) {
  final idx = [for (var i = 0; i < counts.length; i++) if (counts[i] > 0) i]
    ..sort((a, b) => counts[b] != counts[a] ? counts[b].compareTo(counts[a]) : a.compareTo(b));
  return idx.take(n).toList();
}

/// The line under the hours: "Busiest at 6 pm, 8 pm and 4 pm."
String mygigBestHoursText(List<int> counts) {
  final best = mygigBestHours(counts);
  if (best.isEmpty) return 'Not enough myGiG rides here on this day yet.';
  final names = best.map(mygigHourLabel).toList();
  final list = names.length == 1 ? names.first : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  return 'Busiest at $list.';
}

// ---- After the trip -------------------------------------------------------------------------------------

/// What the passenger may do after the trip (mygig_after_view).
class MygigAfter {
  const MygigAfter(this.raw);
  final Map<String, dynamic> raw;

  String get rideId => '${raw['rideId'] ?? ''}';
  String get status => _s(raw['status']) ?? 'completed';
  bool get completed => status == 'completed';
  bool get inApp => _b(raw['inApp']);
  bool get registered => _b(raw['registered']);
  MygigDriverCard get driver => MygigDriverCard(_m(raw['driver']));
  Map<String, dynamic> get receipt => _m(raw['receipt']);
  double get total => _d(receipt['total']);
  double get tolls => _d(receipt['tolls']);
  double get other => _d(receipt['other']);
  double get waiting => _d(receipt['waiting']);
  String get pay => _s(receipt['pay']) ?? 'cash';
  bool get paid => receipt['paymentStatus'] == 'paid';
  double get owed => _d(raw['owed']);
  Map<String, dynamic> get can => _m(raw['can']);
  bool get canRate => _b(can['rate']);
  bool get canTip => _b(can['tip']);
  bool get canSplit => _b(can['split']);
  bool get canEinvoice => _b(can['einvoice']);
  bool get canBookAgain => _b(can['bookAgain']);
  int? get stars => raw['rating'] is Map ? _i(_m(raw['rating'])['stars']) : null;
  Map<String, dynamic>? get tip => raw['tip'] is Map ? _m(raw['tip']) : null;
  Map<String, dynamic>? get tipPart => raw['tipPart'] is Map ? _m(raw['tipPart']) : null;
  List<Map<String, dynamic>> get parts => _l(raw['parts']);
  Map<String, dynamic>? get einvoice => raw['einvoice'] is Map ? _m(raw['einvoice']) : null;
  bool get bookedAgain => raw['bookAgainAt'] != null;
  double get tipMax => _d(raw['tipMax'], 100);
  List<double> get tipPresets =>
      [for (final p in (raw['tipPresets'] is List ? raw['tipPresets'] as List : const [2, 5, 10])) _d(p)];
  int get splitMax => _i(raw['splitMax'], 3).clamp(2, 3);
  MygigAppOffer? get appOffer => raw['appOffer'] is Map ? MygigAppOffer(_m(raw['appOffer'])) : null;
}

/// The app offer for a passenger without the app: the driver's referral code.
class MygigAppOffer {
  const MygigAppOffer(this.raw);
  final Map<String, dynamic> raw;

  String get code => _s(raw['code']) ?? '';
  double get coins => _d(raw['coins']);
  bool get enabled => _b(raw['enabled'], true);
  String get driver => _s(raw['driver']) ?? 'your driver';

  String get title => 'Get the get.ride app';
  String get body => '${enabled && code.isNotEmpty ? 'Sign up with $driver’s code $code'
          '${coins > 0 ? ' and get ${coins.toStringAsFixed(coins == coins.roundToDouble() ? 0 : 2)} GET.coin' : ''}. ' : ''}'
      'Book $driver or any driver, follow your rides and keep your receipts.';
}

/// Each person's share when [owed] is split [n] ways: the others pay an
/// even share (rounded down to the sen), the first person the rest (as the
/// server splits it).
List<double> mygigSplitShares(double owed, int n) {
  if (n < 2) return [owed];
  final each = (owed / n * 100).floorToDouble() / 100;
  final first = ((owed - each * (n - 1)) * 100).roundToDouble() / 100;
  return [first, for (var i = 1; i < n; i++) each];
}

/// Whether a typed tip is one the server takes (above 0, at most [max]).
String? mygigTipProblem(double? amount, double max) {
  if (amount == null || amount <= 0) return 'Enter a tip.';
  if (amount > max) return 'The most tip is ${mygigMoney(max)}.';
  return null;
}

/// The ID types an e-Invoice buyer gives when they have no TIN.
const mygigEinvoiceIdTypes = <(String, String)>[
  ('nric', 'MyKad'),
  ('passport', 'Passport'),
  ('brn', 'Business registration'),
  ('army', 'Army or police ID'),
];

/// Why an e-Invoice request can't be sent yet, or null.
String? mygigEinvoiceProblem({required String name, required String email, String tin = '', String? idType, String idNo = ''}) {
  if (name.trim().isEmpty) return 'Enter the name on the invoice.';
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim())) return 'Enter an email address for the e-Invoice.';
  final t = tin.replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty && (idType == null || idNo.trim().isEmpty)) return 'Enter your TIN, or your ID or passport number.';
  if (t.isNotEmpty && !RegExp(r'^[A-Za-z0-9]{6,20}$').hasMatch(t)) return 'A TIN is 6 to 20 letters and numbers.';
  if (t.isEmpty && idNo.trim().length < 4) return 'Enter the whole ID number.';
  return null;
}

/// What the passenger is told after asking: no e-Invoice connection exists
/// yet, so get.ride's team sends it.
const mygigEinvoiceSavedText =
    'Saved. get.ride sends it to LHDN MyInvois and emails you the e-Invoice once it is validated.';

// ---- Regulars and quick trips ----------------------------------------------------------------------------

/// A drop-off the driver uses often, or a regular's usual one.
class MygigPlace {
  const MygigPlace(this.raw);
  final Map<String, dynamic> raw;

  String get name => _s(raw['name']) ?? 'Drop-off';
  String? get address => _s(raw['address']);
  double get lat => _d(raw['lat']);
  double get lng => _d(raw['lng']);
  int get trips => _i(raw['trips']);
}

/// A number that rode with the driver before (mygig_regular).
class MygigRegular {
  const MygigRegular(this.raw);
  final Map<String, dynamic> raw;

  static MygigRegular? of(Object? v) => v is Map && v['drop'] is Map ? MygigRegular(Map<String, dynamic>.from(v)) : null;

  int get trips => _i(raw['trips']);
  MygigPlace get drop => MygigPlace(_m(raw['drop']));

  String get title => 'Usually goes to ${drop.name}';
  String get subtitle => '$trips myGiG ride${trips == 1 ? '' : 's'} with you';
}

/// Whether two places are the same drop-off (about 100 m apart).
bool mygigSamePlace(double lat1, double lng1, double lat2, double lng2) =>
    (lat1 - lat2).abs() < 0.001 && (lng1 - lng2).abs() < 0.001;

// ---- Admin dashboard ---------------------------------------------------------------------------------------

class MygigDashboard {
  const MygigDashboard(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> get tiles => _m(raw['tiles']);
  int get rides => _i(tiles['rides']);
  int get completed => _i(tiles['completed']);
  int get cancelled => _i(tiles['cancelled']);
  double get takings => _d(tiles['takings']);
  int get noShows => _i(tiles['noShows']);
  int get viaApp => _i(tiles['viaApp']);
  int get viaLink => _i(tiles['viaLink']);
  int get viaHere => _i(tiles['viaHere']);
  int get reassigned => _i(tiles['reassigned']);
  Map<String, dynamic> get flags => _m(raw['flags']);
  List<Map<String, dynamic>> get priceGuard => _l(flags['priceGuard']);
  List<Map<String, dynamic>> get repeatNumbers => _l(flags['repeatNumbers']);
  List<Map<String, dynamic>> get dailyLimit => _l(flags['dailyLimit']);
  List<MygigReassign> get reassigns => [for (final r in _l(raw['reassigns'])) MygigReassign(r)];
  List<Map<String, dynamic>> get einvoices => _l(raw['einvoices']);

  int get accepted => viaApp + viaLink + viaHere;

  /// "46%" of the accepted rides that came [n] way.
  String share(int n) => accepted == 0 ? '0%' : '${(n * 100 / accepted).round()}%';
}

/// The admin's booking filters.
const mygigBookingKinds = <(String, String)>[
  ('', 'All'),
  ('trip', 'Later trips'),
  ('hourly', 'Hourly'),
  ('daily', 'Daily'),
  ('weekly', 'Weekly'),
  ('monthly', 'Monthly'),
];
const mygigBookingStatuses = <(String, String)>[
  ('open', 'Open'),
  ('', 'All'),
  ('completed', 'Completed'),
  ('cancelled', 'Cancelled'),
  ('expired', 'Not paid'),
];
