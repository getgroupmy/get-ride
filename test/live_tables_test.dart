// Every admin change reaches running apps live (lib/src/data/live_tables.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/live_tables.dart';

void main() {
  test('one stamp moves when any of its tables changes', () {
    const tables = ['countries', 'states'];
    final before = {'countries': 2, 'states': 1, 'wallets': 9};
    expect(liveStamp(before, tables), 3);
    expect(liveStamp(bumpRevisions(before, ['states']), tables), 4);
    expect(liveStamp(bumpRevisions(before, ['wallets']), tables), 3, reason: 'another table');
    expect(liveStamp(const {}, tables), 0);
  });

  test('the region tables are followed live', () {
    for (final t in liveRegionTables) {
      expect(liveSettingTables, contains(t));
    }
  });

  test("the account's own rows are followed by the column that names it", () {
    expect(liveOwnTables, {
      'profiles': 'id',
      'partners': 'auth_user_id',
      'provider_documents': 'auth_user_id',
      'vehicle': 'auth_user_id',
      'vehicle_documents': 'auth_user_id',
      'driver_ride_extras': 'driver_id',
    });
    for (final t in liveOwnTables.keys) {
      expect(liveSettingTables, isNot(contains(t)), reason: 'followed for the account only, not every row');
    }
  });

  test('every table followed live is checked to be in the realtime publication', () {
    // supabase/tests/live_admin_changes.sql fails when one is not, so the
    // two lists must not drift apart.
    final sql = File('supabase/tests/live_admin_changes.sql').readAsStringSync();
    const notSettings = {'messaging_routes', 'sms_outbox', 'sms_inbox'};
    for (final t in [...liveSettingTables, ...liveOwnTables.keys, ...liveAdminTables]) {
      if (notSettings.contains(t)) continue;
      expect(sql, contains("'$t'"), reason: '$t is followed live but not checked');
    }
  });

  test('no table followed live is one 0227 or 0229 took out of the realtime publication', () {
    // Following one again means adding it back to supabase_realtime first.
    const unpublished = {
      'user_location_history',
      'notification_outbox',
      'wallet_transactions',
      'vehicle_active_session',
      'emergency_contacts',
      'vehicles',
      'auth_rate_hits',
      // 0229: a heartbeat every few seconds per device; the admin page polls it.
      'messaging_devices',
      'auth_rate_counts',
    };
    for (final t in [...liveSettingTables, ...liveOwnTables.keys, ...liveAdminTables]) {
      expect(unpublished, isNot(contains(t)), reason: '$t is not in the realtime publication');
    }
  });

  test('the commission tiers the admin page watches are followed live', () {
    expect(liveSettingTables, contains('commission_tiers'));
  });

  test('admin pages follow every row of the account tables, the app only its own', () {
    for (final t in liveOwnTables.keys) {
      expect(liveAdminTables, contains(t), reason: 'an admin list of $t shows everyone\'s changes');
    }
    for (final t in liveAdminTables) {
      expect(liveSettingTables, isNot(contains(t)), reason: '$t is too busy for every app\'s channel');
    }
  });

  test('both live channels keep a slow jittered safety net while healthy', () {
    // Realtime can report "subscribed" while missing changes: neither
    // channel may go without any timer read while it is open.
    final src = File('lib/src/data/live_tables.dart').readAsStringSync();
    expect(src, isNot(contains('healthy: null')));
    expect('healthy: realtimeBackupSafetyNetInterval'.allMatches(src).length, 2);
    expect('healthyJitter: realtimeBackupSafetyNetJitter'.allMatches(src).length, 2);
  });
}
