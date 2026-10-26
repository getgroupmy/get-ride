// Home page added sections: tile rows, wide tile rows and promo cards — the
// model (pure), what riders see, and the admin adding, editing and removing
// them, in light and dark.
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
import 'package:get_ride/src/admin/screens/meterapp/home_tiles_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/home_layout.dart';
import 'package:get_ride/src/core/home_tiles.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/service_boxes.dart' show BoxAnchor;
import 'package:get_ride/src/features/ride/home_parts.dart';
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

const _wide = HomeSection({
  'id': 'c2c',
  'type': 'wide',
  'title': 'City to City',
  'route': '/wallet',
  'seeAll': 'Book a ride',
  'items': [
    {'id': 'ipoh', 'caption': 'Kuala Lumpur — Ipoh', 'sub': 'From RM 180', 'label': '2 hours', 'labelBg': '#C6F135', 'labelFg': '#1B1D22', 'route': '/wallet'},
    {'id': 'off', 'caption': 'Hidden', 'on': false},
    {'id': 'melaka', 'caption': 'Kuala Lumpur — Melaka', 'label': 'New', 'labelAt': 'tl'},
  ],
});

HomeLayout _master(Map<String, dynamic> blob) => HomeLayouts.fromSettings(blob).master;

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

void main() {
  group('model', () {
    test('added sections: as many as wanted, removable; built-in parts are not', () {
      var l = _master(const {});
      l = l.added(newTileSection(HomeSectionType.tiles)).added(newTileSection(HomeSectionType.promos));
      final saved = HomeLayouts.fromSettings(withMasterHomeLayout(const {}, l)).master;
      expect(saved.sections.where((s) => s.type == HomeSectionType.tiles).length, 1);
      expect(saved.sections.last.type, HomeSectionType.promos, reason: 'added at the end, under the fold');
      final tilesId = saved.sections.firstWhere((s) => s.type == HomeSectionType.tiles).id;
      expect(saved.removed(tilesId).byId(tilesId), isNull);
      expect(saved.removed('search').byId('search'), isNotNull, reason: 'a built-in part stays');
      expect(HomeSectionType.tiles.builtIn, isFalse);
    });

    test('tiles: what is set, defaults, across, the width of each', () {
      expect(_wide.tiles.length, 3);
      expect(_wide.shownTiles.map((t) => t.id), ['ipoh', 'melaka']);
      final t = _wide.tiles.first;
      expect((t.caption, t.sub, t.label, t.labelFill, t.labelInk, t.labelAt), ('Kuala Lumpur — Ipoh', 'From RM 180', '2 hours', 0xFFC6F135, 0xFF1B1D22, BoxAnchor.bottomRight));
      expect(_wide.tiles[2].labelAt, BoxAnchor.topLeft);
      expect(t.size, tilePictureDefault);
      expect(const HomeTile({'size': 900}).size, tilePictureMax);
      expect(_wide.across, 2, reason: 'wide tiles two across unless set');
      expect(const HomeSection({'type': 'tiles', 'across': 7}).across, 3);
      expect(tileWidth(320, 3), closeTo((320 - 24) / 3.15, 0.001));
      expect(newTile(HomeSectionType.promos).background, isNotNull);
      expect(newTile(HomeSectionType.tiles).route, isNull, reason: 'Coming Soon until given a page');
    });
  });

  for (final b in Brightness.values) {
    testWidgets('riders see the heading, the tiles shown, labels in their colours, see all (${b.name})', (tester) async {
      final opened = <String?>[];
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(b),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: Column(children: [
              HomeTileRow(section: _wide, onOpen: (r, _) => opened.add(r)),
              HomePromoRow(
                section: const HomeSection({'id': 'p', 'type': 'promos', 'items': [
                  {'id': 'safe', 'caption': 'Safety above all', 'bg': '#DDF7C9'},
                  {'id': 'dark', 'caption': 'Night rides', 'bg': '#1E2127'},
                ]}),
                onOpen: (r, _) => opened.add(r),
              ),
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('City to City'), findsOneWidget);
      expect(find.text('Hidden'), findsNothing, reason: 'switched off');
      expect(find.text('From RM 180'), findsOneWidget);
      final label = tester.widget<Container>(find.byKey(const ValueKey('home-tile-label-ipoh')));
      expect((label.decoration! as BoxDecoration).color, const Color(0xFFC6F135));
      // Promo words white on a dark card.
      expect(tester.widget<Text>(find.text('Night rides')).style!.color, Colors.white);
      await tester.tap(find.byKey(const ValueKey('home-tile-ipoh')));
      await tester.tap(find.byKey(const ValueKey('home-tile-melaka')));
      expect(opened, ['/wallet', null]);
      await tester.drag(find.byKey(const ValueKey('home-tile-ipoh')), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-tiles-see-all-c2c')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  group('admin', () {
    Future<_FakeStore> pump(WidgetTester tester, Brightness b, Widget screen, [Map<String, dynamic> raw = const {}]) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = _FakeStore(raw);
      await tester.pumpWidget(ProviderScope(
        retry: (_, _) => null,
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
          displayStoreProvider.overrideWithValue(store),
          regionsProvider.overrideWith((ref) async => <RegionEntry>[]),
        ],
        child: MaterialApp(theme: appTheme(b), home: screen),
      ));
      await tester.pumpAndSettle();
      return store;
    }

    for (final b in Brightness.values) {
      testWidgets('add a tile row and a promo row, then remove one (${b.name})', (tester) async {
        final store = await pump(tester, b, const HomeLayoutScreen());
        await _tap(tester, find.byKey(const ValueKey('home-add-tiles')));
        await _tap(tester, find.byKey(const ValueKey('home-add-promos')));
        final added = [for (final s in _master(store.blob).sections) if (!s.type!.builtIn) s];
        expect(added.map((s) => s.type), [HomeSectionType.tiles, HomeSectionType.promos]);
        expect(find.text('Tile row: New section'), findsOneWidget);
        await _tap(tester, find.byKey(ValueKey('home-remove-${added.first.id}')));
        expect(_master(store.blob).byId(added.first.id), isNull);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });

      testWidgets('a section: across, a tile added, a tile switched off; a tile: label words and colour (${b.name})', (tester) async {
        final store = await pump(tester, b, const HomeTilesScreen(place: RegionScope.all, sectionId: 'c2c'), {
          homeLayoutKey: {
            'sections': [_wide.raw],
          },
        });
        await _tap(tester, find.text('4'));
        expect(_master(store.blob).byId('c2c')!.across, 4);
        await _tap(tester, find.byKey(const ValueKey('home-tiles-add')));
        expect(_master(store.blob).byId('c2c')!.tiles.length, 4);
        await _tap(tester, find.descendant(of: find.byKey(const ValueKey('home-tiles-item-0')), matching: find.byType(Switch)));
        expect(_master(store.blob).byId('c2c')!.tiles.first.on, isFalse);
        expect(tester.takeException(), isNull);
        await _unmount(tester);

        final s2 = await pump(tester, b, const HomeTileScreen(place: RegionScope.all, sectionId: 'c2c', index: 0), store.blob);
        await tester.enterText(find.widgetWithText(TextFormField, '2 hours'), '3 hours');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(_master(s2.blob).byId('c2c')!.tiles.first.label, '3 hours');
        await _tap(tester, find.descendant(of: find.byKey(const ValueKey('home-tile-label-bg')), matching: find.bySemanticsLabel('#E5483F')));
        expect(_master(s2.blob).byId('c2c')!.tiles.first.labelFill, 0xFFE5483F);
        await _tap(tester, find.text('Top left'));
        expect(_master(s2.blob).byId('c2c')!.tiles.first.labelAt, BoxAnchor.topLeft);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });
    }
  });
}
