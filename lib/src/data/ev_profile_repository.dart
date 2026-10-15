// EV profiles and OBD captures (migration 0202). The app reads the active
// profiles through `ev_profiles_for_app`, keeps them on the device for a
// car park with no signal, and follows the table live; admins edit every
// profile and read the captures drivers record for support.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ev_profile.dart';
import '../providers.dart';
import 'live_tables.dart';

class EvProfileRepository {
  /// The client is looked up on first use, so building one needs no backend.
  EvProfileRepository(this._db);
  final SupabaseClient Function() _db;

  static const cacheKey = 'ev_profiles_v1';

  /// The active profiles; kept on the device. Offline (or signed out), the
  /// ones kept last time.
  Future<List<EvProfile>> forApp() async {
    try {
      final res = await _db().rpc('ev_profiles_for_app');
      final list = parseEvProfiles(res is String ? jsonDecode(res) : res);
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(cacheKey, jsonEncode([for (final e in list) e.toJson()]));
      } catch (_) {}
      return list;
    } catch (_) {
      return kept();
    }
  }

  /// The profiles this device last had.
  Future<List<EvProfile>> kept() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString(cacheKey);
      return s == null ? const [] : parseEvProfiles(jsonDecode(s));
    } catch (_) {
      return const [];
    }
  }

  // ---- Admin ----------------------------------------------------------------------------

  /// Every profile, active or not (an admin's row-level access).
  Future<List<EvProfile>> adminList() async {
    final rows = await _db().from('ev_profiles').select().order('make').order('model');
    return parseEvProfiles(rows);
  }

  /// Saves [p] (new when it has no id) and answers the row as stored.
  Future<EvProfile> save(EvProfile p) async {
    final row = p.toJson()
      ..remove('id')
      ..remove('updated_at');
    final id = p.id;
    final saved = id == null
        ? await _db().from('ev_profiles').insert(row).select().single()
        : await _db().from('ev_profiles').update(row).eq('id', id).select().single();
    return EvProfile.fromJson(saved) ?? p;
  }

  Future<void> delete(String id) => _db().from('ev_profiles').delete().eq('id', id);

  /// The latest captures, newest first.
  Future<List<EvCapture>> adminCaptures({int limit = 200}) async {
    final rows = await _db().from('obd_captures').select().order('created_at', ascending: false).limit(limit);
    return [for (final r in rows) ?EvCapture.fromJson(r)];
  }

  Future<void> deleteCapture(String id) => _db().from('obd_captures').delete().eq('id', id);

  // ---- Driver ---------------------------------------------------------------------------

  /// Uploads a capture as the signed-in driver's own.
  Future<void> uploadCapture(EvCapture c) async {
    final row = c.toJson()
      ..remove('id')
      ..remove('profile_id')
      ..remove('created_at');
    await _db().from('obd_captures').insert(row);
  }
}

final evProfileRepositoryProvider = Provider((ref) => EvProfileRepository(() => ref.read(supabaseProvider)));

/// The active profiles, kept live (an admin's change applies at the next
/// search for the car's profile).
final evProfilesProvider = FutureProvider<List<EvProfile>>((ref) {
  ref.watchLive('ev_profiles');
  return ref.watch(evProfileRepositoryProvider).forApp();
});

/// Which profile the driver chose when one car matched several, per reader
/// and set of matches (a reader moved to another car meets another set).
class EvChoiceStore {
  static String keyFor(String readerId, Iterable<String> candidateIds) =>
      'ev_profile_choice_v1:$readerId:${(candidateIds.toList()..sort()).join(',')}';

  Future<String?> chosen(String readerId, Iterable<String> candidateIds) async {
    try {
      return (await SharedPreferences.getInstance()).getString(keyFor(readerId, candidateIds));
    } catch (_) {
      return null;
    }
  }

  Future<void> remember(String readerId, Iterable<String> candidateIds, String profileId) async {
    try {
      await (await SharedPreferences.getInstance()).setString(keyFor(readerId, candidateIds), profileId);
    } catch (_) {}
  }
}

final evChoiceStoreProvider = Provider((_) => EvChoiceStore());
