import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/screens/catalogue/catalogue_data.dart';
import 'package:get_ride/src/admin/screens/catalogue/partner_type_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Admin extends AdminRepository {
  _Admin() : super(_db);
  final saved = <(String?, Map<String, dynamic>)>[];

  @override
  Future<void> saveSetting(SettingsCategory c, {String? id, required Map<String, dynamic> values, int? position}) async =>
      saved.add((id, values));
}

final _types = [
  SettingEntry(id: 'dealer', values: {'name': 'Dealer', 'enabled': true, 'isDefault': true, 'displayPriority': 1}),
  SettingEntry(
    id: 'ehail',
    values: {'name': 'eHailing', 'enabled': true, 'isDefault': true, 'vehicleRequired': true, 'displayPriority': 2},
  ),
];

final _regions = [
  RegionEntry(id: 'my', values: {'country': 'Malaysia'}),
  RegionEntry(id: 'sg', values: {'country': 'Singapore'}),
  RegionEntry(id: 'sel', values: {'country': 'Malaysia', 'state': 'Selangor'}),
  RegionEntry(id: 'kl', values: {'country': 'Malaysia', 'state': 'Kuala Lumpur'}),
];

void main() {
  for (final b in Brightness.values) {
    group('Partner Type rules editor (${b.name})', () {
      Future<_Admin> pump(WidgetTester tester) async {
        final admin = _Admin();
        await tester.binding.setSurfaceSize(const Size(900, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              supabaseProvider.overrideWithValue(_db),
              ...quietLiveOverrides,
              adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: true)])),
              adminRepositoryProvider.overrideWithValue(admin),
              catalogueEntriesProvider.overrideWith(
                (ref, c) async => c.key == partnerTypeCategory.key ? _types : const <SettingEntry>[],
              ),
              regionsProvider.overrideWith((ref) async => _regions),
            ],
            child: MaterialApp(theme: appTheme(b), home: const PartnerTypeScreen()),
          ),
        );
        await tester.pumpAndSettle();
        return admin;
      }

      Future<void> open(WidgetTester tester, String name) async {
        await tester.tap(find.text(name).first);
        await _settle(tester);
        expect(find.text('Edit Partner Type'), findsOneWidget);
      }

      Future<void> save(WidgetTester tester) async {
        final button = find.text('Save changes');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await _settle(tester);
      }

      Future<void> tapKey(WidgetTester tester, String key) async {
        final f = find.byKey(ValueKey(key));
        await tester.ensureVisible(f);
        await _settle(tester);
        await tester.tap(f);
        await _settle(tester);
      }

      testWidgets('vehicle rules show only with Vehicle required on; availability always', (tester) async {
        await pump(tester);
        await open(tester, 'Dealer');
        expect(find.text('Max vehicle age limit'), findsNothing);
        expect(find.text('Permit'), findsNothing);
        expect(find.text('Allow hail service'), findsNothing);
        expect(find.text('Service availability'), findsOneWidget);

        final vehicle = find.widgetWithText(SwitchListTile, 'Vehicle required');
        await tester.ensureVisible(vehicle);
        await tester.tap(vehicle);
        await _settle(tester);
        expect(find.text('Max vehicle age limit'), findsOneWidget);
        expect(find.text('Permit'), findsOneWidget);
        expect(find.text('Allow hail service'), findsOneWidget);
      });

      testWidgets('ages are 1 to 50 and "required" needs a rule or a region; then it saves', (tester) async {
        final admin = await pump(tester);
        await open(tester, 'eHailing');
        expect(find.text('Max vehicle age limit'), findsOneWidget);

        await tapKey(tester, 'rule-age-required');
        await save(tester);
        expect(find.textContaining('Add at least one vehicle age rule'), findsOneWidget);
        expect(admin.saved, isEmpty);

        // An all-regions rule (the dialog starts on All regions) of 60
        // years: out of range.
        await tapKey(tester, 'age-rule-add');
        await tester.tap(find.byKey(const ValueKey('region-scope-ok')));
        await _settle(tester);
        await tester.enterText(find.byKey(const ValueKey('age-rule-years-0')), '60');
        await save(tester);
        expect(find.text('A vehicle age limit is 1 to 50 years.'), findsOneWidget);
        expect(find.text('Enter 1 to 50 years'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('age-rule-years-0')), '10');

        // A narrower rule for Selangor.
        await tapKey(tester, 'age-rule-add');
        await tester.tap(find.byKey(const ValueKey('region-scope-all')));
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('region-country-')));
        await _settle(tester);
        await tester.tap(find.text('Malaysia').last);
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('region-state-Malaysia')));
        await _settle(tester);
        await tester.tap(find.text('Selangor').last);
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('region-scope-ok')));
        await _settle(tester);
        expect(find.text('Selangor, Malaysia'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('age-rule-years-1')), '7');

        // Permit required with no region picked: refused.
        await tapKey(tester, 'rule-permit-required');
        await tapKey(tester, 'permit-scope');
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('permit-scope')), matching: find.text('Selected')));
        await _settle(tester);
        await save(tester);
        expect(find.textContaining('regions where a permit is required'), findsOneWidget);
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('permit-scope')), matching: find.text('All regions')));
        await _settle(tester);

        await save(tester);
        expect(admin.saved, hasLength(1));
        final (id, values) = admin.saved.single;
        expect(id, 'ehail');
        final rules = values['rules'] as Map<String, dynamic>;
        expect(rules['vehicleAge'], {
          'required': true,
          'rules': [
            {'maxYears': 10},
            {'country': 'Malaysia', 'state': 'Selangor', 'maxYears': 7},
          ],
        });
        expect(rules['permit'], {'required': true, 'all': true, 'regions': <Object>[]});
        expect((rules['availability'] as Map)['all'], true);
        expect(values['isDefault'], true, reason: 'a default type stays default');
      });

      testWidgets('a type never edited keeps no rules; availability needs a region when "Selected"', (tester) async {
        final admin = await pump(tester);
        await open(tester, 'Dealer');
        await tapKey(tester, 'availability-scope');
        await tester.tap(
          find.descendant(of: find.byKey(const ValueKey('availability-scope')), matching: find.text('Selected')),
        );
        await _settle(tester);
        await save(tester);
        expect(find.textContaining('regions where this partner type is offered'), findsOneWidget);

        await tapKey(tester, 'availability-add');
        await tester.tap(find.byKey(const ValueKey('region-country-')));
        await _settle(tester);
        await tester.tap(find.text('Singapore').last);
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('region-scope-ok')));
        await _settle(tester);
        expect(find.byKey(const ValueKey('availability-region-singapore')), findsOneWidget);
        await save(tester);
        final values = admin.saved.single.$2;
        expect((values['rules'] as Map)['availability'], {
          'all': false,
          'regions': [
            {'country': 'Singapore'},
          ],
        });
      });

      testWidgets('saving untouched rules writes none', (tester) async {
        final admin = await pump(tester);
        await open(tester, 'eHailing');
        await save(tester);
        expect(admin.saved.single.$2.containsKey('rules'), isFalse);
      });
    });
  }
}

/// The row's spinner turns while its editor is open, so pumpAndSettle
/// never settles: frames for a moment instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
