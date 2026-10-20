// Ride Options by place (migration 0253): the `ride_option_places` rows the
// rider's sheet prices and offers the options from, the place the server
// reads a booking's options at, and the admin's edits.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/partner_type_rules.dart' show RegionScope;
import '../core/ride_option_places.dart';
import '../providers.dart';
import 'app_display_repository.dart' show displaySettingsBlobProvider;
import 'geo_service.dart' show AreaInfo;
import 'live_tables.dart';

const rideOptionPlacesTable = 'ride_option_places';

class RideOptionPlacesRepository {
  RideOptionPlacesRepository(this._db);
  final SupabaseClient _db;

  /// Every place's row; null when they can't be read (a database before
  /// 0253), which keeps the blob's amounts.
  Future<List<OptionPlaceSettings>?> all() async {
    try {
      final rows = await _db.from(rideOptionPlacesTable).select();
      return [for (final r in rows) OptionPlaceSettings.fromRow(r)];
    } catch (_) {
      return null;
    }
  }

  /// [edit] applied to [scope]'s row as it is now; a row left with nothing
  /// set is removed (its place then follows the one above).
  Future<OptionPlaceSettings> edit(
    RegionScope scope,
    OptionPlaceSettings Function(OptionPlaceSettings current) edit,
  ) async {
    final row = await _db.from(rideOptionPlacesTable).select().eq('place_key', scope.key).maybeSingle();
    final current = row == null ? OptionPlaceSettings(scope: scope) : OptionPlaceSettings.fromRow(row);
    final next = edit(current);
    await save(next);
    return next;
  }

  Future<void> save(OptionPlaceSettings s) async {
    if (s.isEmpty) {
      await _db.from(rideOptionPlacesTable).delete().eq('place_key', s.scope.key);
      return;
    }
    await _db.from(rideOptionPlacesTable).upsert(s.toRow(), onConflict: 'place_key');
  }

  /// A charge key renamed in every place (a pet type renamed).
  Future<void> renameCharge(String from, String to) async {
    final rows = await all();
    if (rows == null) return;
    for (final r in OptionPlaces(rows).renamedCharge(from, to)) {
      await save(r);
    }
  }

  /// The place the server reads a booking at [p]'s options at (the
  /// smallest mapped outline at each level, else the geocoder's [area]);
  /// null when it can't be asked.
  Future<RegionScope?> placeAt(LatLng p, AreaInfo? area) async {
    try {
      final r = await _db.rpc('ride_option_place_at', params: {
        'p_lat': p.latitude,
        'p_lng': p.longitude,
        'p_country': area?.country,
        'p_state': area?.state,
        'p_city': area?.city,
      });
      return r is Map ? RegionScope.fromJson(r) : null;
    } catch (_) {
      return null;
    }
  }
}

final rideOptionPlacesRepositoryProvider =
    Provider((ref) => RideOptionPlacesRepository(ref.watch(supabaseProvider)));

/// Every place's settings, live; the blob's amounts as Default where the
/// table can't be read.
final rideOptionPlacesProvider = FutureProvider<OptionPlaces>((ref) async {
  List<OptionPlaceSettings>? rows;
  try {
    ref.watchLive(rideOptionPlacesTable);
    rows = await ref.watch(rideOptionPlacesRepositoryProvider).all();
  } catch (_) {
    rows = null; // no connection to read them over: the blob's amounts
  }
  if (rows != null) return OptionPlaces(rows);
  Map<String, dynamic> blob;
  try {
    blob = await ref.watch(displaySettingsBlobProvider.future);
  } catch (_) {
    blob = const {};
  }
  return OptionPlaces.fromBlob(blob);
});

/// The place for a pickup when the server can't be asked: the geocoder's
/// names (never a suburb by name, as the server).
RegionScope optionPlaceFromArea(AreaInfo? a) {
  String s(String? v) => (v ?? '').trim();
  final country = s(a?.country), state = country.isEmpty ? '' : s(a?.state);
  return RegionScope(country: country, state: state, city: state.isEmpty ? '' : s(a?.city));
}
