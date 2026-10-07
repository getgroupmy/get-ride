import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/config.dart';
import 'package:get_ride/src/core/app_version.dart';
import 'package:get_ride/src/data/app_version_repository.dart';
import 'package:get_ride/src/features/shell/update_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppVersionRule rule(String platform, String latest, {String? min, bool force = false, String? url}) =>
    AppVersionRule(platform: platform, latest: latest, minVersion: min, forceUpdate: force, storeUrl: url);

void main() {
  group('versions', () {
    test('parse ignores a v prefix, build number and pre-release tag', () {
      expect(parseVersion('1.4.3'), [1, 4, 3]);
      expect(parseVersion('v2.0'), [2, 0]);
      expect(parseVersion('1.4.3+12'), [1, 4, 3]);
      expect(parseVersion('1.5.0-beta'), [1, 5, 0]);
      expect(parseVersion(''), isNull);
      expect(parseVersion('latest'), isNull);
    });

    test('compare is numeric, not alphabetical', () {
      expect(compareVersions('1.10.0', '1.9.9'), 1);
      expect(compareVersions('1.4', '1.4.0'), 0);
      expect(compareVersions('1.4.3', '1.5'), -1);
      expect(compareVersions('garbage', '9.9.9'), 0);
    });

    test('platform names are normalised', () {
      expect(rulePlatform('iOS'), 'ios');
      expect(rulePlatform('iPhone'), 'ios');
      expect(rulePlatform('Android'), 'android');
      expect(rulePlatform('iOS / Android'), 'all');
      expect(rulePlatform(''), 'all');
      expect(rulePlatform('All'), 'all');
      expect(rulePlatform('Windows'), 'windows');
    });
  });

  group('rows', () {
    test('a row without a usable latest version is ignored', () {
      expect(AppVersionRule.fromValues({'platform': 'iOS'}), isNull);
      expect(AppVersionRule.fromValues({'platform': 'iOS', 'version': 'soon'}), isNull);
    });

    test('a row is read from the admin form values', () {
      final r = AppVersionRule.fromValues({
        'platform': 'Android',
        'version': '1.5.0',
        'minVersion': '1.2',
        'forceUpdate': 'true',
        'storeUrl': ' https://example.com/app ',
      })!;
      expect(r.latest, '1.5.0');
      expect(r.minVersion, '1.2');
      expect(r.forceUpdate, isTrue);
      expect(r.storeUrl, 'https://example.com/app');
    });
  });

  group('resolveUpdate', () {
    test('the seeded 1.0.0 rows never touch a newer build', () {
      final v = resolveUpdate([rule('iOS', '1.0.0'), rule('Android', '1.0.0')], platform: 'android', current: '1.4.3');
      expect(v.kind, UpdateKind.none);
    });

    test('behind latest is optional, below min is required', () {
      final rules = [rule('Android', '1.6.0', min: '1.5.0')];
      expect(resolveUpdate(rules, platform: 'android', current: '1.5.2').kind, UpdateKind.optional);
      expect(resolveUpdate(rules, platform: 'android', current: '1.4.3').kind, UpdateKind.required);
    });

    test('force update requires every build behind latest', () {
      final v = resolveUpdate([rule('iOS', '1.5.0', force: true)], platform: 'ios', current: '1.4.3');
      expect(v.kind, UpdateKind.required);
      expect(v.latest, '1.5.0');
    });

    test('a platform row wins over an All row', () {
      final rules = [rule('All', '2.0.0', force: true), rule('iOS', '1.4.3')];
      expect(resolveUpdate(rules, platform: 'ios', current: '1.4.3').kind, UpdateKind.none);
      expect(resolveUpdate(rules, platform: 'android', current: '1.4.3').kind, UpdateKind.required);
    });

    test('another platform row does not apply', () {
      expect(
        resolveUpdate([rule('iOS', '9.0.0', force: true)], platform: 'android', current: '1.0.0').kind,
        UpdateKind.none,
      );
    });

    test('the web build is never asked to update', () {
      expect(
        resolveUpdate([rule('All', '9.0.0', force: true)], platform: 'web', current: '1.0.0').kind,
        UpdateKind.none,
      );
    });

    test('a min version above latest does not lock out builds already on latest', () {
      expect(
        resolveUpdate(
          [rule('Android', '1.4.3', min: '2.0.0')],
          platform: 'android',
          current: '1.4.3',
        ).kind,
        UpdateKind.none,
      );
    });
  });

  group('store link', () {
    test('each platform falls back to its own store listing', () {
      expect(updateStoreUrl('android', null), 'https://play.google.com/store/apps/details?id=com.taxxee.teksi');
      expect(updateStoreUrl('ios', null), 'https://apps.apple.com/my/app/teksi-bid-agree-ride/id6457262236');
      expect(updateStoreUrl('web', null), isNull);
      expect(updateStoreUrl('ios', 'https://apps.apple.com/app/id123'), 'https://apps.apple.com/app/id123');
    });

    test('a link that is not a store or web link is ignored', () {
      expect(updateStoreUrl('ios', 'javascript:alert(1)'), iosAppStoreUrl);
      expect(updateStoreUrl('ios', 'App Store'), iosAppStoreUrl);
      expect(updateStoreUrl('macos', 'App Store'), isNull);
      expect(updateStoreUrl('android', 'file:///x'), 'https://play.google.com/store/apps/details?id=com.taxxee.teksi');
    });
  });

  group('UpdateGate', () {
    Future<void> pump(WidgetTester tester, UpdateVerdict v, {StoreOpener? open}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appUpdateProvider.overrideWith((_) async => v)],
          child: MaterialApp(
            home: UpdateGate(
              openStore: open,
              child: const Scaffold(body: Text('the app')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('no update shows the app', (tester) async {
      await pump(tester, const UpdateVerdict.none());
      expect(find.text('the app'), findsOneWidget);
      expect(find.text('Update available'), findsNothing);
    });

    testWidgets('a required update replaces the app and opens the store', (tester) async {
      String? opened;
      await pump(
        tester,
        const UpdateVerdict(UpdateKind.required, latest: '2.0.0', storeUrl: 'https://store.example/app'),
        open: (url) async {
          opened = url;
          return true;
        },
      );
      expect(find.text('the app'), findsNothing);
      expect(find.text('Update required'), findsOneWidget);
      expect(find.textContaining(AppConfig.appVersion), findsOneWidget);
      await tester.tap(find.text('Update now'));
      await tester.pump();
      expect(opened, 'https://store.example/app');
    });

    testWidgets('a required update without a link says where to go', (tester) async {
      await pump(tester, const UpdateVerdict(UpdateKind.required, latest: '2.0.0'));
      expect(find.text('Update now'), findsNothing);
      expect(find.text('Open the App Store and update GET.ride.'), findsOneWidget);
    });

    testWidgets('a store that will not open is reported', (tester) async {
      await pump(
        tester,
        const UpdateVerdict(UpdateKind.required, latest: '2.0.0', storeUrl: 'https://store.example/app'),
        open: (_) async => false,
      );
      await tester.tap(find.text('Update now'));
      await tester.pump();
      expect(find.textContaining("couldn't be opened"), findsOneWidget);
    });

    testWidgets('an optional update is a card over the app that stays dismissed', (tester) async {
      const v = UpdateVerdict(UpdateKind.optional, latest: '1.9.0', storeUrl: 'https://store.example/app');
      await pump(tester, v);
      expect(find.text('the app'), findsOneWidget);
      expect(find.text('Update available'), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.text('Update available'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(updateDismissedKey), '1.9.0');

      // Next launch: the same version stays dismissed, a newer one shows.
      await tester.pumpWidget(const SizedBox());
      await pump(tester, v);
      expect(find.text('Update available'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, const UpdateVerdict(UpdateKind.optional, latest: '2.0.0'));
      expect(find.text('Update available'), findsOneWidget);
    });
  });
}
