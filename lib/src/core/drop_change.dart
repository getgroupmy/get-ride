// Mid-ride drop-off change (migration 0341): the admin rules, and the pure
// logic that decides whether a change applies instantly or needs the driver.
//
// The passenger moves the drop during an ongoing ride; the fare re-computes.
// A cheaper change (or an increase within the admin threshold) applies at
// once; a bigger increase is held for the driver to accept or reject. The
// server (city_ride_config 'dropChange' + ride_drop_change_request) is the
// source of truth — this mirrors it so the app can preview the outcome and
// the admin can edit the rules. Pure.
library;

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

  /// A change that lowers (or keeps) the fare applies at once, no driver ask.
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

/// What a proposed change will do, previewed on the client with the same rule
/// the server applies ([DropChangeSettings]). The server decides for real.
enum DropChangeKind {
  /// Applies at once (cheaper/same, or a small-enough increase).
  instant,

  /// Held for the driver to accept or reject (a bigger increase).
  needsDriver,
}

/// Whether moving the fare from [oldFare] to [newFare] applies instantly or
/// needs the driver, under [rules]. Mirrors ride_drop_change_request.
DropChangeKind dropChangeKind({required double oldFare, required double newFare, required DropChangeSettings rules}) {
  final delta = newFare - oldFare;
  if (delta <= 0) return rules.autoApproveCheaper ? DropChangeKind.instant : DropChangeKind.needsDriver;
  final threshold = _max(rules.autoApproveRm.toDouble(), oldFare * rules.autoApprovePct / 100.0);
  return delta <= threshold + 1e-9 ? DropChangeKind.instant : DropChangeKind.needsDriver;
}

double _max(double a, double b) => a > b ? a : b;
