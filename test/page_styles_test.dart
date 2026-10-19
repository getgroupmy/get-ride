// App Page Settings: every page, sheet and modal is listed and goes through
// the styled helpers; the admin's values resolve own → app-wide → default
// and reach the screens; the admin page lists, previews and edits them in
// light and dark.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/meterapp/page_settings_screen.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/page_inventory.g.dart';
import 'package:get_ride/src/core/page_inventory_scan.dart';
import 'package:get_ride/src/core/page_styles.dart';
import 'package:get_ride/src/data/page_styles_repository.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart' show FareInfoSheet;
import 'package:get_ride/src/features/ride/home_parts.dart';
import 'package:get_ride/src/widgets/page_style_host.dart';

Map<String, String> _libFiles() => {
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
    if (f.path.endsWith('.dart') && !f.path.endsWith('.g.dart')) f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
};

Widget _scoped(PageStyles styles, Widget child, {Brightness b = Brightness.light}) => MaterialApp(
  theme: ThemeData(brightness: b),
  home: PageStyleScope(styles: styles, child: Scaffold(body: child)),
);

void main() {
  group('the list of pages, sheets and modals', () {
    test('is up to date: run `dart run scripts/page_inventory.dart` after adding one', () {
      expect(
        File('lib/src/core/page_inventory.g.dart').readAsStringSync(),
        inventorySource(scanSurfaces(_libFiles())),
      );
    });

    test('every sheet, modal and pushed page goes through the styled helpers', () {
      final raw = RegExp(r'\b(showModalBottomSheet|showDialog|showGeneralDialog|MaterialPageRoute)\s*(<[^(;]*>)?\(');
      final offenders = <String>[];
      _libFiles().forEach((path, src) {
        if (path.endsWith('widgets/page_style_host.dart')) return;
        final lines = src.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].trimLeft().startsWith('//')) continue;
          if (raw.hasMatch(lines[i])) offenders.add('$path:${i + 1}');
        }
      });
      expect(offenders, isEmpty, reason: 'use showAppSheet / showAppDialog / showAppGeneralDialog / AppPageRoute with an id');
    });

    test('every id is used once', () {
      final ids = <String, List<String>>{};
      final call = RegExp(r"\b(AppPageRoute|showAppSheet|showAppDialog|showAppGeneralDialog)\s*(?:<[^(]*>)?\(\s*id:\s*'([^']+)'");
      _libFiles().forEach((path, text) {
        final src = text.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');
        for (final m in call.allMatches(src)) {
          final kind = m.group(1) == 'AppPageRoute' ? 'page' : (m.group(1) == 'showAppSheet' ? 'sheet' : 'modal');
          ids.putIfAbsent('$kind:${m.group(2)}', () => []).add(path);
        }
      });
      expect({for (final e in ids.entries) if (e.value.length > 1) e.key: e.value}, isEmpty);
    });

    test('lists the router pages at their full address, and the rider, driver and admin ones', () {
      final byId = {for (final s in pageInventory) s.id: s};
      expect(byId['route:/']?.title, 'Home');
      expect(byId['route:/login/otp']?.kind, SurfaceKind.page);
      expect(byId['route:/account/settings/pin'], isNotNull, reason: 'nested routes join their parents');
      expect(byId[fareInfoSurface]?.kind, SurfaceKind.sheet);
      expect(pageInventory.map((s) => s.area).toSet(), {'Rider & shared', 'Driver', 'Admin panel'});
      expect(pageInventory.where((s) => s.kind == SurfaceKind.sheet).length, greaterThan(40));
      expect(pageInventory.where((s) => s.kind == SurfaceKind.modal).length, greaterThan(100));
      expect(pageInventory.where((s) => s.title.trim().isEmpty || s.title.contains('·  ')), isEmpty);
    });

    test('scans nested routes and the helpers, not comments', () {
      final found = scanSurfaces({
        'lib/a.dart': '''
          // showAppSheet(id: 'not-me')
          GoRoute(path: '/wallet', builder: (_, _) => const WalletScreen(), routes: [
            GoRoute(path: 'history', builder: (_, _) => const WalletHistoryScreen()),
            GoRoute(path: 'old', redirect: (_, _) => '/wallet'),
          ]);
          void f(BuildContext context) {
            showAppSheet<void>(id: 'wallet.show-receipt', context: context, builder: (_) => const Text('(i)'));
            showAppDialog(id: 'wallet.confirm-pay', context: context, builder: (_) => const SizedBox());
          }
        ''',
      });
      expect([for (final s in found) (s.id, s.title)], [
        ('modal:wallet.confirm-pay', 'Wallet · Confirm pay'),
        ('route:/wallet', 'Wallet'),
        ('route:/wallet/history', 'Wallet history'),
        ('sheet:wallet.show-receipt', 'Wallet · Receipt'),
      ]);
    });
  });

  group('values', () {
    const radius = StyleToken.number('topRadius', 'Top curve', 20, min: 0, max: 48);
    const bg = StyleToken.color('background', 'Background');
    const chosen = StyleToken.color('vehicleSelected', 'Chosen', light: 0xFFD8EEFB, dark: 0xFF2B2E8C);

    test('own value, else the app-wide one, else the default; within range', () {
      final s = PageStyles.fromRows([
        {'key': 'page_style:app', 'value': {'sheet.topRadius': 30}},
        {'key': 'page_style:sheet:a', 'value': {'topRadius': 8}},
        {'key': 'page_style:sheet:big', 'value': {'topRadius': 400}},
        {'key': 'api_providers', 'value': {'secret': 'x'}},
      ]);
      expect(s.values.keys, unorderedEquals(['app', 'sheet:a', 'sheet:big']));
      expect(s.number('sheet:a', SurfaceKind.sheet, radius), 8);
      expect(s.number('sheet:b', SurfaceKind.sheet, radius), 30);
      expect(s.number('sheet:big', SurfaceKind.sheet, radius), 48);
      expect(PageStyles.none.number('sheet:a', SurfaceKind.sheet, radius), 20);
      expect(s.isSet('sheet:b', SurfaceKind.sheet, 'topRadius'), isTrue);
      expect(PageStyles.none.isSet('sheet:b', SurfaceKind.sheet, 'topRadius'), isFalse);
    });

    test('colours for light and dark, the theme where nobody set one', () {
      final s = PageStyles({
        'route:/': {'background': '#FF112233', 'background.dark': '#000000'},
      });
      expect(s.color('route:/', SurfaceKind.page, bg, Brightness.light), const Color(0xFF112233));
      expect(s.color('route:/', SurfaceKind.page, bg, Brightness.dark), const Color(0xFF000000));
      expect(s.color('route:/x', SurfaceKind.page, bg, Brightness.light), isNull);
      expect(s.color('route:/', SurfaceKind.page, chosen, Brightness.dark), const Color(0xFF2B2E8C));
      expect(styleHex(const Color(0xFF5468FF)), '#FF5468FF');
      expect(styleColor('nope'), isNull);
    });

    test('kept on the device and read back', () {
      expect(decodePageStyles('{"route:/":{"textScale":1.2}}')?.values, {
        'route:/': {'textScale': 1.2},
      });
      expect(decodePageStyles('nonsense'), isNull);
    });

    test('nothing set leaves the theme as it is', () {
      final base = ThemeData();
      expect(styledTheme(base, const SurfaceStyle(PageStyles.none, 'route:/', SurfaceKind.page)), same(base));
    });
  });

  group('in the app', () {
    testWidgets('a sheet takes its curve, background and tallest height', (tester) async {
      final styles = PageStyles({
        'sheet:test.sheet': {'topRadius': 4, 'background': '#FF00FF00', 'maxHeight': 50},
      });
      await tester.pumpWidget(
        _scoped(
          styles,
          Builder(
            builder: (c) => TextButton(
              onPressed: () => showAppSheet<void>(id: 'test.sheet', context: c, builder: (_) => const Text('In the sheet')),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      expect(sheet.backgroundColor, const Color(0xFF00FF00));
      expect(sheet.shape, const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(4))));
      expect(sheet.constraints?.maxHeight, 300, reason: '50% of the 600 high test screen');
      expect(find.text('In the sheet'), findsOneWidget);
    });

    testWidgets('a modal takes its curve, title size and text size', (tester) async {
      final styles = PageStyles({
        'app': {'modal.cornerRadius': 6},
        'modal:test.modal': {'titleSize': 30, 'textScale': 1.5},
      });
      late double scale;
      await tester.pumpWidget(
        _scoped(
          styles,
          Builder(
            builder: (c) => TextButton(
              onPressed: () => showAppDialog<void>(
                id: 'test.modal',
                context: c,
                builder: (d) {
                  scale = MediaQuery.textScalerOf(d).scale(10) / 10;
                  return const AlertDialog(title: Text('Title'));
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(find.text('Title')));
      expect(theme.dialogTheme.shape, RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)));
      expect(theme.dialogTheme.titleTextStyle?.fontSize, 30);
      expect(scale, 1.5);
    });

    testWidgets("a router page's background follows its address", (tester) async {
      final location = ValueNotifier('/wallet');
      final styles = PageStyles({
        'route:/wallet': {'background': '#FF123456'},
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => PageStyleHost(
            styles: styles,
            location: () => location.value,
            listenable: location,
            child: child!,
          ),
          home: const Scaffold(body: Text('page')),
        ),
      );
      Color bg() => Theme.of(tester.element(find.text('page'))).scaffoldBackgroundColor;
      expect(bg(), const Color(0xFF123456));
      location.value = '/trips';
      await tester.pump();
      expect(bg(), isNot(const Color(0xFF123456)));
    });

    testWidgets('the home search bar and vehicle bar take their sizes and colours', (tester) async {
      final styles = PageStyles({
        homeSurface: {'searchFontSize': 20, 'searchRadius': 8, 'vehicleBarHeight': 90, 'vehicleSelected.dark': '#FFAA0000'},
      });
      const services = [RideService('Ride', '', 1, 4), RideService('XL', '', 1.5, 6)];
      await tester.pumpWidget(
        _scoped(
          styles,
          Column(
            children: [
              HomeSearchPill(onTap: () {}),
              VehicleTypeBar(services: services, selected: services.first, onSelect: (_) {}),
            ],
          ),
          b: Brightness.dark,
        ),
      );
      final text = tester.widget<Text>(find.text('Where to & for how much?'));
      expect(text.style?.fontSize, 20);
      expect(tester.getSize(find.byKey(const ValueKey('vehicle-type-bar'))).height, 90);
      expect(tester.widget<Material>(find.byKey(const ValueKey('vehicle-type-Ride'))).color, const Color(0xFFAA0000));
    });

    testWidgets('the fare sheet takes its picture and text sizes', (tester) async {
      final styles = PageStyles({
        fareInfoSurface: {'titleSize': 32, 'imageWidth': 200},
      });
      await tester.pumpWidget(
        _scoped(styles, const FareInfoSheet(service: RideService('Ride', '', 1, 4), rates: ['Base fare: RM4'])),
      );
      expect(tester.widget<Text>(find.text('Ride')).style?.fontSize, 32);
      expect(tester.getSize(find.byKey(const ValueKey('fare-details-sheet')).first).width, greaterThan(0));
    });
  });

  group('admin page', () {
    Future<void> pump(WidgetTester tester, {Brightness b = Brightness.light, bool edit = true}) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pageStylesProvider.overrideWith(
              (_) async => const PageStyles({
                homeSurface: {'searchFontSize': 18},
              }),
            ),
            adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
          ],
          child: MaterialApp(theme: ThemeData(brightness: b), home: const AdminPageSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    test('filters by words and by kind', () {
      final sheets = filterSurfaces(pageInventory, '', SurfaceKind.sheet);
      expect(sheets.every((s) => s.kind == SurfaceKind.sheet), isTrue);
      expect(filterSurfaces(pageInventory, 'fare info', null).map((s) => s.id), contains(fareInfoSurface));
      expect(filterSurfaces(pageInventory, '/wallet/history', null).single.id, 'route:/wallet/history');
    });

    testWidgets('the search hint is short; what it searches stays under it', (tester) async {
      await pump(tester);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('page-settings-search')));
      expect(field.decoration?.hintText, 'Search pages');
      expect(field.decoration?.helperText, 'Pages, sheets and modals');
    });

    for (final b in Brightness.values) {
      testWidgets('lists every surface, opens one with its preview and edits it (${b.name})', (tester) async {
        await pump(tester, b: b);
        expect(find.byKey(const ValueKey('page-settings-tile-app')), findsOneWidget);
        expect(find.text('Edited'), findsOneWidget, reason: 'home has a value');
        await tester.enterText(find.byKey(const ValueKey('page-settings-search')), 'Home');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('page-settings-tile-route:/')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('page-settings-preview')), findsOneWidget);
        // The real search bar in the preview, at the stored size.
        expect(tester.widget<Text>(find.text('Where to & for how much?')).style?.fontSize, 18);
        expect(find.byKey(const ValueKey('page-settings-save')), findsNothing);
        await tester.scrollUntilVisible(find.byKey(const ValueKey('page-style-searchFontSize')), 200,
            scrollable: find.byType(Scrollable).last);
        final slider = find.byKey(const ValueKey('page-style-searchFontSize'));
        await tester.drag(slider, const Offset(200, 0));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('page-settings-save')), findsOneWidget);
        expect(tester.widget<Text>(find.text('Where to & for how much?')).style?.fontSize, greaterThan(18));
        await tester.tap(find.byKey(const ValueKey('page-style-reset-searchFontSize')));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(find.text('Where to & for how much?')).style?.fontSize, 16, reason: 'the default');
      });
    }

    testWidgets('colours are picked for light and dark', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('page-settings-tile-app')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('page-style-background.dark')), 200,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.byKey(const ValueKey('page-style-background.dark')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('style-color-hex')), '#101820');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('style-color-ok')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-settings-save')), findsOneWidget);
      expect(find.byKey(const ValueKey('page-style-reset-background')), findsOneWidget);
    });

    testWidgets('read-only access sees values but cannot change them', (tester) async {
      await pump(tester, edit: false);
      await tester.enterText(find.byKey(const ValueKey('page-settings-search')), 'Fare info');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('page-settings-tile-sheet:fare-info')));
      await tester.pumpAndSettle();
      expect(find.text('Base fare: RM4'), findsOneWidget, reason: 'the real fare sheet in the preview');
      final slider = tester.widget<Slider>(find.byKey(const ValueKey('page-style-titleSize')));
      expect(slider.onChanged, isNull);
    });
  });
}
