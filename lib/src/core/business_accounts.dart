/// Business accounts (migration 0313): companies whose staff book on the
/// company. The settings an account works with (a Default rule, rules per
/// region of the company's registered address, the account's own
/// overrides), its members and rules, the "Business: (company)" payment,
/// what the server's refusals say, and an invoice as CSV. The resolution is
/// the server's `business_rule_settings` / `business_settings_for`, tested
/// on the same cases (test/business_accounts_test.dart,
/// supabase/tests/business_accounts_0313.sql). Pure.
library;

import 'payment_types.dart';

/// Admin › People › Business accounts: the page an admin is granted.
const businessAccountsPage = 'admin-business-accounts';

double? _numOrNull(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
double _num(Object? v) => _numOrNull(v) ?? 0;
int? _intOrNull(Object? v) => _numOrNull(v)?.round();
String _s(Object? v) => v is String ? v.trim() : (v == null ? '' : '$v'.trim());
bool _b(Object? v) => v == true || v == 'true';

/// "RM 4,812.40", "RM 500".
String businessMoney(num v) {
  final neg = v < 0;
  final cents = (v.abs() * 100).round();
  final whole = cents ~/ 100;
  final frac = cents % 100;
  final digits = '$whole';
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return '${neg ? '-' : ''}RM $out${frac == 0 ? '' : '.${frac.toString().padLeft(2, '0')}'}';
}

/// "RM 4,812.40" always with cents (invoices).
String businessMoneyCents(num v) {
  final s = businessMoney(v);
  return s.contains('.') ? s : '$s.00';
}

enum BusinessRole {
  admin('Admin', 'Manages members, rules and invoices; books anything allowed'),
  booker('Booker', 'Books for themselves and for others'),
  rider('Rider', 'Books rides for themselves');

  const BusinessRole(this.label, this.help);
  final String label;
  final String help;

  static BusinessRole parse(Object? raw) =>
      values.firstWhere((r) => r.name == raw, orElse: () => BusinessRole.rider);
}

enum BusinessTerms {
  wallet('Prepaid wallet'),
  invoice('Monthly invoice');

  const BusinessTerms(this.label);
  final String label;

  static BusinessTerms? parse(Object? raw) => switch (raw) {
    'wallet' => wallet,
    'invoice' => invoice,
    _ => null,
  };
}

/// What a business may book: the server's kinds.
enum BusinessService {
  ride('City rides'),
  scheduled('Scheduled rides'),
  freight('Freight'),
  courier('Courier');

  const BusinessService(this.label);
  final String label;

  static BusinessService? parse(Object? raw) {
    for (final s in values) {
      if (s.name == raw) return s;
    }
    return null;
  }
}

Set<BusinessService>? _services(Object? raw) => raw is List
    ? {for (final s in raw) ?BusinessService.parse(s)}
    : null;

/// The values a rule sets (null: follows the rule above it), as stored.
class BusinessValues {
  const BusinessValues({
    this.creditLimit,
    this.dueDays,
    this.overdueDays,
    this.discountPct,
    this.commissionPct,
    this.memberLimit,
    this.terms,
    this.services,
  });

  /// From a business_region_rules or business_accounts row (snake case).
  factory BusinessValues.fromRow(Map<String, dynamic> r) => BusinessValues(
    creditLimit: _numOrNull(r['credit_limit']),
    dueDays: _intOrNull(r['due_days']),
    overdueDays: _intOrNull(r['overdue_days']),
    discountPct: _numOrNull(r['discount_pct']),
    commissionPct: _numOrNull(r['commission_pct']),
    memberLimit: _numOrNull(r['member_limit']),
    terms: BusinessTerms.parse(r['terms']),
    services: _services(r['services']),
  );

  /// From the server's settings JSON (camel case).
  factory BusinessValues.fromJson(Object? raw) {
    final r = raw is Map ? raw : const {};
    return BusinessValues(
      creditLimit: _numOrNull(r['creditLimit']),
      dueDays: _intOrNull(r['dueDays']),
      overdueDays: _intOrNull(r['overdueDays']),
      discountPct: _numOrNull(r['discountPct']),
      commissionPct: _numOrNull(r['commissionPct']),
      memberLimit: _numOrNull(r['memberLimit']),
      terms: BusinessTerms.parse(r['terms']),
      services: _services(r['services']),
    );
  }

  final double? creditLimit;
  final int? dueDays;
  final int? overdueDays;
  final double? discountPct;
  final double? commissionPct;

  /// 0: no limit.
  final double? memberLimit;
  final BusinessTerms? terms;
  final Set<BusinessService>? services;

  /// Each value set here, over [under].
  BusinessValues over(BusinessValues under) => BusinessValues(
    creditLimit: creditLimit ?? under.creditLimit,
    dueDays: dueDays ?? under.dueDays,
    overdueDays: overdueDays ?? under.overdueDays,
    discountPct: discountPct ?? under.discountPct,
    commissionPct: commissionPct ?? under.commissionPct,
    memberLimit: memberLimit ?? under.memberLimit,
    terms: terms ?? under.terms,
    services: services ?? under.services,
  );

  bool get isComplete =>
      creditLimit != null &&
      dueDays != null &&
      overdueDays != null &&
      discountPct != null &&
      commissionPct != null &&
      memberLimit != null &&
      terms != null &&
      services != null;

  bool get isEmpty =>
      creditLimit == null &&
      dueDays == null &&
      overdueDays == null &&
      discountPct == null &&
      commissionPct == null &&
      memberLimit == null &&
      terms == null &&
      services == null;

  /// As a business_region_rules row's value columns (null clears).
  Map<String, dynamic> toRow() => {
    'credit_limit': creditLimit,
    'due_days': dueDays,
    'overdue_days': overdueDays,
    'discount_pct': discountPct,
    'commission_pct': commissionPct,
    'member_limit': memberLimit,
    'terms': terms?.name,
    'services': services == null ? null : [for (final s in BusinessService.values) if (services!.contains(s)) s.name],
  };

  /// As admin_business_save's keys (every key given; null follows the rules).
  Map<String, dynamic> toOverrides() => {
    'creditLimit': creditLimit,
    'dueDays': dueDays,
    'overdueDays': overdueDays,
    'discountPct': discountPct,
    'commissionPct': commissionPct,
    'memberLimit': memberLimit,
    'terms': terms?.name,
    'services': services == null ? null : [for (final s in BusinessService.values) if (services!.contains(s)) s.name],
  };

  BusinessValues copyWithField(BusinessField f, Object? v) => BusinessValues(
    creditLimit: f == BusinessField.creditLimit ? v as double? : creditLimit,
    dueDays: f == BusinessField.dueDays ? v as int? : dueDays,
    overdueDays: f == BusinessField.overdueDays ? v as int? : overdueDays,
    discountPct: f == BusinessField.discountPct ? v as double? : discountPct,
    commissionPct: f == BusinessField.commissionPct ? v as double? : commissionPct,
    memberLimit: f == BusinessField.memberLimit ? v as double? : memberLimit,
    terms: f == BusinessField.terms ? v as BusinessTerms? : terms,
    services: f == BusinessField.services ? v as Set<BusinessService>? : services,
  );

  Object? valueOf(BusinessField f) => switch (f) {
    BusinessField.creditLimit => creditLimit,
    BusinessField.dueDays => dueDays,
    BusinessField.overdueDays => overdueDays,
    BusinessField.discountPct => discountPct,
    BusinessField.commissionPct => commissionPct,
    BusinessField.memberLimit => memberLimit,
    BusinessField.terms => terms,
    BusinessField.services => services,
  };

  @override
  bool operator ==(Object other) => other is BusinessValues && '${other.toRow()}' == '${toRow()}';

  @override
  int get hashCode => '${toRow()}'.hashCode;
}

/// The values a rule or an account can set, with their steppers.
enum BusinessField {
  creditLimit('Starting credit limit', 1000, 0, 100000000),
  dueDays('Invoice due after', 1, 0, 365),
  overdueDays('Pause bookings when overdue by', 1, 1, 365),
  discountPct('Business discount', 1, 0, 90),
  commissionPct('Commission on business trips', 1, 0, 90),
  memberLimit('Default member monthly limit', 100, 0, 100000000),
  terms('Payment terms', 0, 0, 0),
  services('Services allowed', 0, 0, 0);

  const BusinessField(this.label, this.step, this.min, this.max);
  final String label;
  final num step;
  final num min;
  final num max;

  bool get isNumber => step > 0;

  /// [v] as it reads on the page.
  String show(Object? v) => switch (this) {
    _ when v == null => 'Follows the rule above',
    BusinessField.creditLimit => businessMoney(v as num),
    BusinessField.memberLimit => (v as num) == 0 ? 'No limit' : businessMoney(v),
    BusinessField.dueDays || BusinessField.overdueDays => '$v days',
    BusinessField.discountPct || BusinessField.commissionPct => '${_trim(v as num)}%',
    BusinessField.terms => (v as BusinessTerms).label,
    BusinessField.services => (v as Set<BusinessService>).isEmpty
        ? 'None'
        : [for (final s in BusinessService.values) if (v.contains(s)) s.label].join(', '),
  };

  /// One step up or down from [v] (or from [from] when [v] is null), within bounds.
  Object stepped(Object? v, int dir, {Object? from}) {
    final cur = (v ?? from ?? min) as num;
    final next = (cur + dir * step).clamp(min, max);
    return switch (this) {
      BusinessField.dueDays || BusinessField.overdueDays => next.round(),
      _ => next.toDouble(),
    };
  }
}

String _trim(num v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);

/// A Default or region rule (business_region_rules).
class BusinessRegionRule {
  const BusinessRegionRule({
    this.id,
    this.country = '',
    this.state = '',
    this.city = '',
    this.values = const BusinessValues(),
    this.active = true,
    this.position = 0,
  });

  factory BusinessRegionRule.fromRow(Map<String, dynamic> r) => BusinessRegionRule(
    id: r['id'] as String?,
    country: _s(r['country']),
    state: _s(r['state']),
    city: _s(r['city']),
    values: BusinessValues.fromRow(r),
    active: r['active'] != false,
    position: _intOrNull(r['position']) ?? 0,
  );

  final String? id;
  final String country, state, city;
  final BusinessValues values;
  final bool active;
  final int position;

  bool get isDefault => country.isEmpty;

  /// 0 for the Default, 3 for a city.
  int get rank => country.isEmpty ? 0 : (state.isEmpty ? 1 : (city.isEmpty ? 2 : 3));

  /// "Default", "Sabah", "Kota Kinabalu, Sabah".
  String get name => isDefault ? 'Default' : [city, state, country].where((s) => s.isNotEmpty).take(2).join(', ');

  bool matches(String country, String state, String city) =>
      isDefault ||
      (active &&
          regionNameNorm(this.country) == regionNameNorm(country) &&
          (this.state.isEmpty || regionNameNorm(this.state) == regionNameNorm(state)) &&
          (this.city.isEmpty || regionNameNorm(this.city) == regionNameNorm(city)));

  BusinessRegionRule copyWith({BusinessValues? values, bool? active, String? country, String? state, String? city}) =>
      BusinessRegionRule(
        id: id,
        country: country ?? this.country,
        state: state ?? this.state,
        city: city ?? this.city,
        values: values ?? this.values,
        active: active ?? this.active,
        position: position,
      );

  Map<String, dynamic> toRow() => {
    'country': country,
    'state': state,
    'city': city,
    ...values.toRow(),
    'active': active,
    'position': position,
  };
}

/// As the server's region_name_norm (0126): lower case, punctuation as
/// spaces, the words for a council or a federal territory left out.
String regionNameNorm(String s) {
  var v = s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ');
  v = v.replaceAll(
    RegExp(
      r'\b(municipal council|city council|district council|town council|municipality|majlis perbandaran|majlis bandaraya|majlis daerah|wilayah persekutuan|federal territory of|federal territory|district|daerah|city of)\b',
    ),
    ' ',
  );
  return v.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The rules for a company registered at [country] / [state] / [city]: the
/// Default, then each matching rule from the widest to the narrowest (the
/// lower position wins between two of the same level), each setting what it
/// sets; then the account's [overrides]. As `business_settings_for`.
BusinessValues resolveBusinessValues(
  List<BusinessRegionRule> rules, {
  required String country,
  String state = '',
  String city = '',
  BusinessValues overrides = const BusinessValues(),
}) {
  final ordered = [...rules]..sort((a, b) {
    final r = a.rank.compareTo(b.rank);
    return r != 0 ? r : b.position.compareTo(a.position);
  });
  var v = const BusinessValues();
  for (final r in ordered) {
    if (r.matches(country, state, city)) v = r.values.over(v);
  }
  return overrides.over(v);
}

/// The rule [rules] give a region's own settings: what the rules above it
/// say (for "Follows the rule above").
BusinessValues businessValuesAbove(List<BusinessRegionRule> rules, BusinessRegionRule rule) {
  if (rule.isDefault) return const BusinessValues();
  final above = [
    for (final r in rules)
      if (r.rank < rule.rank && r.id != rule.id) r,
  ];
  return resolveBusinessValues(above, country: rule.country, state: rule.state, city: rule.city);
}

// ---- Accounts as members see them ------------------------------------------------------------

/// One of the caller's accounts or invitations (business_my_accounts).
class BusinessMembership {
  const BusinessMembership({
    required this.accountId,
    required this.name,
    this.status = 'active',
    this.role = BusinessRole.rider,
    this.memberStatus = 'active',
    this.team,
    this.myLimit = 0,
    this.mySpend = 0,
    this.noteRequired = false,
    this.services = const {...BusinessService.values},
    this.bookersFreight = true,
    this.statusNote,
  });

  factory BusinessMembership.fromJson(Map<String, dynamic> j) => BusinessMembership(
    accountId: '${j['id']}',
    name: _s(j['name']),
    status: _s(j['status']),
    statusNote: j['statusNote'] as String?,
    role: BusinessRole.parse(j['role']),
    memberStatus: _s(j['memberStatus']),
    team: j['team'] as String?,
    myLimit: _num(j['myLimit']),
    mySpend: _num(j['mySpend']),
    noteRequired: _b(j['noteRequired']),
    services: _services(j['services']) ?? const {},
    bookersFreight: j['bookersFreight'] != false,
  );

  final String accountId;
  final String name;

  /// pending, active, suspended.
  final String status;
  final String? statusNote;
  final BusinessRole role;

  /// invited or active.
  final String memberStatus;
  final String? team;
  final double myLimit;
  final double mySpend;
  final bool noteRequired;
  final Set<BusinessService> services;
  final bool bookersFreight;

  bool get invited => memberStatus == 'invited';
  bool get canBook => status == 'active' && memberStatus == 'active';

  /// Whether this member may book [kind] on it (the server checks again).
  bool allows(BusinessService kind) {
    if (!canBook || !services.contains(kind)) return false;
    if (kind == BusinessService.freight || kind == BusinessService.courier) {
      return role == BusinessRole.admin || (role == BusinessRole.booker && bookersFreight);
    }
    return true;
  }
}

/// The payment value of a business account: `business:` and its id.
const businessPaymentPrefix = 'business:';

String businessPaymentValue(String accountId) => '$businessPaymentPrefix$accountId';

/// The account a payment value names; null for any other payment.
String? businessAccountIdOf(String? payment) {
  final p = payment?.trim() ?? '';
  if (!p.startsWith(businessPaymentPrefix)) return null;
  final id = p.substring(businessPaymentPrefix.length).trim();
  return id.isEmpty ? null : id;
}

/// "Business: Contoh Trading": the stored payment_mode, as the driver sees it.
String businessPaymentLabel(String name) => 'Business: $name';

/// The "Business: (company)" choices for [kind]: the accounts the member
/// may book it on.
List<PaymentChoice> businessPaymentChoices(List<BusinessMembership> accounts, BusinessService kind) => [
  for (final a in accounts)
    if (a.allows(kind)) PaymentChoice(businessPaymentValue(a.accountId), businessPaymentLabel(a.name), PaymentKind.business),
];

/// The account [payment] names among [accounts], or null.
BusinessMembership? businessAccountFor(String? payment, List<BusinessMembership> accounts) {
  final id = businessAccountIdOf(payment);
  if (id == null) return null;
  for (final a in accounts) {
    if (a.accountId == id) return a;
  }
  return null;
}

/// What business_booking_check answers.
class BusinessCheck {
  const BusinessCheck({
    required this.ok,
    this.code,
    this.message,
    this.needsNote = false,
    this.needsApproval = false,
    this.approvalPending = false,
  });

  factory BusinessCheck.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    return BusinessCheck(
      ok: _b(j['ok']),
      code: j['code'] as String?,
      message: j['message'] as String?,
      needsNote: _b(j['needsNote']),
      needsApproval: _b(j['needsApproval']),
      approvalPending: _b(j['approvalPending']),
    );
  }

  final bool ok;
  final String? code;
  final String? message;
  final bool needsNote;
  final bool needsApproval;
  final bool approvalPending;
}

/// Whether [error] is the server refusing a business booking (BUSINESS_…).
bool isBusinessRefusal(Object error) => '$error'.contains('BUSINESS_');

// ---- One account, as its members see it ---------------------------------------------------------

class BusinessRules {
  const BusinessRules({
    this.hoursOn = false,
    this.hoursFrom = 7,
    this.hoursUntil = 22,
    this.noteRequired = false,
    this.approvalOn = false,
    this.approvalOver = 50,
    this.capOn = false,
    this.monthlyCap = 8000,
    this.bookersFreight = true,
  });

  factory BusinessRules.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    return BusinessRules(
      hoursOn: _b(j['hoursOn']),
      hoursFrom: _intOrNull(j['hoursFrom']) ?? 7,
      hoursUntil: _intOrNull(j['hoursUntil']) ?? 22,
      noteRequired: _b(j['noteRequired']),
      approvalOn: _b(j['approvalOn']),
      approvalOver: _numOrNull(j['approvalOver']) ?? 50,
      capOn: _b(j['capOn']),
      monthlyCap: _numOrNull(j['monthlyCap']) ?? 8000,
      bookersFreight: j['bookersFreight'] != false,
    );
  }

  final bool hoursOn;
  final int hoursFrom;
  final int hoursUntil;
  final bool noteRequired;
  final bool approvalOn;
  final double approvalOver;
  final bool capOn;
  final double monthlyCap;
  final bool bookersFreight;

  BusinessRules copyWith({
    bool? hoursOn,
    int? hoursFrom,
    int? hoursUntil,
    bool? noteRequired,
    bool? approvalOn,
    double? approvalOver,
    bool? capOn,
    double? monthlyCap,
    bool? bookersFreight,
  }) => BusinessRules(
    hoursOn: hoursOn ?? this.hoursOn,
    hoursFrom: hoursFrom ?? this.hoursFrom,
    hoursUntil: hoursUntil ?? this.hoursUntil,
    noteRequired: noteRequired ?? this.noteRequired,
    approvalOn: approvalOn ?? this.approvalOn,
    approvalOver: approvalOver ?? this.approvalOver,
    capOn: capOn ?? this.capOn,
    monthlyCap: monthlyCap ?? this.monthlyCap,
    bookersFreight: bookersFreight ?? this.bookersFreight,
  );

  /// The hours must differ (from 7 until 22; may run past midnight).
  String? get problem => hoursFrom == hoursUntil % 24 ? 'Pick different hours for from and until.' : null;

  Map<String, dynamic> toJson() => {
    'hoursOn': hoursOn,
    'hoursFrom': hoursFrom,
    'hoursUntil': hoursUntil,
    'noteRequired': noteRequired,
    'approvalOn': approvalOn,
    'approvalOver': approvalOver,
    'capOn': capOn,
    'monthlyCap': monthlyCap,
    'bookersFreight': bookersFreight,
  };

  @override
  bool operator ==(Object other) => other is BusinessRules && '${other.toJson()}' == '${toJson()}';

  @override
  int get hashCode => '${toJson()}'.hashCode;
}

/// "07:00".
String businessHour(int h) => '${h.toString().padLeft(2, '0')}:00';

class BusinessMember {
  const BusinessMember({
    required this.id,
    required this.phone,
    this.name,
    this.role = BusinessRole.rider,
    this.team,
    this.monthlyLimit,
    this.status = 'active',
    this.spend = 0,
  });

  factory BusinessMember.fromJson(Map<String, dynamic> j) => BusinessMember(
    id: '${j['id']}',
    phone: _s(j['phone']),
    name: j['name'] as String?,
    role: BusinessRole.parse(j['role']),
    team: j['team'] as String?,
    monthlyLimit: _numOrNull(j['monthlyLimit']),
    status: _s(j['status']),
    spend: _num(j['spend']),
  );

  final String id;
  final String phone;
  final String? name;
  final BusinessRole role;
  final String? team;

  /// Null: the account's default; 0: no limit.
  final double? monthlyLimit;
  final String status;
  final double spend;

  String get display => (name ?? '').trim().isEmpty ? phone : name!.trim();

  /// "RM 500 / month", "No limit", "Default (RM 500 / month)".
  String limitLabel(double defaultLimit) {
    String one(double v) => v <= 0 ? 'No limit' : '${businessMoney(v)} / month';
    return monthlyLimit == null ? 'Default (${one(defaultLimit)})' : one(monthlyLimit!);
  }
}

class BusinessInvoice {
  const BusinessInvoice({
    required this.id,
    required this.invoiceNo,
    required this.periodStart,
    required this.status,
    this.terms = BusinessTerms.invoice,
    this.amount = 0,
    this.gross = 0,
    this.discount = 0,
    this.trips = 0,
    this.dueDate,
    this.paidAt,
    this.periodEnd,
    this.accountId,
    this.accountName,
  });

  factory BusinessInvoice.fromJson(Map<String, dynamic> j) => BusinessInvoice(
    id: '${j['id']}',
    invoiceNo: _s(j['invoice_no']),
    periodStart: DateTime.tryParse('${j['period_start']}') ?? DateTime(2000),
    periodEnd: DateTime.tryParse('${j['period_end']}'),
    status: _s(j['status']),
    terms: BusinessTerms.parse(j['terms']) ?? BusinessTerms.invoice,
    amount: _num(j['amount']),
    gross: _num(j['gross']),
    discount: _num(j['discount']),
    trips: _intOrNull(j['trips']) ?? 0,
    dueDate: DateTime.tryParse('${j['due_date']}'),
    paidAt: DateTime.tryParse('${j['paid_at']}')?.toLocal(),
    accountId: j['account_id'] as String?,
    accountName: (j['business_accounts'] is Map ? (j['business_accounts'] as Map)['name'] : null) as String?,
  );

  final String id;
  final String invoiceNo;
  final DateTime periodStart;
  final DateTime? periodEnd;

  /// open, issued, paid, void.
  final String status;
  final BusinessTerms terms;
  final double amount;
  final double gross;
  final double discount;
  final int trips;
  final DateTime? dueDate;
  final DateTime? paidAt;
  final String? accountId;
  final String? accountName;

  /// "October 2026".
  String get monthLabel => '${_months[periodStart.month - 1]} ${periodStart.year}';

  bool overdue(DateTime today) =>
      status == 'issued' && dueDate != null && DateTime(today.year, today.month, today.day).isAfter(dueDate!);

  /// "Open", "Due 30 Nov", "Overdue since 30 Nov", "Paid 28 Sep".
  String statusLabel(DateTime today) => switch (status) {
    'open' => 'Open',
    'issued' when overdue(today) => 'Overdue since ${shortDate(dueDate!)}',
    'issued' => dueDate == null ? 'Issued' : 'Due ${shortDate(dueDate!)}',
    'paid' when terms == BusinessTerms.wallet => 'Prepaid',
    'paid' => paidAt == null ? 'Paid' : 'Paid ${shortDate(paidAt!)}',
    'void' => 'Cancelled',
    _ => status,
  };

  /// "RM 4,812.40 (so far)" while the month runs.
  String get amountLabel => '${businessMoneyCents(amount)}${status == 'open' ? ' (so far)' : ''}';
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "28 Sep".
String shortDate(DateTime d) => '${d.day} ${_months[d.month - 1].substring(0, 3)}';

class BusinessApproval {
  const BusinessApproval({
    required this.id,
    required this.member,
    required this.amount,
    required this.status,
    this.service,
    this.pickup,
    this.dropoff,
    this.note,
  });

  factory BusinessApproval.fromJson(Map<String, dynamic> j) => BusinessApproval(
    id: '${j['id']}',
    member: _s(j['member']),
    amount: _num(j['amount']),
    status: _s(j['status']),
    service: j['service'] as String?,
    pickup: j['pickup'] as String?,
    dropoff: j['dropoff'] as String?,
    note: j['note'] as String?,
  );

  final String id;
  final String member;
  final double amount;
  final String status;
  final String? service;
  final String? pickup;
  final String? dropoff;
  final String? note;
}

/// One account (business_account_detail).
class BusinessAccountDetail {
  const BusinessAccountDetail({
    required this.id,
    required this.name,
    this.regNo = '',
    this.status = 'active',
    this.statusNote,
    this.role,
    this.isAdmin = false,
    this.settings = const BusinessValues(),
    this.pausedBy,
    this.monthSpend = 0,
    this.monthTrips = 0,
    this.monthDeliveries = 0,
    this.mySpend = 0,
    this.myLimit = 0,
    this.nextInvoice,
    this.walletBalance = 0,
    this.rules = const BusinessRules(),
    this.members = const [],
    this.invoices = const [],
    this.approvals = const [],
  });

  factory BusinessAccountDetail.fromJson(Map<String, dynamic> j) => BusinessAccountDetail(
    id: '${j['id']}',
    name: _s(j['name']),
    regNo: _s(j['regNo']),
    status: _s(j['status']),
    statusNote: j['statusNote'] as String?,
    role: j['role'] == null ? null : BusinessRole.parse(j['role']),
    isAdmin: _b(j['isAdmin']),
    settings: BusinessValues.fromJson(j['settings']),
    pausedBy: j['pausedBy'] as String?,
    monthSpend: _num(j['monthSpend']),
    monthTrips: _intOrNull(j['monthTrips']) ?? 0,
    monthDeliveries: _intOrNull(j['monthDeliveries']) ?? 0,
    mySpend: _num(j['mySpend']),
    myLimit: _num(j['myLimit']),
    nextInvoice: DateTime.tryParse('${j['nextInvoice']}'),
    walletBalance: _num(j['walletBalance']),
    rules: BusinessRules.fromJson(j['rules']),
    members: [
      if (j['members'] is List)
        for (final m in j['members'] as List)
          if (m is Map) BusinessMember.fromJson(Map<String, dynamic>.from(m)),
    ],
    invoices: [
      if (j['invoices'] is List)
        for (final m in j['invoices'] as List)
          if (m is Map) BusinessInvoice.fromJson(Map<String, dynamic>.from(m)),
    ],
    approvals: [
      if (j['approvals'] is List)
        for (final m in j['approvals'] as List)
          if (m is Map) BusinessApproval.fromJson(Map<String, dynamic>.from(m)),
    ],
  );

  final String id;
  final String name;
  final String regNo;
  final String status;
  final String? statusNote;
  final BusinessRole? role;
  final bool isAdmin;
  final BusinessValues settings;

  /// The overdue invoice pausing bookings, when there is one.
  final String? pausedBy;
  final double monthSpend;
  final int monthTrips;
  final int monthDeliveries;
  final double mySpend;
  final double myLimit;
  final DateTime? nextInvoice;
  final double walletBalance;
  final BusinessRules rules;
  final List<BusinessMember> members;
  final List<BusinessInvoice> invoices;
  final List<BusinessApproval> approvals;

  BusinessTerms get terms => settings.terms ?? BusinessTerms.invoice;

  /// "63 trips · 41 deliveries".
  String get monthCounts => '$monthTrips ${monthTrips == 1 ? 'trip' : 'trips'} · '
      '$monthDeliveries ${monthDeliveries == 1 ? 'delivery' : 'deliveries'}';

  /// "Due in 30 days", or the wallet's balance.
  String get termsLine => terms == BusinessTerms.wallet
      ? 'Prepaid wallet ${businessMoneyCents(walletBalance)}'
      : 'Due in ${settings.dueDays ?? 30} days';
}

// ---- Invoices as files ---------------------------------------------------------------------------

/// One trip on an invoice (business_invoice_lines).
class BusinessInvoiceLine {
  const BusinessInvoiceLine({
    required this.at,
    this.member = '',
    this.team = '',
    this.bookedFor = '',
    this.service = '',
    this.pickup = '',
    this.dropoff = '',
    this.note = '',
    this.gross = 0,
    this.discount = 0,
    this.charged = 0,
  });

  factory BusinessInvoiceLine.fromJson(Map<String, dynamic> j) => BusinessInvoiceLine(
    at: DateTime.tryParse('${j['at']}')?.toLocal() ?? DateTime(2000),
    member: _s(j['member']),
    team: _s(j['team']),
    bookedFor: _s(j['for']),
    service: _s(j['service']),
    pickup: _s(j['pickup']),
    dropoff: _s(j['dropoff']),
    note: _s(j['note']),
    gross: _num(j['gross']),
    discount: _num(j['discount']),
    charged: _num(j['charged']),
  );

  final DateTime at;
  final String member, team, bookedFor, service, pickup, dropoff, note;
  final double gross, discount, charged;
}

/// An invoice with its company and trips, for the PDF and CSV.
class BusinessInvoiceFile {
  const BusinessInvoiceFile({
    required this.invoice,
    required this.companyName,
    this.regNo = '',
    this.address = '',
    this.lines = const [],
  });

  factory BusinessInvoiceFile.fromJson(Map<String, dynamic> j) {
    final a = j['account'] is Map ? Map<String, dynamic>.from(j['account'] as Map) : <String, dynamic>{};
    return BusinessInvoiceFile(
      invoice: BusinessInvoice.fromJson(j['invoice'] is Map ? Map<String, dynamic>.from(j['invoice'] as Map) : {}),
      companyName: _s(a['name']),
      regNo: _s(a['regNo']),
      address: [_s(a['address']), _s(a['state']), _s(a['country'])].where((s) => s.isNotEmpty).join(', '),
      lines: [
        if (j['lines'] is List)
          for (final l in j['lines'] as List)
            if (l is Map) BusinessInvoiceLine.fromJson(Map<String, dynamic>.from(l)),
      ],
    );
  }

  final BusinessInvoice invoice;
  final String companyName;
  final String regNo;
  final String address;
  final List<BusinessInvoiceLine> lines;

  String get fileStem => 'get-ride-${invoice.invoiceNo}';
}

String _two(int v) => v.toString().padLeft(2, '0');

/// "2026-10-03 14:05".
String businessStamp(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

String _csvCell(String s) => RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;

/// The invoice's trips as CSV (a header, one row a trip, the total last).
String businessInvoiceCsv(BusinessInvoiceFile f) {
  final rows = <List<String>>[
    ['Date', 'Member', 'Team', 'Passenger', 'Service', 'Pickup', 'Drop-off', 'Note', 'Fare (RM)', 'Discount (RM)', 'Charged (RM)'],
    for (final l in f.lines)
      [
        businessStamp(l.at),
        l.member,
        l.team,
        l.bookedFor,
        l.service,
        l.pickup,
        l.dropoff,
        l.note,
        l.gross.toStringAsFixed(2),
        l.discount.toStringAsFixed(2),
        l.charged.toStringAsFixed(2),
      ],
    [
      'Total',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      f.lines.fold<double>(0, (s, l) => s + l.gross).toStringAsFixed(2),
      f.lines.fold<double>(0, (s, l) => s + l.discount).toStringAsFixed(2),
      f.lines.fold<double>(0, (s, l) => s + l.charged).toStringAsFixed(2),
    ],
  ];
  return '${rows.map((r) => r.map(_csvCell).join(',')).join('\r\n')}\r\n';
}

/// Malaysia's states and federal territories, for the registered address.
const malaysiaStates = [
  'Johor', 'Kedah', 'Kelantan', 'Kuala Lumpur', 'Labuan', 'Melaka', 'Negeri Sembilan', 'Pahang',
  'Penang', 'Perak', 'Perlis', 'Putrajaya', 'Sabah', 'Sarawak', 'Selangor', 'Terengganu',
];
