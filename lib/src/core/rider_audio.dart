/// Rider audio protection (migration 0315): the rider's side of the driver's
/// VoiceProtection (voice_protection.dart). Pure.
///
/// With the rider's switch on (off until they turn it on; the phone
/// remembers it), the phone app records the trip with its microphone while
/// the ride is under way (Start trip to the end), keeps the file encrypted in
/// the app's private folder (its key in the phone's Keychain or Keystore,
/// trip_audio_vault.dart) for the hours the admin set at the pickup, and
/// never plays it back. A metadata row in `voice_protection_recordings`
/// (recorded_by 'rider') lets support ask for it; the phone then uploads it
/// to the private `voice-protection` bucket, as the driver's does. The
/// driver sees "Audio protection on (rider)" (`ride_requests.rider_audio`).
///
/// Admin → Services & catalogue → Rider audio protection: a Default rule and
/// a rule per country, state, city or suburb, each part (on / off, hours on
/// the phone) set or left to the place above; the smallest place that sets a
/// part decides it. `rider_audio_settings_at` is the server's twin of
/// [RiderAudioRules.at].
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'partner_type_rules.dart' show RegionScope;

/// The admin page (grantable to sub-admins).
const riderAudioPage = 'admin-settings-rider-audio';

const riderAudioDefaultHours = 24;
const riderAudioMinHours = 1;
const riderAudioMaxHours = 168;

/// The rider's own switch, per account on this phone.
String riderAudioEnabledKey(String profileId) => 'rider_audio_enabled_$profileId';

/// Which recording is which encrypted file (the keys are in secure storage).
const riderAudioManifestKey = 'rider_audio_manifest_v1';

/// What the driver sees on a ride the rider records.
const riderAudioDriverLine = 'Audio protection on (rider)';

String _s(Object? v) => v is String ? v.trim() : '';
String _norm(String s) => s.trim().toLowerCase();

int clampKeepHours(int h) => h < riderAudioMinHours ? riderAudioMinHours : (h > riderAudioMaxHours ? riderAudioMaxHours : h);

/// One place's rule (a `rider_audio_rules` row). Null parts are left to the
/// place above.
class RiderAudioRule {
  const RiderAudioRule({this.id, this.scope = RegionScope.all, this.enabled, this.keepHours});

  final String? id;
  final RegionScope scope;
  final bool? enabled;
  final int? keepHours;

  bool get isDefault => scope.isAll;

  /// As stored: 'default', 'country', 'state', 'city' or 'suburb'.
  String get level => const ['default', 'country', 'state', 'city', 'suburb'][scope.path.length];

  factory RiderAudioRule.fromRow(Map<String, dynamic> r) {
    final h = r['keep_hours'];
    final hours = h is num ? h.round() : int.tryParse('${h ?? ''}');
    return RiderAudioRule(
      id: r['id'] == null ? null : '${r['id']}',
      scope: r['level'] == 'default'
          ? RegionScope.all
          : RegionScope(country: _s(r['country']), state: _s(r['state']), city: _s(r['city']), suburb: _s(r['suburb'])),
      enabled: r['enabled'] is bool ? r['enabled'] as bool : null,
      keepHours: hours == null ? null : clampKeepHours(hours),
    );
  }

  Map<String, Object?> toRow() {
    final p = scope.path;
    return {
      'level': level,
      'country': p.isNotEmpty ? p[0] : null,
      'state': p.length > 1 ? p[1] : null,
      'city': p.length > 2 ? p[2] : null,
      'suburb': p.length > 3 ? p[3] : null,
      'enabled': enabled,
      'keep_hours': keepHours,
    };
  }

  RiderAudioRule copyWith({bool? Function()? enabled, int? Function()? keepHours}) => RiderAudioRule(
    id: id,
    scope: scope,
    enabled: enabled == null ? this.enabled : enabled(),
    keepHours: keepHours == null ? this.keepHours : keepHours(),
  );

  /// Whether this rule's place holds [place] (the same names, level by level).
  bool holds(RegionScope place) {
    final mine = scope.path;
    final theirs = place.path;
    if (mine.length > theirs.length) return false;
    for (var i = 0; i < mine.length; i++) {
      if (_norm(mine[i]) != _norm(theirs[i])) return false;
    }
    return true;
  }
}

/// What holds at a place.
class RiderAudioAt {
  const RiderAudioAt({this.enabled = true, this.keepHours = riderAudioDefaultHours});

  final bool enabled;
  final int keepHours;

  /// Until the server answers: offered, for a day (Default's out of the box).
  static const fallback = RiderAudioAt();

  factory RiderAudioAt.fromJson(Object? raw) {
    if (raw is! Map) return fallback;
    final h = raw['keepHours'];
    final hours = h is num ? h.round() : int.tryParse('${h ?? ''}');
    return RiderAudioAt(
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
      keepHours: clampKeepHours(hours ?? riderAudioDefaultHours),
    );
  }

  Duration get retention => Duration(hours: keepHours);

  @override
  bool operator ==(Object other) => other is RiderAudioAt && other.enabled == enabled && other.keepHours == keepHours;

  @override
  int get hashCode => Object.hash(enabled, keepHours);
}

/// Every place's rule.
class RiderAudioRules {
  const RiderAudioRules(this.rules);

  final List<RiderAudioRule> rules;

  RiderAudioRule get defaultRule =>
      rules.firstWhere((r) => r.isDefault, orElse: () => const RiderAudioRule(enabled: true, keepHours: 24));

  /// Region rules, broadest first, then by name.
  List<RiderAudioRule> get regionRules =>
      rules.where((r) => !r.isDefault).toList()
        ..sort((a, b) {
          final byRank = a.scope.rank.compareTo(b.scope.rank);
          return byRank != 0 ? byRank : a.scope.label.toLowerCase().compareTo(b.scope.label.toLowerCase());
        });

  /// What holds at [place]: each part from the smallest place that sets it;
  /// nothing set anywhere: on, 24 hours.
  RiderAudioAt at(RegionScope place) {
    var on = true;
    var hours = riderAudioDefaultHours;
    final holding = rules.where((r) => r.holds(place)).toList()
      ..sort((a, b) => a.scope.rank.compareTo(b.scope.rank));
    for (final r in holding) {
      on = r.enabled ?? on;
      hours = r.keepHours ?? hours;
    }
    return RiderAudioAt(enabled: on, keepHours: hours);
  }

  /// The place that decides each part at [place] (null: the built-in value).
  ({RegionScope? enabledFrom, RegionScope? hoursFrom}) from(RegionScope place) {
    RegionScope? on, hours;
    final holding = rules.where((r) => r.holds(place)).toList()
      ..sort((a, b) => a.scope.rank.compareTo(b.scope.rank));
    for (final r in holding) {
      if (r.enabled != null) on = r.scope;
      if (r.keepHours != null) hours = r.scope;
    }
    return (enabledFrom: on, hoursFrom: hours);
  }
}

/// "24 h", "2 days" (a whole number of days), "36 h".
String keepHoursLabel(int hours) {
  if (hours >= 48 && hours % 24 == 0) return '${hours ~/ 24} days';
  return '$hours h';
}

/// The switch's line under "Audio protection" (the booking sheet, Safety).
String riderAudioSummary(RiderAudioAt at) => at.enabled
    ? 'Records on your phone during the trip; kept ${keepHoursLabel(at.keepHours)}, never played in the app; '
          'support can ask for it if you report the trip'
    : 'Not offered here';

/// The consent wording under the switch on the Safety page.
String riderAudioConsent(RiderAudioAt at) =>
    'When on, your trip is recorded with your phone\'s microphone from the moment your driver starts the trip '
    'until the ride ends. The recording is encrypted and stays on your phone for '
    '${keepHoursLabel(at.keepHours)}, then it is deleted. You can\'t play it in the app. It is only sent to our '
    'team if a ride is reported to support and an agent asks for it. Your driver sees that audio protection '
    'is on.';

const riderAudioPrivacyLine =
    'By turning this on, you agree to the processing of personal data for audio protection, and you tell '
    'your driver the trip is recorded, in line with the Privacy Notice.';

/// Whether the phone records [rideId] now: the rider's switch on, the ride
/// saying so (so the driver has been told), the trip started, a phone app.
bool riderShouldRecord({
  required bool switchOn,
  required bool rideSaysOn,
  required bool onTrip,
  required bool supported,
}) => switchOn && rideSaysOn && onTrip && supported;

/// Whether to tell the server the rider has it on for a ride (once per ride,
/// while it is under way, where it is offered).
bool riderShouldMarkRide({
  required bool switchOn,
  required bool rideSaysOn,
  required bool rideUnderWay,
  required bool offered,
}) => switchOn && !rideSaysOn && rideUnderWay && offered;

/// The metadata row written when a rider's recording is saved. The server
/// sets expires_at from the hours at the pickup; the phone's guess is sent
/// all the same.
Map<String, dynamic> newRiderRecordingRow({
  required String id,
  required String profileId,
  required String rideId,
  required DateTime recordedAt,
  required Duration duration,
  required bool savedOnDevice,
  required int keepHours,
  String? rideLabel,
}) => {
  'id': id,
  'profile_id': profileId,
  'ride_id': rideId,
  'ride_label': rideLabel,
  'recorded_by': 'rider',
  'recorded_at': recordedAt.toUtc().toIso8601String(),
  'duration_sec': duration.inSeconds < 0 ? 0 : (duration.inMilliseconds / 1000).round(),
  'expires_at': recordedAt.add(Duration(hours: keepHours)).toUtc().toIso8601String(),
  'unavailable': !savedOnDevice,
};

// ---- On the phone: the encrypted file -----------------------------------------------------------

/// A recording on the phone: the sealed file and when it is to be gone. Its
/// key is in the phone's secure storage (TripAudioVault), under its id.
/// [legacyKey] and [legacyNonce] are only read from a manifest written
/// before the vault, which kept them here; the app moves them to secure
/// storage at start-up (RiderAudioDeviceStore.migrateKeys).
class RiderAudioLocal {
  const RiderAudioLocal({required this.path, required this.expiresAt, this.legacyKey, this.legacyNonce});

  final String path;
  final DateTime expiresAt;
  final Uint8List? legacyKey;
  final Uint8List? legacyNonce;

  bool get hasLegacyKey => legacyKey != null && legacyNonce != null;

  /// As kept in the manifest: never a key, but one from before the vault
  /// that could not be moved yet (so it isn't lost).
  Map<String, Object> toJson() => {
    'path': path,
    if (hasLegacyKey) 'key': base64Encode(legacyKey!),
    if (hasLegacyKey) 'nonce': base64Encode(legacyNonce!),
    'expires': expiresAt.toUtc().toIso8601String(),
  };

  static RiderAudioLocal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final key = raw['key'], nonce = raw['nonce'];
      return RiderAudioLocal(
        path: raw['path'] as String,
        expiresAt: DateTime.parse(raw['expires'] as String),
        legacyKey: key is String ? base64Decode(key) : null,
        legacyNonce: nonce is String ? base64Decode(nonce) : null,
      );
    } catch (_) {
      return null;
    }
  }
}

Map<String, RiderAudioLocal> decodeRiderManifest(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final m = jsonDecode(raw);
    if (m is! Map) return {};
    return {
      for (final e in m.entries)
        if (e.key is String) e.key as String: ?RiderAudioLocal.fromJson(e.value),
    };
  } catch (_) {
    return {};
  }
}

String encodeRiderManifest(Map<String, RiderAudioLocal> m) => jsonEncode({for (final e in m.entries) e.key: e.value.toJson()});

/// [n] random bytes for a key or nonce.
Uint8List riderAudioRandomBytes(int n, [math.Random? random]) {
  final r = random ?? math.Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

/// Encrypts or decrypts (the same thing): [data] XOR an HMAC-SHA256 counter
/// keystream under [key] and [nonce]. How 0315 sealed a rider recording;
/// still read for one sealed before the vault (trip_audio_cipher.dart seals
/// every new one).
Uint8List riderAudioCipher(Uint8List key, Uint8List nonce, Uint8List data) {
  final mac = Hmac(sha256, key);
  final out = Uint8List(data.length);
  final block = Uint8List(nonce.length + 8)..setRange(0, nonce.length, nonce);
  final view = ByteData.sublistView(block);
  var counter = 0;
  for (var off = 0; off < data.length; off += 32) {
    view.setUint32(nonce.length, counter >> 32 & 0xffffffff);
    view.setUint32(nonce.length + 4, counter & 0xffffffff);
    final ks = mac.convert(block).bytes;
    final end = math.min(off + 32, data.length);
    for (var i = off; i < end; i++) {
      out[i] = data[i] ^ ks[i - off];
    }
    counter++;
  }
  return out;
}

/// Which local recordings to delete: past their own time, gone from disk, or
/// past their row's time on the server.
Set<String> expiredRiderRecordings({
  required Map<String, RiderAudioLocal> manifest,
  required Set<String> expiredIds,
  required DateTime now,
  required bool Function(String path) exists,
}) => {
  for (final e in manifest.entries)
    if (expiredIds.contains(e.key) || !exists(e.value.path) || !now.isBefore(e.value.expiresAt)) e.key,
};
