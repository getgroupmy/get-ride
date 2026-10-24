// Admin > Services & catalogue > Partner type services: the page over a fake
// PostgREST `partner_type_services` table (in memory) — the list with its
// "All" / "N of M", the editor (ticks, All services, save, remove with the
// in-page confirm), Add type from Partner Type, "Who sees this request?",
// wide and phone, light and dark.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/catalogue/partner_type_services_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionVehicleTypesProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show ServiceOption;
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notice.dart';

const _services = [
  ServiceOption(id: 'r', name: 'Ride'),
  ServiceOption(id: 'c', name: 'Comfort'),
  ServiceOption(id: 's', name: '6-seater'),
  ServiceOption(id: 'p', name: 'Premium'),
  ServiceOption(id: 't', name: 'Teksi'),
  ServiceOption(id: 'd', name: 'Delivery'),
  ServiceOption(id: 'f', name: 'Food'),
  ServiceOption(id: 'm', name: 'Mart'),
];

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

class _QuietAdminLive extends AdminLiveTables {
  @override
  Map<String, int> build() => const {};
}

/// `partner_type_services` held in memory, served as PostgREST would.
class _FakeTable {
  _FakeTable() {
    for (final r in [
      {'type_key': 'teksi', 'type_name': 'Teksi', 'all_services': false, 'services': ['Teksi', 'Ride', 'Comfort', '6-seater']},
      {'type_key': 'phailing', 'type_name': 'pHailing', 'all_services': false, 'services': ['Delivery', 'Food', 'Mart']},
      {'type_key': 'fleet', 'type_name': 'Fleet', 'all_services': true, 'services': <String>[]},
    ]) {
      rows[r['type_key'] as String] = {...r, 'note': null, 'updated_at': '2026-10-21T03:15:00Z', 'updated_by': null};
    }
  }

  final rows = <String, Map<String, dynamic>>{};
  final writes = <String>[];
  var _tick = 0;

  late final SupabaseClient client = SupabaseClient(
    'http://localhost',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(_handle),
  );

  http.Response _json(Object body, http.Request req) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'}, request: req);

  Future<http.Response> _handle(http.Request req) async {
    final u = req.url;
    if (!u.path.endsWith('/rest/v1/partner_type_services')) return _json([], req);
    switch (req.method) {
      case 'GET':
        final list = rows.values.toList()
          ..sort((a, b) => '${a['type_name']}'.compareTo('${b['type_name']}'));
        if ((u.queryParameters['order'] ?? '').contains('.desc')) return _json(list.reversed.toList(), req);
        return _json(list, req);
      case 'POST':
        final body = jsonDecode(req.body);
        for (final r in (body is List ? body : [body])) {
          final m = Map<String, dynamic>.from(r as Map);
          _tick++;
          rows[m['type_key'] as String] = {
            ...m,
            'updated_at': DateTime.utc(2026, 10, 21, 4, _tick).toIso8601String(),
            'updated_by': 'admin',
          };
          writes.add('upsert ${m['type_key']}');
        }
        return http.Response('', 201, request: req);
      case 'DELETE':
        final key = (u.queryParameters['type_key'] ?? '').replaceFirst('eq.', '');
        rows.remove(key);
        writes.add('delete $key');
        return http.Response('', 204, request: req);
    }
    return http.Response('', 405, request: req);
  }
}

Future<_FakeTable> _pump(WidgetTester tester, Brightness b, {Size size = const Size(1200, 2000), bool canEdit = true}) async {
  final table = _FakeTable();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        supabaseProvider.overrideWithValue(table.client),
        liveTablesProvider.overrideWith(_QuietLive.new),
        adminLiveTablesProvider.overrideWith(_QuietAdminLive.new),
        pageAccessProvider.overrideWith((ref, page) => canEdit ? AccessLevel.edit : AccessLevel.read),
        regionVehicleTypesProvider.overrideWith((ref) async => _services),
        partnerTypeNamesForServicesProvider.overrideWith((ref) async => ['TEKSI', 'eHailing', 'pHailing', 'Dealer', 'Fleet']),
      ],
      child: MaterialApp(theme: appTheme(b), home: const PartnerTypeServicesScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return table;
}

Finder _inTile(String key, String text) =>
    find.descendant(of: find.byKey(ValueKey('pts-type-$key')), matching: find.text(text));

void main() {
  test('listed under Services & catalogue next to Partner Service type, and grantable', () {
    final i = allAdminEntries.indexWhere((e) => e.path == '/admin/m/partner-type');
    final e = allAdminEntries[i + 1];
    expect(e.path, partnerTypeServicesPath);
    expect(e.section, 'Services & catalogue');
    expect(e.pages, contains(partnerTypeServicesPage));
    expect(grantablePages, contains(partnerTypeServicesPage));
    expect(liveAdminTables, contains('partner_type_services'));
  });

  for (final b in Brightness.values) {
    testWidgets('list, editor and who sees it (${b.name})', (tester) async {
      final table = await _pump(tester, b);
      expect(tester.takeException(), isNull);

      // The list: All or N of M (of the 8 services), and the summary.
      expect(_inTile('teksi', '4 of 8'), findsOneWidget);
      expect(_inTile('teksi', 'Teksi, Ride, Comfort, 6-seater'), findsOneWidget);
      expect(_inTile('fleet', 'All'), findsOneWidget);
      expect(_inTile('fleet', 'All services'), findsOneWidget);

      // Wide: the list and the editor side by side.
      final list = tester.getTopLeft(find.byKey(const ValueKey('pts-types')));
      final editor = tester.getTopLeft(find.byKey(const ValueKey('pts-editor')));
      expect(editor.dx, greaterThan(list.dx));
      expect(editor.dy, list.dy);

      // Search the list.
      await tester.enterText(find.byKey(const ValueKey('pts-type-search')), 'deliv');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pts-type-phailing')), findsOneWidget);
      expect(find.byKey(const ValueKey('pts-type-teksi')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('pts-type-search')), '');
      await tester.pumpAndSettle();

      // Pick Teksi.
      await tester.tap(find.byKey(const ValueKey('pts-type-teksi')));
      await tester.pumpAndSettle();
      expect(find.text('Sees every service, including new ones added later'), findsOneWidget);
      expect(find.text('Removing the rule lets this type see every service.'), findsOneWidget);
      expect(find.byKey(const ValueKey('pts-updated')), findsOneWidget);

      // Who sees a Delivery: pHailing and Fleet, Teksi not; partner types
      // without a rule (eHailing, Dealer) see it too.
      await tester.tap(find.byKey(const ValueKey('pts-test-Delivery')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pts-sees-teksi-no')), findsOneWidget);
      expect(find.byKey(const ValueKey('pts-sees-phailing-yes')), findsOneWidget);
      expect(find.byKey(const ValueKey('pts-sees-fleet-yes')), findsOneWidget);
      expect(find.byKey(const ValueKey('pts-sees-ehailing-yes')), findsOneWidget);
      expect(find.byKey(const ValueKey('pts-sees-dealer-yes')), findsOneWidget);

      // Tick Delivery for Teksi: the tester follows the draft, Save writes it.
      await tester.ensureVisible(find.byKey(const ValueKey('pts-service-Delivery')));
      await tester.tap(find.byKey(const ValueKey('pts-service-Delivery')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pts-sees-teksi-yes')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('pts-save')));
      await tester.tap(find.byKey(const ValueKey('pts-save')));
      await tester.pumpAndSettle();
      expect(table.writes, ['upsert teksi']);
      expect(table.rows['teksi']!['services'], ['Ride', 'Comfort', '6-seater', 'Teksi', 'Delivery']);
      expect(_inTile('teksi', '5 of 8'), findsOneWidget);

      await closeNotice(tester);
      // All services greys the ticks out and saves as All.
      await tester.tap(find.byKey(const ValueKey('pts-all')));
      await tester.pumpAndSettle();
      final chip = tester.widget<FilterChip>(find.byKey(const ValueKey('pts-service-Ride')));
      expect(chip.onSelected, isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('pts-save')));
      await tester.tap(find.byKey(const ValueKey('pts-save')));
      await tester.pumpAndSettle();
      expect(table.rows['teksi']!['all_services'], isTrue);

      await closeNotice(tester);
      // Remove asks on the page first; Cancel keeps it.
      await tester.ensureVisible(find.byKey(const ValueKey('pts-remove')));
      await tester.tap(find.byKey(const ValueKey('pts-remove')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pts-remove-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pts-remove-cancel')));
      await tester.pumpAndSettle();
      expect(table.rows, contains('teksi'));
      await tester.tap(find.byKey(const ValueKey('pts-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pts-remove-yes')));
      await tester.pumpAndSettle();
      expect(table.rows, isNot(contains('teksi')));
      expect(find.byKey(const ValueKey('pts-type-teksi')), findsNothing);

      // Add type: the Partner Type names without a rule (TEKSI again now).
      await closeAnyNotice(tester);
      await tester.tap(find.byKey(const ValueKey('pts-add')));
      await tester.pumpAndSettle();
      final picker = find.byWidgetPredicate((w) => w.runtimeType.toString().startsWith('_SearchDialog'));
      Finder choice(String s) => find.descendant(of: picker, matching: find.text(s));
      expect(choice('Dealer'), findsOneWidget);
      expect(choice('TEKSI'), findsOneWidget);
      expect(choice('Fleet'), findsNothing, reason: 'Fleet already has a rule');
      await tester.tap(choice('eHailing'));
      await tester.pumpAndSettle();
      expect(table.rows['ehailing'], isNotNull);
      expect(table.rows['ehailing']!['type_name'], 'eHailing');
      expect(table.rows['ehailing']!['all_services'], isTrue);
      expect(find.byKey(const ValueKey('pts-type-ehailing')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: stacked, read-only without the edit grant (${b.name})', (tester) async {
      await _pump(tester, b, size: const Size(390, 2400), canEdit: false);
      final list = tester.getTopLeft(find.byKey(const ValueKey('pts-types')));
      final editor = tester.getTopLeft(find.byKey(const ValueKey('pts-editor')));
      expect(editor.dy, greaterThan(list.dy));
      expect(editor.dx, list.dx);
      expect(find.byKey(const ValueKey('pts-add')), findsNothing);
      expect(find.byKey(const ValueKey('pts-save')), findsNothing);
      final chip = tester.widget<FilterChip>(find.byKey(const ValueKey('pts-service-Delivery')));
      expect(chip.onSelected, isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
