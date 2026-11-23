// Mid-ride drop-off change (migration 0341): the admin rules, what the server
// says a change comes to, and the phone's own quote for a database that
// doesn't say.
//
// The passenger moves the drop during an ongoing ride; the fare re-computes.
// The server prices it (migration 0431: the ride's fare card over the route
// it measured) and decides whether it applies at once or is held for the
// driver to accept or reject: an increase within the admin threshold applies
// at once, and so does a lower fare for a trip that got shorter to match.
// The app asks before the rider confirms ([DropChangeQuote]) and shows that
// fare; the fare it sends with the change is only the one the rider saw.
// [dropChangeKind] and [quoteDropChangeFare] are the phone's own preview,
// used only against a database from before 0431. Pure.
library;

import 'fare_tariff.dart';
import 'fare.dart' show ServiceRates;
import 'region_pricing.dart';

/// Admin > App Settings > Mid-ride drop-off change (app_settings
/// 'drop_change_rules').
class DropChangeSettings {
  const DropChangeSettings({
    this.allow = true,
    this.autoApproveCheaper = true,
    this.autoApproveRm = defaultAutoApproveRm,
    this.autoApprovePct = defaultAutoApprovePct,
    this.responseWindowSec = defaultResponseWindowSec,
    this.maxChangesPerRide = defaultMaxChangesPerRide,
  });

  static const defaultAutoApproveRm = 3,
      defaultAutoApprovePct = 15,
      defaultResponseWindowSec = 30,
      defaultMaxChangesPerRide = 2;
  static const minRm = 0, maxRm = 50, minPct = 0, maxPct = 100, minWindow = 10, maxWindow = 120, minMax = 1, maxMax = 10;

  static const standard = DropChangeSettings();

  /// Whether a passenger may move the drop on an ongoing ride at all.
  final bool allow;

  /// A change that keeps the fare, or lowers it for a trip that got shorter
  /// to match, applies at once, no driver ask (0431).
  final bool autoApproveCheaper;

  /// An increase up to this many RM applies at once.
  final int autoApproveRm;

  /// …or up to this percent of the current fare, whichever is larger.
  final int autoApprovePct;

  /// How long the driver has to answer a held change before it lapses.
  final int responseWindowSec;

  /// How many changes one ride allows, against repeated re-routing.
  final int maxChangesPerRide;

  Duration get responseWindow => Duration(seconds: responseWindowSec);

  factory DropChangeSettings.fromJson(Object? json) {
    if (json is! Map) return standard;
    int n(String k, int f, int lo, int hi) => json[k] is num ? (json[k] as num).round().clamp(lo, hi) : f;
    return DropChangeSettings(
      allow: json['allow'] != false,
      autoApproveCheaper: json['autoApproveCheaper'] != false,
      autoApproveRm: n('autoApproveRm', defaultAutoApproveRm, minRm, maxRm),
      autoApprovePct: n('autoApprovePct', defaultAutoApprovePct, minPct, maxPct),
      responseWindowSec: n('responseWindowSec', defaultResponseWindowSec, minWindow, maxWindow),
      maxChangesPerRide: n('maxChangesPerRide', defaultMaxChangesPerRide, minMax, maxMax),
    );
  }

  Map<String, dynamic> toJson() => {
    'allow': allow,
    'autoApproveCheaper': autoApproveCheaper,
    'autoApproveRm': autoApproveRm,
    'autoApprovePct': autoApprovePct,
    'responseWindowSec': responseWindowSec,
    'maxChangesPerRide': maxChangesPerRide,
  };

  @override
  bool operator ==(Object other) =>
      other is DropChangeSettings &&
      other.allow == allow &&
      other.autoApproveCheaper == autoApproveCheaper &&
      other.autoApproveRm == autoApproveRm &&
      other.autoApprovePct == autoApprovePct &&
      other.responseWindowSec == responseWindowSec &&
      other.maxChangesPerRide == maxChangesPerRide;

  @override
  int get hashCode =>
      Object.hash(allow, autoApproveCheaper, autoApproveRm, autoApprovePct, responseWindowSec, maxChangesPerRide);
}

/// What a proposed change will do. The server decides ([DropChangeQuote]).
enum DropChangeKind {
  /// Applies at once.
  instant,

  /// Held for the driver to accept or reject.
  needsDriver,
}

double? _amount(Object? v) {
  final d = v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
  return d == null || !d.isFinite || d < 0 ? null : d;
}

/// What the server says moving the drop-off would come to
/// (`ride_drop_change_quote`, migration 0431), before the rider confirms.
class DropChangeQuote {
  const DropChangeQuote({required this.fare, required this.instant});

  /// The ride's fare with the new drop-off: the server's own figure. Null
  /// when the ride has no fare yet (a metered trip): it stays so.
  final double? fare;

  /// Applies at once; otherwise the driver is asked first.
  final bool instant;

  DropChangeKind get kind => instant ? DropChangeKind.instant : DropChangeKind.needsDriver;

  /// The server's answer `{fare, instant}`; null when it is not one.
  static DropChangeQuote? fromJson(Object? json) {
    if (json is! Map || json['instant'] is! bool) return null;
    final fare = json['fare'];
    if (fare != null && _amount(fare) == null) return null;
    return DropChangeQuote(fare: _amount(fare), instant: json['instant'] as bool);
  }
}

/// The server's answer to a change that was sent (`ride_drop_change_request`,
/// `{applied, pending, fare}`): whether it is live now (else it waits for the
/// driver), and the fare the server put on it; null from a server that
/// didn't say.
({bool applied, double? fare}) parseDropChangeAnswer(Object? json) =>
    (applied: json is Map && json['applied'] == true, fare: json is Map ? _amount(json['fare']) : null);

/// Whether moving the fare from [oldFare] to [newFare] applies instantly or
/// needs the driver, under [rules]: the phone's own preview, as 0341 decided
/// it. Only for a database from before 0431, which doesn't quote a change.
DropChangeKind dropChangeKind({required double oldFare, required double newFare, required DropChangeSettings rules}) {
  final delta = newFare - oldFare;
  if (delta <= 0) return rules.autoApproveCheaper ? DropChangeKind.instant : DropChangeKind.needsDriver;
  final threshold = _max(rules.autoApproveRm.toDouble(), oldFare * rules.autoApprovePct / 100.0);
  return delta <= threshold + 1e-9 ? DropChangeKind.instant : DropChangeKind.needsDriver;
}

double _max(double a, double b) => a > b ? a : b;

/// The fare for the trip re-quoted to the new drop, the same way the booking
/// priced it: on the ride's tariff [card] (null → the service's [rates], else
/// the built-in TEKSI tariff), with the service [multiplier], over the new
/// route's [distanceKm] / [durationMin], rounded as the ride's region books
/// fares ([pricing]). The phone's own figure, only for a database from
/// before 0431: since then the server works this out (`ride_card_fare`).
/// Pure.
double quoteDropChangeFare({
  FareTariff? card,
  required double distanceKm,
  required double durationMin,
  double multiplier = 1,
  ServiceRates? rates,
  RegionPricing pricing = RegionPricing.none,
}) =>
    pricing.roundFare(quoteFare(card, distanceKm, durationMin, multiplier: multiplier, rates: rates).fare);
