/// Partner statements and the Earnings page (migration 0201): the totals the
/// server works out for a period (one calculation for both, so the page and
/// the PDF never disagree), the periods a statement covers, and the admin's
/// settings. Days and weeks are Malaysia's (UTC+8), as the server counts
/// them. Pure.
library;

import 'package:flutter/foundation.dart' show listEquals;

import 'driver_earnings.dart' show EarningsPeriod;

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

/// One period's totals, as `partner_statement_totals` returns them.
class StatementTotals {
  const StatementTotals(this._v);

  factory StatementTotals.fromJson(Object? json) =>
      StatementTotals(json is Map ? Map<String, dynamic>.from(json) : const {});

  static const zero = StatementTotals({});

  final Map<String, dynamic> _v;

  double _d(String k) => _num(_v[k]);

  int get trips => _d('trips').round();

  /// Of [trips], the meter / TEKSI hires (0224).
  int get meterTrips => _d('meterTrips').round();

  // Earnings.
  double get fares => _d('fare');

  /// The surcharges an admin counts as earnings.
  double get surcharges => _d('surcharges');

  /// Scheduling and late-cancel fees the driver collected for GET.ride.
  double get feesCollected => _d('platformCollected');
  double get incentives => _d('incentives');
  double get handoverIn => _d('handoverIn');

  /// Tips riders gave in the app, as they reached the driver (0314).
  double get tips => _d('tips');
  double get totalEarnings => _d('totalEarnings');

  /// Cash tips the driver marked, for the Earnings page only (0314): not in
  /// the totals, and never on the statement.
  double get cashTips => _d('cashTips');
  int get cashTipCount => _d('cashTipCount').round();

  // Deductions.
  double get commission => _d('commission');
  double get platformFees => _d('platformFees');
  double get handoverOut => _d('handoverOut');
  double get totalDeductions => _d('totalDeductions');

  double get adjustments => _d('adjustments');
  double get net => _d('net');

  // Collected for others: not income.
  double get taxes => _d('taxes');
  double get tolls => _d('tolls');
  double get otherCharges => _d('otherCharges');
  double get otherSurcharges => _d('surchargesPass');
  double get passThrough => _d('passThrough');

  // How riders paid, and activity.
  double get cash => _d('cash');
  double get coins => _d('coins');
  double get onlineHours => _d('onlineHours');
  double get distanceKm => _d('distanceKm');
}

/// One bucket of `my_earnings_series`: its first day and totals.
class EarningsBucket {
  const EarningsBucket(this.start, this.totals);

  factory EarningsBucket.fromRow(Map<String, dynamic> r) =>
      EarningsBucket(DateTime.parse('${r['bucket_start']}'), StatementTotals.fromJson(r['totals']));

  /// The bucket's first day (a date, no time).
  final DateTime start;
  final StatementTotals totals;
}

/// Admin → Settings → Partner statements.
class StatementSettings {
  const StatementSettings({
    this.weekStartsSunday = false,
    this.earningSurcharges = const [],
    this.showBank = false,
    this.companyName = '',
    this.companySsm = '',
    this.supportContact = '',
    this.verifyUrl = '',
  });

  factory StatementSettings.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return StatementSettings(
      weekStartsSunday: m['weekStart'] == 'sunday',
      earningSurcharges: [
        for (final n in (m['earningSurcharges'] is List ? m['earningSurcharges'] as List : const []))
          if ('$n'.trim().isNotEmpty) '$n'.trim(),
      ],
      showBank: m['showBank'] == true,
      companyName: '${m['companyName'] ?? ''}',
      companySsm: '${m['companySsm'] ?? ''}',
      supportContact: '${m['supportContact'] ?? ''}',
      verifyUrl: '${m['verifyUrl'] ?? ''}',
    );
  }

  final bool weekStartsSunday;
  final List<String> earningSurcharges;
  final bool showBank;
  final String companyName;
  final String companySsm;
  final String supportContact;
  final String verifyUrl;

  Map<String, dynamic> toJson() => {
    'weekStart': weekStartsSunday ? 'sunday' : 'monday',
    'earningSurcharges': earningSurcharges,
    'showBank': showBank,
    'companyName': companyName.trim(),
    'companySsm': companySsm.trim(),
    'supportContact': supportContact.trim(),
    'verifyUrl': verifyUrl.trim(),
  };

  StatementSettings copyWith({
    bool? weekStartsSunday,
    List<String>? earningSurcharges,
    bool? showBank,
    String? companyName,
    String? companySsm,
    String? supportContact,
    String? verifyUrl,
  }) => StatementSettings(
    weekStartsSunday: weekStartsSunday ?? this.weekStartsSunday,
    earningSurcharges: earningSurcharges ?? this.earningSurcharges,
    showBank: showBank ?? this.showBank,
    companyName: companyName ?? this.companyName,
    companySsm: companySsm ?? this.companySsm,
    supportContact: supportContact ?? this.supportContact,
    verifyUrl: verifyUrl ?? this.verifyUrl,
  );

  @override
  bool operator ==(Object other) =>
      other is StatementSettings &&
      other.weekStartsSunday == weekStartsSunday &&
      listEquals(other.earningSurcharges, earningSurcharges) &&
      other.showBank == showBank &&
      other.companyName == companyName &&
      other.companySsm == companySsm &&
      other.supportContact == supportContact &&
      other.verifyUrl == verifyUrl;

  @override
  int get hashCode => Object.hash(
    weekStartsSunday,
    Object.hashAll(earningSurcharges),
    showBank,
    companyName,
    companySsm,
    supportContact,
    verifyUrl,
  );
}

// ---- Malaysia time ---------------------------------------------------------------------------
const _myt = Duration(hours: 8);

/// Today's date in Malaysia (a UTC date with no time) for the instant [now].
DateTime malaysiaDate(DateTime now) {
  final t = now.toUtc().add(_myt);
  return DateTime.utc(t.year, t.month, t.day);
}

/// The instant Malaysia's day [date] starts.
DateTime malaysiaMidnight(DateTime date) => DateTime.utc(date.year, date.month, date.day).subtract(_myt);

/// The first day of [date]'s week: Monday, or Sunday when the admin says so.
DateTime statementWeekStart(DateTime date, {bool sunday = false}) {
  final back = sunday ? date.weekday % 7 : date.weekday - DateTime.monday;
  return DateTime.utc(date.year, date.month, date.day - back);
}

/// The Earnings page's period as instants: from its first moment up to now.
({DateTime from, DateTime to}) earningsRange(EarningsPeriod period, DateTime now, {bool sunday = false}) {
  final today = malaysiaDate(now);
  final start = switch (period) {
    EarningsPeriod.today => today,
    EarningsPeriod.week => statementWeekStart(today, sunday: sunday),
    EarningsPeriod.month => DateTime.utc(today.year, today.month),
  };
  // Up to the end of today, so a trip completed a moment ago is never cut off by clock drift.
  return (from: malaysiaMidnight(start), to: malaysiaMidnight(today.add(const Duration(days: 1))));
}

/// The chart's last [weeks] weeks as instants.
({DateTime from, DateTime to}) earningsWeeksRange(DateTime now, {int weeks = 8, bool sunday = false}) {
  final today = malaysiaDate(now);
  final first = statementWeekStart(today, sunday: sunday).subtract(Duration(days: 7 * (weeks - 1)));
  return (from: malaysiaMidnight(first), to: malaysiaMidnight(today.add(const Duration(days: 1))));
}

// ---- Statements ------------------------------------------------------------------------------
enum StatementType {
  weekly('Weekly'),
  monthly('Monthly'),
  annual('Annual');

  const StatementType(this.label);
  final String label;
}

enum StatementLang {
  en('English'),
  ms('Bahasa Melayu');

  const StatementLang(this.label);
  final String label;

  static StatementLang parse(String? s) => s == 'ms' ? StatementLang.ms : StatementLang.en;
}

enum StatementStatus {
  provisional('Provisional'),
  finalised('Final'),
  revised('Revised');

  const StatementStatus(this.label);
  final String label;

  static StatementStatus parse(Object? s, {Object? revisedAt}) => switch ('$s') {
    _ when revisedAt != null => StatementStatus.revised,
    'revised' => StatementStatus.revised,
    'final' => StatementStatus.finalised,
    _ => StatementStatus.provisional,
  };
}

String _two(int n) => n.toString().padLeft(2, '0');

/// `2026-09-07`.
String isoDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// One row of the statements list (`my_statement_periods`).
class StatementPeriod {
  const StatementPeriod({
    required this.type,
    required this.start,
    required this.end,
    required this.status,
    required this.net,
    required this.trips,
  });

  factory StatementPeriod.fromRow(StatementType type, Map<String, dynamic> r) => StatementPeriod(
    type: type,
    start: DateTime.parse('${r['period_start']}'),
    end: DateTime.parse('${r['period_end']}'),
    status: StatementStatus.parse(r['status'], revisedAt: r['revised_at']),
    net: _num(r['net']),
    trips: _num(r['trips']).round(),
  );

  final StatementType type;
  final DateTime start;
  final DateTime end;
  final StatementStatus status;
  final double net;
  final int trips;

  /// "7 – 13 Sep 2026", "Sep 2026", "2026".
  String get label => switch (type) {
    StatementType.annual => '${start.year}',
    StatementType.monthly => '${_months[start.month - 1]} ${start.year}',
    StatementType.weekly =>
      start.month == end.month
          ? '${start.day} – ${end.day} ${_months[end.month - 1]} ${end.year}'
          : '${start.day} ${_months[start.month - 1]} – ${end.day} ${_months[end.month - 1]} ${end.year}',
  };

  /// Where a downloaded copy is kept on the device.
  String cacheName(StatementLang lang) => 'statement-${type.name}-${isoDate(start)}-${lang.name}.pdf';
}

/// January to April: the season for Borang B/BE, when the previous year's
/// annual statement is pinned at the top. The year to pin, else null.
int? taxSeasonYear(DateTime now) {
  final today = malaysiaDate(now);
  return today.month <= 4 ? today.year - 1 : null;
}

/// What `partner-statement` hands back.
class StatementDownload {
  const StatementDownload({
    required this.url,
    required this.fileName,
    required this.statementNo,
    required this.status,
    this.revisedAt,
  });

  factory StatementDownload.fromJson(Map<String, dynamic> m) => StatementDownload(
    url: '${m['url'] ?? ''}',
    fileName: '${m['fileName'] ?? 'statement.pdf'}',
    statementNo: '${m['statementNo'] ?? ''}',
    status: StatementStatus.parse(m['status']),
    revisedAt: DateTime.tryParse('${m['revisedAt'] ?? ''}'),
  );

  final String url;
  final String fileName;
  final String statementNo;
  final StatementStatus status;
  final DateTime? revisedAt;
}

/// The function's or the database's refusal, in words.
String statementErrorMessage(Object? error, {int? status}) => switch (status) {
  429 => 'You\'ve downloaded a lot of statements this hour. Try again later.',
  401 || 403 => 'Statements are for approved drivers.',
  _ when error is String && error.trim().isNotEmpty => error.trim(),
  _ => 'Couldn\'t get the statement. Check your connection and try again.',
};

/// What the verification page (`getride.my/verify/<token>`) shows.
class StatementVerification {
  const StatementVerification({
    required this.statementNo,
    required this.initials,
    required this.type,
    required this.start,
    required this.end,
    required this.net,
    required this.isFinal,
    this.revisedAt,
    this.issuedAt,
  });

  static StatementVerification? fromJson(Object? json) {
    if (json is! Map || json['statementNo'] == null) return null;
    return StatementVerification(
      statementNo: '${json['statementNo']}',
      initials: '${json['initials'] ?? ''}',
      type: StatementType.values.firstWhere((t) => t.name == json['type'], orElse: () => StatementType.weekly),
      start: DateTime.parse('${json['periodStart']}'),
      end: DateTime.parse('${json['periodEnd']}'),
      net: _num(json['net']),
      isFinal: json['final'] == true,
      revisedAt: DateTime.tryParse('${json['revisedAt'] ?? ''}'),
      issuedAt: DateTime.tryParse('${json['issuedAt'] ?? ''}'),
    );
  }

  final String statementNo;
  final String initials;
  final StatementType type;
  final DateTime start;
  final DateTime end;
  final double net;
  final bool isFinal;
  final DateTime? revisedAt;
  final DateTime? issuedAt;

  StatementPeriod get period => StatementPeriod(
    type: type,
    start: start,
    end: end,
    status: revisedAt != null
        ? StatementStatus.revised
        : isFinal
        ? StatementStatus.finalised
        : StatementStatus.provisional,
    net: net,
    trips: 0,
  );
}

/// A verify token is 24 hex characters; anything else isn't worth asking about.
bool isStatementToken(String s) => RegExp(r'^[0-9a-f]{24}$').hasMatch(s.trim());

/// A payout account as the driver typed it: digits only, 6 to 20 of them.
String? payoutAccountError(String account) {
  final digits = account.replaceAll(RegExp(r'[\s-]'), '');
  return RegExp(r'^\d{6,20}$').hasMatch(digits) ? null : 'Enter the 6 to 20 digit account number.';
}
