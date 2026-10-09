// How fares are priced in a region (Admin → Country / States / Cities, each
// region's add / edit page): whether fares are whole amounts — rounded up,
// never shown or typed with decimals — and the tax added on top. Tolls and
// other charges keep their decimals either way. A country row always sets
// the region's pricing; a state, city or suburb row only when it overrides
// its parent ("pricingOverride"), so a row added just for a geofence never
// switches the country's tax off. Pure.
import 'dart:math' as math;

enum TaxKind { percent, fixed }

/// The tax on a fare: a name ("SST"), and a percentage of the fare or a
/// fixed amount.
class RegionTax {
  const RegionTax({required this.name, required this.kind, required this.value});

  final String name;
  final TaxKind kind;
  final double value;

  /// What it adds to [fare], to the cent.
  double on(double fare) {
    final t = kind == TaxKind.percent ? fare * value / 100 : value;
    return (math.max(0, t) * 100).roundToDouble() / 100;
  }

  /// `SST 6%` / `Service tax`.
  String get label => kind == TaxKind.percent ? '$name ${_trim(value)}%' : name;

  String get kindId => kind == TaxKind.percent ? 'percent' : 'fixed';

  static TaxKind kindFrom(Object? v) => v == 'fixed' ? TaxKind.fixed : TaxKind.percent;
}

String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';

double _cents(double v) => (math.max(0, v) * 100).roundToDouble() / 100;

/// A tax or surcharge from a region's scheduled rules (Admin → Country /
/// States / Cities → Rules), stamped on the ride when it is booked. A
/// percentage stays a percentage, so it follows the fare through bidding.
class FareCharge {
  const FareCharge({required this.isTax, required this.name, required this.percent, required this.value});

  final bool isTax;
  final String name;

  /// [value] is a percentage of the base, else a fixed amount.
  final bool percent;
  final double value;

  double on(double base) => _cents(percent ? base * value / 100 : value);

  /// "SST 8%", "Midnight surcharge".
  String get label => percent ? '$name ${_trim(value)}%' : name;

  Map<String, Object?> toJson() => {
    'kind': isTax ? 'tax' : 'surcharge',
    'name': name,
    'charge': percent ? 'percent' : 'fixed',
    'value': value,
  };

  static FareCharge? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final value = raw['value'] is num ? (raw['value'] as num).toDouble() : null;
    final name = '${raw['name'] ?? ''}'.trim();
    if (value == null || value <= 0 || name.isEmpty) return null;
    return FareCharge(isTax: raw['kind'] == 'tax', name: name, percent: raw['charge'] != 'fixed', value: value);
  }

  @override
  bool operator ==(Object other) =>
      other is FareCharge && other.isTax == isTax && other.name == name && other.percent == percent && other.value == value;

  @override
  int get hashCode => Object.hash(isTax, name, percent, value);
}

/// One line of a fare's breakdown: what it is and what it adds.
typedef ChargeLine = ({String label, double amount, bool isTax});

class RegionPricing {
  const RegionPricing({this.wholeFare = false, this.tax, this.charges = const []});

  /// Fares round up to whole amounts, shown and typed without decimals.
  final bool wholeFare;

  /// The region's plain Tax setting; null when it has none, or when its
  /// scheduled rules decide the taxes instead ([charges]).
  final RegionTax? tax;

  /// Taxes and surcharges from the region's scheduled rules. Surcharges are
  /// added to the fare; taxes are on the fare and its surcharges.
  final List<FareCharge> charges;

  /// This pricing with the scheduled [taxes] (when the rules decide them —
  /// they then replace the plain Tax) and [surcharges] in force.
  RegionPricing withRules({List<FareCharge>? taxes, List<FareCharge> surcharges = const []}) => RegionPricing(
    wholeFare: wholeFare,
    tax: taxes == null ? tax : null,
    charges: [...surcharges, ...?taxes],
  );

  /// The surcharges on [fare].
  double surchargesOn(double fare) =>
      _cents([for (final c in charges) if (!c.isTax) c.on(fare)].fold(0.0, (a, b) => a + b));

  /// The breakdown on top of [fare]: surcharges, then taxes.
  List<ChargeLine> linesFor(double fare) {
    final surcharge = surchargesOn(fare);
    final taxBase = fare + surcharge;
    return [
      for (final c in charges)
        if (!c.isTax) (label: c.label, amount: c.on(fare), isTax: false),
      if (tax != null) (label: tax!.label, amount: tax!.on(fare), isTax: true),
      for (final c in charges)
        if (c.isTax) (label: c.label, amount: c.on(taxBase), isTax: true),
    ];
  }

  static const none = RegionPricing();

  /// The pricing a region entry sets, or null when it leaves its parent's.
  static RegionPricing? fromValues(Map<String, dynamic> v) {
    String s(Object? x) => x is String ? x.trim() : '';
    final isCountry = s(v['state']).isEmpty && s(v['city']).isEmpty && s(v['suburb']).isEmpty;
    if (!isCountry && v['pricingOverride'] != true) return null;
    final amount = v['taxAmount'] is num ? (v['taxAmount'] as num).toDouble() : double.tryParse('${v['taxAmount']}');
    final name = s(v['taxName']);
    final tax = v['taxEnabled'] == true && name.isNotEmpty && amount != null && amount > 0
        ? RegionTax(name: name, kind: RegionTax.kindFrom(v['taxType']), value: amount)
        : null;
    return RegionPricing(wholeFare: v['wholeFare'] == true, tax: tax);
  }

  /// [fare] as booked here: rounded up to a whole amount, or to the cent.
  double roundFare(double fare) {
    if (!fare.isFinite || fare <= 0) return 0;
    return wholeFare ? (fare - 1e-9).ceilToDouble() : (fare * 100).roundToDouble() / 100;
  }

  /// The taxes on [fare] (and its surcharges); 0 without any.
  double taxOn(double fare) =>
      _cents([for (final l in linesFor(fare)) if (l.isTax) l.amount].fold(0.0, (a, b) => a + b));

  /// Everything added to [fare]: surcharges and taxes.
  double extrasOn(double fare) => _cents(surchargesOn(fare) + taxOn(fare));

  /// The decimals a fare is shown with.
  int get fareDecimals => wholeFare ? 0 : 2;

  /// The `ride_requests` columns a booking carries (migration 0119), so
  /// every screen after it prices the ride the same way.
  Map<String, Object?> toRideColumns() => {
    'whole_fare': wholeFare,
    'tax_name': tax?.name,
    'tax_kind': tax?.kindId,
    'tax_value': tax?.value,
    'charges': charges.isEmpty ? null : [for (final c in charges) c.toJson()],
  };

  /// The pricing stamped on a ride row (see [toRideColumns]).
  static RegionPricing fromRide(Map<String, dynamic> row) {
    final name = row['tax_name'] is String ? (row['tax_name'] as String).trim() : '';
    final value = row['tax_value'] is num ? (row['tax_value'] as num).toDouble() : null;
    final charges = row['charges'];
    return RegionPricing(
      wholeFare: row['whole_fare'] == true,
      tax: name.isEmpty || value == null || value <= 0
          ? null
          : RegionTax(name: name, kind: RegionTax.kindFrom(row['tax_kind']), value: value),
      charges: [
        if (charges is List)
          for (final c in charges) ?FareCharge.fromJson(c),
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RegionPricing &&
      other.wholeFare == wholeFare &&
      other.tax?.name == tax?.name &&
      other.tax?.kind == tax?.kind &&
      other.tax?.value == tax?.value &&
      _sameCharges(other.charges, charges);

  static bool _sameCharges(List<FareCharge> a, List<FareCharge> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(wholeFare, tax?.name, tax?.kind, tax?.value, Object.hashAll(charges));
}

/// What the admin form saves for a region's pricing, and what it problems
/// it has, if any.
String? regionPricingProblem({
  required bool taxEnabled,
  required String taxName,
  required TaxKind taxKind,
  required String taxAmount,
}) {
  if (!taxEnabled) return null;
  if (taxName.trim().isEmpty) return 'Enter the tax name, e.g. SST.';
  final a = double.tryParse(taxAmount.trim());
  if (a == null || a <= 0) return 'Enter the tax amount.';
  if (taxKind == TaxKind.percent && a > 100) return 'A percentage tax is at most 100%.';
  return null;
}
