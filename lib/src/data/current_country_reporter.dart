import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../providers.dart' show supabaseProvider, geoServiceProvider;

/// Records the signed-in person's **current country** (where they are using the
/// service) from the device's location, so the ID requirement and the booking
/// gate can follow it (migration 0400). The country drives whether a rider must
/// upload an ID in the country they are currently in — e.g. required in Malaysia
/// but not in Singapore.
///
/// It is deliberately cheap: it reverse-geocodes and writes only on the first
/// fix and after a country-scale move (so a rider crossing a border updates),
/// de-dupes by the last country it sent, and swallows errors — a missed update
/// just means the booking gate falls back to the last known value.

/// Trim / collapse whitespace / cap length; null when empty. Pure + tested.
String? normalizeReportedCountry(String? raw) {
  final t = (raw ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.isEmpty) return null;
  return t.length > 80 ? t.substring(0, 80) : t;
}

/// A country-scale move: far enough that the country may have changed. Pure +
/// tested. ~0.1° (~11 km) on either axis — small enough to catch a border
/// crossing, large enough that ordinary movement never re-geocodes.
bool movedFar(LatLng? from, LatLng to) {
  if (from == null) return true;
  return (from.latitude - to.latitude).abs() > 0.1 ||
      (from.longitude - to.longitude).abs() > 0.1;
}

/// Decide whether a freshly read country is worth sending: non-null and
/// different from the last one sent. Pure + tested.
bool shouldSend(String? last, String? next) => next != null && next != last;

class CurrentCountryReporter {
  CurrentCountryReporter(this._ref);
  final Ref _ref;

  String? _lastSent;
  LatLng? _lastPoint;
  bool _busy = false;

  /// Reverse-geocode [p] to a country and record it, subject to the move gate
  /// and de-dupe. Fire-and-forget; never throws (everything, including reading
  /// the Supabase client, is inside the guard so it is safe in tests and on a
  /// legacy local-PIN session).
  Future<void> reportFrom(LatLng p) async {
    if (_busy) return;
    _busy = true;
    try {
      // Only when we have a real Supabase session — a legacy local-PIN session
      // has no server row to write to.
      final client = _ref.read(supabaseProvider);
      if (client.auth.currentUser == null) return;
      if (!movedFar(_lastPoint, p) && _lastSent != null) return;
      final area = await _ref.read(geoServiceProvider).reverseArea(p);
      _lastPoint = p;
      final country = normalizeReportedCountry(area?.country);
      if (shouldSend(_lastSent, country)) {
        await client.rpc('set_my_current_country', params: {'p_country': country});
        _lastSent = country;
      }
    } catch (_) {
      // Best-effort: a failed update leaves the last known country in place.
    } finally {
      _busy = false;
    }
  }
}

final currentCountryReporterProvider =
    Provider<CurrentCountryReporter>((ref) => CurrentCountryReporter(ref));
