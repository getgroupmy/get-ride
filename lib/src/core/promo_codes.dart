// Rider promo codes (migration 0242).
//
// A code takes a fixed amount (RM) or a percentage (optionally capped) off
// the fare. The admin sets its limits (uses in total and per rider, a budget,
// a minimum fare), when it runs (from / to, a date range, a daily window that
// may run past midnight, weekdays, on Malaysia's clock), where (regions, about
// the pickup, the drop-off or both), who (genders, listed riders, first ride
// only), which services, and whether it applies by itself.
//
// The server decides everything: the rider's app asks which codes apply
// (promo_offers), checks a typed one (promo_check) and books with the code's
// id; the database checks it again and settles it when the trip completes in
// full, crediting the discount to the driver's GET.wallet.
import 'package:flutter/foundation.dart';

import 'commission_promotions.dart' show parseTimeOfDay, timeOfDayLabel;

double? _numOrNull(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
double _num(Object? v) => _numOrNull(v) ?? 0;
int? _intOrNull(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toUtc();
DateTime? _date(Object? v) {
  final d = v == null ? null : DateTime.tryParse('$v');
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "RM5.00".
String promoMoney(num? v) => 'RM${(v ?? 0).toStringAsFixed(2)}';

/// A code as the server takes it: upper case, letters, digits, - and _.
String normalizePromoCode(String v) => v.trim().toUpperCase();

/// Whether [v] could be a code (2–32 of A–Z, 0–9, - and _).
bool isPromoCodeShape(String v) => RegExp(r'^[A-Z0-9_-]{2,32}$').hasMatch(normalizePromoCode(v));

enum PromoDiscountType {
  fixed('fixed'),
  percent('percent');

  const PromoDiscountType(this.db);
  final String db;
  static PromoDiscountType parse(Object? v) => v == 'percent' ? percent : fixed;
}

/// Which of the ride's points must be inside the code's regions.
enum PromoAppliesTo {
  pickup('pickup', 'Pickup'),
  dropoff('dropoff', 'Drop-off'),
  both('both', 'Pickup and drop-off');

  const PromoAppliesTo(this.db, this.label);
  final String db;
  final String label;
  static PromoAppliesTo parse(Object? v) => values.firstWhere((e) => e.db == v, orElse: () => pickup);
}

/// The genders a profile can have (profiles.gender).
const promoGenders = ['male', 'female', 'other'];

String promoGenderLabel(String g) => switch (g) {
  'male' => 'Male',
  'female' => 'Female',
  _ => 'Other',
};

/// A place a code is for: a country, and optionally a state, city and suburb in it.
@immutable
class PromoRegion {
  const PromoRegion({required this.country, this.state = '', this.city = '', this.suburb = ''});

  factory PromoRegion.fromJson(Map<String, dynamic> j) => PromoRegion(
        country: '${j['country'] ?? ''}'.trim(),
        state: '${j['state'] ?? ''}'.trim(),
        city: '${j['city'] ?? ''}'.trim(),
        suburb: '${j['suburb'] ?? ''}'.trim(),
      );

  final String country;
  final String state;
  final String city;
  final String suburb;

  bool get isEmpty => country.isEmpty && state.isEmpty && city.isEmpty && suburb.isEmpty;

  Map<String, dynamic> toJson() => {
        'country': country,
        if (state.isNotEmpty) 'state': state,
        if (city.isNotEmpty) 'city': city,
        if (suburb.isNotEmpty) 'suburb': suburb,
      };

  /// "Kuala Lumpur, Malaysia" — the smallest first.
  String get label => [suburb, city, state, country].where((s) => s.isNotEmpty).join(', ');

  @override
  bool operator ==(Object other) =>
      other is PromoRegion &&
      other.country.toLowerCase() == country.toLowerCase() &&
      other.state.toLowerCase() == state.toLowerCase() &&
      other.city.toLowerCase() == city.toLowerCase() &&
      other.suburb.toLowerCase() == suburb.toLowerCase();

  @override
  int get hashCode => Object.hash(country.toLowerCase(), state.toLowerCase(), city.toLowerCase(), suburb.toLowerCase());
}

/// A promo code as the admin edits it (the promo_codes row).
@immutable
class PromoCode {
  const PromoCode({
    this.id,
    required this.code,
    this.description = '',
    this.active = true,
    this.discountType = PromoDiscountType.fixed,
    required this.discountValue,
    this.maxDiscount,
    this.maxUses,
    this.maxUsesPerRider,
    this.budget,
    this.minFare,
    this.startsAt,
    this.endsAt,
    this.appliesTo = PromoAppliesTo.pickup,
    this.regions = const [],
    this.dateFrom,
    this.dateTo,
    this.weekdays = const [],
    this.timeFrom,
    this.timeTo,
    this.genders = const [],
    this.riderIds = const [],
    this.services = const [],
    this.firstRideOnly = false,
    this.autoApply = false,
    this.showInApp = true,
    this.usesCount = 0,
    this.discountTotal = 0,
  });

  factory PromoCode.fromRow(Map<String, dynamic> r) {
    List<T> list<T>(Object? v, T? Function(Object?) each) => [
          for (final x in (v is List ? v : const [])) ?each(x),
        ];
    return PromoCode(
      id: r['id'] as String?,
      code: '${r['code'] ?? ''}',
      description: '${r['description'] ?? ''}',
      active: r['active'] != false,
      discountType: PromoDiscountType.parse(r['discount_type']),
      discountValue: _num(r['discount_value']),
      maxDiscount: _numOrNull(r['max_discount']),
      maxUses: _intOrNull(r['max_uses']),
      maxUsesPerRider: _intOrNull(r['max_uses_per_rider']),
      budget: _numOrNull(r['budget']),
      minFare: _numOrNull(r['min_fare']),
      startsAt: _time(r['starts_at']),
      endsAt: _time(r['ends_at']),
      appliesTo: PromoAppliesTo.parse(r['applies_to']),
      regions: list(r['regions'], (x) => x is Map ? PromoRegion.fromJson(Map<String, dynamic>.from(x)) : null),
      dateFrom: _date(r['date_from']),
      dateTo: _date(r['date_to']),
      weekdays: list(r['weekdays'], (x) => x is num && x >= 1 && x <= 7 ? x.toInt() : null)..sort(),
      timeFrom: parseTimeOfDay(r['time_from']),
      timeTo: parseTimeOfDay(r['time_to']),
      genders: list(r['genders'], (x) => promoGenders.contains('$x') ? '$x' : null),
      riderIds: list(r['rider_ids'], (x) => '${x ?? ''}'.isEmpty ? null : '$x'),
      services: list(r['services'], (x) => '${x ?? ''}'.trim().isEmpty ? null : '$x'.trim()),
      firstRideOnly: r['first_ride_only'] == true,
      autoApply: r['auto_apply'] == true,
      showInApp: r['show_in_app'] != false,
      usesCount: _intOrNull(r['uses_count']) ?? 0,
      discountTotal: _num(r['discount_total']),
    );
  }

  final String? id;
  final String code;
  final String description;
  final bool active;
  final PromoDiscountType discountType;

  /// RM for a fixed amount; percent (0–100] for a percentage.
  final double discountValue;

  /// A percentage's cap (RM); null: none.
  final double? maxDiscount;
  final int? maxUses;
  final int? maxUsesPerRider;

  /// The most the code may give in all (RM); null: no budget.
  final double? budget;
  final double? minFare;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final PromoAppliesTo appliesTo;

  /// Empty: everywhere.
  final List<PromoRegion> regions;

  /// A date range on Malaysia's calendar (inclusive).
  final DateTime? dateFrom;
  final DateTime? dateTo;

  /// ISO days; empty: every day.
  final List<int> weekdays;

  /// Minutes after midnight; both or neither; from > to runs past midnight.
  final int? timeFrom;
  final int? timeTo;

  /// Empty: everyone.
  final List<String> genders;

  /// Empty: every rider.
  final List<String> riderIds;

  /// Service names; empty: every service.
  final List<String> services;
  final bool firstRideOnly;
  final bool autoApply;

  /// Listed to riders on the confirm step and the zone bar; off, the code
  /// works only when typed. A code that applies by itself is always shown.
  final bool showInApp;

  /// Kept by the server's settlement.
  final int usesCount;
  final double discountTotal;

  bool get hasHours => timeFrom != null && timeTo != null;

  /// "RM5.00 off" or "10% off (up to RM3.00)".
  String get discountLabel => discountType == PromoDiscountType.percent
      ? '${_trim(discountValue)}% off${maxDiscount == null ? '' : ' (up to ${promoMoney(maxDiscount)})'}'
      : '${promoMoney(discountValue)} off';

  /// Off, Scheduled, Running, Ended or Used up.
  String statusAt(DateTime now) {
    if (!active) return 'Off';
    if (startsAt != null && now.isBefore(startsAt!)) return 'Scheduled';
    if (endsAt != null && !endsAt!.isAfter(now)) return 'Ended';
    if ((maxUses != null && usesCount >= maxUses!) || (budget != null && discountTotal >= budget!)) return 'Used up';
    return 'Running';
  }

  /// The row the admin's editor saves; the counters are the server's.
  Map<String, dynamic> toRow() => {
        'code': normalizePromoCode(code),
        'description': description.trim().isEmpty ? null : description.trim(),
        'active': active,
        'discount_type': discountType.db,
        'discount_value': discountValue,
        'max_discount': discountType == PromoDiscountType.percent ? maxDiscount : null,
        'max_uses': maxUses,
        'max_uses_per_rider': maxUsesPerRider,
        'budget': budget,
        'min_fare': minFare,
        'starts_at': startsAt?.toUtc().toIso8601String(),
        'ends_at': endsAt?.toUtc().toIso8601String(),
        'applies_to': appliesTo.db,
        'regions': [for (final r in regions) if (!r.isEmpty) r.toJson()],
        'date_from': dateFrom == null ? null : _ymd(dateFrom!),
        'date_to': dateTo == null ? null : _ymd(dateTo!),
        'weekdays': weekdays.length == 7 ? <int>[] : ([...weekdays]..sort()),
        'time_from': hasHours ? '${timeOfDayLabel(timeFrom!)}:00' : null,
        'time_to': hasHours ? '${timeOfDayLabel(timeTo!)}:00' : null,
        'genders': genders.toSet().length == promoGenders.length ? <String>[] : genders,
        'rider_ids': riderIds,
        'services': services,
        'first_ride_only': firstRideOnly,
        'auto_apply': autoApply,
        // Applying by itself means being shown (the server holds it too).
        'show_in_app': showInApp || autoApply,
      };

  /// What is wrong with the code as entered, or null.
  String? get problem {
    if (!isPromoCodeShape(code)) return 'The code is 2 to 32 letters, digits, - or _.';
    if (discountValue <= 0) return 'Enter a discount above zero.';
    if (discountType == PromoDiscountType.percent && discountValue > 100) return 'A percentage is at most 100.';
    if (startsAt != null && endsAt != null && !endsAt!.isAfter(startsAt!)) return 'The code must end after it starts.';
    if (dateFrom != null && dateTo != null && dateTo!.isBefore(dateFrom!)) return 'The date range ends before it starts.';
    if (hasHours && timeFrom == timeTo) return 'The hours must start and end at different times.';
    return null;
  }
}

String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// A code that applies to the rider's trip (one promo_offers row).
@immutable
class PromoOffer {
  const PromoOffer({
    required this.codeId,
    required this.code,
    this.description = '',
    this.discountType = PromoDiscountType.fixed,
    this.discountValue = 0,
    this.maxDiscount,
    required this.estimatedDiscount,
    this.estimatedPayable,
    this.autoApply = false,
    this.appliesTo = PromoAppliesTo.pickup,
    this.endsAt,
  });

  factory PromoOffer.fromRow(Map<String, dynamic> r) => PromoOffer(
        codeId: '${r['code_id']}',
        code: '${r['code'] ?? ''}',
        description: '${r['description'] ?? ''}',
        discountType: PromoDiscountType.parse(r['discount_type']),
        discountValue: _num(r['discount_value']),
        maxDiscount: _numOrNull(r['max_discount']),
        estimatedDiscount: _num(r['estimated_discount'] ?? r['discount']),
        estimatedPayable: _numOrNull(r['estimated_payable'] ?? r['payable']),
        autoApply: r['auto_apply'] == true,
        appliesTo: PromoAppliesTo.parse(r['applies_to']),
        endsAt: _time(r['ends_at']),
      );

  final String codeId;
  final String code;
  final String description;
  final PromoDiscountType discountType;
  final double discountValue;
  final double? maxDiscount;
  final double estimatedDiscount;
  final double? estimatedPayable;

  /// The one the server applies by itself.
  final bool autoApply;
  final PromoAppliesTo appliesTo;
  final DateTime? endsAt;

  bool get pickupOnly => appliesTo == PromoAppliesTo.pickup;

  /// "RM5.00 off" or "10% off (up to RM3.00)".
  String get discountLabel => discountType == PromoDiscountType.percent
      ? '${_trim(discountValue)}% off${maxDiscount == null ? '' : ' (up to ${promoMoney(maxDiscount)})'}'
      : '${promoMoney(discountValue)} off';
}

/// What promo_check answered for a typed code.
@immutable
class PromoCheckResult {
  const PromoCheckResult._({this.offer, this.reason, this.message});

  factory PromoCheckResult.fromJson(Map<String, dynamic> j) {
    if (j['ok'] == true) return PromoCheckResult._(offer: PromoOffer.fromRow(j));
    final reason = '${j['reason'] ?? 'not_found'}';
    final m = '${j['message'] ?? ''}'.trim();
    return PromoCheckResult._(reason: reason, message: m.isEmpty ? promoReasonText(reason) : m);
  }

  const PromoCheckResult.refused(String reason, [String? message])
      : this._(reason: reason, message: message);

  final PromoOffer? offer;
  final String? reason;
  final String? message;

  bool get ok => offer != null;
}

/// The plain reason for a code that doesn't apply (the server sends its own).
String promoReasonText(String? reason) => switch (reason) {
  'not_found' || 'inactive' => "This code isn't valid.",
  'not_started' => "This code isn't active yet.",
  'expired' => 'This code has expired.',
  'not_for_you' => "This code isn't available on your account.",
  'first_ride_only' => 'This code is for your first ride only.',
  'not_now' => "This code can't be used at this time.",
  'outside_area' => "This code doesn't apply to this pickup or drop-off.",
  'service' => "This code doesn't apply to this service.",
  'min_fare' => 'The fare is under this code\'s minimum.',
  'used_up' => 'This code has been fully used.',
  'used_by_you' => "You've already used this code.",
  'rate_limited' => 'Too many tries. Please wait a few minutes and try again.',
  'ended_early' => 'The trip ended early, so the promo was not applied.',
  _ => "This code can't be used on this ride.",
};

/// "You pay about RM15.00 after promo".
String promoPayLine(double fare, double discount) {
  final pay = fare - discount;
  return 'You pay about ${promoMoney(pay < 0 ? 0 : pay)} after promo';
}

/// The promo on a booked ride, as its row holds it.
@immutable
class RidePromo {
  const RidePromo({
    required this.code,
    this.estimate,
    this.discount,
    this.payable,
    this.settled = false,
    this.error,
  });

  /// Null when the ride has no promo (or the server dropped it).
  static RidePromo? of(Map<String, dynamic> raw) {
    final id = raw['promo_code_id'];
    final code = '${raw['promo_code'] ?? ''}'.trim();
    if (id == null || code.isEmpty) return null;
    return RidePromo(
      code: code,
      estimate: _numOrNull(raw['promo_estimate']),
      discount: _numOrNull(raw['promo_discount']),
      payable: _numOrNull(raw['promo_payable']),
      settled: raw['promo_settled_at'] != null,
      error: (raw['promo_error'] as String?)?.trim().isEmpty ?? true ? null : raw['promo_error'] as String,
    );
  }

  final String code;
  final double? estimate;

  /// The settled discount (0 when the trip didn't qualify in the end).
  final double? discount;
  final double? payable;
  final bool settled;
  final String? error;

  /// Settled with money off.
  bool get applied => settled && (discount ?? 0) > 0;

  /// The amount to show: settled, else estimated.
  double get amount => settled ? (discount ?? 0) : (estimate ?? 0);
}
