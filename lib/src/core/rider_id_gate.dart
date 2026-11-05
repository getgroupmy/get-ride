// Rider ID-verification gate (migrations 0342 / 0343): the admin's per-country
// rule, and the pure check of whether a rider must verify before booking. The
// server (rider_id_gate_block + the BEFORE INSERT triggers) is the real
// enforcement; this mirrors it so the app can run the verify flow up front
// rather than letting the booking fail, and so the admin can edit the rule.
// Pure.
library;

/// One country's rule (or the 'master' default).
class RiderIdGateRule {
  const RiderIdGateRule({
    this.require = false,
    this.idType = 'either',
    this.nthBooking = 1,
    this.selfie = true,
    this.allowPhoto = true,
    this.autoVerifyScore = defaultAutoVerifyScore,
  });

  static const defaultNthBooking = 1, defaultAutoVerifyScore = 85;
  static const minNth = 1, maxNth = 50, minScore = 60, maxScore = 99;

  static const standard = RiderIdGateRule();

  /// Whether a rider must verify before booking in this country.
  final bool require;

  /// Which ID is accepted: 'national', 'passport' or 'either'.
  final String idType;

  /// They may take nthBooking-1 bookings first, then must verify before #nth.
  final int nthBooking;

  /// Whether a live selfie face-match is part of it.
  final bool selfie;

  /// Whether a saved photo may stand in for a live camera capture; off means
  /// live-only (native-enforced, best-effort on web).
  final bool allowPhoto;

  /// Face-match score (0..100) at or above which the rider is verified without
  /// a human; below it the submission waits for admin review.
  final int autoVerifyScore;

  factory RiderIdGateRule.fromJson(Object? json) {
    if (json is! Map) return standard;
    int n(String k, int f, int lo, int hi) => json[k] is num ? (json[k] as num).round().clamp(lo, hi) : f;
    final t = json['idType'];
    return RiderIdGateRule(
      require: json['require'] == true,
      idType: (t == 'national' || t == 'passport' || t == 'either') ? t as String : 'either',
      nthBooking: n('nthBooking', defaultNthBooking, minNth, maxNth),
      selfie: json['selfie'] != false,
      allowPhoto: json['allowPhoto'] != false,
      autoVerifyScore: n('autoVerifyScore', defaultAutoVerifyScore, minScore, maxScore),
    );
  }

  Map<String, dynamic> toJson() => {
    'require': require,
    'idType': idType,
    'nthBooking': nthBooking,
    'selfie': selfie,
    'allowPhoto': allowPhoto,
    'autoVerifyScore': autoVerifyScore,
  };

  @override
  bool operator ==(Object other) =>
      other is RiderIdGateRule &&
      other.require == require &&
      other.idType == idType &&
      other.nthBooking == nthBooking &&
      other.selfie == selfie &&
      other.allowPhoto == allowPhoto &&
      other.autoVerifyScore == autoVerifyScore;

  @override
  int get hashCode => Object.hash(require, idType, nthBooking, selfie, allowPhoto, autoVerifyScore);
}

/// The whole admin config: a map of 'master' and country names to rules.
class RiderIdGateConfig {
  const RiderIdGateConfig(this.rules);
  final Map<String, RiderIdGateRule> rules;

  static const empty = RiderIdGateConfig({});

  factory RiderIdGateConfig.fromJson(Object? json) {
    if (json is! Map) return empty;
    return RiderIdGateConfig({
      for (final e in json.entries)
        if (e.value is Map) '${e.key}': RiderIdGateRule.fromJson(e.value),
    });
  }

  /// The rule that governs a rider in [country]: the country's own, else the
  /// master default, else none.
  RiderIdGateRule? ruleFor(String? country) =>
      (country != null ? rules[country] : null) ?? rules['master'];
}

/// Whether a rider in [country] with [priorBookings] completed and
/// [verified] status must verify before they may book now, under [config].
/// Mirrors the server's rider_id_gate_block.
bool riderIdGateBlocks({
  required RiderIdGateConfig config,
  required String? country,
  required int priorBookings,
  required bool verified,
}) {
  final rule = config.ruleFor(country);
  if (rule == null || !rule.require || verified) return false;
  return priorBookings >= (rule.nthBooking - 1);
}
