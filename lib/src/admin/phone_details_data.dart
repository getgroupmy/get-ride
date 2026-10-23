// The admin Phone card's data: an account's newest `user_sessions` rows and
// its `push_tokens` (both admin-read under RLS, `caller_is_admin()`), turned
// into one summary per phone (core/phone_details.dart). Refreshed as session
// rows arrive (user_sessions is an admin live table).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/phone_details.dart';
import '../data/live_tables.dart';
import '../providers.dart';

/// How many of the account's newest session rows are read.
const phoneSessionRows = 60;

class PhoneDetailsRepository {
  PhoneDetailsRepository(this._db);
  final SupabaseClient? _db;

  /// The account's newest session rows and its push tokens (no token
  /// values). A database without the newer token columns gives no tokens
  /// rather than no card.
  Future<({List<Map<String, dynamic>> sessions, List<Map<String, dynamic>> tokens})> load(String profileId) async {
    final db = _db!;
    final r = await Future.wait([
      db
          .from('user_sessions')
          .select()
          .eq('user_id', profileId)
          .order('captured_at', ascending: false)
          .limit(phoneSessionRows),
      db
          .from('push_tokens')
          .select('platform, device_key, location_always, located_bg, located_at, capabilities, updated_at')
          .eq('profile_id', profileId)
          .order('updated_at', ascending: false)
          .then<List<Map<String, dynamic>>>((v) => v, onError: (_) => <Map<String, dynamic>>[]),
    ]);
    return (sessions: List<Map<String, dynamic>>.from(r[0]), tokens: List<Map<String, dynamic>>.from(r[1]));
  }
}

final phoneDetailsRepositoryProvider = Provider((ref) => PhoneDetailsRepository(ref.watch(supabaseProvider)));

/// The phones, newest first, or [failed] when they couldn't be read.
class PhoneDetailsLoad {
  const PhoneDetailsLoad(this.phones) : failed = false;
  const PhoneDetailsLoad.failed() : phones = const [], failed = true;

  final List<PhoneDetails> phones;
  final bool failed;
}

/// An account's phones by its profile id. A failure is an answer, not an
/// error, so nothing retries on a timer.
final phoneDetailsProvider = FutureProvider.autoDispose.family<PhoneDetailsLoad, String>((ref, profileId) async {
  ref.watchAdminLive('user_sessions');
  if (profileId.isEmpty) return const PhoneDetailsLoad([]);
  try {
    final r = await ref.watch(phoneDetailsRepositoryProvider).load(profileId);
    return PhoneDetailsLoad(phonesFrom(r.sessions, r.tokens));
  } catch (_) {
    return const PhoneDetailsLoad.failed();
  }
});
