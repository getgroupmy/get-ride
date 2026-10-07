// Booking tariffs by place (migration 0109): one master card, then
// country / state / city / suburb overrides, the narrowest card that
// matches the pickup winning, resolved like commission rates. With no card
// the built-in TEKSI tariff (calculateFare) prices the trip in ringgit. Pure.
import 'dart:math' as math;

import 'commission.dart' show Geo;
import 'fare.dart';

const fareTariffLevels = ['master', 'country', 'state', 'city', 'suburb'];

class FareTariff {
  const FareTariff({
    required this.level,
    this.id,
    this.country,
    this.state,
    this.city,
    this.suburb,
    this.label,
    this.currency = 'MYR',
    this.baseFare = 0,
    this.perKm = 0,
    this.perMinute = 0,
    this.minimumFare = 0,
    this.bookingFee = 0,
    this.active = true,
  });

  factory FareTariff.fromRow(Map<String, dynamic> r) {
    double n(String k) {
      final v = r[k];
      final d = v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
      return d == null || !d.isFinite || d < 0 ? 0 : d;
    }

    String? s(String k) => r[k] is String && (r[k] as String).trim().isNotEmpty ? (r[k] as String).trim() : null;
    return FareTariff(
      id: s('id'),
      level: s('level') ?? 'master',
      country: s('country'),
      state: s('state'),
      city: s('city'),
      suburb: s('suburb'),
      label: s('label'),
      currency: (s('currency') ?? 'MYR').toUpperCase(),
      baseFare: n('base_fare'),
      perKm: n('per_km'),
      perMinute: n('per_minute'),
      minimumFare: n('minimum_fare'),
      bookingFee: n('booking_fee'),
      active: r['active'] != false,
    );
  }

  final String? id;
  final String level;
  final String? country, state, city, suburb, label;
  final String currency;
  final double baseFare, perKm, perMinute, minimumFare, bookingFee;
  final bool active;

  /// Where the card applies, as the admin list names it.
  String get scope => level == 'master' ? 'Everywhere' : [suburb, city, state, country].whereType<String>().join(', ');
}

bool _eqi(String? a, String? b) => (a ?? '').trim().toLowerCase() == (b ?? '').trim().toLowerCase();

/// The card for a pickup at [geo]: suburb → city → state → country →
/// master, each matching its parents too (a "Georgetown" suburb card in
/// Penang never prices a Georgetown elsewhere). Null when none applies.
FareTariff? resolveFareTariff(List<FareTariff> cards, Geo geo) {
  final active = cards.where((c) => c.active).toList();
  bool parents(FareTariff c, {bool state = false, bool city = false}) =>
      _eqi(c.country, geo.country) && (!state || _eqi(c.state, geo.state)) && (!city || _eqi(c.city, geo.city));
  FareTariff? find(bool Function(FareTariff) test) => active.where(test).firstOrNull;
  bool known(String? v) => (v ?? '').trim().isNotEmpty;
  return (known(geo.suburb)
          ? find((c) => c.level == 'suburb' && parents(c, state: true, city: true) && _eqi(c.suburb, geo.suburb))
          : null) ??
      (known(geo.city) ? find((c) => c.level == 'city' && parents(c, state: true) && _eqi(c.city, geo.city)) : null) ??
      (known(geo.state) ? find((c) => c.level == 'state' && parents(c) && _eqi(c.state, geo.state)) : null) ??
      (known(geo.country) ? find((c) => c.level == 'country' && _eqi(c.country, geo.country)) : null) ??
      find((c) => c.level == 'master');
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// What [t] charges for a trip, the service [multiplier] on the metered
/// part and the booking fee added on top.
double tariffFare(FareTariff t, double distanceKm, double durationMin, {double multiplier = 1}) {
  final km = math.max(0.0, distanceKm), min = math.max(0.0, durationMin);
  final metered = (t.baseFare + t.perKm * km + t.perMinute * min) * multiplier;
  return _round2(math.max(t.minimumFare, metered) + t.bookingFee);
}

/// A trip's quote: on the card for the pickup when there is one, else on
/// the built-in TEKSI tariff in ringgit.
({double fare, String currency}) quoteFare(
  FareTariff? card,
  double distanceKm,
  double durationMin, {
  double multiplier = 1,
  String fallbackCurrency = 'MYR',
}) => card == null
    ? (fare: calculateFare(distanceKm, durationMin, multiplier: multiplier), currency: fallbackCurrency)
    : (fare: tariffFare(card, distanceKm, durationMin, multiplier: multiplier), currency: card.currency);

/// The card's rates, as the admin list and the booking sheet print them.
String describeFareTariff(FareTariff t) {
  String m(double v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
  return [
    '${t.currency} ${m(t.baseFare)} base',
    '${m(t.perKm)}/km',
    '${m(t.perMinute)}/min',
    if (t.minimumFare > 0) 'min ${m(t.minimumFare)}',
    if (t.bookingFee > 0) '+${m(t.bookingFee)} booking fee',
  ].join(' · ');
}

/// Why a card can't be saved, or null.
String? fareTariffProblem(FareTariff t) {
  const needs = {
    'country': ['country'],
    'state': ['country', 'state'],
    'city': ['country', 'state', 'city'],
    'suburb': ['country', 'state', 'city', 'suburb'],
  };
  final values = {'country': t.country, 'state': t.state, 'city': t.city, 'suburb': t.suburb};
  for (final k in needs[t.level] ?? const <String>[]) {
    if ((values[k] ?? '').trim().isEmpty) return 'Enter the $k.';
  }
  if (!RegExp(r'^[A-Z]{3}$').hasMatch(t.currency)) return 'The currency is a 3-letter code, e.g. MYR.';
  if (t.baseFare + t.perKm + t.perMinute + t.minimumFare <= 0) return 'Set at least one charge.';
  return null;
}

/// The row as stored: only the levels the card names.
Map<String, dynamic> fareTariffRow(FareTariff t) {
  final depth = fareTariffLevels.indexOf(t.level);
  String? keep(String? v, int level) => depth >= level ? v?.trim() : null;
  return {
    if (t.id != null) 'id': t.id,
    'level': t.level,
    'country': keep(t.country, 1),
    'state': keep(t.state, 2),
    'city': keep(t.city, 3),
    'suburb': keep(t.suburb, 4),
    'label': (t.label ?? '').trim().isEmpty ? null : t.label!.trim(),
    'currency': t.currency,
    'base_fare': t.baseFare,
    'per_km': t.perKm,
    'per_minute': t.perMinute,
    'minimum_fare': t.minimumFare,
    'booking_fee': t.bookingFee,
    'active': t.active,
  };
}
