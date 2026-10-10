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
    });
    for (final t in liveOwnTables.keys) {
      expect(liveSettingTables, isNot(contains(t)), reason: 'followed for the account only, not every row');
    }
  });

  test('every table followed live is checked to be in the realtime publication', () {
    // supabase/tests/live_admin_changes.sql fails when one is not, so the
    // two lists must not drift apart.
    final sql = File('supabase/tests/live_admin_changes.sql').readAsStringSync();
    const notSettings = {'messaging_devices', 'messaging_routes', 'sms_outbox', 'sms_inbox'};
    for (final t in [...liveSettingTables, ...liveOwnTables.keys]) {
      if (notSettings.contains(t)) continue;
      expect(sql, contains("'$t'"), reason: '$t is followed live but not checked');
    }
  });
}
