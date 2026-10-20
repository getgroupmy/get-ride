/// Order dispatch (migration 0251): stands, their admins and staff, groups
/// and fleets, and the orders a stand makes for walk-in customers. Pure, so
/// the console, the admin pages and the driver's card share one reading of
/// the server's rows, and the rules the server enforces are mirrored here for
/// the tests (`dispatch_ticket_text`, `dispatch_fee_amount`,
/// `dispatch_split`, `dispatch_offer_ok`).
library;

import 'dart:math' as math;

// ---- Small helpers --------------------------------------------------------------

double? _d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
DateTime? _t(Object? v) => v is String ? DateTime.tryParse(v) : null;
bool _b(Object? v) => v == true;
double _round2(double v) => (v * 100).roundToDouble() / 100;

/// "PAV-0041": the stand's code and its running number, at least four digits.
String formatTicketNo(String code, int n) {
  final digits = '$n';
  return '$code-${digits.padLeft(math.max(4, digits.length), '0')}';
}

/// Whether [code] is a stand code the server takes (2 to 6 letters or digits).
bool isStandCode(String code) => RegExp(r'^[A-Z0-9]{2,6}$').hasMatch(code.trim().toUpperCase());

// ---- Fees -----------------------------------------------------------------------

enum FeeType {
  none,
  fixed,
  percent;

  static FeeType parse(Object? v) => switch (v) {
    'fixed' => fixed,
    'percent' || 'pct' => percent,
    _ => none,
  };
}

enum FeePayer {
  customer,
  driver;

  static FeePayer parse(Object? v) => v == 'driver' ? driver : customer;
}

/// The stand fee on [fare]: a fixed amount, or a percentage rounded to the sen.
double feeAmount(FeeType type, double value, double fare) => switch (type) {
  FeeType.fixed => _round2(math.max(0, value)),
  FeeType.percent => _round2(math.max(0, fare) * value.clamp(0, 100) / 100),
  FeeType.none => 0,
};

/// A stand order's money (`dispatch_split`): the fee, what the platform
/// takes out of it, what the stand keeps, what the customer pays and what
/// the driver gets before the usual commission.
class DispatchSplit {
  const DispatchSplit({
    required this.fare,
    required this.fee,
    required this.platform,
    required this.customer,
    required this.driver,
  });

  final double fare;
  final double fee;
  final double platform;
  final double customer;
  final double driver;

  double get stand => _round2(fee - platform);

  /// What a counter-paid order settled in the app costs the stand's
  /// GET.credit: the driver's share and the platform's fee
  /// (`dispatch_counter_due`).
  double get counterDue => _round2(math.max(0, driver) + platform);

  @override
  String toString() => 'fare $fare fee $fee platform $platform stand $stand customer $customer driver $driver';
}

DispatchSplit dispatchSplit({
  required double fare,
  required FeeType feeType,
  required double feeValue,
  required FeePayer payer,
  required FeeType platformType,
  required double platformValue,
}) {
  final f = _round2(math.max(0, fare));
  final fee = feeAmount(feeType, feeValue, f);
  final cut = platformType == FeeType.fixed
      ? _round2(math.max(0, platformValue))
      : _round2(fee * platformValue.clamp(0, 100) / 100);
  return DispatchSplit(
    fare: f,
    fee: fee,
    platform: math.min(fee, cut),
    customer: _round2(f + (payer == FeePayer.customer ? fee : 0)),
    driver: _round2(f - (payer == FeePayer.driver ? fee : 0)),
  );
}

/// A stand's fee settings.
class StandFee {
  const StandFee({
    this.type = FeeType.none,
    this.value = 0,
    this.payer = FeePayer.customer,
    this.setByStand = false,
    this.platformType = FeeType.percent,
    this.platformValue = 0,
    this.creditLimit,
    this.creditLimitByStand = false,
    this.creditLimitMax = 0,
  });

  factory StandFee.fromRow(Map<String, dynamic> r) => StandFee(
    type: FeeType.parse(r['fee_type']),
    value: _d(r['fee_value']) ?? 0,
    payer: FeePayer.parse(r['fee_bearer']),
    setByStand: r['fee_set_by'] == 'stand',
    platformType: r['platform_fee_type'] == 'fixed' ? FeeType.fixed : FeeType.percent,
    platformValue: _d(r['platform_fee_value']) ?? 0,
    creditLimit: _d(r['credit_limit']),
    creditLimitByStand: r['credit_limit_set_by'] == 'stand',
    creditLimitMax: _d(r['credit_limit_max']) ?? 0,
  );

  final FeeType type;
  final double value;
  final FeePayer payer;
  final bool setByStand;
  final FeeType platformType;
  final double platformValue;

  /// How far below zero the stand's GET.credit may go with counter-paid
  /// orders (500: down to RM -500); null, no limit.
  final double? creditLimit;

  /// The stand admin sets the limit, from 0 to [creditLimitMax].
  final bool creditLimitByStand;
  final double creditLimitMax;

  StandFee copyWith({double? creditLimit, bool clearCreditLimit = false, bool? creditLimitByStand, double? creditLimitMax}) =>
      StandFee(
        type: type,
        value: value,
        payer: payer,
        setByStand: setByStand,
        platformType: platformType,
        platformValue: platformValue,
        creditLimit: clearCreditLimit ? null : (creditLimit ?? this.creditLimit),
        creditLimitByStand: creditLimitByStand ?? this.creditLimitByStand,
        creditLimitMax: creditLimitMax ?? this.creditLimitMax,
      );

  /// The columns of the charges on `dispatch_stands` (an admin's write).
  Map<String, dynamic> toRow() => {
    'fee_type': type.name,
    'fee_value': value,
    'fee_bearer': payer.name,
    'fee_set_by': setByStand ? 'stand' : 'admin',
    'platform_fee_type': platformType == FeeType.fixed ? 'fixed' : 'percent',
    'platform_fee_value': platformValue,
    'credit_limit': creditLimit,
    'credit_limit_set_by': creditLimitByStand ? 'stand' : 'admin',
    'credit_limit_max': creditLimitMax,
  };

  DispatchSplit splitFor(double fare) => dispatchSplit(
    fare: fare,
    feeType: type,
    feeValue: value,
    payer: payer,
    platformType: platformType,
    platformValue: platformValue,
  );

  /// "RM 3 per order, paid by the customer"; "No fee".
  String get label {
    if (type == FeeType.none || value <= 0) return 'No fee';
    final amount = type == FeeType.fixed ? 'RM ${_money(value)} per order' : '${_pct(value)}% of the fare';
    return '$amount, paid by the ${payer == FeePayer.customer ? 'customer' : 'driver'}';
  }

  String get platformLabel => platformValue <= 0
      ? 'No platform fee'
      : platformType == FeeType.fixed
      ? 'RM ${_money(platformValue)} per order'
      : '${_pct(platformValue)}% of the stand fee';
}

String _money(double v) => v.toStringAsFixed(2);
String _pct(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// Whether the caller may change a stand's fee: admins always, a stand admin
/// when the admin lets the stand set it, staff never (`dispatch_set_stand_fee`).
bool canSetStandFee({required bool admin, required bool standAdmin, required StandFee fee}) =>
    admin || (standAdmin && fee.setByStand);

/// Whether the caller may change a stand's credit limit: admins always, a
/// stand admin when the admin lets the stand set it, staff never
/// (`dispatch_set_credit_limit`).
bool canSetCreditLimit({required bool admin, required bool standAdmin, required StandFee fee}) =>
    admin || (standAdmin && fee.creditLimitByStand);

const _creditLimitTop = 1000000.0;

/// What is wrong with a credit limit, or null: admins RM 0 up (empty: no
/// limit), a stand admin RM 0 to the admin's cap.
String? creditLimitProblem(double? limit, {required bool admin, required double max}) {
  if (limit == null) return admin ? null : 'Enter the limit.';
  final top = admin ? _creditLimitTop : max;
  if (limit < 0 || limit > top) return 'The limit is RM 0 to RM ${_money(top)}.';
  return null;
}

String _rmWhole(double v) {
  final a = v.abs();
  final n = a == a.roundToDouble() ? '${a.round()}' : a.toStringAsFixed(2);
  return v < 0 ? '\u2212$n' : n;
}

/// "Top up to send counter-paid orders": a stand past its credit limit.
const standCreditTopUpText = 'Top up to send counter-paid orders';

/// A stand's GET.credit standing for counter-paid orders (`dispatch_stand_credit`).
class StandCredit {
  const StandCredit({
    this.applies = false,
    this.balance = 0,
    this.limit,
    this.pending = 0,
    this.available,
    this.blocked = false,
  });

  factory StandCredit.fromJson(Map<String, dynamic> j) => StandCredit(
    applies: _b(j['applies']),
    balance: _d(j['balance']) ?? 0,
    limit: _d(j['limit']),
    pending: _d(j['pending']) ?? 0,
    available: _d(j['available']),
    blocked: _b(j['blocked']),
  );

  /// Counter orders are settled in the app and the stand has a limit.
  final bool applies;
  final double balance;
  final double? limit;

  /// What the stand's open counter-paid orders will still cost.
  final double pending;

  /// Left before the limit (after [pending]); null without a limit.
  final double? available;
  final bool blocked;

  /// "GET.credit: RM −320 of −500 limit"; "GET.credit: RM 150".
  String get label => limit == null || !applies
      ? 'GET.credit: RM ${_rmWhole(balance)}'
      : 'GET.credit: RM ${_rmWhole(balance)} of ${_rmWhole(-limit!)} limit';

  /// Whether a counter-paid order costing [due] may go out (`dispatch_credit_check`).
  bool allows(double due) => !applies || (available != null && available! > 0 && due <= available!);
}

// ---- Who an order is offered to -------------------------------------------------

enum DispatchMode {
  assign,
  broadcast,

  /// The Call centre's "Nearby drivers · normal booking": dispatched as a
  /// booking made in the app.
  nearby;

  static DispatchMode parse(Object? v) => switch (v) {
    'assign' => assign,
    'nearby' => nearby,
    _ => broadcast,
  };
}

/// How a Call centre customer asked for the ride.
enum BookedVia {
  phone('Phone call', 'phone call'),
  sms('SMS', 'SMS'),
  whatsapp('WhatsApp', 'WhatsApp');

  const BookedVia(this.label, this.inLine);
  final String label;
  final String inLine;

  static BookedVia? parse(Object? v) => switch (v) {
    'phone' => phone,
    'sms' => sms,
    'whatsapp' => whatsapp,
    _ => null,
  };
}

/// The release lead times a booking ahead offers (minutes before pickup).
const dispatchLeadMinutes = [15, 30, 60];

/// A booking's pickup from the date boxes (yyyy-mm-dd) and a time ("14:30",
/// "9.05", "0930"), in the phone's time; null when either doesn't read.
DateTime? parsePickupAt(String ymd, String hhmm) {
  final d = DateTime.tryParse(ymd.trim());
  final m = RegExp(r'^\s*(\d{1,2})\s*[:.h]?\s*(\d{2})\s*$').firstMatch(hhmm);
  if (d == null || m == null) return null;
  final h = int.parse(m.group(1)!), min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return DateTime(d.year, d.month, d.day, h, min);
}

/// "Tue 21 Oct, 14:30".
String formatPickupAt(DateTime at) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${days[l.weekday - 1]} ${l.day} ${months[l.month - 1]}, ${two(l.hour)}:${two(l.minute)}';
}

enum GroupKind {
  closed('Closed group', 'Only its members get the order.'),
  open('Open group', 'Its members get it first for a few seconds, then any nearby driver can take it.'),
  fleet('Fleet', 'Every driver of the fleet gets it, wherever they are.');

  const GroupKind(this.label, this.description);
  final String label;
  final String description;

  static GroupKind parse(Object? v) => switch (v) {
    'open' => open,
    'fleet' => fleet,
    _ => closed,
  };
}

/// How long an assigned driver has to accept (the server's 30 s).
const assignWindow = Duration(seconds: 30);

/// Whether a stand order is offered to a driver now (`dispatch_offer_ok`):
/// the assigned driver inside the window until it returns; for a broadcast,
/// any driver once widened or once an open group's members' time is up, else
/// a member of the group.
bool dispatchOfferOk({
  required String? driver,
  required DispatchMode mode,
  required String? target,
  required bool member,
  required DateTime now,
  DateTime? offerUntil,
  DateTime? openAfter,
  DateTime? widenedAt,
  DateTime? returnedAt,
}) {
  if (driver == null) return false;
  if (mode == DispatchMode.assign) {
    return driver == target && returnedAt == null && offerUntil != null && offerUntil.isAfter(now);
  }
  return widenedAt != null || (openAfter != null && !openAfter.isAfter(now)) || member;
}

/// Seconds left in an open group's members-only time (0 once it is open to all).
int membersOnlySecondsLeft(DateTime? openAfter, DateTime now) =>
    openAfter == null ? 0 : math.max(0, openAfter.difference(now).inMilliseconds / 1000).ceil();

/// Seconds an assigned driver has left to accept.
int assignSecondsLeft(DateTime? offerUntil, DateTime now) =>
    offerUntil == null ? 0 : math.max(0, offerUntil.difference(now).inMilliseconds / 1000).ceil();

// ---- Stands, groups, people -----------------------------------------------------

enum StandKind {
  mall('Mall'),
  hotel('Hotel'),
  busTerminal('Bus terminal'),
  trainStation('Train station'),
  airport('Airport'),
  hospital('Hospital'),
  eventVenue('Event venue'),
  other('Other'),

  /// The admins' own pickup for phone and text bookings.
  callCentre('Call centre');

  const StandKind(this.label);
  final String label;

  String get db => switch (this) {
    callCentre => 'call_centre',
    busTerminal => 'bus_terminal',
    trainStation => 'train_station',
    eventVenue => 'event_venue',
    _ => name,
  };

  static StandKind parse(Object? v) => StandKind.values.firstWhere((k) => k.db == v, orElse: () => other);
}

/// What one person may do at a stand.
class StandPerms {
  const StandPerms({
    this.assign = false,
    this.broadcast = false,
    this.fixedFare = false,
    this.cancel = false,
    this.reassign = false,
    this.reports = false,
    this.staff = false,
  });

  static const all = StandPerms(
    assign: true,
    broadcast: true,
    fixedFare: true,
    cancel: true,
    reassign: true,
    reports: true,
    staff: true,
  );

  factory StandPerms.fromJson(Map<String, dynamic>? j) => StandPerms(
    assign: _b(j?['assign']),
    broadcast: _b(j?['broadcast']),
    fixedFare: _b(j?['fixed_fare']),
    cancel: _b(j?['cancel']),
    reassign: _b(j?['reassign']),
    reports: _b(j?['reports']),
    staff: _b(j?['staff']),
  );

  /// A staff row's access (`dispatch_stand_people`).
  factory StandPerms.fromStaffRow(Map<String, dynamic> r) => StandPerms(
    assign: _b(r['can_assign']),
    broadcast: _b(r['can_broadcast']),
    fixedFare: _b(r['can_fixed_fare']),
    cancel: _b(r['can_cancel']),
    reassign: _b(r['can_reassign']),
    reports: _b(r['can_reports']),
  );

  final bool assign;
  final bool broadcast;
  final bool fixedFare;
  final bool cancel;
  final bool reassign;
  final bool reports;

  /// Managing staff: the stand admin's alone.
  final bool staff;

  bool has(StaffAccess a) => switch (a) {
    StaffAccess.assign => assign,
    StaffAccess.broadcast => broadcast,
    StaffAccess.fixedFare => fixedFare,
    StaffAccess.cancel => cancel,
    StaffAccess.reassign => reassign,
    StaffAccess.reports => reports,
  };

  StandPerms toggled(StaffAccess a) => StandPerms(
    assign: a == StaffAccess.assign ? !assign : assign,
    broadcast: a == StaffAccess.broadcast ? !broadcast : broadcast,
    fixedFare: a == StaffAccess.fixedFare ? !fixedFare : fixedFare,
    cancel: a == StaffAccess.cancel ? !cancel : cancel,
    reassign: a == StaffAccess.reassign ? !reassign : reassign,
    reports: a == StaffAccess.reports ? !reports : reports,
    staff: staff,
  );

  Map<String, bool> toJson() => {
    'assign': assign,
    'broadcast': broadcast,
    'fixed_fare': fixedFare,
    'cancel': cancel,
    'reassign': reassign,
    'reports': reports,
  };

  /// The columns of a staff row.
  Map<String, bool> toStaffRow() => {
    'can_assign': assign,
    'can_broadcast': broadcast,
    'can_fixed_fare': fixedFare,
    'can_cancel': cancel,
    'can_reassign': reassign,
    'can_reports': reports,
  };

  /// Can send an order at all.
  bool get sends => assign || broadcast;
}

/// The access chips a stand admin gives their staff.
enum StaffAccess {
  assign('Assign'),
  broadcast('Broadcast'),
  fixedFare('Fixed fare'),
  cancel('Cancel'),
  reassign('Reassign'),
  reports('See reports');

  const StaffAccess(this.label);
  final String label;
}

class DispatchGroup {
  const DispatchGroup({
    required this.id,
    required this.name,
    required this.kind,
    this.membersFirstSec = 30,
    this.members = 0,
    this.allowJoin = true,
    this.active = true,
    this.fleetOwnerPartnerId,
    this.note,
  });

  factory DispatchGroup.fromJson(Map<String, dynamic> j) => DispatchGroup(
    id: '${j['id']}',
    name: _s(j['name']) ?? 'Group',
    kind: GroupKind.parse(j['kind']),
    membersFirstSec: (_d(j['members_first_sec']) ?? 30).round(),
    members: (_d(j['members']) ?? 0).round(),
    allowJoin: j['allow_join'] != false,
    active: j['active'] != false,
    fleetOwnerPartnerId: _s(j['fleet_owner_partner_id']),
    note: _s(j['note']),
  );

  final String id;
  final String name;
  final GroupKind kind;
  final int membersFirstSec;
  final int members;
  final bool allowJoin;
  final bool active;
  final String? fleetOwnerPartnerId;
  final String? note;

  /// "Members first for 30 s." on an open group; the kind's description.
  String get howItWorks =>
      kind == GroupKind.open ? '${kind.description} Members first for $membersFirstSec s.' : kind.description;

  Map<String, dynamic> toRow() => {
    'name': name.trim(),
    'kind': kind.name,
    'members_first_sec': membersFirstSec,
    'allow_join': allowJoin,
    'active': active,
    'fleet_owner_partner_id': fleetOwnerPartnerId,
    'note': note,
  };
}

class DispatchStand {
  const DispatchStand({
    required this.id,
    required this.name,
    required this.code,
    this.kind = StandKind.other,
    this.address,
    this.lat,
    this.lng,
    this.allowFixedFare = false,
    this.settleInApp = true,
    this.fee = const StandFee(),
    this.perms = StandPerms.all,
    this.admin = false,
    this.role,
    this.groups = const [],
    this.groupIds = const [],
    this.active = true,
    this.ownerId,
    this.adminOnly = false,
  });

  factory DispatchStand.fromJson(Map<String, dynamic> j) => DispatchStand(
    id: '${j['id']}',
    name: _s(j['name']) ?? 'Stand',
    code: _s(j['code']) ?? '',
    kind: StandKind.parse(j['kind']),
    address: _s(j['address']),
    lat: _d(j['lat']),
    lng: _d(j['lng']),
    allowFixedFare: _b(j['allow_fixed_fare']),
    settleInApp: j['settlement'] != 'outside',
    fee: StandFee.fromRow(j),
    perms: j['perms'] is Map ? StandPerms.fromJson(Map<String, dynamic>.from(j['perms'] as Map)) : StandPerms.all,
    admin: _b(j['admin']),
    role: _s(j['role']),
    groups: [
      if (j['groups'] is List)
        for (final g in j['groups'] as List)
          if (g is Map) DispatchGroup.fromJson(Map<String, dynamic>.from(g)),
    ],
    groupIds: [
      if (j['group_ids'] is List)
        for (final g in j['group_ids'] as List) '$g',
    ],
    active: j['active'] != false,
    ownerId: _s(j['owner_id']),
    adminOnly: _b(j['admin_only']),
  );

  final String id;
  final String name;
  final String code;
  final StandKind kind;
  final String? address;
  final double? lat;
  final double? lng;
  final bool allowFixedFare;

  /// "Paid at counter": the driver is paid into their wallet (true), or it is
  /// settled outside the app.
  final bool settleInApp;
  final StandFee fee;
  final StandPerms perms;

  /// The caller is an admin (every stand, every access).
  final bool admin;

  /// The caller's role here: 'admin' (stand admin) or 'staff'.
  final String? role;
  final List<DispatchGroup> groups;
  final List<String> groupIds;
  final bool active;
  final String? ownerId;

  /// Admins only: the Call centre (each order has its own pickup).
  final bool adminOnly;
  bool get isCallCentre => adminOnly;

  bool get isStandAdmin => admin || role == 'admin';

  /// Whether the caller may set a fixed fare here.
  bool get canFixFare => admin || (allowFixedFare && perms.fixedFare);

  /// The stand's short name: the part before " · ".
  String get shortName => name.split(' · ').first;

  Map<String, dynamic> toRow() => {
    'name': name.trim(),
    'code': code.trim().toUpperCase(),
    'kind': kind.db,
    'address': address,
    'lat': lat,
    'lng': lng,
    'allow_fixed_fare': allowFixedFare,
    'settlement': settleInApp ? 'wallet' : 'outside',
    ...fee.toRow(),
    'owner_id': ownerId,
    'active': active,
  };

  /// What is wrong with the form, or null.
  String? get problem {
    if (name.trim().isEmpty) return 'Give the stand a name.';
    if (!isStandCode(code)) return 'The short code is 2 to 6 letters or digits.';
    if (!adminOnly && (lat == null || lng == null)) return 'Pick the stand on the map.';
    if (fee.type == FeeType.percent && fee.value > 100) return 'A percentage fee is 0 to 100.';
    if (fee.platformType == FeeType.percent && fee.platformValue > 100) return 'A percentage fee is 0 to 100.';
    return null;
  }
}

// ---- Orders ---------------------------------------------------------------------

enum FareMode {
  meter('Meter'),
  estimate('App fare'),
  fixed('Fixed');

  const FareMode(this.label);
  final String label;

  static FareMode parse(Object? v) => switch (v) {
    'estimate' => estimate,
    'fixed' => fixed,
    _ => meter,
  };
}

enum CounterPayment {
  counter('Paid at counter'),
  cash('Cash to driver'),
  app('Card / e-wallet');

  const CounterPayment(this.label);
  final String label;

  /// Taken at the counter (the stand's GET.credit pays the driver).
  bool get atCounter => this != cash;

  static CounterPayment parse(Object? v) => switch (v) {
    'cash' => cash,
    'app' => app,
    _ => counter,
  };
}

/// The board's columns.
enum BoardColumn {
  scheduled('Scheduled'),
  waiting('Waiting for a driver'),
  coming('Driver coming'),
  onTheWay('On the way'),
  done('Done');

  const BoardColumn(this.label);
  final String label;
}

BoardColumn boardColumnFor(String status) => switch (status) {
  'open' => BoardColumn.waiting,
  'accepted' || 'arrived' => BoardColumn.coming,
  'on_trip' => BoardColumn.onTheWay,
  _ => BoardColumn.done,
};

class DispatchEvent {
  const DispatchEvent({required this.action, this.detail, this.actor, this.at});

  factory DispatchEvent.fromJson(Map<String, dynamic> j) =>
      DispatchEvent(action: '${j['action']}', detail: _s(j['detail']), actor: _s(j['actor']), at: _t(j['at']));

  final String action;
  final String? detail;
  final String? actor;
  final DateTime? at;

  /// "Aina · Broadcast to Pavilion stand drivers".
  String get line => [actor ?? 'System', detail ?? action].join(' · ');
}

class DispatchOrder {
  DispatchOrder(this.raw);

  factory DispatchOrder.fromJson(Map<String, dynamic> j) => DispatchOrder(j);

  final Map<String, dynamic> raw;

  String get id => '${raw['id']}';
  String get standId => '${raw['stand_id']}';
  String get standName => _s(raw['stand_name']) ?? 'Stand';
  String get ticketNo => _s(raw['ticket_no']) ?? '';
  String get status => _s(raw['status']) ?? 'open';
  DispatchMode get mode => DispatchMode.parse(raw['mode']);
  String? get groupName => _s(raw['group_name']);
  GroupKind? get groupKind => raw['group_kind'] == null ? null : GroupKind.parse(raw['group_kind']);
  String? get targetDriverId => _s(raw['driver_id']);
  String? get targetDriverName => _s(raw['driver_target_name']);
  DateTime? get offeredAt => _t(raw['offered_at']);
  DateTime? get offerUntil => _t(raw['offer_until']);
  DateTime? get openAfter => _t(raw['open_after']);
  DateTime? get widenedAt => _t(raw['widened_at']);
  DateTime? get returnedAt => _t(raw['returned_at']);
  DateTime? get createdAt => _t(raw['created_at']);
  String get dropName => _s(raw['drop_name']) ?? 'Destination';
  String? get service => _s(raw['service']);
  int get passengers => (_d(raw['passengers']) ?? 1).round();
  String? get note => _s(raw['note']);
  FareMode get fareMode => FareMode.parse(raw['fare_mode']);
  double? get fare => _d(raw['fare']);
  CounterPayment get payment => CounterPayment.parse(raw['payment']);
  double? get feeAmount => _d(raw['fee_amount']);
  FeePayer get feePayer => FeePayer.parse(raw['fee_bearer']);
  FeeType get feeType => FeeType.parse(raw['fee_type']);
  double get feeValue => _d(raw['fee_value']) ?? 0;
  String? get customerName => _s(raw['customer_name']);
  String? get customerPhone => _s(raw['customer_phone']);
  String? get driverName => _s(raw['partner_name']);
  String? get driverPhone => _s(raw['partner_phone']);
  String? get driverPlate => _s(raw['partner_plate']);

  /// The car the driver took the order in, as the ride stamped it:
  /// "Silver Toyota Vios · VBA 8821" (colour, make, model, then plate).
  String? get carLine => dispatchCarLine(driverVehicle, driverPlate);

  /// The driver and their car as labelled lines: "Driver: Mei Ling",
  /// "Car: Silver Toyota Vios", "Plate: VBA 8821".
  List<String> get driverLines => [
    'Driver: ${driverName ?? 'on the way'}',
    if (driverVehicle != null) 'Car: $driverVehicle',
    if (driverPlate != null) 'Plate: $driverPlate',
  ];
  String? get driverVehicle => _s(raw['partner_vehicle']);
  String? get tripCode => _s(raw['trip_code']);
  String? get shareToken => _s(raw['share_token']);
  String? get createdByName => _s(raw['created_by_name']);
  String? get cancelReason => _s(raw['cancel_reason']);
  List<DispatchEvent> get events => [
    if (raw['events'] is List)
      for (final e in raw['events'] as List)
        if (e is Map) DispatchEvent.fromJson(Map<String, dynamic>.from(e)),
  ];

  BoardColumn get column => isScheduled ? BoardColumn.scheduled : boardColumnFor(status);

  /// Booked ahead and not out yet (a scheduled ride of the stand's).
  bool get isScheduled => raw['kind'] == 'scheduled';
  DateTime? get pickupAt => _t(raw['pickup_at']);
  int get leadMinutes => (_d(raw['lead_minutes']) ?? 30).round();
  bool get driverConfirmed => raw['driver_confirmed'] == true;
  String? get offerStatus => _s(raw['offer_status']);
  String? get pickupName => _s(raw['pickup_name']);
  BookedVia? get bookedVia => BookedVia.parse(raw['booked_via']);
  bool get riderAccount => raw['rider_account'] == true;

  /// "Menara A to KLCC" for a Call centre order (its own pickup); the
  /// destination for a stand's.
  String get routeLine => bookedVia != null && pickupName != null ? '$pickupName to $dropName' : dropName;

  /// A booking ahead's state: "Driver confirmed", "Waiting for Ali to
  /// confirm", or "Goes out 30 min before".
  String get scheduleState {
    if (driverConfirmed) return 'Driver confirmed';
    if (mode == DispatchMode.assign && offerStatus == 'pending') {
      return 'Waiting for ${targetDriverName ?? 'the driver'} to confirm';
    }
    return 'Goes out $leadMinutes min before';
  }

  bool get waiting => status == 'open';
  bool get hasDriver => status == 'accepted' || status == 'arrived' || status == 'on_trip';
  bool get cancelled => status == 'cancelled' || status == 'expired';

  /// An assigned order no longer offered: declined, unanswered, or past its window.
  bool returned(DateTime now) =>
      waiting && mode == DispatchMode.assign && (returnedAt != null || assignSecondsLeft(offerUntil, now) == 0);

  /// Who it was sent to: the driver, the group, or anyone nearby.
  String sentTo(DateTime now) {
    if (mode == DispatchMode.assign) return targetDriverName ?? 'a driver';
    if (mode == DispatchMode.nearby) return 'nearby drivers';
    if (widenedAt != null) return 'any nearby driver';
    final g = groupName ?? 'the group';
    if (groupKind == GroupKind.open && openAfter != null && !openAfter!.isAfter(now)) return '$g, then anyone nearby';
    return g;
  }

  /// "Fixed RM 28", "Meter", "App fare RM 22".
  String get fareText => switch (fareMode) {
    FareMode.meter => fare == null ? 'Meter' : 'Meter RM ${_money(fare!)}',
    FareMode.estimate => 'App fare${fare == null ? '' : ' RM ${_money(fare!)}'}',
    FareMode.fixed => 'Fixed${fare == null ? '' : ' RM ${_money(fare!)}'}',
  };

  /// What the customer pays: the fare and the fee they bear (null on a
  /// metered order not yet done).
  double? get customerTotal {
    final f = fare;
    if (f == null) return null;
    final fee = feeAmount ?? (feeType == FeeType.none ? 0 : _feeOn(f));
    return _round2(f + (feePayer == FeePayer.customer ? fee : 0));
  }

  double _feeOn(double fare) => switch (feeType) {
    FeeType.fixed => _round2(feeValue),
    FeeType.percent => _round2(fare * feeValue / 100),
    FeeType.none => 0,
  };

  /// The pill on a card: "Sent 18 s ago", "No answer", "Coming", ….
  String pill(DateTime now) {
    if (isScheduled) return pickupAt == null ? 'Scheduled' : formatPickupAt(pickupAt!);
    switch (status) {
      case 'open':
        if (returned(now)) return 'No answer · back to you';
        final at = offeredAt ?? createdAt;
        return 'Sent ${at == null ? 0 : now.difference(at).inSeconds.clamp(0, 1 << 30)} s ago';
      case 'accepted':
        return 'Coming';
      case 'arrived':
        return 'At the stand';
      case 'on_trip':
        return 'On the way';
      case 'completed':
        return 'Done';
      case 'expired':
        return 'Nobody took it';
      default:
        return 'Cancelled';
    }
  }
}

/// The board: orders per column, newest first, optionally one stand only.
Map<BoardColumn, List<DispatchOrder>> boardColumns(Iterable<DispatchOrder> orders, {String? standId}) {
  final out = {for (final c in BoardColumn.values) c: <DispatchOrder>[]};
  for (final o in orders) {
    if (standId != null && o.standId != standId) continue;
    out[o.column]!.add(o);
  }
  for (final l in out.values) {
    l.sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
  }
  // Bookings ahead soonest first.
  out[BoardColumn.scheduled]!.sort((a, b) => (a.pickupAt ?? DateTime(0)).compareTo(b.pickupAt ?? DateTime(0)));
  return out;
}

/// What each card offers, by the caller's access (the server checks again).
class OrderActions {
  const OrderActions({
    this.resend = false,
    this.reassign = false,
    this.pickedUp = false,
    this.complete = false,
    this.cancel = false,
    this.sendNow = false,
    this.editTime = false,
  });

  /// A booking ahead: send it out now, or move its time.
  final bool sendNow;
  final bool editTime;
  final bool resend;
  final bool reassign;
  final bool pickedUp;
  final bool complete;
  final bool cancel;
}

OrderActions orderActions(DispatchOrder o, StandPerms p) => o.isScheduled
    ? OrderActions(sendNow: p.broadcast || p.assign, editTime: true, cancel: p.cancel)
    : OrderActions(
        resend: o.waiting && (p.broadcast || p.assign),
        reassign: (o.status == 'accepted' || o.status == 'arrived') && p.reassign,
        pickedUp: o.status == 'accepted' || o.status == 'arrived',
        complete: o.status == 'on_trip',
        cancel: (o.waiting || o.status == 'accepted' || o.status == 'arrived') && p.cancel,
      );

// ---- Drivers near the stand -----------------------------------------------------

enum DriverState {
  atStand('At the stand'),
  free('Free'),
  onTrip('On a trip'),
  offline('Offline');

  const DriverState(this.label);
  final String label;

  static DriverState parse(Object? v) => switch (v) {
    'at_stand' => atStand,
    'on_trip' => onTrip,
    'offline' => offline,
    _ => free,
  };
}

class NearbyDriver {
  const NearbyDriver({
    required this.id,
    required this.name,
    this.plate,
    this.vehicle,
    this.service,
    this.km,
    this.state = DriverState.free,
    this.groups = const [],
  });

  factory NearbyDriver.fromJson(Map<String, dynamic> j) => NearbyDriver(
    id: '${j['id'] ?? j['driver_id']}',
    name: _s(j['name']) ?? 'Driver',
    plate: _s(j['plate']),
    vehicle: _s(j['vehicle']),
    service: _s(j['service']),
    km: _d(j['km']),
    state: DriverState.parse(j['state']),
    groups: [
      if (j['groups'] is List)
        for (final g in j['groups'] as List) '$g',
    ],
  );

  final String id;
  final String name;
  final String? plate;

  /// The car they are driving now: colour, make and model.
  final String? vehicle;
  final String? service;
  final double? km;

  /// "Silver Toyota Vios · VBA 8821".
  String? get carLine => dispatchCarLine(vehicle, plate);
  final DriverState state;
  final List<String> groups;

  /// "Taxi · 0.3 km · At the stand".
  String get subtitle => [?service, if (km != null) '${km!.toStringAsFixed(1)} km', state.label].join(' · ');
}

/// A driver's car as every dispatch screen shows it: colour, make and model,
/// then the plate ("Silver Toyota Vios · VBA 8821"); null with neither.
String? dispatchCarLine(String? vehicle, String? plate) {
  final parts = [
    for (final s in [vehicle, plate])
      if (s != null && s.trim().isNotEmpty) s.trim(),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Nearest first; a driver on a trip after the free ones; the asked-for
/// service first when given.
List<NearbyDriver> sortNearest(Iterable<NearbyDriver> drivers, {String? service}) {
  int rank(NearbyDriver d) => d.state == DriverState.onTrip ? 1 : 0;
  bool fits(NearbyDriver d) => service == null || (d.service ?? '').toLowerCase() == service.toLowerCase();
  final list = drivers.toList();
  list.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    final f = (fits(a) ? 0 : 1).compareTo(fits(b) ? 0 : 1);
    if (f != 0) return f;
    return (a.km ?? double.infinity).compareTo(b.km ?? double.infinity);
  });
  return list;
}

// ---- The new-order form -----------------------------------------------------------

class NewOrder {
  const NewOrder({
    required this.standId,
    this.dropName = '',
    this.dropAddress,
    this.dropLat,
    this.dropLng,
    this.distanceKm,
    this.durationMin,
    this.customerName = '',
    this.customerPhone = '',
    this.service,
    this.passengers = 1,
    this.fareMode = FareMode.meter,
    this.fare,
    this.payment = CounterPayment.counter,
    this.note = '',
    this.mode = DispatchMode.broadcast,
    this.groupId,
    this.driverId,
    this.bookedVia,
    this.pickupName,
    this.pickupAddress,
    this.pickupLat,
    this.pickupLng,
    this.pickupAt,
    this.leadMinutes = 30,
  });

  /// The Call centre: how they asked, and where they are picked up.
  final BookedVia? bookedVia;
  final String? pickupName;
  final String? pickupAddress;
  final double? pickupLat;
  final double? pickupLng;

  /// Booked ahead: when, and how long before it goes out.
  final DateTime? pickupAt;
  final int leadMinutes;
  final String standId;
  final String dropName;
  final String? dropAddress;
  final double? dropLat;
  final double? dropLng;
  final double? distanceKm;
  final int? durationMin;
  final String customerName;
  final String customerPhone;
  final String? service;
  final int passengers;
  final FareMode fareMode;
  final double? fare;
  final CounterPayment payment;
  final String note;
  final DispatchMode mode;
  final String? groupId;
  final String? driverId;

  /// What stops it being sent, or null.
  String? problemFor(DispatchStand stand, {DateTime? now}) {
    if (stand.isCallCentre) {
      if (bookedVia == null) return 'Say how the customer booked.';
      if ((pickupName ?? '').trim().isEmpty || pickupLat == null || pickupLng == null) {
        return 'Find the pickup address.';
      }
      if (customerName.trim().isEmpty || customerPhone.trim().isEmpty) {
        return "A phone booking needs the customer's name and phone.";
      }
    }
    if (pickupAt != null && pickupAt!.isBefore((now ?? DateTime.now()).add(Duration(minutes: leadMinutes + 5)))) {
      return 'Pick a time at least ${leadMinutes + 5} minutes from now.';
    }
    if (dropName.trim().isEmpty) return 'Say where the customer is going.';
    if (passengers < 1 || passengers > 20) return 'Passengers are 1 to 20.';
    final digits = customerPhone.replaceAll(RegExp(r'\D'), '');
    if (customerPhone.trim().isNotEmpty && (digits.length < 6 || digits.length > 20)) {
      return "The phone number doesn't look right.";
    }
    if (fareMode == FareMode.fixed && !stand.canFixFare) return "You can't set a fixed fare here.";
    if (fareMode != FareMode.meter && (fare == null || fare! <= 0)) return 'Enter the fare.';
    if (mode == DispatchMode.assign) {
      if (!stand.perms.assign) return "You can't assign drivers here.";
      if (driverId == null) return 'Pick a driver.';
    } else if (mode == DispatchMode.nearby) {
      if (!stand.isCallCentre) return 'Pick a group.';
    } else {
      if (!stand.perms.broadcast) return "You can't broadcast here.";
      if (groupId == null) return 'Pick a group.';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'drop_name': dropName.trim(),
    'drop_address': dropAddress,
    'drop_lat': dropLat,
    'drop_lng': dropLng,
    'distance_km': distanceKm,
    'duration_min': durationMin,
    'customer_name': customerName.trim(),
    'customer_phone': customerPhone.trim(),
    'service': service,
    'passengers': passengers,
    'fare_mode': fareMode.name,
    'fare': fareMode == FareMode.meter ? null : fare,
    'payment': payment.name,
    'note': note.trim(),
    'mode': mode.name,
    'group_id': mode == DispatchMode.broadcast ? groupId : null,
    'driver_id': mode == DispatchMode.assign ? driverId : null,
    if (bookedVia != null) ...{
      'booked_via': bookedVia!.name,
      'pickup_name': pickupName?.trim(),
      'pickup_address': pickupAddress,
      'pickup_lat': pickupLat,
      'pickup_lng': pickupLng,
    },
    if (pickupAt != null) ...{'pickup_at': pickupAt!.toUtc().toIso8601String(), 'lead_minutes': leadMinutes},
  };
}

/// The send modes the caller has: both, or the one their access allows.
List<DispatchMode> sendModes(StandPerms p) => [
  if (p.broadcast) DispatchMode.broadcast,
  if (p.assign) DispatchMode.assign,
];

/// The fare modes offered at [stand].
List<FareMode> fareModes(DispatchStand stand) => [
  FareMode.meter,
  FareMode.estimate,
  if (stand.canFixFare) FareMode.fixed,
];

// ---- The driver's side ------------------------------------------------------------

/// A stand order as the driver's request card shows it (the ride row's own
/// columns): "Stand order · Pavilion stand drivers" or "Assigned to you".
class StandOrderInfo {
  const StandOrderInfo({
    required this.standName,
    required this.ticketNo,
    required this.assignedToMe,
    this.groupName,
    this.fareMode = FareMode.meter,
    this.payment = CounterPayment.counter,
    this.offerUntil,
  });

  /// Null for a request that is no stand order.
  static StandOrderInfo? of(Map<String, dynamic> row, {String? me}) {
    if (row['stand_id'] == null) return null;
    return StandOrderInfo(
      standName: _s(row['dispatch_stand_name']) ?? _s(row['pickup_name']) ?? 'Stand',
      ticketNo: _s(row['ticket_no']) ?? '',
      assignedToMe: row['dispatch_mode'] == 'assign' && me != null && row['dispatch_driver_id'] == me,
      groupName: _s(row['dispatch_group_name']),
      fareMode: FareMode.parse(row['fare_mode']),
      payment: CounterPayment.parse(row['dispatch_payment']),
      offerUntil: _t(row['dispatch_offer_until']),
    );
  }

  final String standName;
  final String ticketNo;
  final bool assignedToMe;
  final String? groupName;
  final FareMode fareMode;
  final CounterPayment payment;
  final DateTime? offerUntil;

  String get title => assignedToMe ? 'Assigned to you' : 'Stand order · ${groupName ?? 'nearby drivers'}';

  /// "Pavilion KL · Ticket PAV-0041 · Paid at counter".
  String get details => [standName, if (ticketNo.isNotEmpty) 'Ticket $ticketNo', payment.label].join(' · ');
}

/// A driver's place in a group they may join.
enum JoinState {
  none('Ask to join'),
  pending('Waiting for approval'),
  approved('Member'),
  rejected('Not approved');

  const JoinState(this.label);
  final String label;

  static JoinState parse(Object? v) => switch (v) {
    'pending' => pending,
    'approved' => approved,
    'rejected' => rejected,
    _ => none,
  };
}

/// Who approves a request to join [kind]: a fleet's owner, else an admin.
String approverOf(GroupKind kind) => kind == GroupKind.fleet ? 'the fleet owner' : 'an admin';

// ---- Statements ---------------------------------------------------------------------

class StandStatement {
  const StandStatement({required this.orders, required this.totals});

  factory StandStatement.fromJson(Map<String, dynamic> j) => StandStatement(
    orders: [
      if (j['orders'] is List)
        for (final o in j['orders'] as List)
          if (o is Map) Map<String, dynamic>.from(o),
    ],
    totals: j['totals'] is Map ? Map<String, dynamic>.from(j['totals'] as Map) : const {},
  );

  final List<Map<String, dynamic>> orders;
  final Map<String, dynamic> totals;

  double total(String k) => _d(totals[k]) ?? 0;
}
