// The latest build to download / install directly: lib/src/core/app_builds.dart,
// the Admin → App Release panel and the public install page.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/app_branding.dart';
import 'package:get_ride/src/core/app_builds.dart';
import 'package:get_ride/src/features/install/app_install_screen.dart';
import 'package:get_ride/src/widgets/app_build_widgets.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _ipa = 'https://github.com/getgroupmy/get-ride/releases/download/ios-latest/getride.ipa';
const _apk = 'https://github.com/getgroupmy/get-ride/releases/download/android-latest/getride.apk';
const _aab = 'https://github.com/getgroupmy/get-ride/releases/download/android-latest/getride.aab';
const _itms =
    'itms-services://?action=download-manifest&url=https%3A%2F%2Fx.supabase.co%2Ffunctions%2Fv1%2Fapp-install';

AppBuild _ios({bool installable = true}) => AppBuild.fromJson('ios', {
  'available': true,
  'version': '1.4.3',
  'build': '107',
  'size': 52 * 1024 * 1024,
  'installable': installable,
  'created_at': '2026-10-12T06:00:00Z',
  'download_url': _ipa,
  if (installable) 'install_url': _itms,
});

AppBuild _android() => AppBuild.fromJson('android', {
  'available': true,
  'version': '1.4.3',
  'build': '88',
  'size': 31 * 1024 * 1024,
  'installable': true,
  'download_url': _apk,
  'install_url': _apk,
});

void main() {
  group('the build', () {
    test('read from app-install', () {
      final b = _ios();
      expect(b.available, isTrue);
      expect(b.label, '1.4.3 (107)');
      expect(b.installable, isTrue);
      expect(b.installUrl, _itms);
      expect(b.fileName, 'getride.ipa');
      expect(formatBuildSize(b.size), '52.0 MB');
      expect(_android().fileName, 'getride.apk');
    });

    test('nothing published, or nothing safe to open, is nothing on offer', () {
      expect(AppBuild.fromJson('ios', {'available': false}).available, isFalse);
      expect(AppBuild.fromJson('ios', null).available, isFalse);
      expect(
        AppBuild.fromJson('android', {'available': true, 'download_url': 'http://evil/app.apk'}).available,
        isFalse,
        reason: 'https only',
      );
      expect(
        AppBuild.fromJson('ios', {'available': true, 'download_url': _ipa, 'installable': true}).installable,
        isFalse,
        reason: 'installable needs a link to install from',
      );
    });

    test('labels, sizes and links', () {
      expect(const AppBuild(platform: 'ios', build: '9').label, 'Build 9');
      expect(const AppBuild(platform: 'ios').label, 'Latest build');
      expect(formatBuildSize(null), '');
      expect(formatBuildSize(900), '900 B');
      expect(formatBuildSize(150 * 1024 * 1024), '150 MB');
      expect(appInstallPageUrl('ios'), 'https://getride.my/install/ios');
      expect(
        appInstallShareText(_android()),
        'Install GET.ride 1.4.3 (88) for Android: https://getride.my/install/android',
      );
    });

    test('what a tester is told', () {
      expect(appInstallHint(_ios()), contains('registered in the Ad Hoc profile'));
      expect(appInstallHint(_ios(installable: false)), contains('not installed directly'));
      expect(appInstallHint(_android()), contains('remove it first'));
      expect(appInstallHint(const AppBuild(platform: 'android')), contains('No build'));
    });
  });

  group('Admin → App Release', () {
    Future<List<String>> pump(WidgetTester tester, AppBuild b, {ThemeMode mode = ThemeMode.light}) async {
      final shared = <String>[];
      final opened = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBuildProvider.overrideWith((ref, p) async => p == 'ios' ? b : _android()),
            appInstallSharerProvider.overrideWithValue((t) async => shared.add(t)),
            appLinkOpenerProvider.overrideWithValue((u) async {
              opened.add(u);
              return true;
            }),
          ],
          child: MaterialApp(
            theme: appTheme(Brightness.light),
            darkTheme: appTheme(Brightness.dark),
            themeMode: mode,
            home: Scaffold(body: AppBuildPanel(platform: b.platform)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return [...shared, ...opened];
    }

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('download, share the install link, show the QR (${mode.name})', (tester) async {
        final shared = <String>[];
        final opened = <String>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appBuildProvider.overrideWith((ref, p) async => _ios()),
              appInstallSharerProvider.overrideWithValue((t) async => shared.add(t)),
              appLinkOpenerProvider.overrideWithValue((u) async {
                opened.add(u);
                return true;
              }),
            ],
            child: MaterialApp(
              theme: appTheme(Brightness.light),
              darkTheme: appTheme(Brightness.dark),
              themeMode: mode,
              home: const Scaffold(body: AppBuildPanel(platform: 'ios')),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('1.4.3 (107) · 52.0 MB'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('app-build-download-ios')));
        await tester.pump();
        expect(opened, [_ipa]);

        await tester.tap(find.byKey(const ValueKey('app-build-share-ios')));
        await tester.pump();
        expect(shared.single, contains('https://getride.my/install/ios'));

        await tester.tap(find.byKey(const ValueKey('app-build-qr-ios')));
        await tester.pumpAndSettle();
        final qr = tester.widget<QrImageView>(find.byKey(const ValueKey('app-install-qr')));
        expect(qr, isNotNull);
        expect(find.text('https://getride.my/install/ios'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Android offers the .aab as a download beside the APK, light and dark', (tester) async {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        final opened = <String>[];
        final b = AppBuild.fromJson('android', {
          'available': true,
          'download_url': _apk,
          'install_url': _apk,
          'installable': true,
          'bundle_url': _aab,
        });
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              appBuildProvider.overrideWith((ref, p) async => b),
              appLinkOpenerProvider.overrideWithValue((u) async {
                opened.add(u);
                return true;
              }),
            ],
            child: MaterialApp(
              theme: appTheme(Brightness.light),
              darkTheme: appTheme(Brightness.dark),
              themeMode: mode,
              home: const Scaffold(body: AppBuildPanel(platform: 'android')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('app-build-download-aab-android')));
        await tester.pump();
        expect(opened, [_aab]);
        expect(find.text('Download .aab'), findsOneWidget);
        // Share and QR are the APK's: one of each, none for the bundle.
        expect(find.byKey(const ValueKey('app-build-share-android')), findsOneWidget);
        expect(find.byKey(const ValueKey('app-build-qr-android')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    test('a bundle link is Android-only and https-only', () {
      expect(_android().bundleUrl, isNull, reason: 'older releases have none');
      expect(AppBuild.fromJson('ios', {'available': true, 'download_url': _ipa, 'bundle_url': _aab}).bundleUrl, isNull);
      expect(
        AppBuild.fromJson('android', {'available': true, 'download_url': _apk, 'bundle_url': 'http://x/getride.aab'})
            .bundleUrl,
        isNull,
      );
    });

    testWidgets('an App Store IPA downloads, but offers no install link or QR', (tester) async {
      await pump(tester, _ios(installable: false));
      expect(find.byKey(const ValueKey('app-build-download-ios')), findsOneWidget);
      expect(find.byKey(const ValueKey('app-build-share-ios')), findsNothing);
      expect(find.byKey(const ValueKey('app-build-qr-ios')), findsNothing);
      expect(find.textContaining('not installed directly'), findsOneWidget);
    });

    testWidgets('nothing published yet says so', (tester) async {
      await pump(tester, const AppBuild(platform: 'ios'));
      expect(find.textContaining('No build to download yet'), findsOneWidget);
    });
  });

  group('the install page', () {
    Future<List<String>> pump(
      WidgetTester tester,
      String platform,
      AppBuild b, {
      Size size = const Size(400, 900),
      AppBranding branding = const AppBranding(),
      ThemeMode mode = ThemeMode.light,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBuildProvider.overrideWith((ref, p) async => b),
            installBrandingProvider.overrideWith((ref) async => branding),
            appLinkOpenerProvider.overrideWithValue((u) async {
              opened.add(u);
              return true;
            }),
          ],
          child: MaterialApp(
            theme: appTheme(Brightness.light),
            darkTheme: appTheme(Brightness.dark),
            themeMode: mode,
            home: AppInstallScreen(platform: platform),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return opened;
    }

    testWidgets('Install opens the itms-services link on iPhone', (tester) async {
      final opened = await pump(tester, 'ios', _ios());
      await tester.tap(find.byKey(const ValueKey('app-install-button')));
      await tester.pump();
      expect(opened, [_itms]);
      expect(find.byType(QrImageView), findsNothing, reason: 'a phone needs no QR of its own page');
    });

    testWidgets('Install opens the APK on Android; a computer gets a QR to scan', (tester) async {
      final opened = await pump(tester, 'android', _android(), size: const Size(1200, 900));
      await tester.tap(find.byKey(const ValueKey('app-install-button')));
      await tester.pump();
      expect(opened, [_apk]);
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets('an App Store IPA has no Install button, and says why', (tester) async {
      await pump(tester, 'ios', _ios(installable: false));
      expect(find.byKey(const ValueKey('app-install-button')), findsNothing);
      expect(find.textContaining('not installed directly'), findsOneWidget);
      expect(find.text('Download getride.ipa'), findsOneWidget);
    });

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('branded: the built-in icon, the wordmark and the tagline (${mode.name})', (tester) async {
        await pump(tester, 'android', _android(), mode: mode);
        expect(find.byKey(const ValueKey('install-icon-builtin')), findsOneWidget);
        expect(find.byKey(const ValueKey('install-icon-admin')), findsNothing);
        expect(find.text('Your ride, your way.'), findsOneWidget);
        expect(find.text('For Android'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the icon the admin published replaces the built-in one', (tester) async {
      await pump(tester, 'ios', _ios(), branding: const AppBranding(appIconUrl: 'https://cdn.example.com/icon.png'));
      expect(find.byKey(const ValueKey('install-icon-admin')), findsOneWidget);
      expect(find.text('For iPhone'), findsOneWidget);
    });

    testWidgets('an unknown platform is not a page', (tester) async {
      await pump(tester, 'windows', const AppBuild(platform: 'windows'));
      expect(find.text('There is no build for that platform.'), findsOneWidget);
    });
  });
}
