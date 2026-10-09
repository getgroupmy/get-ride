import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/admin/screens/geo/regions_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Repo extends GeoAdminRepository {
  _Repo(this.entries, {this.defaults}) : super(_db);
  final List<RegionEntry> entries;
  final Map<String, dynamic>? defaults;
  final saved = <Map<String, dynamic>>[];
  final asked = <String>[];

  @override
  Future<List<RegionEntry>> regions() async => entries;
  @override
  Future<List<ServiceOption>> services() async => const [];
  @override
  Future<Map<String, dynamic>?> regionDefaults(String country) async {
    asked.add(country);
    return defaults;
  }

  @override
  Future<void> saveRegion({String? id, required Map<String, dynamic> values, int position = 0}) async =>
      saved.add(values);
}

const _api = {
  'iso2': 'MY',
  'country': 'Malaysia',
  'currencyName': 'MYR',
  'currencySymbol': 'RM',
  'callingCode': '+60',
  'languageCode': 'en-MY',
  'dateFormat': 'DD/MM/YYYY',
  'timezone': 'Asia/Kuala_Lumpur',
  'emergencyNumber': null,
  'lat': 3.1412,
  'lng': 101.68653,
};

void main() {
  group('pure', () {
    test('the sheet asks for the page level\'s own name; parents are shown', () {
      expect(RegionLevel.values.map(regionNameField), ['country', 'state', 'city', 'suburb']);
      final f = RegionForm(country: 'Malaysia', state: 'Selangor', city: 'Kajang');
      expect(regionParentLine(f, RegionLevel.suburb), 'In Kajang, Selangor, Malaysia');
      expect(regionParentLine(f, RegionLevel.city), 'In Selangor, Malaysia');
      expect(regionParentLine(f, RegionLevel.state), 'In Malaysia');
      expect(regionParentLine(f, RegionLevel.country), '');
    });

    test('defaults: the API fills, the hand-checked list wins for language and emergency number', () {
      final f = RegionForm(country: 'Malaysia');
      final filled = applyRegionDefaults(f, _api);
      expect([f.currencyName, f.currencySymbol, f.callingCode], ['MYR', 'RM', '+60']);
      expect([f.dateFormat, f.timezone], ['DD/MM/YYYY', 'Asia/Kuala_Lumpur']);
      expect([f.languageCode, f.emergencyNumber], ['ms-MY', '999']);
      expect([f.lat, f.lng], ['3.14120', '101.68653']);
      expect(filled, containsAll(['currency', 'time zone', 'emergency number', 'position']));

      // A position already there is kept.
      final g = RegionForm(country: 'Malaysia', lat: '1', lng: '2');
      applyRegionDefaults(g, _api);
      expect([g.lat, g.lng], ['1', '2']);

      // Unreachable: the built-in list still answers what it knows.
      final h = RegionForm(country: 'Malaysia');
      expect(applyRegionDefaults(h, null), ['emergency number', 'language']);
      expect(applyRegionDefaults(RegionForm(country: 'Atlantis'), null), isEmpty);
    });
  });

  Future<_Repo> pump(WidgetTester tester, {Map<String, dynamic>? defaults}) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repo([
      RegionEntry(id: 'c1', values: {'country': 'Malaysia', 'state': '', 'city': '', 'suburb': ''}),
      RegionEntry(id: 's1', values: {'country': 'Malaysia', 'state': 'Selangor', 'city': '', 'suburb': ''}),
    ], defaults: defaults);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
          geoAdminRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(home: AdminRegionsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('adding a state on Malaysia\'s page asks only for the state', (tester) async {
    final repo = await pump(tester);
    await tester.tap(find.text('Malaysia'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add state').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('region-parent')), findsOneWidget);
    expect(find.text('In Malaysia'), findsOneWidget);
    expect(field('State'), findsOneWidget);
    for (final other in ['Country', 'City', 'Suburb']) {
      expect(field(other), findsNothing, reason: other);
    }
    expect(find.text('Country information'), findsNothing);

    await tester.enterText(field('State'), 'Johor');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(repo.saved.single['country'], 'Malaysia');
    expect(repo.saved.single['state'], 'Johor');
    expect(repo.saved.single['city'], '');
    await _drain(tester);
  });

  testWidgets('adding a country: Fill defaults pulls its details', (tester) async {
    final repo = await pump(tester, defaults: _api);
    await tester.tap(find.text('Add country').first);
    await tester.pumpAndSettle();
    expect(field('State'), findsNothing);
    expect(find.byKey(const ValueKey('region-parent')), findsNothing);

    await tester.enterText(field('Country'), 'Malaysia');
    await tester.tap(find.byKey(const ValueKey('region-fill-defaults')));
    await tester.pumpAndSettle();
    expect(repo.asked, ['Malaysia']);
    String text(String label) => tester.widget<TextField>(field(label)).controller!.text;
    expect(text('Currency name'), 'MYR');
    expect(text('Calling code'), '+60');
    expect(text('Time zone'), 'Asia/Kuala_Lumpur');
    expect(text('Language code'), 'ms-MY');
    await _drain(tester);
  });
}

/// Lets the success note and any realtime retry run out.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}
