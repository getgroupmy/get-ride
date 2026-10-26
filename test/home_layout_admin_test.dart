// Admin → Display Settings → Home page: the sections in order with their
// switches, moving one, the search words, and a place's own layout made and
// dropped, in light and dark; read-only access sees but cannot change.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_store.dart';
import 'package:get_ride/src/admin/screens/meterapp/home_layout_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/home_layout.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _FakeStore implements DisplaySettingsStore {
  _FakeStore(Map<String, dynamic> raw) : blob = mergeDisplaySettings(raw);
  Map<String, dynamic> blob;

  @override
  Future<Map<String, dynamic>> fetch() async => blob;

  @override
  Future<Map<String, dynamic>> update(DisplayEdit edit) async => blob = edit(blob);

  @override
  Future<List<Map<String, dynamic>>> entries(String category) async => const [];
}

Future<_FakeStore> _pump(WidgetTester tester, Brightness b, {AccessLevel access = AccessLevel.edit}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = _FakeStore(const {});
  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      pageAccessProvider.overrideWith((ref, page) => access),
      displayStoreProvider.overrideWithValue(store),
      regionsProvider.overrideWith((ref) async => [
            RegionEntry(id: 'my', values: const {'country': 'Malaysia'}),
            RegionEntry(id: 'png', values: const {'country': 'Malaysia', 'state': 'Penang'}),
          ]),
    ],
    child: MaterialApp(theme: appTheme(b), home: const HomeLayoutScreen()),
  ));
  await tester.pumpAndSettle();
  return store;
}

/// Off the screen, and past the live connection's 50 s goodbye.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

List<String> _order(Map<String, dynamic> blob, [RegionScope? place]) {
  final ls = HomeLayouts.fromSettings(blob);
  final l = place == null ? ls.master : ls.places[place.key]!.layout;
  return [for (final s in l.sections) s.id];
}

void main() {
  const penang = RegionScope(country: 'Malaysia', state: 'Penang');

  for (final b in Brightness.values) {
    testWidgets('master: switch, move and reword (${b.name})', (tester) async {
      final store = await _pump(tester, b);
      expect(tester.takeException(), isNull);
      for (final label in ['Search bar', 'Vehicle bar', 'Pickup row', 'Upcoming ride', 'Recent places', 'Service boxes', 'Sheet fold']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // Today's home screen until the admin saves.
      expect(store.blob.containsKey(homeLayoutKey), isFalse);

      await _tap(tester, find.widgetWithText(SwitchListTile, 'Vehicle bar'));
      expect(HomeLayouts.fromSettings(store.blob).master.shows(HomeSectionType.vehicles), isFalse);

      await _tap(tester, find.descendant(
          of: find.byKey(const ValueKey('home-section-boxes')), matching: find.byTooltip('Move up')));
      expect(_order(store.blob), ['search', 'vehicles', 'pickup', 'upcoming', 'boxes', 'recent', 'fold']);

      await tester.enterText(find.widgetWithText(TextFormField, 'Words in the bar'), 'Ke mana?');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(HomeLayouts.fromSettings(store.blob).master.of(HomeSectionType.search)!.text, 'Ke mana?');

      // Recent places: one fewer with the sheet down.
      await _tap(tester, find.byTooltip('Fewer'));
      expect(HomeLayouts.fromSettings(store.blob).master.of(HomeSectionType.recent)!.atRest, 1);
      await _unmount(tester);
    });

    testWidgets('a place follows the master, gets its own, goes back (${b.name})', (tester) async {
      final store = await _pump(tester, b);
      await _tap(tester, find.byKey(const ValueKey('home-layout-place')));
      await _tap(tester, find.text('Penang').last);
      expect(find.text('Penang follows Master'), findsOneWidget);
      expect(find.text('Search bar'), findsNothing, reason: 'nothing to edit while it follows');

      await _tap(tester, find.byKey(const ValueKey('home-layout-own')));
      expect(HomeLayouts.fromSettings(store.blob).places.keys, [penang.key]);
      expect(find.byKey(ValueKey('home-layout-chip-${penang.key}')), findsOneWidget);

      // Its changes stay its own.
      await _tap(tester, find.widgetWithText(SwitchListTile, 'Upcoming ride'));
      expect(HomeLayouts.fromSettings(store.blob).layoutFor(penang).shows(HomeSectionType.upcoming), isFalse);
      expect(HomeLayouts.fromSettings(store.blob).master.shows(HomeSectionType.upcoming), isTrue);

      await _tap(tester, find.byKey(const ValueKey('home-layout-follow')));
      expect(HomeLayouts.fromSettings(store.blob).places, isEmpty);
      expect(find.text('Penang follows Master'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  }

  testWidgets('read-only access sees the layout but cannot change it', (tester) async {
    await _pump(tester, Brightness.light, access: AccessLevel.read);
    final tile = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Vehicle bar'));
    expect(tile.onChanged, isNull);
    expect(tester.widget<IconButton>(find.descendant(
        of: find.byKey(const ValueKey('home-section-boxes')), matching: find.byType(IconButton)).first).onPressed, isNull);
    await _unmount(tester);
  });
}
