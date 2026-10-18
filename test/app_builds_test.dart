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
  _splitTests();

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

const _dl = 'https://github.com/getgroupmy/get-ride/releases/download/android-latest';

/// What app-install answers once the per-processor APKs are published: the
/// 64-bit one picked by default, every APK listed.
AppBuild _split({bool with32 = true, bool universal = true}) => AppBuild.fromJson('android', {
  'available': true,
  'version': '1.5.0',
  'build': '120',
  'size': 57 * 1024 * 1024,
  'installable': true,
  'abi': 'arm64-v8a',
  'download_url': '$_dl/getride-arm64-v8a.apk',
  'install_url': '$_dl/getride-arm64-v8a.apk',
  'apks': [
    {'abi': 'arm64-v8a', 'url': '$_dl/getride-arm64-v8a.apk', 'size': 57 * 1024 * 1024},
    if (with32) {'abi': 'armeabi-v7a', 'url': '$_dl/getride-armeabi-v7a.apk', 'size': 52 * 1024 * 1024},
    if (universal) {'abi': 'universal', 'url': '$_dl/getride.apk', 'size': 154 * 1024 * 1024},
  ],
});

const _phone64 = ['arm64-v8a', 'armeabi-v7a', 'armeabi'];
const _phone32 = ['armeabi-v7a', 'armeabi'];

void _splitTests() {
  group('per-processor APKs', () {
    test('a phone gets its own: 64-bit, 32-bit when that is all it runs, 64-bit when unknown', () {
      expect(wantedApkAbi(_phone64), abiArm64);
      expect(wantedApkAbi(_phone32), abiArm32);
      expect(wantedApkAbi(const []), abiArm64);
      expect(wantedApkAbi(const ['x86_64']), abiUniversal, reason: 'an emulator or Chromebook: the universal one');

      final b64 = _split().forDevice(_phone64);
      expect(b64.installUrl, '$_dl/getride-arm64-v8a.apk');
      expect(b64.fileName, 'getride-arm64-v8a.apk');
      expect(formatBuildSize(b64.size), '57.0 MB');

      final b32 = _split().forDevice(_phone32);
      expect(b32.abi, abiArm32);
      expect(b32.installUrl, '$_dl/getride-armeabi-v7a.apk');
      expect(b32.downloadUrl, b32.installUrl);
      expect(b32.fileName, 'getride-armeabi-v7a.apk');
      expect(formatBuildSize(b32.size), '52.0 MB');
      expect(b32.otherApk?.abi, abiArm64);
      expect(b64.otherApk?.abi, abiArm32);

      expect(_split().forDevice(const []).abi, abiArm64);
      expect(_split().forDevice(const ['x86_64']).installUrl, '$_dl/getride.apk');
    });

    test('a missing split falls back to the universal APK', () {
      final b = _split(with32: false).forDevice(_phone32);
      expect(b.abi, abiUniversal);
      expect(b.installUrl, '$_dl/getride.apk');
      expect(b.fileName, 'getride.apk');
      expect(formatBuildSize(b.size), '154 MB');
      expect(b.otherApk, isNull, reason: 'no choice to offer from the universal one');
      expect(_split(with32: false).forDevice(_phone64).otherApk, isNull, reason: 'no 32-bit one published');
    });

    test('without a universal APK: the phone\'s own split, never one it can\'t run', () {
      final only64 = _split(with32: false, universal: false);
      expect(only64.forDevice(_phone32).available, isFalse, reason: 'a 32-bit phone cannot run the 64-bit APK');
      expect(only64.forDevice(const []).installUrl, '$_dl/getride-arm64-v8a.apk');
      final apks = [const AppApk(abi: abiArm32, url: '$_dl/getride-armeabi-v7a.apk')];
      expect(pickApk(apks, const [])?.abi, abiArm32, reason: 'a phone that said nothing: what there is');
      expect(pickApk(apks, _phone64)?.abi, abiArm32, reason: 'a 64-bit phone runs 32-bit apps too');
      expect(pickApk(apks, const ['arm64-v8a']), isNull, reason: 'a 64-bit-only phone does not');
      expect(pickApk(const [], _phone64), isNull);
    });

    test('an older app-install (no APK list) and iPhone builds are left as they are', () {
      expect(_android().apks, isEmpty);
      expect(_android().forDevice(_phone32).installUrl, _apk);
      expect(_ios().forDevice(_phone32).installUrl, _itms);
      expect(
        AppBuild.fromJson('ios', {
          'available': true,
          'download_url': _ipa,
          'apks': [
            {'abi': 'arm64-v8a', 'url': '$_dl/getride-arm64-v8a.apk'},
          ],
        }).apks,
        isEmpty,
      );
      expect(
        AppBuild.fromJson('android', {
          'available': true,
          'download_url': _apk,
          'apks': [
            {'abi': 'arm64-v8a', 'url': 'http://evil/x.apk'},
            {'url': '$_dl/getride.apk'},
            'nope',
          ],
        }).apks,
        isEmpty,
        reason: 'https only, and every entry names its processor',
      );
    });

    test('what a browser lets on about the phone', () {
      const chrome = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 Chrome/141.0 Mobile Safari/537.36';
      expect(deviceAbisFromUserAgent(chrome), isEmpty, reason: 'reduced UA: unknown, so 64-bit');
      expect(deviceAbisFromUserAgent(chrome, bitness: '32', architecture: 'arm'), [abiArm32]);
      expect(deviceAbisFromUserAgent(chrome, bitness: '64', architecture: 'arm'), [abiArm64, abiArm32]);
      expect(deviceAbisFromUserAgent(chrome, bitness: '', architecture: ''), isEmpty);
      expect(deviceAbisFromUserAgent('Mozilla/5.0 (Linux; U; Android 4.4.2; armv7l; SM-T110)'), [abiArm32]);
      expect(
        deviceAbisFromUserAgent('Mozilla/5.0 (Linux; Android 9; Linux armv8l) Chrome/90'),
        [abiArm32],
        reason: 'armv8l is a 32-bit system on a 64-bit processor',
      );
      expect(deviceAbisFromUserAgent('Mozilla/5.0 (Linux; Android 12; aarch64)'), [abiArm64, abiArm32]);
      expect(deviceAbisFromUserAgent('Mozilla/5.0 (X11; Linux armv7l) Chrome/90'), isEmpty, reason: 'not a phone');
      expect(
        wantedApkAbi(deviceAbisFromUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64)', bitness: '64', architecture: 'x86')),
        abiArm64,
        reason: 'a computer gets the 64-bit default (its QR leads the phone to its own)',
      );
    });

    test('new clients always name the processor; iPhone needs none', () {
      expect(appInstallQuery('android', const []), {'platform': 'android', 'abi': abiArm64});
      expect(appInstallQuery('android', _phone32), {'platform': 'android', 'abi': abiArm32});
      expect(appInstallQuery('android', _phone64), {'platform': 'android', 'abi': abiArm64});
      expect(appInstallQuery('android', const ['x86_64']), {'platform': 'android', 'abi': abiUniversal});
      expect(appInstallQuery('ios', _phone64), {'platform': 'ios'});
    });

    test('an old-client answer (universal picked, APKs listed) is re-picked for this phone', () {
      final old = AppBuild.fromJson('android', {
        'available': true,
        'installable': true,
        'abi': 'universal',
        'download_url': '$_dl/getride.apk',
        'install_url': '$_dl/getride.apk',
        'apks': [
          {'abi': 'arm64-v8a', 'url': '$_dl/getride-arm64-v8a.apk'},
          {'abi': 'armeabi-v7a', 'url': '$_dl/getride-armeabi-v7a.apk'},
          {'abi': 'universal', 'url': '$_dl/getride.apk'},
        ],
      });
      expect(old.installUrl, '$_dl/getride.apk');
      expect(old.forDevice(_phone32).installUrl, '$_dl/getride-armeabi-v7a.apk');
      expect(old.forDevice(const []).installUrl, '$_dl/getride-arm64-v8a.apk');
    });

    test('the update link: the universal APK becomes the phone\'s own; anything else stays', () {
      const universal = '$_dl/getride.apk';
      expect(isUniversalApkLink(universal), isTrue);
      expect(isUniversalApkLink('https://play.google.com/store/apps/details?id=com.taxxee.teksi'), isFalse);
      expect(isUniversalApkLink('$_dl/getride-arm64-v8a.apk'), isFalse);
      expect(updateApkLink(universal, _split(), _phone64), '$_dl/getride-arm64-v8a.apk');
      expect(updateApkLink(universal, _split(), _phone32), '$_dl/getride-armeabi-v7a.apk');
      expect(updateApkLink(universal, _split(with32: false), _phone32), universal);
      expect(updateApkLink(universal, _android(), _phone64), universal, reason: 'no APK list yet');
      expect(updateApkLink(universal, const AppBuild(platform: 'android'), _phone64), universal);
      const play = 'https://play.google.com/store/apps/details?id=com.taxxee.teksi';
      expect(updateApkLink(play, _split(), _phone64), play);
    });

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('the install page installs the phone\'s APK and offers the other (${mode.name})', (tester) async {
        for (final (abis, own, other, link) in [
          (_phone64, 'getride-arm64-v8a.apk', 'getride-armeabi-v7a.apk', 'Download the 32-bit version'),
          (_phone32, 'getride-armeabi-v7a.apk', 'getride-arm64-v8a.apk', 'Download the 64-bit version'),
        ]) {
          tester.view.physicalSize = const Size(400, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final opened = <String>[];
          await tester.pumpWidget(
            ProviderScope(
              key: UniqueKey(),
              overrides: [
                appBuildProvider.overrideWith((ref, p) async => _split()),
                deviceAbisProvider.overrideWith((ref) async => abis),
                installBrandingProvider.overrideWith((ref) async => const AppBranding()),
                appLinkOpenerProvider.overrideWithValue((u) async {
                  opened.add(u);
                  return true;
                }),
              ],
              child: MaterialApp(
                theme: appTheme(Brightness.light),
                darkTheme: appTheme(Brightness.dark),
                themeMode: mode,
                home: const AppInstallScreen(platform: 'android'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Download $own'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('app-install-button')));
          await tester.pump();
          expect(opened, ['$_dl/$own']);
          await tester.ensureVisible(find.byKey(const ValueKey('app-install-other-apk')));
          expect(find.textContaining(link), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('app-install-other-apk')));
          await tester.pump();
          expect(opened.last, '$_dl/$other');
          expect(tester.takeException(), isNull);
        }
      });

      testWidgets('Admin → App Release downloads both processors\' APKs (${mode.name})', (tester) async {
        final opened = <String>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appBuildProvider.overrideWith((ref, p) async => _split()),
              deviceAbisProvider.overrideWith((ref) async => const []),
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
        expect(find.textContaining('1.5.0 (120) · 57.0 MB'), findsOneWidget);
        expect(find.text('Download .apk (64-bit)'), findsOneWidget);
        expect(find.text('Download .apk (32-bit)'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('app-build-download-android')));
        await tester.tap(find.byKey(const ValueKey('app-build-download-other-android')));
        await tester.pump();
        expect(opened, ['$_dl/getride-arm64-v8a.apk', '$_dl/getride-armeabi-v7a.apk']);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a release from before the split shows one download, as before', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBuildProvider.overrideWith((ref, p) async => _android()),
            deviceAbisProvider.overrideWith((ref) async => _phone32),
          ],
          child: MaterialApp(
            theme: appTheme(Brightness.light),
            home: const AppInstallScreen(platform: 'android'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Download getride.apk'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-install-other-apk')), findsNothing);
    });
  });
}
