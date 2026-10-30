// myGiG Delivery (migration 0332): someone stops a driver and asks for
// something to be delivered. The admin's delivery settings (by region), the
// driver's own Delivery settings, the server's price and deposit, and the
// delivery as each side reads it (driver, sender, recipient), with the
// checks the screens show before the server is asked: what can be sent,
// who pays, what is due at the door, the proof, and every line a return
// needs before it starts. The server decides; these only explain.
import 'mygig.dart';

double _d(Object? v, [double fallback = 0]) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? fallback;
int _i(Object? v, [int fallback = 0]) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
bool _b(Object? v, [bool fallback = false]) => v is bool ? v : (v == null ? fallback : '$v' == 'true');
String? _s(Object? v) => v == null || '$v'.isEmpty ? null : '$v';
Map<String, dynamic> _m(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};
List<Object?> _l(Object? v) => v is List ? v : const [];
DateTime? _t(Object? v) => DateTime.tryParse('${v ?? ''}')?.toLocal();

/// The sizes, smallest first, with what fits each (the admin's hints).
const mygigDeliverySizes = <(String, String, String)>[
  ('small', 'Small', 'Envelope or small box, up to 5 kg'),
  ('medium', 'Medium', 'Shoebox, up to 10 kg'),
  ('large', 'Large', 'Carton, up to 30 kg'),
  ('bulky', 'Bulky', 'Furniture, appliances, up to 300 kg'),
];

String mygigDeliverySizeName(String k) => mygigDeliverySizes.where((s) => s.$1 == k).firstOrNull?.$2 ?? 'Small';

/// A driver's vehicle for deliveries.
const mygigDeliveryVehicles = <(String, String)>[('bike', 'Motorbike'), ('car', 'Car'), ('van', 'Van')];

String mygigDeliveryVehicleName(String k) => mygigDeliveryVehicles.where((v) => v.$1 == k).firstOrNull?.$2 ?? 'Car';

/// The admin's delivery part of the myGiG settings (mygig_defaults on the server).
class MygigDeliverySettings {
  const MygigDeliverySettings(this.raw);
  final Map<String, dynamic> raw;

  bool get enabled => _b(raw['enabled'], true);
  bool vehicleOn(String v) => _b(_m(_m(raw['vehicles'])[v])['on']);
  double maxKg(String v) => _d(_m(_m(raw['vehicles'])[v])['maxKg'], 30);
  bool sizeFits(String size, String vehicle) => _b(_m(_m(raw['sizes'])[size])[vehicle]);
  List<String> get itemTypes => [for (final t in _l(raw['itemTypes'])) '$t'];
  List<String> get prohibited => [for (final t in _l(raw['prohibited'])) '$t'];
  int get maxDrops => _i(raw['maxDrops'], 4).clamp(1, 5);
  bool get senderPhoneRequired => '${raw['senderPhone'] ?? 'required'}' == 'required';
  double get maxValue => _d(raw['maxValue'], 2000);
  double get coverFee => _d(_m(raw['protection'])['fee'], 0.5);
  double get coverFree => _d(_m(raw['protection'])['free'], 300);
  double get coverPct => _d(_m(raw['protection'])['pct'], 1);
  double get guaranteeFee => _d(raw['guaranteeFee'], 0.5);
  double get waitFreeMin => _d(_m(raw['waiting'])['freeMin'], 5);
  double get waitPerMin => _d(_m(raw['waiting'])['perMin'], 0.3);
  double get allowanceMin => _d(_m(raw['waiting'])['allowanceMin'], 15);
  double get returnPctMax => _d(raw['returnPctMax'], 100);
  double get ackMin => _d(raw['ackMin'], 10);
  bool get recipientPays => _b(raw['recipientPays'], true);
  bool get codOn => _b(_m(raw['cod'])['on'], true);
  double get codFeePct => _d(_m(raw['cod'])['feePct'], 1.5);
  double get codMax => _d(_m(raw['cod'])['max'], 1000);
  String get proof => '${raw['proof'] ?? 'code'}';
  int get pickupPhotos => _i(raw['pickupPhotos'], 1);
  bool get allowOwnRates => _b(raw['allowOwnRates'], true);
  bool get allowOwnWait => _b(raw['allowOwnWait'], true);
  Map<String, dynamic> get limits => _m(raw['ownLimits']);

  /// The sizes [vehicle] may carry, by the admin.
  List<String> sizesFor(String vehicle) => [for (final s in mygigDeliverySizes) if (sizeFits(s.$1, vehicle)) s.$1];

  /// "needs a car or van".
  String needsText(String size) {
    final who = [for (final v in mygigDeliveryVehicles) if (sizeFits(size, v.$1)) v.$2.toLowerCase()];
    return who.isEmpty ? 'not offered' : 'needs a ${who.join(' or ')}';
  }
}

/// A rate card: get.ride's for the vehicle, or the driver's own.
class MygigDeliveryCard {
  const MygigDeliveryCard(this.raw);
  final Map<String, dynamic> raw;

  double get base => _d(raw['base']);
  double get perKm => _d(raw['perKm']);
  double get min => _d(raw['min']);
  double extra(String size) => size == 'small' ? 0 : _d(raw[size]);
  double get freeKg => _d(raw['freeKg']);
  double get perKg => _d(raw['perKg']);
  double get fragile => _d(raw['fragile']);
  double get extraDrop => _d(raw['extraDrop']);
  bool get own => _b(raw['own']);

  /// "RM6.00 + RM1.00/km, min. RM9.00".
  String get line => '${mygigMoney(base)} + ${mygigMoney(perKm)}/km, min. ${mygigMoney(min)}';
}

/// The driver's Delivery settings (mygig_delivery_prefs_normalize).
class MygigDeliveryPrefs {
  const MygigDeliveryPrefs(this.raw);
  final Map<String, dynamic> raw;

  bool get own => _b(raw['own']);
  MygigDeliveryCard get rates => MygigDeliveryCard(_m(raw['rates']));
  bool get waitOwn => _b(raw['waitOwn']);
  int get waitFree => _i(raw['waitFree'], 5);
  double get waitPerMin => _d(raw['waitPerMin'], 0.3);
  int get returnPct => _i(raw['returnPct'], 50);
  int get maxKm => _i(raw['maxKm'], 25);
  List<String> get offTypes => [for (final t in _l(raw['offTypes'])) '$t'];
  bool get takeCod => _b(raw['takeCod'], true);
  bool get takeRecipientPays => _b(raw['takeRecipientPays'], true);
  bool get showTax => _b(raw['showTax'], true);
  bool get roundUp => _b(raw['roundUp']);

  MygigDeliveryPrefs copyWith(Map<String, dynamic> changes) => MygigDeliveryPrefs({...raw, ...changes});
  MygigDeliveryPrefs withRate(String key, double v) => MygigDeliveryPrefs({...raw, 'rates': {..._m(raw['rates']), key: v}});
}

/// What the driver's app needs (mygig_delivery_config).
class MygigDeliveryConfig {
  const MygigDeliveryConfig(this.raw);
  final Map<String, dynamic> raw;

  bool get ok => _b(raw['ok']);
  String? get code => _s(raw['code']);
  String? get message => _s(raw['message']);
  bool get offered => _b(raw['offered']);
  String get vehicle => '${raw['vehicle'] ?? 'car'}';
  String get vehicleName => '${raw['vehicleName'] ?? mygigDeliveryVehicleName(vehicle)}';
  MygigDeliverySettings get settings => MygigDeliverySettings(_m(raw['settings']));
  MygigDeliveryPrefs get prefs => MygigDeliveryPrefs(_m(raw['prefs']));
  MygigDeliveryCard get card => MygigDeliveryCard(_m(raw['card']));
  MygigDeliveryCard get gcard => MygigDeliveryCard(_m(raw['gcard']));
  double get waitFree => _d(_m(raw['wait'])['freeMin'], 5);
  double get waitPerMin => _d(_m(raw['wait'])['perMin'], 0.3);

  /// "A delivery" shows on the myGiG sheet.
  bool get shows => ok && offered;
}

/// The deposit a sender without in-app payment pays by link when accepting.
class MygigDeliveryDeposit {
  const MygigDeliveryDeposit(this.raw);
  final Map<String, dynamic> raw;

  double get ret => _d(raw['ret']);
  double get wait => _d(raw['wait']);
  double get fare => _d(raw['fare']);
  double get fee => _d(raw['fee']);
  double get total => _d(raw['total']);
  double get waitMin => _d(raw['waitMin'], 15);
}

/// The server's price (mygig_delivery_price).
class MygigDeliveryQuote {
  const MygigDeliveryQuote(this.raw);
  final Map<String, dynamic> raw;

  double get km => _d(raw['km']);
  double get fare => _d(raw['fare']);
  double get size => _d(raw['size']);
  double get kg => _d(raw['kg']);
  double get fragile => _d(raw['fragile']);
  double get extraDrops => _d(raw['extraDrops']);
  int get drops => _i(raw['drops'], 1);
  double get cover => _d(raw['cover']);
  double get coverFree => _d(raw['coverFree'], 300);
  double get coverPct => _d(raw['coverPct'], 1);
  double get coverUpTo => _d(raw['coverUpTo']);
  double get tax => _d(raw['tax']);
  String get taxName => '${raw['taxName'] ?? 'Service tax'}';
  bool get showTax => _b(raw['showTax'], true);
  double get rounded => _d(raw['rounded']);
  double get total => _d(raw['total']);
  bool get own => _b(raw['own']);
  int get retPct => _i(raw['retPct'], 50);
  double get maxFail => _d(raw['maxFail']);
  double get maxReturn => _d(raw['maxReturn']);
  double get waitFree => _d(_m(raw['wait'])['freeMin'], 5);
  double get waitPerMin => _d(_m(raw['wait'])['perMin'], 0.3);
  double get codFee => _d(raw['codFee']);
  double get cod => _d(raw['cod']);
  String get vehicleName => '${raw['vehicleName'] ?? 'Car'}';
  MygigDeliveryDeposit? get deposit => raw['deposit'] is Map ? MygigDeliveryDeposit(_m(raw['deposit'])) : null;
  Map<String, dynamic> get problem => _m(raw['problem']);

  /// The price's lines, as the driver and the sender see them.
  List<(String, double)> lines({required String sizeKey, required double weight, required double freeKg}) => [
    ('Delivery · $vehicleName · ${km.toStringAsFixed(1)} km${drops > 1 ? ' · $drops drop-offs' : ''}', fare),
    if (size > 0) ('Size · ${mygigDeliverySizeName(sizeKey)}', size),
    if (kg > 0) ('Weight over ${_trim(freeKg)} kg · ${_trim(weight)} kg', kg),
    if (fragile > 0) ('Fragile handling', fragile),
    if (extraDrops > 0) ('Extra drop-offs · ${drops - 1}', extraDrops),
    ('Cover${coverUpTo > coverFree ? ' · ${_trim(coverPct)}% above ${mygigMoney(coverFree)}' : ''}', cover),
    if (showTax && tax > 0) (taxName, tax),
    if (rounded > 0) ('Rounded up', rounded),
  ];
}

String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

// ---- Before sending ---------------------------------------------------------------------------------

/// Why the parcel step can't go on, or null (the server checks the same).
String? mygigParcelProblem({
  required MygigDeliverySettings s,
  required String vehicle,
  required String vehicleName,
  required String? type,
  required String size,
  required double kg,
  required double value,
  required int photos,
  required bool noProhibited,
  List<String> offTypes = const [],
}) {
  if (type == null || !s.itemTypes.contains(type)) return 'Choose what is being sent.';
  if (offTypes.contains(type)) return 'You don’t take ${type.toLowerCase()} (Delivery settings).';
  if (!s.sizeFits(size, vehicle)) return 'Your ${vehicleName.toLowerCase()} can’t carry this size.';
  if (kg <= 0 || kg > s.maxKg(vehicle)) {
    return 'Too heavy for your ${vehicleName.toLowerCase()} (up to ${_trim(s.maxKg(vehicle))} kg).';
  }
  if (value > s.maxValue) return 'The declared value is over the ${mygigMoney(s.maxValue)} limit.';
  if (photos == 0) return 'Take a photo of the item.';
  if (!noProhibited) return 'The sender must confirm there are no prohibited items.';
  return null;
}

/// A drop-off as the route step holds it.
class MygigDropDraft {
  const MygigDropDraft({this.placeSet = false, this.phone = '', this.lookup = const MygigLookup(), this.name = ''});
  final bool placeSet;
  final String phone;
  final MygigLookup lookup;
  final String name;
}

/// Why the route step can't go on, or null.
String? mygigRouteProblem({
  required bool senderPhoneRequired,
  required String senderPhone,
  required MygigLookup sender,
  required String senderName,
  required List<MygigDropDraft> drops,
}) {
  final typed = senderPhone.trim().isNotEmpty;
  if (senderPhoneRequired && !mygigPhoneComplete(senderPhone)) return 'Enter the sender’s phone.';
  if (typed && !mygigPhoneComplete(senderPhone)) return 'Finish the sender’s phone number, or clear it.';
  if (sender.state == MygigLookupState.blocked) return 'You blocked this number.';
  if ((sender.needsName || !typed) && senderName.trim().isEmpty) {
    return typed ? 'Enter the sender’s name: this number isn’t registered.' : 'Enter the sender’s name.';
  }
  for (final (i, d) in drops.indexed) {
    final n = drops.length > 1 ? ' ${i + 1}' : '';
    if (!d.placeSet) return 'Choose drop-off$n.';
    if (!mygigPhoneComplete(d.phone)) return 'Enter the recipient’s phone for drop-off$n.';
    if (d.lookup.state == MygigLookupState.blocked) return 'You blocked the number for drop-off$n.';
    if (d.lookup.needsName && d.name.trim().isEmpty) return 'Enter the recipient’s name for drop-off$n.';
  }
  return null;
}

/// The sender pays in the app: registered, GET.wallet, Family or business.
bool mygigDeliveryInApp({required bool registered, required MygigPay pay}) =>
    registered && (pay == MygigPay.wallet || pay == MygigPay.family || pay == MygigPay.business);

/// How the sender may pay: cash and by link always; GET.wallet, Family and
/// business when registered.
List<MygigPay> mygigDeliveryPayOptions(MygigLookup l) => [
  MygigPay.cash,
  if (l.registered) MygigPay.wallet,
  MygigPay.link,
  if (l.familyHost != null) MygigPay.family,
  if (l.businesses.isNotEmpty) MygigPay.business,
];

/// May the recipient pay; else why not.
String? mygigRecipientPaysNo({required MygigDeliverySettings s, required MygigDeliveryPrefs p, required MygigPay pay}) {
  if (!p.takeRecipientPays) return 'You don’t take recipient pays (Delivery settings).';
  if (!s.recipientPays) return 'get.ride has switched off recipient pays.';
  if (pay == MygigPay.business) return 'A business account pays the delivery itself.';
  return null;
}

/// May the delivery have cash on delivery; else why not.
String? mygigCodNo({required MygigDeliverySettings s, required MygigDeliveryPrefs p, required bool senderRegistered}) {
  if (!p.takeCod) return 'You don’t take cash on delivery (Delivery settings).';
  if (!s.codOn) return 'get.ride has switched off cash on delivery here.';
  if (!senderRegistered) {
    return 'Cash on delivery needs a registered sender: the money goes to their GET.wallet. '
        'Nothing can be paid out to someone without the app.';
  }
  return null;
}

/// Why the price step can't send yet, or null.
String? mygigDeliverySendProblem({
  required MygigDeliveryQuote? quote,
  required bool codOn,
  required double codAmount,
  required double codMax,
  required MygigWay? way,
  required bool inApp,
  required bool hasPhone,
}) {
  final problem = quote?.problem['message'];
  if (problem is String && problem.isNotEmpty) return problem;
  if (quote == null) return 'Working out the price…';
  if (codOn && codAmount <= 0) return 'Enter the amount to collect, or switch cash on delivery off.';
  if (codOn && codAmount > codMax) return 'Cash on delivery is up to ${mygigMoney(codMax)}.';
  if (!inApp && !hasPhone) return 'A sender without in-app payment pays a refundable deposit by link: enter their phone.';
  if (way == null) return 'Choose how the sender accepts.';
  return null;
}

/// The deposit, in words (the price step and the sender's page).
String mygigDepositText(MygigDeliveryDeposit d) =>
    'No app account to charge later, so a refundable deposit of ${mygigMoney(d.total)} is paid by link when the sender '
    'accepts: return up to ${mygigMoney(d.ret)}, waiting up to ${_trim(d.waitMin)} min ${mygigMoney(d.wait)}'
    '${d.fare > 0 ? ', the delivery fare ${mygigMoney(d.fare)} in case the recipient doesn’t pay' : ''}, and a '
    '${mygigMoney(d.fee)} guarantee fee that isn’t refunded. The rest is refunded once it isn’t needed.';

/// "If it comes back", as the sender reads it when they accept.
String mygigComesBackText({
  required MygigDeliveryQuote q,
  required bool inApp,
  required String payName,
  required bool recipientPaysAsked,
  required int drops,
}) {
  final dep = q.deposit;
  final failed = 'Nobody there or refused: you pay ${mygigMoney(q.maxFail)} at most'
      '${dep != null ? ', from the ${mygigMoney(dep.total)} deposit paid now and refunded when it’s delivered' : inApp ? ', from $payName only if it happens' : ''}.';
  final asked = ' If ${drops > 1 ? 'a recipient asks' : 'the recipient asks'} to send it back: '
      '${recipientPaysAsked ? 'they pay' : 'you pay'} the return fare first. You’ll be asked to acknowledge any return.';
  return failed + asked;
}

/// The sender's Accept button.
String mygigDeliveryAcceptLabel({required double payNow, required double total}) =>
    payNow > 0 ? 'Accept and pay ${mygigMoney(payNow)}' : 'Accept · ${mygigMoney(total)}';

/// What the sender pays by link when accepting: the fare (paying by link) and the deposit.
double mygigDeliveryPayNow({required MygigDeliveryQuote q, required bool senderPays, required MygigPay pay}) =>
    (senderPays && pay == MygigPay.link ? q.total : 0) + (q.deposit?.total ?? 0);

// ---- The delivery -----------------------------------------------------------------------------------

/// A drop-off as the delivery reads it.
class MygigDeliveryDrop {
  const MygigDeliveryDrop(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id'] ?? ''}';
  int get n => _i(raw['n'], 1);
  String get name => '${raw['name'] ?? 'Recipient'}';
  String get placeName => '${_m(raw['place'])['name'] ?? 'Drop-off'}';
  double? get lat => _m(raw['place'])['lat'] is num ? _d(_m(raw['place'])['lat']) : null;
  double? get lng => _m(raw['place'])['lng'] is num ? _d(_m(raw['place'])['lng']) : null;
  String get status => '${raw['status'] ?? 'waiting'}';
  String? get phone => _s(raw['phone']);
  String? get code => _s(raw['code']);
  double get dueFare => _d(_m(raw['due'])['fare']);
  double get dueCod => _d(_m(raw['due'])['cod']);
  double get dueWait => _d(_m(raw['due'])['wait']);
  double get due => _d(_m(raw['due'])['total']);
  String? get paidHow => _s(raw['paidHow']);
  int get waitMin => _i(_m(raw['wait'])['min']);
  int get waitOver => _i(_m(raw['wait'])['over']);
  double get waitCharge => _d(_m(raw['wait'])['charge']);
  Map<String, dynamic> get proof => _m(raw['proof']);
  DateTime? get deliveredAt => _t(raw['deliveredAt']);
  double get returnFare => _d(raw['returnFare']);
  double get failFee => _d(raw['failFee']);
  bool get ended => status == 'delivered' || status == 'returned';
  bool get delivered => status == 'delivered';

  /// "Delivery code given" / "Handed to Guard Ali, with a photo".
  String get proofText {
    final p = proof;
    if (p.isEmpty) return '';
    return p['kind'] == 'code' ? 'Delivery code given' : 'Handed to ${p['name'] ?? 'the recipient'}, with a photo';
  }
}

/// The lines a return needs before it starts.
class MygigReturnChecks {
  const MygigReturnChecks(this.raw);
  final Map<String, dynamic> raw;

  bool get pay => _b(raw['pay']);
  bool get payerAck => _b(raw['payerAck']);
  bool get photo => _b(raw['photo']);
  bool get sender => _b(raw['sender']);
  bool get all => pay && payerAck && photo && sender;
}

/// A return as the delivery reads it.
class MygigDeliveryReturn {
  const MygigDeliveryReturn(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id'] ?? ''}';
  int get n => _i(raw['n'], 1);
  bool get failed => raw['kind'] == 'failed';
  String get reason => '${raw['reason'] ?? ''}';
  String get payer => '${raw['payer'] ?? 'sender'}';
  String get method => '${raw['method'] ?? 'link'}';
  double get amount => _d(raw['amount']);
  String get status => '${raw['status'] ?? 'waiting'}';
  bool get driverCash => raw['driverCashAt'] != null;
  bool get recipientCashAck => raw['recipientCashAckAt'] != null;
  bool get senderAck => raw['senderAckAt'] != null;
  bool get paid => raw['paidAt'] != null;
  String? get payRequest => _s(raw['payRequest']);
  DateTime? get answerBy => _t(raw['answerBy']);
  MygigReturnChecks get checks => MygigReturnChecks(_m(raw['checks']));
  bool get support => status == 'support';
  bool get started => status == 'started';
  bool get done => status == 'done';
}

/// One line on the driver's return screen: done, title, what it is.
typedef MygigReturnLine = ({bool ok, String title, String sub});

/// The lines before a return starts ([sender], [recipient]: the names shown;
/// [payName]: how an in-app sender pays).
List<MygigReturnLine> mygigReturnLines(MygigDeliveryReturn r,
    {required String sender, required String recipient, required String payName, required bool senderInApp}) {
  final c = r.checks;
  final pay = r.failed
      ? (ok: true, title: 'Return fee ${mygigMoney(r.amount)}',
         sub: r.method == 'app' ? 'Charged to $payName when it’s back' : 'From the sender’s return deposit')
      : r.payer == 'sender'
      ? (ok: c.pay, title: '$sender pays ${mygigMoney(r.amount)}',
         sub: c.pay ? 'Paid and acknowledged' : 'Waiting for them to accept and pay')
      : r.method == 'link'
      ? (ok: c.pay, title: '$recipient pays ${mygigMoney(r.amount)} by link', sub: c.pay ? 'Paid on the link' : 'Waiting for the payment')
      : (ok: c.pay, title: '$recipient pays ${mygigMoney(r.amount)} in cash',
         sub: '${r.driverCash ? 'You confirmed it' : 'Confirm when you have it'} · '
             '${r.recipientCashAck ? '$recipient confirmed it on the link' : 'waiting for $recipient to confirm on the link'}');
  return [
    pay,
    (ok: c.photo, title: 'Photo of the item now', sub: c.photo ? 'Saved with the return' : 'Shows its condition before it goes back'),
    (ok: c.sender, title: '$sender acknowledges',
     sub: c.sender ? 'They know it’s coming and have the return code' : senderInApp ? 'Asked in their app' : 'Asked on a WhatsApp / SMS link'),
  ];
}

/// The delivery as each side reads it (mygig_delivery_json).
class MygigDelivery {
  const MygigDelivery(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id'] ?? ''}';
  String get rideId => '${raw['rideId'] ?? ''}';
  String get status => '${raw['status'] ?? 'pickup'}';
  Map<String, dynamic> get parcel => _m(raw['parcel']);
  String get type => '${parcel['type'] ?? 'Parcel'}';
  String get size => '${parcel['size'] ?? 'small'}';
  double get kg => _d(parcel['kg']);
  double get value => _d(parcel['value']);
  bool get fragile => _b(parcel['fragile']);
  String get sealCode => '${raw['sealCode'] ?? ''}';
  String get senderName => '${_m(raw['sender'])['name'] ?? 'Sender'}';
  String? get senderPhone => _s(_m(raw['sender'])['phone']);
  bool get senderRegistered => _b(_m(raw['sender'])['registered']);
  String get pickupName => '${_m(raw['pickup'])['name'] ?? 'Pickup'}';
  Map<String, dynamic> get driver => _m(raw['driver']);
  String get payer => '${raw['payer'] ?? 'sender'}';
  bool get recipientPays => payer == 'recipient';
  MygigPay get pay => mygigPayFrom(raw['pay']);
  bool get inApp => _b(raw['inApp']);
  String get retPayer => '${raw['retPayer'] ?? 'recipient'}';
  MygigDeliveryQuote get quote => MygigDeliveryQuote(_m(raw['quote']));
  double get total => _d(raw['total']);
  double get codAmount => _d(_m(raw['cod'])['amount']);
  double get codFee => _d(_m(raw['cod'])['fee']);
  String get codStatus => '${_m(raw['cod'])['status'] ?? 'none'}';
  Map<String, dynamic> get deposit => _m(raw['deposit']);
  double get depositTotal => _d(deposit['total']);
  double get depositPaid => _d(deposit['paid']);
  double? get waitLeft => deposit['waitLeft'] is num ? _d(deposit['waitLeft']) : null;
  Map<String, dynamic> get money => _m(raw['money']);
  int get pickupPhotos => raw['pickupPhotos'] is List ? (raw['pickupPhotos'] as List).length : _i(raw['pickupPhotos']);
  List<String> get pickupPhotoPaths => [for (final p in _l(raw['pickupPhotos'])) '$p'];
  bool get itemMatches => _b(raw['itemMatches']);
  bool get sealed => _b(raw['sealed']);
  bool get senderCashTaken => raw['senderCashAt'] != null;
  int get pickupWaitOver => _i(_m(raw['pickupWait'])['over']);
  double get pickupWaitCharge => _d(_m(raw['pickupWait'])['charge']);
  String get proofRule => '${_m(raw['rules'])['proof'] ?? 'code'}';
  int get needPhotos => _i(_m(raw['rules'])['pickupPhotos'], 1);
  double get ackMin => _d(_m(raw['rules'])['ackMin'], 10);
  String? get returnCode => _s(raw['returnCode']);
  String? get shareToken => _s(raw['shareToken']);
  List<MygigDeliveryDrop> get drops => [for (final d in _l(raw['drops'])) if (d is Map) MygigDeliveryDrop(Map<String, dynamic>.from(d))];
  List<MygigDeliveryReturn> get returns => [for (final r in _l(raw['returns'])) if (r is Map) MygigDeliveryReturn(Map<String, dynamic>.from(r))];
  List<Map<String, dynamic>> get payParts => [for (final p in _l(raw['payParts'])) if (p is Map) Map<String, dynamic>.from(p)];

  bool get atPickup => status == 'pickup';
  bool get delivering => status == 'delivering';
  bool get done => status == 'done';
  bool get ended => status == 'done' || status == 'refused' || status == 'cancelled';

  /// The sender's cash, taken at the pickup before Start delivery.
  bool get senderCashDue => !recipientPays && pay == MygigPay.cash && !senderCashTaken;

  /// The sender's link (fare and deposit) still to pay, or null.
  Map<String, dynamic>? get acceptPart =>
      payParts.where((p) => p['purpose'] == 'accept' && p['paidAt'] == null).firstOrNull;

  /// The next drop-off still to do.
  MygigDeliveryDrop? get nextDrop => drops.where((d) => d.status == 'waiting' || d.status == 'arrived').firstOrNull;

  /// The return of drop-off [n], if any.
  MygigDeliveryReturn? returnOf(int n) => returns.where((r) => r.n == n).firstOrNull;

  /// What still stops Start delivery, or null.
  String? get startProblem {
    if (pickupPhotos < needPhotos) return 'Take ${needPhotos > 1 ? '$needPhotos photos' : 'a photo'} of the item first.';
    if (!itemMatches || !sealed) return 'Check the item matches and write the seal code on it first.';
    final part = acceptPart;
    if (part != null) {
      return 'The sender pays ${mygigMoney(_d(part['amount']))} by link first.';
    }
    if (senderCashDue) return 'Collect ${mygigMoney(total)} in cash from the sender first.';
    return null;
  }

  /// Who pays the waiting at drop-off [d], in words.
  String waitLine(MygigDeliveryDrop d, double freeMin) {
    final who = recipientPays && d.n == 1 && d.paidHow == null
        ? 'added to what ${d.name} pays'
        : inApp
        ? 'charged to ${mygigPayName(pay)}'
        : 'paid from the sender’s deposit${waitLeft == null ? '' : ' (${mygigMoney(waitLeft!)} left)'}. When that is used up, '
            'start a return: you’re never left waiting unpaid';
    return 'Waiting after ${_trim(freeMin)} min: $who.';
  }

  /// The deposit can't pay any more waiting: time to start the return.
  bool get waitUsedUp => !inApp && waitLeft != null && waitLeft! <= 0;
}

/// Whether the hand-over's proof is done ([rule]: code | codeOrPhoto | photo).
bool mygigProofOk({required String rule, required String code, required bool handOther, required String name, required bool photo}) {
  final codeOk = RegExp(r'^\d{4}$').hasMatch(code.trim());
  return switch (rule) {
    'photo' => photo,
    'codeOrPhoto' => codeOk || (handOther && name.trim().isNotEmpty && photo),
    _ => codeOk,
  };
}

/// What the hand-over still needs, in words, or null.
String? mygigHandoverProblem({required MygigDeliveryDrop d, required String rule, required bool proofOk}) {
  if (d.due > 0 && d.paidHow == null) return 'Collect the payment first.';
  if (proofOk) return null;
  return switch (rule) {
    'photo' => 'Take the hand-over photo.',
    'codeOrPhoto' => 'Enter the delivery code, or hand it to someone else with a photo.',
    _ => 'Enter the delivery code.',
  };
}

// ---- Admin --------------------------------------------------------------------------------------------

/// The Money safety panel: no setting leaves get.ride or the driver unpaid.
List<(String, String)> mygigMoneySafety(MygigDeliverySettings s) => [
  ('Paid before it moves',
   'The sender pays at pickup (cash, in-app, or link) before the driver leaves. The recipient pays at the door before the driver hands it over.'),
  ('Every return is paid for',
   'Failed delivery: the sender pays, from their in-app account or a refundable deposit taken by link at the start. Return asked by the recipient: whoever was chosen at the start pays before it leaves.'),
  ('Recipient pays is guaranteed',
   'By the sender’s in-app account, or the deposit includes the fare. If the recipient doesn’t pay, the sender does.'),
  ('Waiting is never unpaid',
   'Paid by the recipient (if they pay), the in-app sender, or the deposit up to ${_trim(s.allowanceMin)} min. Then the app tells the driver to start the return.'),
  ('Deposits cost nothing',
   'Card holds are released for free; a ${mygigMoney(s.guaranteeFee)} guarantee fee covers the payment gateway when a deposit is refunded.'),
  ('COD is settled at once',
   'Only for registered senders (paid into their GET.wallet). The driver’s cash COD comes off their GET.credit straight away, so cash COD needs enough GET.credit.'),
  ('Cover pays for itself',
   'A ${mygigMoney(s.coverFee)} cover fee on every delivery funds the cover; above ${mygigMoney(s.coverFree)}, ${_trim(s.coverPct)}% of the value.'),
  ('Disputes have proof',
   'Pickup photos, seal code, delivery and return codes, both sides’ acknowledgements and the route are kept for disputes and chargebacks.'),
  ('Fees come off GET.credit', 'Commission and the myGiG fee on cash jobs come off GET.credit when the job ends, as with rides.'),
];
