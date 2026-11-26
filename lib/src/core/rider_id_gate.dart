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

  /// Which ID is accepted: 'national', 'passport', 'licence' or 'either' (any
  /// of the three). A driving licence counts as an identity document.
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
      idType: (t == 'national' || t == 'passport' || t == 'licence' || t == 'either') ? t as String : 'either',
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

  /// The rule for a rider, matched exactly as the server does
  /// (rider_id_gate_block): where they are now first, then their nationality,
  /// then the master default, else none.
  RiderIdGateRule? ruleForRider({String? currentCountry, String? nationality}) =>
      _exact(currentCountry) ?? _exact(nationality) ?? rules['master'];

  RiderIdGateRule? _exact(String? country) {
    final key = country?.trim() ?? '';
    return key.isEmpty ? null : rules[key];
  }
}

/// Whether a rider in [country] with [priorBookings] completed and
/// [verified] status must verify before they may book now, under [config].
/// Mirrors the server's rider_id_gate_block.
bool riderIdGateBlocks({
  required RiderIdGateConfig config,
  required String? country,
  String? currentCountry,
  required int priorBookings,
  required bool verified,
}) {
  final rule = config.ruleForRider(currentCountry: currentCountry, nationality: country);
  if (rule == null || !rule.require || verified) return false;
  return priorBookings >= (rule.nthBooking - 1);
}

/// The admin's single per-country choice for how riders verify, combining the
/// eKYC/ID gate (0342) and the live-selfie gate (0401). It is derived from the
/// two rules' require flags, and written back to both. Pure.
enum RiderVerifyMethod {
  none,
  liveSelfie,
  ekyc,
  both;

  /// Whether this method requires the eKYC/ID gate (0342).
  bool get idRequired => this == ekyc || this == both;

  /// Whether this method requires the live-selfie gate (0401).
  bool get selfieRequired => this == liveSelfie || this == both;

  /// The admin-facing name.
  String get label => switch (this) {
        none => 'Not required',
        liveSelfie => 'Live selfie',
        ekyc => 'eKYC (ID)',
        both => 'eKYC + live selfie',
      };

  /// The method the two gates add up to.
  static RiderVerifyMethod of({required bool idRequired, required bool selfieRequired}) {
    if (idRequired && selfieRequired) return both;
    if (idRequired) return ekyc;
    if (selfieRequired) return liveSelfie;
    return none;
  }
}
