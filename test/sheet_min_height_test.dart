// Admin → Display Settings → "Bottom sheet minimum height": the pure height
// rules (the adjustment's range, the floor and the cap), the admin's row on
// the home, confirm and tracking cards in light and dark, and the rider's
// tracking sheet resting lower or higher as the admin sets it. The home and
// confirm sheets are covered in home_confirm_test.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_store.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/demo_mode.dart';
import 'package:get_ride/src/core/sheet_min_height.dart';
import 'package:get_ride/src/data/app_display_repository.dart' show displaySettingsBlobProvider;
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/ride/demo_ride.dart' show demoSettingsProvider;
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// The settings row kept in memory, edits applied as the real store does.
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

Future<_FakeStore> _pumpAdmin(WidgetTester tester, Brightness b, [Map<String, dynamic> raw = const {}]) async {
  tester.view.physicalSize = const Size(900, 2400);
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
    child: MaterialApp(theme: appTheme(b), home: const AdminDisplaySettingsScreen()),
  ));
  await tester.pumpAndSettle();
  return store;
}

/// Off the screen, and past the live connection's 50 s goodbye.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

String _text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

bool _enabled(WidgetTester tester, String key) {
  final button = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(IconButton));
  return tester.widget<IconButton>(button).onPressed != null;
}

class _Rides implements RideRepository {
  @override
  Future<Map<String, double>> nearbyDrivers(double lat, double lng) async => const {};

  @override
  Future<void> expireStaleOpen() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The display settings blob as the phone reads it, changed live.
class _Display extends Notifier<Map<String, dynamic>> {
  @override
  Map<String, dynamic> build() => const {};

  void set(Map<String, dynamic> next) => state = next;
}

final _display = NotifierProvider<_Display, Map<String, dynamic>>(_Display.new);

/// The rider's ride screen on an open request (searching), on a phone tall
/// enough that the sheet rests below its highest.
Future<ProviderContainer> _pumpTracking(WidgetTester tester, Brightness b, Map<String, dynamic> display) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(430, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  final rows = StreamController<RideRequest>.broadcast();
  addTearDown(rows.close);
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      rideRepositoryProvider.overrideWithValue(_Rides()),
      rideStreamProvider.overrideWith((ref, id) => rows.stream),
      riderPositionStreamProvider.overrideWithValue(() => const Stream<LatLng>.empty()),
      fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
      walletBalancesProvider.overrideWith((ref) async => const []),
      walletTxProvider.overrideWith((ref) async => const []),
      displaySettingsBlobProvider.overrideWith((ref) async => ref.watch(_display)),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      demoSettingsProvider.overrideWithValue(const DemoSettings()),
    ],
  );
  addTearDown(container.dispose);
  container.read(_display.notifier).set(display);
  final router = GoRouter(
    initialLocation: '/ride',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
      GoRoute(path: '/ride', builder: (_, _) => const RideTrackingScreen(requestId: 'r1')),
    ],
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
  ));
  await tester.pump();
  rows.add(RideRequest({
    'id': 'r1',
    'rider_id': 'me',
    'status': 'open',
    'fare': 20,
    'currency': 'MYR',
    'pickup_name': 'KLCC',
    'drop_name': 'KL Sentral',
    'offer_me': true,
    'created_at': DateTime.now().toUtc().toIso8601String(),
  }));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  return container;
}

/// The sheet's top edge once pulled all the way down and let go.
Future<double> _restTop(WidgetTester tester) async {
  await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, 600));
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return tester.getRect(find.byKey(const ValueKey('map-sheet-header'))).top;
}

void main() {
  group('height rules', () {
    test('automatic plus the adjustment, between the floor and the highest', () {
      expect(effectiveSheetMin(auto: 300, adjust: 0, floor: 100, max: 700), 300);
      expect(effectiveSheetMin(auto: 300, adjust: 120, floor: 100, max: 700), 420);
      expect(effectiveSheetMin(auto: 300, adjust: -60, floor: 100, max: 700), 240);
      // Never under the floor: the first item whole.
      expect(effectiveSheetMin(auto: 130, adjust: -60, floor: 100, max: 700), 100);
      // Never over the sheet's highest.
      expect(effectiveSheetMin(auto: 650, adjust: 300, floor: 100, max: 700), 700);
      // A floor above the highest: the highest wins.
      expect(effectiveSheetMin(auto: 200, adjust: -60, floor: 900, max: 700), 700);
    });

    test('the stored adjustment: 0 unset, numbers or text, kept to −60…+300', () {
      expect(sheetMinAdjust(null, homeSheetMinAdjustKey), 0);
      expect(sheetMinAdjust(const {}, homeSheetMinAdjustKey), 0);
      expect(sheetMinAdjust(const {homeSheetMinAdjustKey: 40}, homeSheetMinAdjustKey), 40);
      expect(sheetMinAdjust(const {homeSheetMinAdjustKey: ' -30 '}, homeSheetMinAdjustKey), -30);
      expect(sheetMinAdjust(const {homeSheetMinAdjustKey: -500}, homeSheetMinAdjustKey), -60);
      expect(sheetMinAdjust(const {homeSheetMinAdjustKey: 900}, homeSheetMinAdjustKey), 300);
      expect(sheetMinAdjust(const {homeSheetMinAdjustKey: 'tall'}, homeSheetMinAdjustKey), 0);
    });

    test('defaults hold 0 for each sheet; a stepper edit is clamped and rounded', () {
      final d = defaultDisplaySettings();
      for (final k in [homeSheetMinAdjustKey, confirmSheetMinAdjustKey, trackingSheetMinAdjustKey]) {
        expect(d[k], 0);
        expect(displayNum(const {}, k), 0);
      }
      final s = setDisplayNumber(d, homeSheetMinAdjustKey, 412, sheetMinAdjustMin, sheetMinAdjustMax);
      expect(s[homeSheetMinAdjustKey], 300);
    });

    test("the admin's estimate follows the switches and keeps the adjustment", () {
      final only = {'rideTypes': false, 'recentLocations': false, 'serviceCategories': true, homeSheetMinAdjustKey: 20};
      final e = sheetMinEstimate(only, homeSheetMinAdjustKey);
      expect(e.automatic, 186);
      expect(e.total, 206);
      expect(
        e.breakdown,
        'Items shown: Search Bar 48 + Service Categories 84 + handle and gaps = 186 px automatic · '
        'your adjustment +20 px = 206 px',
      );
      // Recent Locations on: up by its height and a gap, the +20 kept.
      final more = sheetMinEstimate({...only, 'recentLocations': true}, homeSheetMinAdjustKey);
      expect(more.total - e.total, 116 + sheetItemGap);
      expect(more.adjust, 20);
      // Taken right down it stops at the search bar whole.
      final low = sheetMinEstimate({'rideTypes': false, 'recentLocations': false, homeSheetMinAdjustKey: -60},
          homeSheetMinAdjustKey);
      expect(low.total, low.floor);
      expect(low.atFloor, isTrue);
      expect(low.breakdown, contains('your adjustment -60 px'));
      // Confirm and tracking have their own items.
      expect(sheetMinEstimate(const {}, confirmSheetMinAdjustKey).breakdown, contains('Vehicle cards'));
      expect(sheetMinEstimate(const {}, trackingSheetMinAdjustKey).breakdown, contains('Driver card'));
    });
  });

  for (final b in Brightness.values) {
    group('admin row (${b.name})', () {
      testWidgets('shows the total, how it adds up, and moves with − and +', (tester) async {
        final store = await _pumpAdmin(tester, b);
        expect(find.text('Bottom sheet minimum height'), findsNWidgets(3));
        final home = sheetMinEstimate(store.blob, homeSheetMinAdjustKey);
        expect(_text(tester, '$homeSheetMinAdjustKey-value'), '${home.total} px');
        expect(_text(tester, '$homeSheetMinAdjustKey-breakdown'), home.breakdown);
        expect(_text(tester, '$homeSheetMinAdjustKey-breakdown'), contains('Search Bar 48'));
        // At automatic: Back to automatic has nothing to do.
        final reset = find.byKey(const ValueKey('$homeSheetMinAdjustKey-reset'));
        final resetButton = find.descendant(of: reset, matching: find.byType(TextButton));
        expect(tester.widget<TextButton>(resetButton).onPressed, isNull);

        await _tap(tester, find.byKey(const ValueKey('$homeSheetMinAdjustKey-increase')));
        await _tap(tester, find.byKey(const ValueKey('$homeSheetMinAdjustKey-increase')));
        expect(store.blob[homeSheetMinAdjustKey], 20);
        expect(_text(tester, '$homeSheetMinAdjustKey-value'), '${home.total + 20} px');
        expect(
          _text(tester, '$homeSheetMinAdjustKey-breakdown'),
          endsWith('your adjustment +20 px = ${home.total + 20} px'),
        );
        await _tap(tester, find.byKey(const ValueKey('$homeSheetMinAdjustKey-decrease')));
        expect(store.blob[homeSheetMinAdjustKey], 10);

        // The confirm and tracking rows keep their own.
        await _tap(tester, find.byKey(const ValueKey('$trackingSheetMinAdjustKey-decrease')));
        expect(store.blob[trackingSheetMinAdjustKey], -10);
        expect(store.blob[confirmSheetMinAdjustKey], 0);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });

      testWidgets('turning a section on raises the figure by it and keeps the adjustment', (tester) async {
        final store = await _pumpAdmin(tester, b, const {homeSheetMinAdjustKey: 20});
        final before = sheetMinEstimate(store.blob, homeSheetMinAdjustKey).total;
        expect(_text(tester, '$homeSheetMinAdjustKey-value'), '$before px');
        await _tap(tester, find.widgetWithText(SwitchListTile, 'Service Categories'));
        expect(store.blob['serviceCategories'], isTrue);
        expect(_text(tester, '$homeSheetMinAdjustKey-value'), '${before + 84 + sheetItemGap} px');
        expect(_text(tester, '$homeSheetMinAdjustKey-breakdown'), contains('Service Categories 84'));
        expect(store.blob[homeSheetMinAdjustKey], 20);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });

      testWidgets('Back to automatic clears the adjustment; − and + stop at their ends', (tester) async {
        final store = await _pumpAdmin(tester, b, const {confirmSheetMinAdjustKey: 300});
        expect(_enabled(tester, '$confirmSheetMinAdjustKey-increase'), isFalse, reason: 'at +300');
        await _tap(tester, find.byKey(const ValueKey('$confirmSheetMinAdjustKey-reset')));
        expect(store.blob[confirmSheetMinAdjustKey], 0);
        final e = sheetMinEstimate(store.blob, confirmSheetMinAdjustKey);
        expect(_text(tester, '$confirmSheetMinAdjustKey-value'), '${e.automatic} px');
        expect(_text(tester, '$confirmSheetMinAdjustKey-breakdown'), contains('your adjustment 0 px'));
        expect(_enabled(tester, '$confirmSheetMinAdjustKey-increase'), isTrue);
        // The ride-confirm sheet goes down to 150 px and stops there.
        for (var i = 0; i < 60 && _enabled(tester, '$confirmSheetMinAdjustKey-decrease'); i++) {
          await _tap(tester, find.byKey(const ValueKey('$confirmSheetMinAdjustKey-decrease')));
        }
        expect(_text(tester, '$confirmSheetMinAdjustKey-value'), '$confirmSheetMinFloor px');
        expect(_enabled(tester, '$confirmSheetMinAdjustKey-decrease'), isFalse, reason: 'at 150 px');
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });

      testWidgets('− stops at the floor: the search bar alone, whole', (tester) async {
        await _pumpAdmin(tester, b, const {'rideTypes': false, 'recentLocations': false, homeSheetMinAdjustKey: -20});
        final e = sheetMinEstimate(
          mergeDisplaySettings(const {'rideTypes': false, 'recentLocations': false, homeSheetMinAdjustKey: -20}),
          homeSheetMinAdjustKey,
        );
        expect(e.atFloor, isTrue);
        expect(_text(tester, '$homeSheetMinAdjustKey-value'), '${e.floor} px');
        expect(_enabled(tester, '$homeSheetMinAdjustKey-decrease'), isFalse);
        expect(_enabled(tester, '$homeSheetMinAdjustKey-increase'), isTrue);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });
    });
  }

  // The rider's tracking sheet while searching: its rest line is the route
  // card; the admin's px move it.
  for (final b in Brightness.values) {
    testWidgets('tracking: the adjustment moves the least height by its px (${b.name})', (tester) async {
      Future<double> top(Map<String, dynamic> display) async {
        await _pumpTracking(tester, b, display);
        return _restTop(tester);
      }

      final auto = await top(const {});
      expect(auto - await top(const {trackingSheetMinAdjustKey: 50}), closeTo(50, 1));
      expect(await top(const {trackingSheetMinAdjustKey: -60}) - auto, closeTo(60, 1));
      // Its search header stays whole however low.
      expect(
        tester.getRect(find.byKey(const ValueKey('search-header-slot'))).top,
        greaterThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('map-sheet-header'))).bottom),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tracking: an admin change moves the resting sheet live (${b.name})', (tester) async {
      final container = await _pumpTracking(tester, b, const {});
      final auto = await _restTop(tester);
      double top() => tester.getRect(find.byKey(const ValueKey('map-sheet-header'))).top;
      container.read(_display.notifier).set(const {trackingSheetMinAdjustKey: 80});
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(auto - top(), closeTo(80, 1));
      // Back to automatic: down again.
      container.read(_display.notifier).set(const {trackingSheetMinAdjustKey: 0});
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(top(), closeTo(auto, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
