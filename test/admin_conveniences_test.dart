import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_categories.g.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/profile_search.dart';
import 'package:get_ride/src/admin/saved_push.dart';
import 'package:get_ride/src/admin/screens/commission_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/admin/screens/push_screen.dart';
import 'package:get_ride/src/admin/screens/settings_screens.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/notification_delivery.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _personId = '11111111-2222-3333-4444-555555555555';

class _Geo extends GeoAdminRepository {
  _Geo() : super(_db);

  @override
  Future<List<RegionEntry>> regions() async => [
    RegionEntry(id: 'my', values: {'country': 'Malaysia'}),
    RegionEntry(id: 'sel', values: {'country': 'Malaysia', 'state': 'Selangor'}),
    RegionEntry(id: 'kl', values: {'country': 'Malaysia', 'state': 'Kuala Lumpur'}),
  ];
}

class _Admin extends AdminRepository {
  _Admin() : super(_db);

  // Push
  final saved = <SettingEntry>[
    SettingEntry(
      id: 'old',
      values: {'title': 'Old promo', 'body': 'Expired', 'audience': 'users', 'updatedAt': '2026-01-01T00:00:00Z'},
    ),
    SettingEntry(
      id: 'p1',
      values: {
        'title': 'Rain bonus',
        'body': 'Double coins tonight',
        'audience': 'drivers',
        'updatedAt': '2026-09-01T00:00:00Z',
        'extra': 'kept',
      },
    ),
  ];
  final templateWrites = <({String? id, Map<String, dynamic> values})>[];
  final sent = <List<String>>[];
  final deleted = <String>[];

  @override
  Future<List<SavedPush>> savedPushes() async => savedPushesFrom(saved);

  @override
  Future<void> savePushTemplate({String? id, required Map<String, dynamic> values}) async =>
      templateWrites.add((id: id, values: values));

  @override
  Future<void> deleteSavedPush(String id) async => deleted.add(id);

  @override
  Future<Map<String, dynamic>> sendPush(
    String title,
    String body,
    String audience, {
    Map<String, dynamic>? area,
    bool dryRun = false,
  }) async {
    if (dryRun) return {'dryRun': true, 'recipients': 3, 'accounts': 2, 'unlocated': 0};
    sent.add([title, body, audience]);
    return {'sent': 3, 'recipients': 3, 'failed': 0};
  }

  @override
  Future<List<Map<String, dynamic>>> pushHistory() async => const [];

  @override
  Future<List<NotificationDelivery>> notificationDelivery({int hours = 24}) async => const [];

  // Settings lists
  @override
  Future<List<SettingEntry>> settings(SettingsCategory c) async => [
    SettingEntry(id: 'a', values: {'title': 'Summer sale', 'url': 'https://x/summer.png', 'active': true}),
    SettingEntry(id: 'b', values: {'title': 'Winter deal', 'url': 'https://x/winter.png', 'link': 'promo/WINTER'}),
  ];

  // Commission
  final activeWrites = <(String, bool)>[];
  final rateWrites = <Map<String, dynamic>>[];
  final searches = <String>[];

  @override
  Future<List<Map<String, dynamic>>> commissionRates() async => [
    {'id': 'r1', 'level': 'master', 'rate': 0.15, 'active': true},
  ];

  @override
  Future<void> setCommissionRateActive(String id, bool active) async => activeWrites.add((id, active));

  @override
  Future<void> saveCommissionRate(Map<String, dynamic> row) async => rateWrites.add(row);

  var uncharged = <Map<String, dynamic>>[];
  var chargeCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> unchargedCommissions() async => uncharged;

  @override
  Future<({int charged, int failed})> chargeUnchargedCommissions() async {
    chargeCalls++;
    final n = uncharged.length;
    uncharged = [];
    return (charged: n, failed: 0);
  }

  @override
  Future<List<Map<String, dynamic>>> commissionHistory({int limit = 100}) async => [
    {
      'id': 'h1',
      'op': 'update',
      'changed_at': '2026-10-18T02:00:00Z',
      'old_row': {'level': 'master', 'rate': 0.15, 'active': true, 'priority': 0},
      'new_row': {'level': 'master', 'rate': 0.12, 'active': true, 'priority': 0},
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> searchPeople(String query, {int limit = 20}) async {
    searches.add(query);
    return query.toLowerCase().contains('aisyah')
        ? [
            {'id': _personId, 'name': 'Aisyah Rahman', 'phone': '+60123456789', 'display_id': 'GR123'},
          ]
        : const [];
  }
}

Future<_Admin> _pump(
  WidgetTester tester,
  Widget home, {
  Brightness brightness = Brightness.light,
  bool edit = true,
}) async {
  final admin = _Admin();
  await tester.binding.setSurfaceSize(const Size(1000, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
        adminRepositoryProvider.overrideWithValue(admin),
        geoAdminRepositoryProvider.overrideWithValue(_Geo()),
      ],
      child: MaterialApp(theme: appTheme(brightness), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return admin;
}

void main() {
  group('saved push notifications (logic)', () {
    test('audiences normalise like Expo, drivers meaning partners', () {
      expect(normalizePushAudience('drivers'), 'partners');
      expect(normalizePushAudience('Partners'), 'partners');
      expect(normalizePushAudience('users'), 'users');
      expect(normalizePushAudience(null), 'all');
      expect(normalizePushAudience('nonsense'), 'all');
      expect(pushAudienceLabel('drivers'), 'Partners');
    });

    test('newest edit first; a row without a title or message cannot be sent', () {
      final list = savedPushesFrom([
        SettingEntry(id: 'a', values: {'title': 'A', 'body': 'x', 'updatedAt': '2026-01-01'}),
        SettingEntry(id: 'b', values: {'title': 'B', 'body': '', 'updatedAt': '2026-05-01'}),
        SettingEntry(id: 'c', values: {'title': 'C', 'body': 'y'}),
      ]);
      expect(list.map((p) => p.id), ['b', 'a', 'c']);
      expect(list.first.sendable, isFalse);
      expect(list[1].sendable, isTrue);
    });

    test('drafts need a title and a message', () {
      expect(validatePushDraft(' ', 'x'), 'Add a title.');
      expect(validatePushDraft('t', ''), 'Add a message.');
      expect(validatePushDraft('t', 'b'), isNull);
    });

    test('editing keeps keys it does not own', () {
      final v = savedPushValues(
        existing: {'title': 'old', 'extra': 1},
        title: ' New ',
        body: ' Body ',
        audience: 'drivers',
        now: DateTime.utc(2026, 10, 12, 8),
      );
      expect(v, {
        'title': 'New',
        'body': 'Body',
        'audience': 'partners',
        'area': null,
        'extra': 1,
        'updatedAt': '2026-10-12T08:00:00.000Z',
      });
    });

    test('the send result names who got it', () {
      expect(pushResultText({'sent': 2, 'recipients': 3, 'failed': 1}, 'all'), 'Sent to 2 of 3 devices (1 failed).');
      expect(pushResultText({'sent': 0, 'recipients': 0}, 'partners'), 'No registered devices match "Partners" yet.');
    });

    test('saved notifications live where Expo kept them', () {
      expect(savedPushCategory.key, 'push-notification');
      expect(savedPushCategory.table, 'settings_entries');
    });
  });

  group('person search (logic)', () {
    test('drops the characters PostgREST filters reserve', () {
      expect(peopleSearchTerm('Ali, (bin)*: 100% "x"\\'), 'Ali bin 100 x');
      expect(peopleSearchTerm('a'), isNull);
      expect(peopleSearchTerm(' ,( '), isNull);
      expect(peopleSearchTerm('ab'), 'ab');
    });

    test('a sanitised term cannot break out of the or() filter', () {
      final f = peopleOrFilter(peopleSearchTerm('x),id.eq.1')!);
      // name, email and account id only: one digit is too few for the phone.
      expect(f.split(','), ['name.ilike.*x id.eq.1*', 'email.ilike.*x id.eq.1*', 'display_id.ilike.*x id.eq.1*']);
    });

    test('phones are matched on their digits, and only with enough of them', () {
      expect(peopleOrFilter('+60 12-345'), contains('phone.ilike.*6012345*'));
      expect(peopleOrFilter('Aisyah'), isNot(contains('phone')));
    });

    test('profile ids are recognised exactly', () {
      expect(isProfileUuid(_personId), isTrue);
      expect(isProfileUuid(' ${_personId.toUpperCase()} '), isTrue);
      expect(isProfileUuid('1111-2222'), isFalse);
    });

    test('labels fall back from name to phone, email, account id, then id', () {
      expect(personLabel({'id': 'x', 'name': ' Aisyah '}), 'Aisyah');
      expect(personLabel({'id': 'x', 'name': '', 'phone': '+601'}), '+601');
      expect(personLabel({'id': 'x', 'email': 'a@b.c'}), 'a@b.c');
      expect(personLabel({'id': 'x'}), 'x');
      expect(personDetails({'display_id': 'GR1', 'phone': '+601', 'email': null}), 'GR1 · +601');
    });
  });

  group('settings list search (logic)', () {
    final c = crudCategories.firstWhere((c) => c.key == 'advertisement-banners');
    final e = SettingEntry(id: 'a', values: {'title': 'Summer Sale', 'url': 'https://x/s.png', 'link': 'promo/SUN'});

    test('matches every word, ignoring case, across what the row shows', () {
      expect(entryMatchesSearch(c, e, ''), isTrue);
      expect(entryMatchesSearch(c, e, 'summer'), isTrue);
      expect(entryMatchesSearch(c, e, 'SALE s.png'), isTrue);
      expect(entryMatchesSearch(c, e, 'promo/sun'), isTrue, reason: 'a field shown in the editor');
      expect(entryMatchesSearch(c, e, 'winter'), isFalse);
      expect(entryMatchesSearch(c, e, 'summer winter'), isFalse);
    });

    test('raw categories search their JSON', () {
      const raw = SettingsCategory(
        key: 'k',
        page: 'p',
        title: 'T',
        subtitle: '',
        table: 'settings_entries',
        fields: [],
      );
      expect(entryMatchesSearch(raw, SettingEntry(id: 'z', values: {'colour': 'teal'}), 'TEAL'), isTrue);
    });
  });

  for (final b in Brightness.values) {
    group('push screen (${b.name})', () {
      testWidgets('lists saved notifications, newest first', (tester) async {
        await _pump(tester, const AdminPushScreen(), brightness: b);
        expect(find.text('Rain bonus'), findsOneWidget);
        expect(find.textContaining('Partners'), findsWidgets);
        final rain = tester.getTopLeft(find.byKey(const ValueKey('saved-push-p1'))).dy;
        final old = tester.getTopLeft(find.byKey(const ValueKey('saved-push-old'))).dy;
        expect(rain, lessThan(old));
      });

      testWidgets('saves a new draft without sending it', (tester) async {
        final admin = await _pump(tester, const AdminPushScreen(), brightness: b);
        await tester.enterText(find.byKey(const ValueKey('push-title')), 'Holiday');
        await tester.enterText(find.byKey(const ValueKey('push-body')), 'Fares are capped');
        await tester.tap(find.byKey(const ValueKey('push-save')));
        await tester.pumpAndSettle();
        expect(admin.templateWrites.single.id, isNull);
        expect(admin.templateWrites.single.values['title'], 'Holiday');
        expect(admin.templateWrites.single.values['audience'], 'all');
        expect(admin.sent, isEmpty);
      });
    });
  }

  testWidgets('edits a saved notification and keeps its other keys', (tester) async {
    final admin = await _pump(tester, const AdminPushScreen());
    await tester.tap(find.byKey(const ValueKey('saved-push-edit-p1')));
    await tester.pumpAndSettle();
    expect(find.text('Edit saved notification'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('push-title')), 'Rain bonus!');
    await tester.tap(find.byKey(const ValueKey('push-save')));
    await tester.pumpAndSettle();
    final w = admin.templateWrites.single;
    expect(w.id, 'p1');
    expect(w.values['title'], 'Rain bonus!');
    expect(w.values['audience'], 'partners');
    expect(w.values['extra'], 'kept');
    expect(find.text('New broadcast'), findsOneWidget, reason: 'the card returns to composing');
  });

  testWidgets('re-sends a saved notification only after confirming', (tester) async {
    final admin = await _pump(tester, const AdminPushScreen(), brightness: Brightness.dark);
    await tester.tap(find.byKey(const ValueKey('saved-push-send-p1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Send "Rain bonus" to all partners?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(admin.sent, isEmpty);

    await tester.tap(find.byKey(const ValueKey('saved-push-send-p1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Send')),
    );
    await tester.pumpAndSettle();
    expect(admin.sent.single, ['Rain bonus', 'Double coins tonight', 'partners']);
    expect(find.text('Sent to 3 of 3 devices.'), findsOneWidget);
  });

  testWidgets('deletes a saved notification after confirming', (tester) async {
    final admin = await _pump(tester, const AdminPushScreen());
    await tester.tap(find.byKey(const ValueKey('saved-push-delete-old')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(admin.deleted, ['old']);
  });

  testWidgets('read-only admins see saved notifications but cannot act on them', (tester) async {
    await _pump(tester, const AdminPushScreen(), edit: false);
    expect(find.text('Rain bonus'), findsOneWidget);
    expect(find.byKey(const ValueKey('saved-push-send-p1')), findsNothing);
    expect(find.byKey(const ValueKey('push-save')), findsNothing);
  });

  for (final b in Brightness.values) {
    testWidgets('settings lists filter as you type, with an empty state (${b.name})', (tester) async {
      await _pump(tester, const AdminCategoryScreen(categoryKey: 'advertisement-banners'), brightness: b);
      expect(find.text('Summer sale'), findsOneWidget);
      expect(find.text('Winter deal'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('settings-search')), 'WINTER');
      await tester.pumpAndSettle();
      expect(find.text('Summer sale'), findsNothing);
      expect(find.text('Winter deal'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('settings-search')), 'promo/winter');
      await tester.pumpAndSettle();
      expect(find.text('Winter deal'), findsOneWidget, reason: 'fields beyond the two shown lines are searched');

      await tester.enterText(find.byKey(const ValueKey('settings-search')), 'autumn');
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Summer sale'), findsOneWidget);
      expect(find.text('Winter deal'), findsOneWidget);
    });
  }

  group('commission', () {
    for (final b in Brightness.values) {
      testWidgets('the row switch saves at once (${b.name})', (tester) async {
        final admin = await _pump(tester, const AdminCommissionScreen(), brightness: b);
        final sw = find.descendant(
          of: find.byKey(const ValueKey('commission-active-r1')),
          matching: find.byType(Switch),
        );
        expect(tester.widget<Switch>(sw).value, isTrue);
        await tester.tap(sw);
        await tester.pumpAndSettle();
        expect(admin.activeWrites, [('r1', false)]);
      });
    }

    testWidgets('read-only admins cannot flip the switch', (tester) async {
      await _pump(tester, const AdminCommissionScreen(), edit: false);
      final sw = find.descendant(of: find.byKey(const ValueKey('commission-active-r1')), matching: find.byType(Switch));
      expect(tester.widget<Switch>(sw).onChanged, isNull);
    });

    testWidgets('a per-user rule is made by finding the person', (tester) async {
      final admin = await _pump(tester, const AdminCommissionScreen(), brightness: Brightness.dark);
      await tester.tap(find.text('Add rate'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('commission-level')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('One person').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Rate (%)'), '10');

      // Saving without a person is refused.
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Choose the person this rate is for.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('commission-person-search')), 'nobody');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('No one matches that search.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('commission-person-search')), 'aisyah');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(admin.searches.last, 'aisyah');
      await tester.tap(find.byKey(const ValueKey('commission-person-$_personId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('commission-person-selected')), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      final row = admin.rateWrites.single;
      expect(row['level'], 'user');
      expect(row['user_id'], _personId);
      expect(row['user_label'], 'Aisyah Rahman');
      expect(row['rate'], 0.1);
    });

    testWidgets('only admins who may edit see Add rate', (tester) async {
      await _pump(tester, const AdminCommissionScreen(), edit: false);
      expect(find.byKey(const ValueKey('commission-add')), findsNothing);
    });

    for (final b in Brightness.values) {
      testWidgets('a state rate is picked from the regions, with a priority and a note (${b.name})', (tester) async {
        final admin = await _pump(tester, const AdminCommissionScreen(), brightness: b);
        await tester.tap(find.byKey(const ValueKey('commission-add')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('commission-level')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('State').last);
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextField, 'Rate (%)'), '12');
        await tester.tap(find.text('Choose a country'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Malaysia').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose a state'));
        await tester.pumpAndSettle();
        expect(find.text('Kuala Lumpur'), findsWidgets, reason: 'the states under Malaysia are offered');
        await tester.tap(find.text('Selangor').last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('commission-priority')), '5');
        await tester.enterText(find.byKey(const ValueKey('commission-note')), 'Launch promo');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        final row = admin.rateWrites.single;
        expect(row['level'], 'state');
        expect(row['country'], 'Malaysia');
        expect(row['state'], 'Selangor');
        expect(row['priority'], 5);
        expect(row['note'], 'Launch promo');
        expect(row['rate'], 0.12);
      });
    }

    testWidgets('uncharged trips are listed and charged with one tap', (tester) async {
      final admin = _Admin()
        ..uncharged = [
          {'ride_id': 'x1', 'partner_id': 'd1', 'fare': 20, 'completed_at': '2026-10-18T01:00:00Z', 'error': null},
          {'ride_id': 'x2', 'partner_id': 'd1', 'fare': 30, 'completed_at': '2026-10-18T01:00:00Z', 'error': 'boom'},
        ];
      await tester.binding.setSurfaceSize(const Size(1000, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            ...quietLiveOverrides,
            adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
            adminRepositoryProvider.overrideWithValue(admin),
            geoAdminRepositoryProvider.overrideWithValue(_Geo()),
          ],
          child: MaterialApp(theme: appTheme(Brightness.light), home: const AdminCommissionScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 completed trips not charged commission'), findsOneWidget);
      expect(find.text('1 failed to charge; see the trip.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('commission-charge-now')));
      await tester.pumpAndSettle();
      expect(admin.chargeCalls, 1);
      expect(find.byKey(const ValueKey('commission-uncharged')), findsNothing);
    });

    testWidgets('the change history says what changed', (tester) async {
      await _pump(tester, const AdminCommissionScreen());
      await tester.tap(find.byKey(const ValueKey('commission-history')));
      await tester.pumpAndSettle();
      expect(find.textContaining('rate 15.00% to 12.00%'), findsOneWidget);
    });

    test('history lines', () {
      expect(
        commissionHistoryLine({
          'op': 'insert',
          'new_row': {'level': 'city', 'rate': 0.08, 'city': 'Kajang', 'state': 'Selangor', 'country': 'Malaysia'},
        }),
        'Added 8.00% · city (Kajang, Selangor, Malaysia)',
      );
      expect(
        commissionHistoryLine({
          'op': 'update',
          'old_row': {'level': 'master', 'rate': 0.15, 'active': true},
          'new_row': {'level': 'master', 'rate': 0.15, 'active': false, 'priority': 2, 'note': 'paused'},
        }),
        'Changed 15.00% · master (Platform default): turned off, priority 0 to 2, note "paused"',
      );
      expect(commissionHistoryLine({'op': 'delete', 'old_row': {'level': 'master', 'rate': 0.1}}),
          'Deleted 10.00% · master (Platform default)');
    });
  });
}
