// Partner registration identity gate: before someone registers as a partner,
// the admin's per-country rule may require them to verify their identity
// (ID + live selfie). It mirrors the rider ID gate (0342) but is its own
// per-country switch, so a country may gate riders, partners, both or
// neither. The verification itself is the shared identity flow that sets
// profiles.id_verified; this file is only the pure "must they verify now?"
// decision and the citizen-ID rule it layers on top. Pure, so it is tested
// without a database or a camera.
library;

import 'document_text.dart' show IdDocType, idShowsNonCitizen;

/// The admin's per-country rule for partner identity verification: a map of
/// 'master' and country names to whether verification is required there.
/// Stored in app_settings.partner_id_gate as {country: {require: bool}},
/// the same shape as the live-selfie gate (0401).
class PartnerIdGateConfig {
  const PartnerIdGateConfig(this.require);

  /// country name (or 'master') -> required.
  final Map<String, bool> require;

  static const empty = PartnerIdGateConfig({});

  factory PartnerIdGateConfig.fromJson(Object? json) {
    if (json is! Map) return empty;
    return PartnerIdGateConfig({
      for (final e in json.entries)
        '${e.key}': e.value is Map ? (e.value as Map)['require'] == true : e.value == true,
    });
  }

  /// Whether verification is required for a partner registering in [country]
  /// (their first service country, else their nationality): the country's own
  /// rule, else the master default, else false.
  bool requiredIn(String? country) {
    final key = country?.trim() ?? '';
    return (key.isEmpty ? null : require[key]) ?? require['master'] ?? false;
  }
}

/// Whether an ID establishes citizenship: only a citizen's national ID card
/// (a MyKad whose read does not say non-citizen). A passport, a permanent
/// resident card (MyPR) or a driving licence never proves citizenship, so a
/// citizens-only service may not be taken on one of those. The inverse of the
/// non-citizen check the registration flow already uses.
bool idProvesCitizenship(IdDocType? type, String? nationality) =>
    type == IdDocType.mykad && !idShowsNonCitizen(type, nationality);

/// Whether a partner must verify their identity before registering now.
///
/// [verified] is profiles.id_verified == 'Verified'; [country] the country the
/// gate is read for; [config] the admin rule.
///
/// An **unverified** partner must verify where the admin turned the gate on for
/// their country (the citizens-only pick does not independently force it — the
/// general gate decides). An **already-verified** partner is normally let
/// through, except the citizen rule: when a citizens-only service is among the
/// picks ([pickedCitizensOnly]) and their ID ([idType]/[nationality]) does not
/// prove citizenship (a passport, MyPR or licence), they are sent back to
/// (re)verify with a citizen ID.
bool partnerIdGateBlocks({
  required PartnerIdGateConfig config,
  required String? country,
  required bool verified,
  bool pickedCitizensOnly = false,
  IdDocType? idType,
  String? nationality,
}) {
  if (verified) {
    // The one reason a verified partner is sent back: a citizens-only pick on
    // an ID that does not prove citizenship.
    return pickedCitizensOnly && !idProvesCitizenship(idType, nationality);
  }
  return config.requiredIn(country);
}
