/// Family (migration 0317): a host, members who joined by phone, children
/// without a phone, what the family pays and what the host may see. The
/// server decides (family_payer_for, family_can_view_location, …); this is
/// what the app shows, read from the server's answers, and the admin's
/// values by place resolved as the server resolves them. Pure.
///
/// Privacy (owner's rules): only three disclosed ways to see a member: the
/// Family viewer the member can see ("Shared with family" and who can see),
/// a logged admin look with a reason, and the admin's location rule per
/// region. Nothing hidden.
library;

import 'commission.dart' show Geo;
import 'payment_types.dart';

/// Admin › People › Family's page id: EDIT writes the values, the module
/// matrix, member caps and requests (admin_table_pages, 0317).
const familyAdminPage = 'admin-settings-family';

/// The stored payment_mode of a trip the family pays (the member's own trip).
const familyPaymentMode = 'Family';

/// City to City's `payment` for the same.
const familyC2cPayment = 'family';

/// What the host may see of a member, at most the admin's rule.
enum FamilyLocationRule {
  never('never', 'Never'),
  ride('ride', 'While on a ride'),
  always('always', 'Always, if the member allows');

  const FamilyLocationRule(this.db, this.label);
  final String db;
  final String label;

  static FamilyLocationRule parse(Object? v) {
    for (final r in values) {
      if (r.db == v) return r;
    }
    return ride;
  }

  /// The lesser of the two.
  FamilyLocationRule atMost(FamilyLocationRule other) => index <= other.index ? this : other;

  /// What the member reads about it.
  String get memberLine => switch (this) {
    never => 'Nobody in the family sees where you are.',
    ride => 'Your host sees your location while you are on a ride. A "Shared with family" chip shows whenever this is on.',
    always => 'Your host may see your location at any time, but only after you turn on Share with family. '
        'A "Shared with family" chip shows whenever this is on.',
  };
}

double? _d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
int? _i(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
bool _b(Object? v, [bool or = false]) => v is bool ? v : or;
DateTime? _t(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

/// The admin's Family values at a place (Admin › People › Family).
class FamilySettings {
  const FamilySettings({
    this.enabled = true,
    this.children = true,
    this.maxMembers = 6,
    this.inviteDays = 7,
    this.aloneAge = 12,
    this.codeTries = 3,
    this.monthCap = 1000,
    this.perRideChoices = const [20, 50, 100, 200],
    this.womenDriversForChildren = true,
    this.locationRule = FamilyLocationRule.ride,
  });

  final bool enabled;
  final bool children;
  final int maxMembers;
  final int inviteDays;
  final int aloneAge;
  final int codeTries;
  final double monthCap;
  final List<double> perRideChoices;
  final bool womenDriversForChildren;
  final FamilyLocationRule locationRule;

  /// The keys an admin edits, with their limits (as family_rules_valid, 0317).
  static const keys = [
    'enabled',
    'children',
    'maxMembers',
    'inviteDays',
    'aloneAge',
    'codeTries',
    'monthCap',
    'perRideChoices',
    'womenDriversForChildren',
    'locationRule',
  ];

  static const limits = <String, (num, num, num)>{
    // key: (lowest, highest, step)
    'maxMembers': (1, 50, 1),
    'inviteDays': (1, 60, 1),
    'aloneAge': (6, 18, 1),
    'codeTries': (1, 10, 1),
    'monthCap': (0, 100000, 100),
  };

  static const labels = <String, String>{
    'enabled': 'Family is on',
    'children': 'Children without a phone',
    'maxMembers': 'Most members',
    'inviteDays': 'Invite expires after',
    'aloneAge': 'Youngest to ride alone',
    'codeTries': 'Pickup code tries before calling the parent',
    'monthCap': 'Highest monthly limit a host can set',
    'perRideChoices': 'Per-trip limit choices',
    'womenDriversForChildren': 'Women drivers for children',
    'locationRule': 'Location the host may see',
  };

  factory FamilySettings.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final choices = m['perRideChoices'];
    return FamilySettings(
      enabled: _b(m['enabled'], true),
      children: _b(m['children'], true),
      maxMembers: _i(m['maxMembers']) ?? 6,
      inviteDays: _i(m['inviteDays']) ?? 7,
      aloneAge: _i(m['aloneAge']) ?? 12,
      codeTries: _i(m['codeTries']) ?? 3,
      monthCap: _d(m['monthCap']) ?? 1000,
      perRideChoices: choices is List ? [for (final c in choices) ?_d(c)] : const [20, 50, 100, 200],
      womenDriversForChildren: _b(m['womenDriversForChildren'], true),
      locationRule: FamilyLocationRule.parse(m['locationRule']),
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'children': children,
    'maxMembers': maxMembers,
    'inviteDays': inviteDays,
    'aloneAge': aloneAge,
    'codeTries': codeTries,
    'monthCap': monthCap,
    'perRideChoices': perRideChoices,
    'womenDriversForChildren': womenDriversForChildren,
    'locationRule': locationRule.db,
  };
}

/// Why a place's values can't be saved, or null. Mirrors family_rules_valid.
String? familyRulesProblem(Map<String, dynamic> rules) {
  for (final e in rules.entries) {
    final lim = FamilySettings.limits[e.key];
    if (lim != null) {
      final v = e.value;
      if (v is! num || v < lim.$1 || v > lim.$2) return '${FamilySettings.labels[e.key]}: between ${lim.$1} and ${lim.$2}.';
    } else if (e.key == 'perRideChoices') {
      final v = e.value;
      if (v is! List || v.length > 10 || v.any((x) => x is! num || x < 1 || x > 100000)) {
        return 'Per-trip limits: up to 10, each from 1 to 100000.';
      }
    } else if (e.key == 'locationRule') {
      if (!const ['never', 'ride', 'always'].contains(e.value)) return 'Pick a location rule.';
    } else if (!FamilySettings.keys.contains(e.key) || e.value is! bool) {
      return 'Unknown value ${e.key}.';
    }
  }
  return null;
}

/// A row of family_places or family_module_rules: Default or a place.
class FamilyPlace {
  const FamilyPlace({this.level = 'default', this.country, this.state, this.city, this.suburb});
  final String level;
  final String? country, state, city, suburb;

  bool get isDefault => level == 'default';

  String get label => isDefault
      ? 'Default (everywhere)'
      : [country, state, city, suburb].whereType<String>().where((s) => s.trim().isNotEmpty).join(', ');

  /// As ride_option_place_key (0253): '' for Default, else the names in lower case.
  String get key {
    if (isDefault) return '';
    String n(String? v) => (v ?? '').trim().toLowerCase();
    return [
      n(country),
      if (const ['state', 'city', 'suburb'].contains(level)) n(state),
      if (const ['city', 'suburb'].contains(level)) n(city),
      if (level == 'suburb') n(suburb),
    ].join('|');
  }

  int get rank => switch (level) { 'default' => 0, 'country' => 1, 'state' => 2, 'city' => 3, _ => 4 };

  factory FamilyPlace.fromRow(Map<String, dynamic> m) => FamilyPlace(
    level: '${m['level'] ?? 'default'}',
    country: m['country'] as String?,
    state: m['state'] as String?,
    city: m['city'] as String?,
    suburb: m['suburb'] as String?,
  );

  Map<String, dynamic> toRow() => {
    'level': level,
    'country': isDefault ? null : country?.trim(),
    'state': const ['state', 'city', 'suburb'].contains(level) ? state?.trim() : null,
    'city': const ['city', 'suburb'].contains(level) ? city?.trim() : null,
    'suburb': level == 'suburb' ? suburb?.trim() : null,
  };
}

/// The keys from Default down to [g] (family_place_keys, 0317).
List<String> familyPlaceKeys(Geo g) {
  String n(String? v) => (v ?? '').trim().toLowerCase();
  final out = [''];
  final c = n(g.country), s = n(g.state), t = n(g.city), b = n(g.suburb);
  if (c.isEmpty) return out;
  out.add(c);
  if (s.isEmpty) return out;
  out.add('$c|$s');
  if (t.isEmpty) return out;
  out.add('$c|$s|$t');
  if (b.isEmpty) return out;
  out.add('$c|$s|$t|$b');
  return out;
}

/// A place's own values (only the keys it sets).
class FamilyPlaceRules {
  const FamilyPlaceRules({this.id, required this.place, this.rules = const {}});
  final String? id;
  final FamilyPlace place;
  final Map<String, dynamic> rules;

  factory FamilyPlaceRules.fromRow(Map<String, dynamic> m) => FamilyPlaceRules(
    id: m['id'] as String?,
    place: FamilyPlace.fromRow(m),
    rules: m['rules'] is Map ? Map<String, dynamic>.from(m['rules'] as Map) : const {},
  );

  Map<String, dynamic> toRow() => {...place.toRow(), 'rules': rules};
}

/// The values at [g]: Default's, then each smaller place's keys (family_settings_at).
FamilySettings resolveFamilySettings(List<FamilyPlaceRules> rows, Geo g) {
  final keys = familyPlaceKeys(g);
  final hits = rows.where((r) => keys.contains(r.place.key)).toList()
    ..sort((a, b) => a.place.rank.compareTo(b.place.rank));
  final merged = <String, dynamic>{...const FamilySettings().toJson()};
  for (final r in hits) {
    merged.addAll(r.rules);
  }
  return FamilySettings.fromJson(merged);
}

/// The four switches of a module (family_module_rule_at).
class FamilyModuleSwitches {
  const FamilyModuleSwitches({
    this.familyPays = false,
    this.bookForMember = false,
    this.childAllowed = false,
    this.liveShare = false,
  });
  final bool familyPays, bookForMember, childAllowed, liveShare;

  static const names = ['Family pays', 'Book for a member', 'Child', 'Live share'];

  List<bool> get list => [familyPays, bookForMember, childAllowed, liveShare];
}

/// A registered module with its switches at a place (family_modules_at).
class FamilyModule {
  const FamilyModule({required this.key, required this.name, this.switches = const FamilyModuleSwitches()});
  final String key;
  final String name;
  final FamilyModuleSwitches switches;

  factory FamilyModule.fromJson(Map<String, dynamic> m) => FamilyModule(
    key: '${m['key']}',
    name: _s(m['name']) ?? '${m['key']}',
    switches: FamilyModuleSwitches(
      familyPays: _b(m['familyPays']),
      bookForMember: _b(m['bookForMember']),
      childAllowed: _b(m['childAllowed']),
      liveShare: _b(m['liveShare']),
    ),
  );
}

/// One row of family_module_rules: a module at a place; null inherits.
class FamilyModuleRule {
  const FamilyModuleRule({
    this.id,
    required this.place,
    required this.moduleKey,
    this.familyPays,
    this.bookForMember,
    this.childAllowed,
    this.liveShare,
  });
  final String? id;
  final FamilyPlace place;
  final String moduleKey;
  final bool? familyPays, bookForMember, childAllowed, liveShare;

  List<bool?> get list => [familyPays, bookForMember, childAllowed, liveShare];

  FamilyModuleRule withSwitch(int i, bool? v) => FamilyModuleRule(
    id: id,
    place: place,
    moduleKey: moduleKey,
    familyPays: i == 0 ? v : familyPays,
    bookForMember: i == 1 ? v : bookForMember,
    childAllowed: i == 2 ? v : childAllowed,
    liveShare: i == 3 ? v : liveShare,
  );

  factory FamilyModuleRule.fromRow(Map<String, dynamic> m) => FamilyModuleRule(
    id: m['id'] as String?,
    place: FamilyPlace.fromRow(m),
    moduleKey: '${m['module_key']}',
    familyPays: m['family_pays'] as bool?,
    bookForMember: m['book_for_member'] as bool?,
    childAllowed: m['child_allowed'] as bool?,
    liveShare: m['live_share'] as bool?,
  );

  Map<String, dynamic> toRow() => {
    ...place.toRow(),
    'module_key': moduleKey,
    'family_pays': familyPays,
    'book_for_member': bookForMember,
    'child_allowed': childAllowed,
    'live_share': liveShare,
  };
}

/// A module's switches at [g]: each from the smallest place that sets it;
/// a module with no rule (a new one) is off.
FamilyModuleSwitches resolveModuleSwitches(List<FamilyModuleRule> rows, String module, Geo g) {
  final keys = familyPlaceKeys(g);
  final hits = rows.where((r) => r.moduleKey == module && keys.contains(r.place.key)).toList()
    ..sort((a, b) => a.place.rank.compareTo(b.place.rank));
  final v = [false, false, false, false];
  for (final r in hits) {
    final l = r.list;
    for (var i = 0; i < 4; i++) {
      if (l[i] != null) v[i] = l[i]!;
    }
  }
  return FamilyModuleSwitches(familyPays: v[0], bookForMember: v[1], childAllowed: v[2], liveShare: v[3]);
}

enum FamilyRole { host, member, none }

/// A member or child as the host (or the member themselves) reads them.
class FamilyMember {
  const FamilyMember({
    required this.id,
    required this.name,
    this.kind = 'member',
    this.status = 'active',
    this.relation,
    this.phone,
    this.birthDate,
    this.photoUrl,
    this.monthlyLimit,
    this.perRideLimit,
    this.services,
    this.location = FamilyLocationRule.ride,
    this.locationPending,
    this.locationNow = FamilyLocationRule.never,
    this.shareAlways = false,
    this.spent = 0,
    this.limit = 0,
    this.left = 0,
    this.expiresAt,
    this.onTrip = false,
  });

  final String id;
  final String name;
  final String kind;
  final String status;
  final String? relation;
  final String? phone;
  final DateTime? birthDate;
  final String? photoUrl;
  final double? monthlyLimit;
  final double? perRideLimit;

  /// The module keys the host allows; null: all the admin allows.
  final List<String>? services;

  /// The host's choice; [locationPending] a raise not yet accepted;
  /// [locationNow] what applies now (the server's family_location_rule).
  final FamilyLocationRule location;
  final FamilyLocationRule? locationPending;
  final FamilyLocationRule locationNow;
  final bool shareAlways;
  final double spent, limit, left;
  final DateTime? expiresAt;
  final bool onTrip;

  bool get isChild => kind == 'child';
  bool get isInvited => status == 'invited';
  bool get isActive => status == 'active';

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.first[0] + (parts.length > 1 ? parts[1][0] : '')).toUpperCase();
  }

  factory FamilyMember.fromJson(Map<String, dynamic> m) => FamilyMember(
    id: '${m['id']}',
    name: _s(m['name']) ?? 'Member',
    kind: _s(m['kind']) ?? 'member',
    status: _s(m['status']) ?? 'active',
    relation: _s(m['relation']),
    phone: _s(m['phone']),
    birthDate: m['birthDate'] is String ? DateTime.tryParse(m['birthDate'] as String) : null,
    photoUrl: _s(m['photoUrl']),
    monthlyLimit: _d(m['monthlyLimit']),
    perRideLimit: _d(m['perRideLimit']),
    services: m['services'] is List ? [for (final s in m['services'] as List) '$s'] : null,
    location: FamilyLocationRule.parse(m['location']),
    locationPending: m['locationPending'] == null ? null : FamilyLocationRule.parse(m['locationPending']),
    locationNow: FamilyLocationRule.parse(m['locationNow'] ?? 'never'),
    shareAlways: _b(m['shareAlways']),
    spent: _d(m['spent']) ?? 0,
    limit: _d(m['limit']) ?? 0,
    left: _d(m['left']) ?? 0,
    expiresAt: _t(m['expiresAt']),
    onTrip: _b(m['onTrip']),
  );
}

/// Whole years from [birth] to [now].
int childAge(DateTime birth, DateTime now) {
  var y = now.year - birth.year;
  if (now.month < birth.month || (now.month == birth.month && now.day < birth.day)) y--;
  return y;
}

/// The caller's family (family_mine).
class FamilyView {
  const FamilyView({
    this.role = FamilyRole.none,
    this.familyId,
    this.hostName,
    this.cap = 6,
    this.count = 0,
    this.spent = 0,
    this.capRequest,
    this.members = const [],
    this.me,
    this.settings = const FamilySettings(),
    this.modules = const [],
  });

  final FamilyRole role;
  final String? familyId;
  final String? hostName;
  final int cap;
  final int count;
  final double spent;

  /// The latest request for more members: {wanted, status, note}.
  final ({int wanted, String status, String? note})? capRequest;
  final List<FamilyMember> members;
  final FamilyMember? me;
  final FamilySettings settings;
  final List<FamilyModule> modules;

  bool get full => count >= cap;

  /// The modules the family pays on in this region.
  List<FamilyModule> get payModules => [for (final m in modules) if (m.switches.familyPays) m];

  factory FamilyView.fromJson(Object? json) {
    final m = json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{};
    final f = m['family'] is Map ? Map<String, dynamic>.from(m['family'] as Map) : null;
    final req = f?['capRequest'] is Map ? Map<String, dynamic>.from(f!['capRequest'] as Map) : null;
    return FamilyView(
      role: switch (m['role']) { 'host' => FamilyRole.host, 'member' => FamilyRole.member, _ => FamilyRole.none },
      familyId: f?['id'] as String?,
      hostName: _s(f?['hostName']),
      cap: _i(f?['cap']) ?? FamilySettings.fromJson(m['settings']).maxMembers,
      count: _i(f?['count']) ?? 0,
      spent: _d(f?['spent']) ?? 0,
      capRequest: req == null
          ? null
          : (wanted: _i(req['wanted']) ?? 0, status: _s(req['status']) ?? 'pending', note: _s(req['note'])),
      members: [
        if (m['members'] is List)
          for (final x in m['members'] as List)
            if (x is Map) FamilyMember.fromJson(Map<String, dynamic>.from(x)),
      ],
      me: m['me'] is Map ? FamilyMember.fromJson(Map<String, dynamic>.from(m['me'] as Map)) : null,
      settings: FamilySettings.fromJson(m['settings']),
      modules: [
        if (m['modules'] is List)
          for (final x in m['modules'] as List)
            if (x is Map) FamilyModule.fromJson(Map<String, dynamic>.from(x)),
      ],
    );
  }
}

/// An invitation the caller can join (family_my_invites).
class FamilyInvite {
  const FamilyInvite({
    required this.member,
    required this.hostName,
    this.adminLocationRule = FamilyLocationRule.ride,
    this.modules = const [],
  });
  final FamilyMember member;
  final String hostName;
  final FamilyLocationRule adminLocationRule;
  final List<String> modules;

  factory FamilyInvite.fromJson(Map<String, dynamic> m) => FamilyInvite(
    member: FamilyMember.fromJson(m),
    hostName: _s(m['hostName']) ?? 'Someone',
    adminLocationRule: FamilyLocationRule.parse(m['adminLocationRule']),
    modules: [if (m['modules'] is List) for (final x in m['modules'] as List) '$x'],
  );

  /// What applies once joined: the host's choice, at most the admin's rule.
  FamilyLocationRule get location => member.location.atMost(adminLocationRule);
}

/// "a, b and c".
String familyList(List<String> items) => switch (items.length) {
  0 => '',
  1 => items.first,
  _ => '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}',
};

/// "Karpal's" (or "James'").
String possessive(String name) {
  final n = name.trim().split(RegExp(r'\s+')).first;
  return n.endsWith('s') ? "$n'" : "$n's";
}

/// The plain terms an invitee reads before Join (icon name, words): what the
/// family pays, what the host sees, that they can always see who can see
/// them, and that they can leave at once.
List<(String, String)> familyJoinTerms(FamilyInvite i, String Function(num) money) {
  final host = i.hostName.trim().split(RegExp(r'\s+')).first;
  final limit = i.member.monthlyLimit;
  final perTrip = i.member.perRideLimit;
  final services = i.modules.isEmpty ? 'no services yet' : familyList(i.modules);
  final pays = StringBuffer("You can pay with ${possessive(i.hostName)} GET.wallet");
  if (limit != null) pays.write(', up to ${money(limit)} a month');
  if (perTrip != null) pays.write(' and ${money(perTrip)} a trip');
  pays.write(', for $services.');
  final where = switch (i.location) {
    FamilyLocationRule.never => '$host doesn\'t see your location. $host sees the trips the family pays for.',
    FamilyLocationRule.ride => '$host sees your location while you are on a ride the family covers, and those trips. '
        'A "Shared with family" chip shows whenever this is on.',
    FamilyLocationRule.always => '$host sees your location while you are on a ride, and at other times only if you '
        'turn on Share with family. A "Shared with family" chip shows whenever this is on.',
  };
  return [
    ('payments', pays.toString()),
    ('location_on', where),
    ('visibility', 'You can always see who can see you. Nobody can watch you without you knowing.'),
    ('logout', 'You can leave at any time; sharing stops at once.'),
  ];
}

/// The payment row's label: "Family · Karpal's GET.wallet".
String familyPayLabel(String hostName) => 'Family · ${possessive(hostName)} GET.wallet';

/// The Family row of a booking screen (family_pay_option).
class FamilyPayOption {
  const FamilyPayOption({required this.available, required this.hostName, this.left, this.code, this.message});
  final bool available;
  final String hostName;
  final double? left;
  final String? code;
  final String? message;

  String get label => familyPayLabel(hostName);

  static FamilyPayOption? fromJson(Object? json) {
    if (json is! Map) return null;
    return FamilyPayOption(
      available: _b(json['available']),
      hostName: _s(json['hostName']) ?? 'Family host',
      left: _d(json['left']),
      code: _s(json['code']),
      message: _s(json['message']),
    );
  }

  String note(String Function(num) money) =>
      available ? '${money(left ?? 0)} left this month for you' : (message ?? 'Not allowed for this service');
}

/// A booking screen's payment list with the Family row first, while the
/// family pays on this module for the caller (the member's own trip).
List<PaymentChoice> withFamilyPayment(List<PaymentChoice> base, FamilyPayOption? o) => o == null || !o.available
    ? base
    : [PaymentChoice(familyPaymentMode, o.label, PaymentKind.wallet), ...base.where((c) => c.value != familyPaymentMode)];

/// Someone the host may book for (family_passengers).
class FamilyPassenger {
  const FamilyPassenger({
    required this.id,
    required this.name,
    this.kind = 'member',
    this.phone,
    this.age,
    this.allowed = false,
    this.needsAdult = false,
    this.code,
    this.message,
  });
  final String id;
  final String name;
  final String kind;
  final String? phone;
  final int? age;
  final bool allowed;
  final bool needsAdult;
  final String? code;
  final String? message;

  bool get isChild => kind == 'child';

  factory FamilyPassenger.fromJson(Map<String, dynamic> m) => FamilyPassenger(
    id: '${m['id']}',
    name: _s(m['name']) ?? 'Member',
    kind: _s(m['kind']) ?? 'member',
    phone: _s(m['phone']),
    age: _i(m['age']),
    allowed: _b(m['allowed']),
    needsAdult: _b(m['needsAdult']),
    code: _s(m['code']),
    message: _s(m['message']),
  );

  /// The chip's words.
  String get label => isChild ? '$name (child)' : name;
}

/// The host's pick of who rides in the family: a member or child, and
/// whether an adult rides along (a child under the age to ride alone).
typedef FamilyPick = ({String id, bool withAdult});

/// The booking's `family` column (0317): who it is for in the family.
Map<String, dynamic> familyBookingColumns({String? passengerId, bool withAdult = false}) => passengerId == null
    ? const {}
    : {
        'family': {'passenger': passengerId, if (withAdult) 'withAdult': true},
      };

/// A trip's Family state for its screen (family_trip_status).
class FamilyTripStatus {
  const FamilyTripStatus({
    this.family = false,
    this.child = false,
    this.familyPays = false,
    this.payer,
    this.shared = false,
    this.left,
    this.viewers = const [],
  });
  final bool family;
  final bool child;
  final bool familyPays;
  final String? payer;

  /// The host can see this trip now: the chip shows exactly then.
  final bool shared;
  final double? left;
  final List<({String name, String what})> viewers;

  factory FamilyTripStatus.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return FamilyTripStatus(
      family: _b(m['family']),
      child: _b(m['child']),
      familyPays: _b(m['familyPays']),
      payer: _s(m['payer']),
      shared: _b(m['shared']),
      left: _d(m['left']),
      viewers: [
        if (m['viewers'] is List)
          for (final v in m['viewers'] as List)
            if (v is Map) (name: _s(v['name']) ?? 'Family host', what: _s(v['what']) ?? ''),
      ],
    );
  }
}

/// "Who can see this ride": the family viewers, then the safety team's
/// logged access (the only other way, never hidden).
List<String> whoCanSeeLines(FamilyTripStatus s) => [
  for (final v in s.viewers) '${v.name} (family host): ${v.what.isEmpty ? 'live location' : v.what.toLowerCase()}.',
  'GET.ride safety team: only when they open it for a report or SOS; every look is logged and you can ask to see the log.',
];

/// One member the host may see now (family_live).
class FamilyLiveItem {
  const FamilyLiveItem({required this.memberId, required this.name, this.kind = 'member', this.trip, this.status,
      this.pickup, this.drop, this.driver, this.plate, this.lat, this.lng, this.at, this.area});
  final String memberId;
  final String name;
  final String kind;
  final String? trip, status, pickup, drop, driver, plate, area;
  final double? lat, lng;
  final DateTime? at;

  factory FamilyLiveItem.fromJson(Map<String, dynamic> m) => FamilyLiveItem(
    memberId: '${m['memberId']}',
    name: _s(m['name']) ?? 'Member',
    kind: _s(m['kind']) ?? 'member',
    trip: _s(m['trip']),
    status: _s(m['status']),
    pickup: _s(m['pickup']),
    drop: _s(m['drop']),
    driver: _s(m['driver']),
    plate: _s(m['plate']),
    lat: _d(m['lat']),
    lng: _d(m['lng']),
    at: _t(m['at']),
    area: _s(m['area']),
  );

  String get line {
    if (trip != null) {
      final route = [pickup, drop].whereType<String>().join(' to ');
      return 'On a ride${route.isEmpty ? '' : ' · $route'}';
    }
    return area == null ? 'Sharing location' : 'Near $area';
  }
}

/// A pickup code as the driver types it.
bool isPickupCode(String s) => RegExp(r'^\d{4}$').hasMatch(s.trim());

/// The child's check for the driver (family_driver_child).
class FamilyChildCheck {
  const FamilyChildCheck({
    required this.name,
    this.age,
    this.photoUrl,
    this.bookedBy = 'Parent',
    this.relation,
    this.withAdult = false,
    this.verified = false,
    this.locked = false,
    this.triesLeft = 3,
  });
  final String name;
  final int? age;
  final String? photoUrl;
  final String bookedBy;
  final String? relation;
  final bool withAdult;
  final bool verified;
  final bool locked;
  final int triesLeft;

  static FamilyChildCheck? fromJson(Object? json) {
    if (json is! Map) return null;
    return FamilyChildCheck(
      name: _s(json['name']) ?? 'Child',
      age: _i(json['age']),
      photoUrl: _s(json['photoUrl']),
      bookedBy: _s(json['bookedBy']) ?? 'Parent',
      relation: _s(json['relation']),
      withAdult: _b(json['withAdult']),
      verified: _b(json['verified']),
      locked: _b(json['locked']),
      triesLeft: _i(json['triesLeft']) ?? 0,
    );
  }

  String get first => name.trim().split(RegExp(r'\s+')).first;

  /// The driver's line above the code boxes.
  String get intro =>
      '${age == null ? name : '$name, $age'}, booked by $bookedBy. Check the photo and ask for the 4-digit code '
      'before ${withAdult ? 'they get in (an adult rides along)' : 'they get in'}.';
}

/// The host's view of a child's code (family_child_code).
class FamilyChildCode {
  const FamilyChildCode({required this.code, this.verified = false, this.locked = false, this.triesLeft = 3, this.name});
  final String code;
  final bool verified;
  final bool locked;
  final int triesLeft;
  final String? name;

  static FamilyChildCode? fromJson(Object? json) {
    if (json is! Map || json['code'] is! String) return null;
    return FamilyChildCode(
      code: json['code'] as String,
      verified: _b(json['verified']),
      locked: _b(json['locked']),
      triesLeft: _i(json['triesLeft']) ?? 0,
      name: _s(json['name']),
    );
  }

  /// "4 8 2 7".
  String get spaced => code.split('').join(' ');
}

/// A refusal from a family function: its code and the words for the person.
class FamilyException implements Exception {
  const FamilyException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// The refusal for a server error's [message] (its code) and [hint] (the
/// server's words), or null when it is not a family refusal.
FamilyException? familyRefusal(String? message, String? hint) {
  final m = message ?? '';
  for (final e in _familyWords.entries) {
    if (m.contains(e.key)) {
      final h = hint?.trim();
      return FamilyException(e.key, h != null && h.isNotEmpty && h != 'null' ? h : e.value);
    }
  }
  return null;
}

/// What the host or a member reads when the server refuses.
String familyProblem(Object error) {
  if (error is FamilyException) return error.message;
  final s = '$error';
  for (final e in _familyWords.entries) {
    if (s.contains(e.key)) return e.value;
  }
  if (s.contains('not_authorized')) return 'Sign in again to do this.';
  return 'That didn\'t work. Please try again.';
}

const _familyWords = {
    'FAMILY_NOT_MEMBER': 'You are not in a family that pays for you.',
    'FAMILY_OFF': 'Family isn\'t available in your area.',
    'FAMILY_MODULE_OFF': 'Family payment isn\'t available for this service.',
    'FAMILY_SERVICE_NOT_ALLOWED': 'Your family doesn\'t cover this service.',
    'FAMILY_RIDE_LIMIT': 'This is over the family limit for one trip.',
    'FAMILY_LIMIT_REACHED': 'The family limit for this month doesn\'t cover this.',
    'FAMILY_NOT_HOST': 'Only the family host books for family members.',
    'FAMILY_BOOK_FOR_OFF': 'Booking for a family member isn\'t available for this service.',
    'FAMILY_CHILD_NOT_ALLOWED': 'Children can\'t be booked on this service.',
    'FAMILY_CHILD_TOO_YOUNG': 'This child rides with an adult.',
    'FAMILY_CHILDREN_OFF': 'Rides for children aren\'t available in your area.',
    'FAMILY_ONLY_FOR_MEMBER': 'Family payment is for a member\'s own trip.',
    'FAMILY_WOMEN_DRIVERS_ONLY': 'This is a child\'s trip: only women drivers take it.',
    'FAMILY_PICKUP_CODE_NEEDED': 'Enter the child\'s pickup code to start the trip.',
    'FAMILY_FULL': 'Your family is full. Ask for more members.',
    'FAMILY_ALREADY_INVITED': 'This number is already in your family.',
    'FAMILY_ALREADY_MEMBER': 'You are already in a family. Leave it first.',
    'FAMILY_CANT_INVITE': 'This number can\'t be invited.',
    'FAMILY_INVITE_GONE': 'This invitation has ended.',
    'FAMILY_MONTH_CAP': 'That monthly limit is higher than your area allows.',
    'FAMILY_PER_RIDE_CHOICE': 'Pick one of the per-trip limits offered.',
    'FAMILY_LOCATION_NOT_ALLOWED': 'Your area doesn\'t allow that much location sharing.',
    'FAMILY_BAD_PHONE': 'Enter their phone number.',
    'FAMILY_NAME_NEEDED': 'Enter a name.',
    'FAMILY_CHILD_AGE': 'A child is under 18. Invite an adult by phone.',
    'FAMILY_CAP_WANTED': 'Ask for more members than you have now.',
    'FAMILY_REASON_NEEDED': 'Give the reason, in at least 10 characters.',
    'FAMILY_CODE_USED': 'The child was already picked up.',
    'FAMILY_NOT_FAMILY_TRIP': 'The family doesn\'t pay for this trip.',
    'FAMILY_GONE': 'This family no longer exists.',
    'FAMILY_REQUEST_GONE': 'This request was already decided.',
    'FAMILY_UNKNOWN_SERVICE': 'Pick services from the list.',
    'FAMILY_FIXED': 'Who the trip is for can\'t be changed.',
};

/// The host's line under a member's name.
String familyMemberLine(FamilyMember m, String Function(num) money, DateTime now) {
  if (m.isInvited) {
    final left = m.expiresAt?.difference(now);
    if (left == null) return 'Invited';
    if (left.isNegative) return 'Invite expired';
    final days = left.inDays;
    return days == 0 ? 'Invited · expires today' : 'Invited · expires in $days day${days == 1 ? '' : 's'}';
  }
  if (m.status == 'expired') return 'Invite expired';
  if (m.isChild) return m.onTrip ? 'On a ride now' : 'Child profile · you book their rides';
  if (m.onTrip) return 'On a ride · shared with you';
  return '${money(m.spent)} of ${money(m.limit)} this month';
}

/// A row of the admin's family list (family_admin_list).
class FamilyAdminRow {
  const FamilyAdminRow({
    required this.id,
    required this.hostName,
    this.hostPhone,
    this.place = '',
    this.cap = 6,
    this.capOwn,
    this.count = 0,
    this.children = 0,
    this.pending = 0,
  });
  final String id;
  final String hostName;
  final String? hostPhone;
  final String place;
  final int cap;
  final int? capOwn;
  final int count;
  final int children;
  final int pending;

  factory FamilyAdminRow.fromJson(Map<String, dynamic> m) {
    final p = m['place'] is Map ? m['place'] as Map : const {};
    return FamilyAdminRow(
      id: '${m['id']}',
      hostName: _s(m['hostName']) ?? 'Host',
      hostPhone: _s(m['hostPhone']),
      place: [p['city'], p['state'], p['country']].whereType<String>().where((s) => s.isNotEmpty).join(', '),
      cap: _i(m['cap']) ?? 6,
      capOwn: _i(m['capOwn']),
      count: _i(m['count']) ?? 0,
      children: _i(m['children']) ?? 0,
      pending: _i(m['pending']) ?? 0,
    );
  }
}

/// A host's request for more members (family_admin_requests).
class FamilyCapRequest {
  const FamilyCapRequest({required this.id, required this.familyId, required this.hostName, this.cap = 6,
      this.count = 0, this.wanted = 0, this.reason, this.status = 'pending'});
  final String id, familyId, hostName;
  final int cap, count, wanted;
  final String? reason;
  final String status;

  factory FamilyCapRequest.fromJson(Map<String, dynamic> m) => FamilyCapRequest(
    id: '${m['id']}',
    familyId: '${m['familyId']}',
    hostName: _s(m['hostName']) ?? 'Host',
    cap: _i(m['cap']) ?? 6,
    count: _i(m['count']) ?? 0,
    wanted: _i(m['wanted']) ?? 0,
    reason: _s(m['reason']),
    status: _s(m['status']) ?? 'pending',
  );
}

/// One admin look at a family (family_view_log / family_my_view_log).
class FamilyViewLogEntry {
  const FamilyViewLogEntry({required this.at, required this.kind, required this.reason, this.by, this.hostName});
  final DateTime? at;
  final String kind;
  final String reason;
  final String? by;
  final String? hostName;

  factory FamilyViewLogEntry.fromJson(Map<String, dynamic> m) => FamilyViewLogEntry(
    at: _t(m['at']),
    kind: _s(m['kind']) ?? 'support',
    reason: _s(m['reason']) ?? '',
    by: _s(m['admin']) ?? _s(m['by']),
    hostName: _s(m['hostName']),
  );
}

/// The reasons an admin can give for a logged look.
const familyViewReasons = {
  'report': 'A report',
  'sos': 'An SOS',
  'legal': 'A legal request',
  'support': 'Support',
};

/// Whether an admin's reason is enough (family_admin_view).
bool familyReasonOk(String kind, String reason) =>
    familyViewReasons.containsKey(kind) && reason.trim().length >= 10;
