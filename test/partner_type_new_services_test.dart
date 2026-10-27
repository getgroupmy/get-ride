// Admin → Partner Service type → Add (0300, docs/KIV.md H3): a new type
// must say which services it takes. Nothing ticked: the form says so and
// nothing is saved; ticked: the button counts them, and the type and its
// rule (only those services) are saved together. Editing a type has no
// such list. Light and dark.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/screens/catalogue/catalogue_data.dart';
import 'package:get_ride/src/admin/screens/catalogue/partner_type_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionVehicleTypesProvider, regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show ServiceOption;
import 'package:get_ride/src/admin/screens/people/vehicle_permits_screen.dart' show adminPermitTypesProvider;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/partner_type_services.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

const _services = [
  ServiceOption(id: 'r', name: 'Ride'),
  ServiceOption(id: 'c', name: 'Comfort'),
  ServiceOption(id: 'p', name: 'Premium'),
  ServiceOption(id: 'w', name: 'Courier Walker'),
];

final _types = [
  SettingEntry(id: 'dealer', values: {'name': 'Dealer', 'enabled': true, 'isDefault': true, 'displayPriority': 1}),
];

class _Admin extends AdminRepository {
  _Admin(super.db);
  final saved = <(String?, Map<String, dynamic>)>[];

  @override
  Future<void> saveSetting(SettingsCategory c, {String? id, required Map<String, dynamic> values, int? position}) async =>
      saved.add((id, values));
}

void main() {
  test('the rule of a new type: only the picked services, in the list order', () {
    expect(newTypeServicesProblem(const []), 'Pick at least one service, or the type takes no jobs.');
    expect(newTypeServicesProblem(const ['Ride']), isNull);
    expect(addTypeLabel(0), 'Add Partner Service type');
    expect(addTypeLabel(1), 'Add Partner Service type (1 service)');
    expect(addTypeLabel(2), 'Add Partner Service type (2 services)');
    final r = newTypeRule(' Airport Shuttle ', const ['premium', 'Ride'], const ['Ride', 'Comfort', 'Premium']);
    expect(r.typeKey, 'airportshuttle');
    expect(r.typeName, 'Airport Shuttle');
    expect(r.allServices, isFalse);
    expect(r.services, ['Ride', 'Premium']);
  });

  for (final b in Brightness.values) {
    group('Add Partner Service type (${b.name})', () {
      late List<Map<String, dynamic>> upserts;

      Future<_Admin> pump(WidgetTester tester) async {
        upserts = [];
        final db = SupabaseClient(
          'http://localhost',
          'anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((req) async {
            if (req.method == 'POST' && req.url.path.endsWith('/rest/v1/partner_type_services')) {
              upserts.add(Map<String, dynamic>.from(jsonDecode(req.body) as Map));
              return http.Response('', 201, request: req);
            }
            return http.Response('[]', 200, headers: {'content-type': 'application/json'}, request: req);
          }),
        );
        final admin = _Admin(db);
        await tester.binding.setSurfaceSize(const Size(900, 3600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              supabaseProvider.overrideWithValue(db),
              ...quietLiveOverrides,
              adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: true)])),
              adminRepositoryProvider.overrideWithValue(admin),
              catalogueEntriesProvider.overrideWith(
                (ref, c) async => c.key == partnerTypeCategory.key ? _types : const <SettingEntry>[],
              ),
              regionVehicleTypesProvider.overrideWith((ref) async => _services),
              regionsProvider.overrideWith((ref) async => const []),
              adminPermitTypesProvider.overrideWith((ref) async => const []),
            ],
            child: MaterialApp(theme: appTheme(b), home: const PartnerTypeScreen()),
          ),
        );
        await tester.pumpAndSettle();
        return admin;
      }

      Future<void> tapKey(WidgetTester tester, String key) async {
        final f = find.byKey(ValueKey(key));
        await tester.ensureVisible(f);
        await _settle(tester);
        await tester.tap(f);
        await _settle(tester);
      }

      Future<void> tapSave(WidgetTester tester, String label) async {
        final f = find.widgetWithText(FilledButton, label).last;
        await tester.ensureVisible(f);
        await _settle(tester);
        await tester.tap(f);
        await _settle(tester);
      }

      testWidgets('nothing ticked is refused; the picked services are saved with the type', (tester) async {
        final admin = await pump(tester);
        await tester.tap(find.text('Add Partner Service type').first);
        await _settle(tester);
        expect(find.text('Services this type takes *'), findsOneWidget);
        for (final s in _services) {
          expect(find.byKey(ValueKey('partner-type-takes-${s.name}')), findsOneWidget);
        }
        await tester.enterText(find.widgetWithText(TextField, 'Name *'), 'Airport Shuttle');
        await _settle(tester);

        await tapSave(tester, 'Add Partner Service type');
        expect(find.text('Pick at least one service, or the type takes no jobs.'), findsWidgets);
        expect(admin.saved, isEmpty);
        expect(upserts, isEmpty);

        await tapKey(tester, 'partner-type-takes-all');
        expect(find.widgetWithText(FilledButton, 'Add Partner Service type (4 services)'), findsOneWidget);
        await tapKey(tester, 'partner-type-takes-clear');
        await tapKey(tester, 'partner-type-takes-Premium');
        await tapKey(tester, 'partner-type-takes-Ride');
        await tapSave(tester, 'Add Partner Service type (2 services)');

        expect(admin.saved.single.$1, isNull);
        expect(admin.saved.single.$2['name'], 'Airport Shuttle');
        expect(upserts.single['type_key'], 'airportshuttle');
        expect(upserts.single['all_services'], isFalse);
        expect(upserts.single['services'], ['Ride', 'Premium']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('editing a type has no services list (Services each type sees changes them)', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Dealer').first);
        await _settle(tester);
        expect(find.text('Edit Partner Service type'), findsOneWidget);
        expect(find.text('Services this type takes *'), findsNothing);
      });
    });
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
