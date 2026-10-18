// Commission settings and tiers (migration 0218): whether GET.credit may go
// below zero and how far, what commission is charged on (the fare, plus the
// surcharges, tolls and other charges ticked), the meter / TEKSI switch, and
// tiers that lower the rate for drivers who reach a number of trips, fare
// earnings or online hours over 7 or 30 days, or a rating.
import 'package:flutter/foundation.dart';

@immutable
class CommissionConfig {
  const CommissionConfig({
    this.allowNegativeCredit = true,
    this.negativeLimit = 0,
    this.baseSurcharges = const [],
    this.baseTolls = false,
    this.baseOtherCharges = false,
    this.meterCommission = false,
  });

  factory CommissionConfig.fromJson(Object? raw) {
    final m = raw is Map ? raw : const {};
    final limit = m['negativeLimit'];
    return CommissionConfig(
      allowNegativeCredit: m['allowNegativeCredit'] != false,
      negativeLimit: limit is num ? limit.toDouble() : double.tryParse('${limit ?? ''}') ?? 0,
      baseSurcharges: [
        for (final n in (m['baseSurcharges'] is List ? m['baseSurcharges'] as List : const []))
          if ('$n'.trim().isNotEmpty) '$n'.trim(),
      ],
      baseTolls: m['baseTolls'] == true,
      baseOtherCharges: m['baseOtherCharges'] == true,
      meterCommission: m['meterCommission'] == true,
    );
  }

  /// False: a driver below RM 0 can't take work until they top up.
  final bool allowNegativeCredit;

  /// How far below zero (RM) when allowed; 0 is no limit.
  final double negativeLimit;

  /// Surcharge names commission is also charged on.
  final List<String> baseSurcharges;
  final bool baseTolls;
  final bool baseOtherCharges;
  final bool meterCommission;

  /// The lowest balance a driver may take work at; null when there is none.
  double? get creditFloor => !allowNegativeCredit ? 0 : (negativeLimit > 0 ? -negativeLimit : null);

  CommissionConfig copyWith({
    bool? allowNegativeCredit,
    double? negativeLimit,
    List<String>? baseSurcharges,
    bool? baseTolls,
    bool? baseOtherCharges,
    bool? meterCommission,
  }) => CommissionConfig(
    allowNegativeCredit: allowNegativeCredit ?? this.allowNegativeCredit,
    negativeLimit: negativeLimit ?? this.negativeLimit,
    baseSurcharges: baseSurcharges ?? this.baseSurcharges,
    baseTolls: baseTolls ?? this.baseTolls,
    baseOtherCharges: baseOtherCharges ?? this.baseOtherCharges,
    meterCommission: meterCommission ?? this.meterCommission,
  );

  Map<String, dynamic> toJson() => {
    'allowNegativeCredit': allowNegativeCredit,
    'negativeLimit': negativeLimit,
    'baseSurcharges': baseSurcharges,
    'baseTolls': baseTolls,
    'baseOtherCharges': baseOtherCharges,
    'meterCommission': meterCommission,
  };

  @override
  bool operator ==(Object other) =>
      other is CommissionConfig &&
      other.allowNegativeCredit == allowNegativeCredit &&
      other.negativeLimit == negativeLimit &&
      setEquals(other.baseSurcharges.toSet(), baseSurcharges.toSet()) &&
      other.baseTolls == baseTolls &&
      other.baseOtherCharges == baseOtherCharges &&
      other.meterCommission == meterCommission;

  @override
  int get hashCode => Object.hash(allowNegativeCredit, negativeLimit, Object.hashAllUnordered(baseSurcharges),
      baseTolls, baseOtherCharges, meterCommission);
}

/// What a tier measures.
enum TierMetric {
  trips('Completed trips', windowed: true),
  earnings('Fare earnings (RM)', windowed: true),
  onlineHours('Hours online', windowed: true, dbName: 'online_hours'),
  rating('Rating (stars)', windowed: false);

  const TierMetric(this.label, {required this.windowed, this.dbName});
  final String label;

  /// Counted over the last 7 or 30 days (a rating is as it stands).
  final bool windowed;
  /// The database's name for it, where it differs.
  final String? dbName;
  String get db => dbName ?? name;

  static TierMetric parse(Object? s) =>
      values.firstWhere((m) => m.db == s, orElse: () => TierMetric.trips);
}

@immutable
class CommissionTier {
  const CommissionTier({
    this.id,
    required this.name,
    this.active = true,
    this.metric = TierMetric.trips,
    this.windowDays = 7,
    required this.threshold,
    this.adjust = 'rate',
    required this.value,
    this.note = '',
    this.position = 0,
  });

  factory CommissionTier.fromRow(Map<String, dynamic> r) {
    double n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
    return CommissionTier(
      id: r['id'] as String?,
      name: '${r['name'] ?? ''}',
      active: r['active'] != false,
      metric: TierMetric.parse(r['metric']),
      windowDays: (r['window_days'] as num?)?.toInt() == 30 ? 30 : 7,
      threshold: n(r['threshold']),
      adjust: r['adjust'] == 'minus' ? 'minus' : 'rate',
      value: n(r['value']),
      note: '${r['note'] ?? ''}',
      position: (r['position'] as num?)?.toInt() ?? 0,
    );
  }

  final String? id;
  final String name;
  final bool active;
  final TierMetric metric;

  /// 7 or 30.
  final int windowDays;
  final double threshold;

  /// rate: the rate is at most [value]; minus: [value] comes off the rate.
  final String adjust;

  /// A fraction (0.10 is 10%).
  final double value;
  final String note;
  final int position;

  /// [rate] for a driver who meets this tier. Pure; mirrors commission_apply_tiers.
  double apply(double rate) => adjust == 'rate' ? (value < rate ? value : rate) : (rate - value < 0 ? 0 : rate - value);

  /// "10+ completed trips in 7 days", "Rating 4.8+".
  String get condition {
    final t = threshold == threshold.roundToDouble() ? threshold.toStringAsFixed(0) : threshold.toString();
    return switch (metric) {
      TierMetric.rating => 'Rating $t+',
      TierMetric.earnings => 'RM $t+ fare earnings in $windowDays days',
      TierMetric.onlineHours => '$t+ hours online in $windowDays days',
      TierMetric.trips => '$t+ completed trips in $windowDays days',
    };
  }

  /// "At most 10%", "2% off".
  String get effect {
    final pct = (value * 100).toStringAsFixed(value * 100 % 1 == 0 ? 0 : 2);
    return adjust == 'rate' ? 'At most $pct%' : '$pct% off the rate';
  }

  Map<String, dynamic> toRow() => {
    'id': ?id,
    'name': name.trim(),
    'active': active,
    'metric': metric.db,
    'window_days': windowDays,
    'threshold': threshold,
    'adjust': adjust,
    'value': value,
    'note': note.trim().isEmpty ? null : note.trim(),
    'position': position,
  };

  CommissionTier copyWith({bool? active, int? position}) => CommissionTier(
    id: id,
    name: name,
    active: active ?? this.active,
    metric: metric,
    windowDays: windowDays,
    threshold: threshold,
    adjust: adjust,
    value: value,
    note: note,
    position: position ?? this.position,
  );
}

/// The rate a driver pays given the tiers they meet: the lowest. A personal
/// (level "user") rate is not lowered. Pure; mirrors commission_apply_tiers.
({double rate, CommissionTier? tier}) applyCommissionTiers(double rate, String level, Iterable<CommissionTier> met) {
  if (level == 'user') return (rate: rate, tier: null);
  var best = rate;
  CommissionTier? tier;
  for (final t in met.where((t) => t.active)) {
    final r = t.apply(rate);
    if (r < best) {
      best = r;
      tier = t;
    }
  }
  return (rate: best, tier: tier);
}
