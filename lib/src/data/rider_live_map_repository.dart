// Rider live map (migration 0322): the rider's overlays and cars, each a
// call to the server, which decides what this rider may see and answers at
// most once per the admin's update interval; the rider's own Map settings
// (kept on the phone, per signed-in user); and Admin › Settings › Rider
// live map's rules (table writes, logged by the server).
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/rider_live_map.dart';
import '../providers.dart';
import 'live_tables.dart';

/// A place ({country, state, city, suburb}) as the functions take it.
typedef LivePlace = Map<String, String>;

class RiderLiveMapRepository {
  RiderLiveMapRepository(this._db);
  final SupabaseClient _db;

  Future<LiveMapConfig> config(LivePlace place) async =>
      LiveMapConfig.fromJson(await _db.rpc('rider_live_map_config', params: {'p_place': place}));

  Future<LiveCars> cars(double lat, double lng, LivePlace place) async =>
      LiveCars.fromJson(await _db.rpc('rider_live_map_cars', params: {'p_lat': lat, 'p_lng': lng, 'p_place': place}));

  Future<BusyAreas> busy({
    required double south,
    required double west,
    required double north,
    required double east,
    required LivePlace place,
  }) async => BusyAreas.fromJson(await _db.rpc('rider_live_map_busy', params: {
    'p_south': south,
    'p_west': west,
    'p_north': north,
    'p_east': east,
    'p_place': place,
  }));

  Future<LivePeople> people(LivePlace place) async =>
      LivePeople.fromJson(await _db.rpc('rider_live_map_people', params: {'p_place': place}));

  Future<LivePeople> team(LivePlace place) async =>
      LivePeople.fromJson(await _db.rpc('rider_live_map_team', params: {'p_place': place}), key: 'trips');

  Future<CompanyTripNote> tripNote(String tripId) async =>
      CompanyTripNote.fromJson(await _db.rpc('rider_live_map_trip_note', params: {'p_trip': tripId}));

  /// The member stops sharing their trip with the family, at once.
  Future<void> stopSharing(String tripId) => _db.rpc('rider_live_map_stop_sharing', params: {'p_trip': tripId});

  // Admin.
  Future<List<LiveMapRule>> rules() async {
    final rows = await _db.from('rider_live_map_rules').select().order('country', ascending: true);
    final out = [for (final r in rows) LiveMapRule.fromJson(Map<String, dynamic>.from(r))]
      ..sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.label.compareTo(b.label));
    return out;
  }

  Future<void> saveRule(LiveMapRule rule) async {
    final row = rule.toRow();
    if (rule.id == null) {
      await _db.from('rider_live_map_rules').insert(row);
    } else {
      await _db.from('rider_live_map_rules').update(row).eq('id', rule.id!);
    }
  }

  Future<void> deleteRule(String id) => _db.from('rider_live_map_rules').delete().eq('id', id);
}

final riderLiveMapRepositoryProvider = Provider((ref) => RiderLiveMapRepository(ref.watch(supabaseProvider)));

/// What this rider may use at [placeKey] (a place as JSON). Off when signed
/// out or when the database has no live map yet.
final liveMapConfigProvider = FutureProvider.autoDispose.family<LiveMapConfig, String>((ref, placeKey) async {
  if (ref.watch(currentUserIdProvider) == null) return LiveMapConfig.off;
  try {
    final place = Map<String, String>.from(jsonDecode(placeKey) as Map);
    return await ref.watch(riderLiveMapRepositoryProvider).config(place);
  } catch (_) {
    return LiveMapConfig.off;
  }
});

final liveMapRulesProvider = FutureProvider.autoDispose<List<LiveMapRule>>((ref) {
  ref.watchLive('rider_live_map_rules');
  return ref.watch(riderLiveMapRepositoryProvider).rules();
});

/// The member's own company trip ("Company trip" chip).
final companyTripNoteProvider = FutureProvider.autoDispose.family<CompanyTripNote, String>((ref, tripId) async {
  try {
    return await ref.watch(riderLiveMapRepositoryProvider).tripNote(tripId);
  } catch (_) {
    return const CompanyTripNote();
  }
});

// ---- The rider's Map settings ---------------------------------------------------------------------

/// Settings › Map, kept on the phone for each signed-in user: hide the cars,
/// remember the overlays, and the overlays left on.
class LiveMapPrefs {
  const LiveMapPrefs({this.hideCars = false, this.remember = true, this.overlays = const {}});
  final bool hideCars, remember;
  final Set<LiveOverlay> overlays;

  LiveMapPrefs copyWith({bool? hideCars, bool? remember, Set<LiveOverlay>? overlays}) => LiveMapPrefs(
    hideCars: hideCars ?? this.hideCars,
    remember: remember ?? this.remember,
    overlays: overlays ?? this.overlays,
  );
}

class LiveMapPrefsNotifier extends Notifier<LiveMapPrefs> {
  /// The signed-in user, or 'guest' (also where no backend is set up, as in
  /// tests that never start Supabase: the home map must still draw).
  String _user = 'guest';
  String _key(String k) => 'live_map.$_user.$k';

  @override
  LiveMapPrefs build() {
    try {
      _user = ref.watch(currentUserIdProvider) ?? 'guest';
    } catch (_) {
      _user = 'guest';
    }
    SharedPreferences.getInstance().then((p) {
      final remember = p.getBool(_key('remember')) ?? true;
      state = LiveMapPrefs(
        hideCars: p.getBool(_key('hide_cars')) ?? false,
        remember: remember,
        // Overlays come back on only while the rider asks for that.
        overlays: remember ? decodeOverlays(p.getString(_key('overlays'))) : const {},
      );
    }).ignore();
    return const LiveMapPrefs();
  }

  Future<void> setHideCars(bool hide) async {
    state = state.copyWith(hideCars: hide);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_key('hide_cars'), hide);
  }

  Future<void> setRemember(bool on) async {
    state = state.copyWith(remember: on);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_key('remember'), on);
    if (on) {
      await p.setString(_key('overlays'), encodeOverlays(state.overlays));
    } else {
      await p.remove(_key('overlays'));
    }
  }

  Future<void> setOverlays(Set<LiveOverlay> on) async {
    state = state.copyWith(overlays: on);
    if (!state.remember) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key('overlays'), encodeOverlays(on));
  }
}

final liveMapPrefsProvider = NotifierProvider<LiveMapPrefsNotifier, LiveMapPrefs>(LiveMapPrefsNotifier.new);
