// The rate card editor (Admin → Settings → Meter Digital Setting): its title
// and Save show at desktop and phone sizes in light and dark, a Save makes
// the round trip, leaving with unsaved changes asks first, and an update
// that changes no row is an error, not "Rate card saved".
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/commerce/commerce_widgets.dart' show FormDialogScaffold;
import 'package:get_ride/src/admin/screens/meterapp/meter_digital_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_store.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/providers.dart' show supabaseProvider;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notice.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _global = defaultMeterProfile.copyWith(id: 'm1', label: () => 'Global (TEKSI old rates)', autoLaunch: false);

/// Cards kept in memory; [failNext] makes the next save throw it.
class _FakeStore implements MeterSettingsStore {
  _FakeStore(List<MeterProfile> cards) : cards = [...cards];
  final List<MeterProfile> cards;
  final saved = <MeterProfile>[];
  Object? failNext;

  @override
  List<String> get missingGroups => const [];

  @override
  Future<List<MeterProfile>> fetch() async => [...cards];

  @override
  Future<void> save(MeterProfile profile) async {
    final fail = failNext;
    failNext = null;
    if (fail != null) throw fail;
    saved.add(profile);
    cards
      ..removeWhere((c) => c.id == profile.id)
      ..add(profile);
  }

  @override
  Future<String?> savePanels(MeterProfile profile, MeterPanels panels) async => profile.id;

  @override
  Future<void> delete(String id) async => cards.removeWhere((c) => c.id == id);
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pumpScreen(WidgetTester tester, _FakeStore store, {Brightness b = Brightness.light}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
      meterStoreProvider.overrideWithValue(store),
      meterProfilesProvider.overrideWith((ref) => ref.watch(meterStoreProvider).fetch()),
    ],
    child: MaterialApp(theme: appTheme(b), home: const AdminMeterDigitalScreen()),
  ));
  await tester.pumpAndSettle();
}

Future<void> _openGlobal(WidgetTester tester) async {
  await tester.tap(find.text('Global (TEKSI old rates)'));
  await tester.pumpAndSettle();
}

final _barSave = find.byKey(const ValueKey('meter-card-save-bar'));
final _bottomSave = find.byKey(const ValueKey('meter-card-save-bottom'));

Finder _launchSwitch() => find.widgetWithText(SwitchListTile, 'Open the meter on launch');

void main() {
  for (final b in Brightness.values) {
    for (final (name, size) in [('desktop 2000×1240', const Size(2000, 1240)), ('phone 390×844', const Size(390, 844))]) {
      testWidgets('title and Save show on the $name, ${b.name}', (tester) async {
        _size(tester, size);
        await _pumpScreen(tester, _FakeStore([_global]), b: b);
        await _openGlobal(tester);
        expect(tester.takeException(), isNull, reason: 'the editor lays out without errors');

        final screen = Offset.zero & size;
        final bar = find.byType(AppBar);
        final barRect = tester.getRect(bar);
        final title = find.descendant(of: bar, matching: find.text('Global rate card'));
        expect(title, findsOneWidget);
        final titleRect = tester.getRect(title);
        expect(titleRect.width, greaterThan(40), reason: 'the title has room in the bar');
        expect(barRect.contains(titleRect.center), isTrue);

        for (final save in [_barSave, _bottomSave]) {
          expect(save, findsOneWidget);
          final r = tester.getRect(save);
          expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight - const Offset(1, 1)), isTrue,
              reason: '$save is on screen');
          final label = save == _barSave && size.width < 600 ? 'Save' : 'Save rate card';
          expect(find.descendant(of: save, matching: find.text(label)), findsOneWidget);
        }
        final barSave = tester.getRect(_barSave);
        expect(barRect.contains(barSave.center), isTrue);
        expect(barSave.width, lessThan(size.width / 2), reason: 'the bar button has its own width');
        expect(barSave.left, greaterThan(titleRect.left), reason: 'Save sits after the title');

        // Title text reads against the bar in this brightness.
        final barColor = tester
            .widget<Material>(find.descendant(of: bar, matching: find.byType(Material)).first)
            .color!;
        final titleColor = tester.widget<RichText>(find.descendant(of: title, matching: find.byType(RichText))).text.style!.color!;
        expect(titleColor.toARGB32(), isNot(barColor.toARGB32()));
        final l1 = titleColor.computeLuminance(), l2 = barColor.computeLuminance();
        final contrast = ((l1 > l2 ? l1 : l2) + 0.05) / ((l1 > l2 ? l2 : l1) + 0.05);
        expect(contrast, greaterThan(4.5));
      });
    }
  }

  testWidgets('a switch changed and saved is there on reopening', (tester) async {
    _size(tester, const Size(2000, 1240));
    final store = _FakeStore([_global]);
    await _pumpScreen(tester, store);
    await _openGlobal(tester);

    expect(tester.widget<SwitchListTile>(_launchSwitch()).value, isFalse);
    await tester.ensureVisible(_launchSwitch());
    await tester.pumpAndSettle();
    await tester.tap(_launchSwitch());
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(_launchSwitch()).value, isTrue);

    await tester.tap(_barSave);
    await tester.pumpAndSettle();
    expect(find.byType(MeterCardEditor), findsNothing, reason: 'Save closes the editor');
    expect(find.text('Rate card saved'), findsOneWidget);
    expect(store.saved.single.id, 'm1');
    expect(store.saved.single.autoLaunch, isTrue);

    await closeNotice(tester);
    await _openGlobal(tester);
    expect(tester.widget<SwitchListTile>(_launchSwitch()).value, isTrue, reason: 'the reopened card shows the save');
  });

  testWidgets('the bottom Save bar saves too (phone)', (tester) async {
    _size(tester, const Size(390, 844));
    final store = _FakeStore([_global]);
    await _pumpScreen(tester, store, b: Brightness.dark);
    await _openGlobal(tester);
    await tester.ensureVisible(_launchSwitch());
    await tester.pumpAndSettle();
    await tester.tap(_launchSwitch());
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(_launchSwitch()).value, isTrue);
    await tester.tap(_bottomSave);
    await tester.pumpAndSettle();
    expect(store.saved.single.autoLaunch, isTrue);
    expect(find.byType(MeterCardEditor), findsNothing);
  });

  for (final b in Brightness.values) {
    testWidgets('leaving with unsaved changes asks first (${b.name})', (tester) async {
      _size(tester, const Size(2000, 1240));
      final store = _FakeStore([_global]);
      await _pumpScreen(tester, store, b: b);
      await _openGlobal(tester);

      // Nothing changed: X just closes.
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.byType(MeterCardEditor), findsNothing);
      expect(find.text('Discard changes?'), findsNothing);

      await _openGlobal(tester);
      await tester.ensureVisible(_launchSwitch());
      await tester.pumpAndSettle();
      await tester.tap(_launchSwitch());
      await tester.pumpAndSettle();

      // X: asked, Keep editing stays.
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(MeterCardEditor), findsOneWidget);
      expect(tester.widget<SwitchListTile>(_launchSwitch()).value, isTrue);

      // Back (the system / browser back): asked, Discard leaves unsaved.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(MeterCardEditor), findsNothing);
      expect(store.saved, isEmpty);

      // A typed change counts too.
      await _openGlobal(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Card name (optional)'), 'Renamed');
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
    });
  }

  testWidgets('a save that changed no row is an error and keeps the editor open', (tester) async {
    _size(tester, const Size(2000, 1240));
    final store = _FakeStore([_global])..failNext = const MeterNotSavedException();
    await _pumpScreen(tester, store);
    await _openGlobal(tester);
    await tester.ensureVisible(_launchSwitch());
    await tester.pumpAndSettle();
    await tester.tap(_launchSwitch());
    await tester.pumpAndSettle();
    await tester.tap(_barSave);
    await tester.pumpAndSettle();
    expect(find.text('Rate card saved'), findsNothing);
    expect(find.textContaining('no rate card was changed'), findsOneWidget);
    expect(find.byType(MeterCardEditor), findsOneWidget);
  });

  group('MeterSettingsStore update checks the row came back', () {
    MeterSettingsStore storeAnswering(List<Map<String, dynamic>> rows, List<http.Request> seen) => MeterSettingsStore(
          SupabaseClient(
            'http://localhost',
            'anon',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((r) async {
              seen.add(r);
              return http.Response(jsonEncode(rows), 200, headers: {'content-type': 'application/json'}, request: r);
            }),
          ),
        );

    test('0 rows updated throws MeterNotSavedException', () async {
      final seen = <http.Request>[];
      final store = storeAnswering(const [], seen);
      await expectLater(store.save(_global), throwsA(isA<MeterNotSavedException>()));
      expect(seen.single.method, 'PATCH');
      expect(seen.single.url.queryParameters['id'], 'eq.m1');
      expect(seen.single.url.queryParameters['select'], 'id');
      await expectLater(store.savePanels(_global, allPanelsOn()), throwsA(isA<MeterNotSavedException>()));
    });

    test('1 row updated saves', () async {
      final seen = <http.Request>[];
      final store = storeAnswering(const [
        {'id': 'm1'},
      ], seen);
      await store.save(_global);
      expect(await store.savePanels(_global, allPanelsOn()), 'm1');
      expect(jsonDecode(seen.first.body)['auto_launch'], isFalse);
    });
  });

  testWidgets('the commerce form bar (same full-width button) keeps its title and Save', (tester) async {
    _size(tester, const Size(2000, 1240));
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: FormDialogScaffold(title: 'Edit product', onSave: () async {}, children: const [Text('body')]),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.text('Edit product')).width, greaterThan(40));
    final save = tester.getRect(find.widgetWithText(FilledButton, 'Save'));
    expect(save.width, lessThan(400));
    expect(save.right, lessThanOrEqualTo(2000));
  });
}
