// Settings → App icon (light and dark), the admin's card, and the sync that
// only asks the phone to switch when the icon differs.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/app_icon_card.dart';
import 'package:get_ride/src/core/app_icons.dart';
import 'package:get_ride/src/data/app_icon_service.dart';
import 'package:get_ride/src/features/settings/app_icon_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePlatform extends AppIconPlatform {
  _FakePlatform({this.supportedHere = true});

  final bool supportedHere;
  String icon = standardAppIcon;
  final sets = <String>[];

  @override
  bool get supported => supportedHere;

  @override
  Future<String?> current() async => icon;

  @override
  Future<bool> set(String id) async {
    sets.add(id);
    icon = id;
    return true;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  List<Override> overrides(_FakePlatform platform, AppIconConfig config) => [
    appIconPlatformProvider.overrideWithValue(platform),
    appIconConfigProvider.overrideWith((_) async => config),
    appIconRegionsProvider.overrideWith((_) async => const <String>{}),
  ];

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget child, {
    _FakePlatform? platform,
    AppIconConfig config = AppIconConfig.standard,
    ThemeData? theme,
  }) async {
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(overrides: overrides(platform ?? _FakePlatform(), config));
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: theme, home: child),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  for (final dark in [false, true]) {
    final theme = dark ? ThemeData.dark() : ThemeData.light();
    testWidgets('picking an icon keeps it on the phone (${dark ? 'dark' : 'light'})', (tester) async {
      final c = await pump(tester, const AppIconScreen(), theme: theme);
      expect(find.byKey(const ValueKey('app-icon-automatic')), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget, reason: 'Automatic is the default');
      for (final i in appIcons) {
        expect(find.byKey(ValueKey('app-icon-${i.id}')), findsOneWidget, reason: i.id);
      }
      final images = tester.widgetList<Image>(find.byType(Image)).map((i) => '${i.image}').join(' ');
      expect(images, dark ? contains('_dark.webp') : isNot(contains('_dark.webp')));

      await tester.tap(find.byKey(const ValueKey('app-icon-g_dot')));
      await tester.pumpAndSettle();
      expect(c.read(appIconChoiceProvider), 'g_dot');
      expect((await SharedPreferences.getInstance()).getString('app_icon_choice'), 'g_dot');

      await tester.tap(find.byKey(const ValueKey('app-icon-automatic')));
      await tester.pumpAndSettle();
      expect(c.read(appIconChoiceProvider), automaticAppIcon);
    });
  }

  testWidgets('when the admin decides, the page says so and nothing can be picked', (tester) async {
    final c = await pump(
      tester,
      const AppIconScreen(),
      config: AppIconConfig.standard.copyWith(allowUserChoice: false, automatic: false, fixedIcon: 'get_dot'),
    );
    expect(find.byKey(const ValueKey('app-icon-locked')), findsOneWidget);
    expect(find.textContaining('GET.'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('app-icon-g_dot')));
    await tester.pumpAndSettle();
    expect(c.read(appIconChoiceProvider), automaticAppIcon);
  });

  testWidgets('the Settings row only where icons can change', (tester) async {
    await pump(tester, const Scaffold(body: AppIconTile()));
    expect(find.byKey(const ValueKey('settings-app-icon')), findsOneWidget);
    expect(find.text('Automatic'), findsOneWidget);
    await pump(tester, const Scaffold(body: AppIconTile()), platform: _FakePlatform(supportedHere: false));
    expect(find.byKey(const ValueKey('settings-app-icon')), findsNothing);
  });

  test('the phone is only asked when the icon differs', () async {
    final platform = _FakePlatform();
    final c = ProviderContainer(
      overrides: overrides(platform, AppIconConfig.standard.copyWith(automatic: false, fixedIcon: 'payday')),
    );
    addTearDown(c.dispose);
    await c.read(appIconConfigProvider.future);
    await c.read(appIconRegionsProvider.future);
    final sync = c.read(appIconSyncProvider);
    await sync.sync();
    expect(platform.sets, ['payday']);
    await sync.sync();
    expect(platform.sets, ['payday'], reason: 'already showing');
    await c.read(appIconChoiceProvider.notifier).set('christmas');
    await sync.sync();
    expect(platform.sets, ['payday', 'christmas']);
  });

  for (final dark in [false, true]) {
    testWidgets('admin card: fixed icon and a new window (${dark ? 'dark' : 'light'})', (tester) async {
      await pump(
        tester,
        const Scaffold(body: SingleChildScrollView(child: AppIconCard(canEdit: true))),
        theme: dark ? ThemeData.dark() : ThemeData.light(),
      );
      expect(find.text('Home-screen icon'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-icon-fixed')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('app-icon-auto')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-icon-fixed')), findsOneWidget);

      final before = defaultIconSchedule.length;
      expect(find.byKey(ValueKey('app-icon-window-${before - 1}')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('app-icon-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-icon-add')));
      await tester.pumpAndSettle();
      final done = find.byKey(const ValueKey('app-icon-window-done'));
      expect(tester.widget<FilledButton>(done).onPressed, isNull, reason: 'no dates yet');
      await tester.enterText(find.byKey(const ValueKey('app-icon-window-start')), '03-01');
      await tester.enterText(find.byKey(const ValueKey('app-icon-window-end')), '03-03');
      await tester.pumpAndSettle();
      await tester.tap(done);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(ValueKey('app-icon-window-$before')));
      await tester.pumpAndSettle();
      expect(find.text('03-01 – 03-03 every year'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
