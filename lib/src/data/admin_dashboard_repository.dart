// Admin > Dashboard (migration 0261): the two reads, the providers that
// keep them fresh, and where each admin's chosen period is kept. Who may
// read is the server's (admin_dashboard_summary / _live refuse anyone
// without the Dashboard page); this only asks.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/admin_dashboard.dart';
import '../providers.dart';
import 'live_tables.dart';

class AdminDashboardRepository {
  AdminDashboardRepository(this._db);
  final SupabaseClient? _db;

  Future<DashboardSummary> summary(DashboardRange r) async {
    final res = await _db!.rpc(
      'admin_dashboard_summary',
      params: {
        'p_from': r.from.toUtc().toIso8601String(),
        'p_to': r.to.toUtc().toIso8601String(),
        'p_prev_from': r.prevFrom.toUtc().toIso8601String(),
        'p_prev_to': r.prevTo.toUtc().toIso8601String(),
        'p_bucket': r.bucket.db,
      },
    );
    return DashboardSummary.fromJson(res is Map ? Map<String, dynamic>.from(res) : const {});
  }

  Future<DashboardLive> live() async {
    final res = await _db!.rpc('admin_dashboard_live');
    return DashboardLive.fromJson(res is Map ? Map<String, dynamic>.from(res) : const {});
  }
}

final adminDashboardRepositoryProvider = Provider<AdminDashboardRepository>(
  (ref) => AdminDashboardRepository(ref.watch(supabaseProvider)),
);

/// How often the page re-reads by itself, besides the live changes (null:
/// never, for tests). The live panel at this interval, the period figures
/// at three times it.
final adminDashboardRefreshProvider = Provider<Duration?>((_) => const Duration(seconds: 20));

/// The dashboard's clock (for tests).
final adminDashboardClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

final adminDashboardSummaryProvider = FutureProvider.autoDispose.family<DashboardSummary, DashboardRange>(
  (ref, r) => ref.watch(adminDashboardRepositoryProvider).summary(r),
);

/// "Right now": re-read as rides and SOS alerts change, and on a timer for
/// what has no live feed (drivers going online, queues).
final adminDashboardLiveProvider = FutureProvider.autoDispose<DashboardLive>((ref) {
  ref.watchAdminLive('ride_requests');
  ref.watchAdminLive('safety_incidents');
  final every = ref.watch(adminDashboardRefreshProvider);
  if (every != null) {
    final t = Timer(every, ref.invalidateSelf);
    ref.onDispose(t.cancel);
  }
  return ref.watch(adminDashboardRepositoryProvider).live();
});

// ---- The chosen period, per admin -------------------------------------------------------------------
/// Where each admin's last period is kept: on this device, by account.
abstract class DashboardChoiceStore {
  Future<DashboardChoice> load();
  Future<void> save(DashboardChoice choice);
}

class PrefsDashboardChoiceStore implements DashboardChoiceStore {
  PrefsDashboardChoiceStore(this._uid);

  /// The signed-in admin, or null.
  final String? Function() _uid;

  String get _key => 'admin_dashboard_period.${_uid() ?? 'anon'}';

  @override
  Future<DashboardChoice> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_key);
      return s == null ? DashboardChoice.initial : DashboardChoice.fromJson(jsonDecode(s));
    } catch (_) {
      return DashboardChoice.initial;
    }
  }

  @override
  Future<void> save(DashboardChoice choice) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(choice.toJson()));
    } catch (_) {
      // Not kept: the page still works, it opens on Today next time.
    }
  }
}

final dashboardChoiceStoreProvider = Provider<DashboardChoiceStore>(
  (ref) => PrefsDashboardChoiceStore(() {
    try {
      return ref.read(currentUserIdProvider);
    } catch (_) {
      return null;
    }
  }),
);
