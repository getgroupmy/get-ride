// Home page › Service boxes: rows and places, each box's picture place, the
// badge whose words take turns (pure), the grid as riders see it, and the
// admin's editor, in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_store.dart';
import 'package:get_ride/src/admin/screens/meterapp/home_boxes_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/home_layout.dart';
import 'package:get_ride/src/core/home_sections.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/service_boxes.dart';
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

HomeSection _boxes(Map<String, dynamic> blob) => HomeLayouts.fromSettings(blob).master.of(HomeSectionType.boxes)!;

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
  group('rows and places', () {
    test('shapes, unknown ones read as two, places named for the admin', () {
      final rows = boxRowsOf(['kbl', 'k3', 'zz']);
      expect(rows, [BoxRowKind.bigLeft, BoxRowKind.three, BoxRowKind.two]);
      final places = boxPlaces(rows);
      expect(places.length, 8);
      expect([for (final p in places.take(3)) p.name], ['Row 1 · big left', 'Row 1 · right top', 'Row 1 · right bottom']);
      expect([for (final p in places.take(3)) p.tall], [true, false, false]);
      expect(places.last.name, 'Row 3 · right');
      expect(boxPlaces([BoxRowKind.one]).single.name, 'Row 1');
      expect(boxTallHeight, boxShortHeight * 2 + boxGap);
    });

    test('the layout before rows: big left with two beside it, then two', () {
      expect(HomeSection.of(HomeSectionType.boxes).rows, [BoxRowKind.bigLeft, BoxRowKind.two]);
    });
  });

  group('badge', () {
    test('words keep their colours through storage; colours read from #RGB hex', () {
      const w = BadgeWord('50% OFF', fill: badgeGreen);
      expect(BadgeWord.fromJson(w.toJson()), w);
      expect(w.toJson(), {'t': '50% OFF', 'bg': '#2E7D32', 'fg': '#FFFFFF'});
      expect(BadgeWord.fromJson('NEW'), const BadgeWord('NEW'));
      expect(parseArgb('#c6f135'), 0xFFC6F135);
      expect(parseArgb('80000000'), 0x80000000);
      expect(parseArgb('nope'), isNull);
    });

    test('turns: each word for its seconds, round and round; one word stays', () {
      expect(badgeWordAt(const Duration(milliseconds: 1999), 2, 2), 0);
      expect(badgeWordAt(const Duration(milliseconds: 2000), 2, 2), 1);
      expect(badgeWordAt(const Duration(seconds: 4), 2, 2), 0);
      expect(badgeWordAt(const Duration(seconds: 9), 1, 2), 0);
      const words = [BadgeWord('NEW'), BadgeWord('50% OFF')];
      expect(badgeTurns(words, flip: false), [words.first]);
      expect(badgeTurns(words, flip: true), words);
    });

    test('a box look: values kept in range, defaults as before', () {
      const look = BoxLook({'size': 999, 'x': -80, 'badgeSize': 3, 'flipSecs': 'x', 'badgeAt': 'cc'});
      expect(look.size, boxPictureMax);
      expect(look.shiftX, -boxShiftMax);
      expect(look.badgeSize, badgeSizeMin);
      expect(look.flipSeconds, badgeSecondsDefault);
      // A badge only takes a corner it knows; the middle reads as top right.
      expect(look.badgeAt, BoxAnchor.center);
      expect(const BoxLook({}).anchor, BoxAnchor.bottomRight);
      expect(const BoxLook({}).badgeOn, isNull);
    });

    test('the picture: its size from the box height, bottom right, moved and allowed past the edge', () {
      final r = boxPictureRect(const BoxLook({'size': 80}), 160, 100);
      expect((r.left, r.top, r.side), (80.0, 20.0, 80.0));
      final moved = boxPictureRect(const BoxLook({'size': 80, 'x': 10, 'y': 10}), 160, 100);
      expect((moved.left, moved.top), (96.0, 30.0));
      final topLeft = boxPictureRect(const BoxLook({'size': 50, 'anchor': 'tl'}), 160, 100);
      expect((topLeft.left, topLeft.top), (14.0, 40.0));
    });
  });

  group('box views', () {
    test('any number of own boxes; their badge: own words, none, else SOON while closed', () {
      final views = serviceBoxViews(const {}, boxes: [
        {'name': 'Groceries', 'route': '/wallet', 'badgeOn': true, 'badgeWords': [
          {'t': 'NEW', 'bg': '#E5483F'},
          {'t': '50% OFF', 'bg': '#2E7D32'},
        ]},
        {'name': 'Quiet', 'badgeOn': false},
        {'name': 'Closed'},
        {'name': 'Sixth', 'route': '/wallet'},
        {}, {}, {},
      ]);
      expect(views.length, 7);
      expect([for (final w in views[0].badgeWords) w.text], ['NEW', '50% OFF']);
      expect(views[1].badgeWords, isEmpty);
      expect(views[2].badge, 'SOON');
      // Own boxes never take the old switch's NEW.
      expect(serviceBoxViews(const {}, boxes: [{'route': '/wallet'}], newBadge: true).first.badgeWords, isEmpty);
    });
  });

  for (final b in Brightness.values) {
    testWidgets('the grid: rows of the admin, empty places, the badge flipping (${b.name})', (tester) async {
      final views = serviceBoxViews(const {}, boxes: [
        {'name': 'Rides', 'badgeOn': true, 'badgeWords': [
          {'t': 'NEW', 'bg': '#E5483F'},
          {'t': '50% OFF', 'bg': '#2E7D32'},
        ], 'flipSecs': 2},
        {'name': 'Groceries'},
        {'name': 'Food'},
      ]);
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(b),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: ServiceBoxesGrid(boxes: views, rows: const [BoxRowKind.twoTall, BoxRowKind.two], onOpen: (_) {}),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const ValueKey('service-box-0'))).height, boxTallHeight);
      expect(tester.getSize(find.byKey(const ValueKey('service-box-2'))).height, boxShortHeight);
      expect(find.byKey(const ValueKey('service-box-3')), findsNothing, reason: 'an empty place');
      final badge = find.byKey(const ValueKey('service-box-badge-0'));
      expect(find.descendant(of: badge, matching: find.text('NEW')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.descendant(of: badge, matching: find.text('50% OFF')), findsOneWidget);
      final pill = tester.widget<Container>(find.ancestor(of: find.text('50% OFF'), matching: find.byType(Container)).first);
      expect((pill.decoration! as BoxDecoration).color, const Color(badgeGreen));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('with reduced motion the words still change, without the flip', (tester) async {
    await tester.pumpWidget(const MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: MaterialApp(home: FlipBadge(words: [BadgeWord('NEW'), BadgeWord('50% OFF')], seconds: 1)),
    ));
    expect(find.byType(AnimatedSwitcher), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('50% OFF'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('admin editor', () {
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
        ],
        child: MaterialApp(theme: appTheme(b), home: screen),
      ));
      await tester.pumpAndSettle();
      return store;
    }

    for (final b in Brightness.values) {
      testWidgets('rows, adding and moving boxes (${b.name})', (tester) async {
        final store = await pump(tester, b, const HomeBoxesScreen(place: RegionScope.all));
        // Display Settings' five until edited here.
        expect(find.text('5 places · 5 boxes'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('home-boxes-preset-Two big')));
        expect(_boxes(store.blob).rows, [BoxRowKind.twoTall, BoxRowKind.two]);
        expect(_boxes(store.blob).boxes!.length, 5);
        expect(find.text('4 places · 5 boxes · 1 not shown'), findsOneWidget);

        // Every place taken: a new box brings a row of two.
        await _tap(tester, find.byKey(const ValueKey('home-boxes-add')));
        expect(_boxes(store.blob).boxes!.length, 6);
        expect(_boxes(store.blob).rows.length, 3);

        final first = _boxes(store.blob).boxes![0]['id'];
        await _tap(tester, find.descendant(of: find.byKey(const ValueKey('home-boxes-box-0')), matching: find.byTooltip('Move down')));
        expect(_boxes(store.blob).boxes![1]['id'], first);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });

      testWidgets('a box: badge words in their own colours, flip, picture place, remove (${b.name})', (tester) async {
        final store = await pump(tester, b, const HomeBoxScreen(place: RegionScope.all, index: 0));
        // Box 1 carries the old switch's NEW: already its own words.
        expect(tester.widget<SegmentedButton<String>>(find.byKey(const ValueKey('home-box-badge-mode'))).selected, {'own'});
        await _tap(tester, find.byKey(const ValueKey('home-box-add-word')));
        final words = BoxLook(_boxes(store.blob).boxes![0]).badgeWords;
        expect(words, const [BadgeWord('NEW'), BadgeWord('50% OFF', fill: badgeGreen)]);

        // The second word in blue.
        await _tap(tester, find.bySemanticsLabel('#1F6FEB').at(1));
        expect(BoxLook(_boxes(store.blob).boxes![0]).badgeWords[1].fill, 0xFF1F6FEB);

        await _tap(tester, find.byKey(const ValueKey('anchor-tl')).first);
        expect(BoxLook(_boxes(store.blob).boxes![0]).anchor, BoxAnchor.topLeft);

        await _tap(tester, find.widgetWithText(SwitchListTile, 'Flip between the words'));
        expect(BoxLook(_boxes(store.blob).boxes![0]).flip, isFalse);

        await _tap(tester, find.byKey(const ValueKey('home-box-remove')));
        expect(_boxes(store.blob).boxes!.length, 4);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });
    }
  });
}
