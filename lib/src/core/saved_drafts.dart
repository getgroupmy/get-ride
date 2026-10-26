// "Welcome back", part 2 (owner, 26 Oct): besides a ride (ride_draft.dart),
// a Freight move, a Courier parcel and a vehicle being added are offered
// again when the app opens. Each screen keeps what it has filled in on the
// phone only, per account, for [rideDraftKeep]; Continue opens that screen
// with it filled in, and the rider or driver sends it from there through
// the usual checks.
import 'dart:convert';

import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import 'ride_draft.dart';
import 'ride_stops.dart';

/// What a saved draft is of.
enum SavedDraftKind {
  freight,
  courier,
  vehicle;

  /// The phone's memory of it, per account.
  String key(String uid) => '${name}_draft_$uid';
}

/// A form left unfinished, and when.
class SavedDraft {
  const SavedDraft({required this.kind, required this.savedAt, required this.data});

  final SavedDraftKind kind;
  final DateTime savedAt;

  /// What the screen filled in, as it reads it back.
  final Map<String, Object?> data;

  String encode() => jsonEncode({'saved_at': savedAt.toUtc().toIso8601String(), 'data': data});

  /// [raw] read back, or null when it is not a draft of [kind].
  static SavedDraft? decode(SavedDraftKind kind, String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final saved = DateTime.tryParse('${m['saved_at']}')?.toLocal();
      final data = m['data'];
      if (saved == null || data is! Map) return null;
      return SavedDraft(kind: kind, savedAt: saved, data: Map<String, Object?>.from(data));
    } catch (_) {
      return null;
    }
  }

  /// Still worth offering at [now]: saved within [rideDraftKeep].
  bool freshAt(DateTime now) {
    final age = now.difference(savedAt);
    return !age.isNegative && age <= rideDraftKeep;
  }
}

/// "6 min ago", "just now".
String draftAgo(DateTime savedAt, DateTime now) {
  final mins = now.difference(savedAt).inMinutes;
  return mins < 1 ? 'just now' : '$mins min ago';
}

// ---- Places ----------------------------------------------------------------

/// A place with the house number and street the rider typed for it.
Map<String, Object> draftAddressToJson(Place p, String details) => {...stopToJson(p), 'details': details};

/// The place and typed details back, or null.
({String details, Place place})? draftAddressFromJson(Object? raw) {
  final p = parseRideStops([raw]);
  if (p.isEmpty) return null;
  final m = raw as Map;
  return (details: '${m['details'] ?? ''}', place: p.first);
}

/// Whether [p] has a real position (not one still being looked up).
bool draftPlaceReal(Place? p) => p != null && p.point != const LatLng(0, 0);

String? draftText(Object? v) {
  final s = v is String ? v.trim() : '';
  return s.isEmpty ? null : s;
}

double? draftNumber(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

// ---- What the Welcome back sheet says ----------------------------------------

/// The sheet's words for a saved Freight, Courier or vehicle draft.
typedef DraftSummary = ({String line, String detail, String go, String other});

DraftSummary draftSummary(SavedDraft d, DateTime now) {
  final m = d.data;
  final ago = draftAgo(d.savedAt, now);
  String place(String k) => draftAddressFromJson(m[k])?.place.name ?? '';
  switch (d.kind) {
    case SavedDraftKind.freight:
      final parts = [
        ?draftText(m['vehicle_name']),
        if (place('pickup').isNotEmpty && place('drop').isNotEmpty) '${place('pickup')} to ${place('drop')}',
      ];
      return (
        line: 'You were booking a Freight move $ago.',
        detail: parts.join(' · '),
        go: 'Continue booking',
        other: 'Start over',
      );
    case SavedDraftKind.courier:
      final size = draftText(m['size']);
      final parts = [
        if (size != null) 'Size ${size.toUpperCase()}',
        if (place('drop').isNotEmpty) 'to ${place('drop')}',
      ];
      return (
        line: 'You were sending a parcel $ago.',
        detail: parts.join(' · '),
        go: 'Continue sending',
        other: 'Start over',
      );
    case SavedDraftKind.vehicle:
      final parts = [?draftText(m['plate']), if (draftText(m['next']) case final n?) '$n next'];
      return (
        line: 'You were adding a vehicle $ago.',
        detail: parts.join(' · '),
        go: 'Continue adding',
        // The vehicle stays in My vehicles: nothing is thrown away.
        other: 'Not now',
      );
  }
}
