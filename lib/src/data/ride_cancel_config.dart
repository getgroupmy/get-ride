// Trip cancellation settings (migration 0191): how long a cancellation
// request waits for an answer, and whether an unanswered or declined one
// opens a support ticket.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ride_cancel.dart';
import '../providers.dart';
import 'live_tables.dart';

/// The admin's settings; the standard 2 minutes when they can't be read
/// (an older database, no signal).
final cancelRequestConfigProvider = FutureProvider<CancelRequestConfig>((ref) async {
  ref.watchLive('app_settings');
  try {
    return CancelRequestConfig.fromJson(await ref.watch(supabaseProvider).rpc('ride_cancel_request_config'));
  } catch (_) {
    return CancelRequestConfig.standard;
  }
});

/// Admin: saves, and returns the settings as stored.
Future<CancelRequestConfig> saveCancelRequestConfig(SupabaseClient db, CancelRequestConfig c) async =>
    CancelRequestConfig.fromJson(await db.rpc('set_ride_cancel_request_config', params: {'p_config': c.toJson()}));
