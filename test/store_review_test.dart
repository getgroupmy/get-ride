// The store review login (migration 0333): who the demo account is, the
// permissions notice, the mode choice and tour, the demo wallet and the
// admin card, in light and dark.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/security/store_review_card.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/core/auth_utils.dart';
import 'package:get_ride/src/features/permissions/permission_actions.dart';
import 'package:get_ride/src/features/settings/news_offers_card.dart';
import 'package:get_ride/src/features/settings/location_checkins_card.dart';
import 'package:get_ride/src/admin/screens/security/location_checkins_admin_card.dart';
import 'package:get_ride/src/core/demo_mode.dart';
import 'package:get_ride/src/core/side_menu.dart' show hideSoon;
import 'package:get_ride/src/core/store_review.dart';
import 'package:get_ride/src/features/store_review/demo_wallet.dart';
import 'package:get_ride/src/features/store_review/store_review_host.dart';
import 'package:get_ride/src/widgets/common.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/permissions_notice.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget child, Brightness b, {List overrides = const []}) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    theme: ThemeData(brightness: b, useMaterial3: true),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  group('who is the demo account', () {
    test('by app_metadata or id, never by name', () {
      expect(isStoreReviewAccount(userId: storeReviewUserId), isTrue);
      expect(isStoreReviewAccount(userId: 'x', appMetadata: {'store_review': true}), isTrue);
      expect(isStoreReviewAccount(userId: 'x', appMetadata: {'store_review': 'true'}), isTrue);
      expect(isStoreReviewAccount(userId: 'x', appMetadata: {'provider': 'phone'}), isFalse);
      expect(isStoreReviewAccount(userId: 'x'), isFalse);
    });

    test('the server seal reads plainly', () {
      expect(isStoreReviewRefusal('PostgrestException(message: STORE_REVIEW_DEMO, code: 403)'), isTrue);
      expect(errorText(Exception('STORE_REVIEW_DEMO: no')), storeReviewRefusal);
      expect(isStoreReviewRefusal('RATE_LIMITED:3'), isFalse);
    });

    test('the sign-in answers', () {
      expect(storeReviewRefreshToken({'session': {'refresh_token': 'rt'}}), 'rt');
      expect(storeReviewRefreshToken({'error': 'review_off'}), isNull);
      expect(storeReviewSignInMessage(403, null), contains('switched off'));
      expect(storeReviewSignInMessage(429, {'retry_after': 120}), contains('2'));
      expect(storeReviewSignInMessage(503, null), contains("Couldn't reach"));
    });

    test('every demo part is on for the demo account alone', () {
      final s = storeReviewDemoSettings('u1');
      expect(s.offersFor('u1') && s.requestsFor('u1') && s.riderTripSim && s.partnerDriveSim, isTrue);
      expect(s.offersFor('u2') || s.requestsFor('u2'), isFalse);
      expect(storeReviewDemoPartner('u1')['status'], 'approved');
    });
  });

  group('permissions notice', () {
    test('lists only what each platform asks for', () {
      final android = permissionNoticeFor(NoticePlatform.android).map((i) => i.id).toList();
      final ios = permissionNoticeFor(NoticePlatform.ios).map((i) => i.id).toList();
      expect(android, containsAll(['location', 'location-background', 'notifications', 'camera', 'microphone', 'calls', 'bluetooth']));
      expect(android, isNot(contains('photos')));
      expect(android, isNot(contains('local-network')));
      expect(ios, containsAll(['photos', 'local-network']));
      expect(ios, isNot(contains('calls')));
      expect(permissionNoticeItems.where((i) => i.driverOnly).map((i) => i.id), ['local-network']);
      for (final i in permissionNoticeItems) {
        expect(i.since <= permissionNoticeVersion, isTrue, reason: i.id);
        expect(i.why.contains('→') || i.title.contains('→'), isFalse, reason: i.id);
      }
      // The background disclosure: Google's sentence first, all four cases, word for word the OS-prompt page's.
      final bg = permissionNoticeItems.firstWhere((i) => i.id == 'location-background').why;
      expect(bg, startsWith('GET.ride collects location data to enable trip tracking, safety and ride requests, even '
          'when the app is closed or not in use.'));
      expect(bg, allOf(contains('During a trip'), contains('online as a driver'), contains('Meter Digital'),
          contains('every 15 minutes'), contains('only during your own trip'), contains('Share my last location'), contains('Your choice')));
      expect(bg, isNot(contains('never tracked')));
      expect(bg, backgroundLocationDisclosure);
      expect(PermissionBlock.notAllTheTime.message, backgroundLocationDisclosure);
      expect(PermissionBlock.notAlways.message, backgroundLocationDisclosure);
      // Every row says what it is for and the choice; the microphone row discloses trip recording.
      for (final i in permissionNoticeItems) {
        expect(i.why.length, greaterThan(150), reason: i.id);
      }
      final mic = permissionNoticeItems.firstWhere((i) => i.id == 'microphone').why;
      expect(mic, allOf(contains('Audio protection'), contains('24 hours'), contains('support')));
      final notif = permissionNoticeItems.firstWhere((i) => i.id == 'notifications').why;
      expect(notif, contains('Settings > Notifications > News and offers'));
    });

    test('the manifest and Info.plist ask for what the notice explains', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(manifest, contains('ACCESS_BACKGROUND_LOCATION'));
      expect(manifest, contains('RECORD_AUDIO'));
      expect(manifest, contains('CAMERA'));
      expect(manifest, contains('POST_NOTIFICATIONS'));
      expect(manifest, contains('BLUETOOTH_CONNECT'));
      expect(manifest, contains('phoneCall'));
      expect(manifest, isNot(contains('READ_MEDIA_IMAGES')), reason: 'Android photos would need a notice line');
      expect(manifest, isNot(contains('READ_CONTACTS')), reason: 'contacts would need a notice line');
      for (final k in [
        'NSLocationAlwaysAndWhenInUseUsageDescription',
        'NSCameraUsageDescription',
        'NSPhotoLibraryUsageDescription',
        'NSMicrophoneUsageDescription',
        'NSBluetoothAlwaysUsageDescription',
        'NSLocalNetworkUsageDescription',
      ]) {
        expect(plist, contains(k));
      }
      expect(plist, isNot(contains('NSContactsUsageDescription')));
    });

    test('when it is due', () {
      expect(permissionNoticeDue(storeReview: true, seenVersion: 1, shownThisRun: false), isTrue);
      expect(permissionNoticeDue(storeReview: true, seenVersion: 1, shownThisRun: true), isFalse);
      expect(permissionNoticeDue(storeReview: false, seenVersion: null, shownThisRun: false), isTrue);
      expect(permissionNoticeDue(storeReview: false, seenVersion: 1, shownThisRun: false), isFalse);
      expect(permissionNoticeDue(storeReview: false, seenVersion: 1, shownThisRun: false, current: 2), isTrue);
      expect(permissionNoticeKey('u1'), 'permissions_notice_seen:u1');
    });

    for (final b in Brightness.values) {
      testWidgets('the modal lists each item with OK ($b)', (tester) async {
        await tester.pumpWidget(_app(PermissionsNoticeDialog(items: permissionNoticeFor(NoticePlatform.android)), b));
        expect(find.byKey(const ValueKey('permissions-notice-location')), findsOneWidget);
        // The background disclosure is open; News and offers starts unticked.
        expect(find.textContaining('even when the app is closed or not in use'), findsWidgets);
        expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('permissions-notice-news'))).value, isFalse);
        expect(permissionBlockAction(PermissionBlock.notAllTheTime), 'Continue');
        expect(find.byKey(const ValueKey('permissions-notice-photos')), findsNothing);
        expect(find.text('OK'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('mode choice and tour', () {
    test('every step has a page and plain words', () {
      expect(passengerTour.length, greaterThan(8));
      expect(driverTour.length, greaterThan(8));
      for (final s in [...passengerTour, ...driverTour]) {
        expect(s.route, startsWith('/'));
        expect(s.body.contains('→') || s.title.contains('→'), isFalse);
      }
      expect(tourStepLabel(2, 9), 'Step 3 of 9');
      expect(reviewModeHome(TourMode.driver), '/drive');
      expect(reviewModeHome(TourMode.passenger), '/');
    });

    test('next, back and stop', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final tour = c.read(reviewTourProvider.notifier);
      tour.start(TourMode.driver);
      tour.back();
      expect(c.read(reviewTourProvider)!.index, 0);
      tour.next();
      expect(c.read(reviewTourProvider)!.index, 1);
      for (var i = 0; i < driverTour.length; i++) {
        tour.next();
      }
      expect(c.read(reviewTourProvider), isNull, reason: 'Finish on the last step ends it');
      tour.start(TourMode.passenger);
      tour.stop();
      expect(c.read(reviewTourProvider), isNull);
    });

    for (final b in Brightness.values) {
      testWidgets('the step card: next, back, skip, hide ($b)', (tester) async {
        var next = 0, back = 0, skip = 0;
        await tester.pumpWidget(_app(
          TourCard(
            state: const TourState(TourMode.passenger, 1),
            onNext: () => next++,
            onBack: () => back++,
            onSkip: () => skip++,
          ),
          b,
        ));
        expect(find.textContaining('Step 2 of ${passengerTour.length}'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('tour-next')));
        await tester.tap(find.byKey(const ValueKey('tour-back')));
        await tester.tap(find.byKey(const ValueKey('tour-skip')));
        expect([next, back, skip], [1, 1, 1]);
        await tester.tap(find.byKey(const ValueKey('tour-fold')));
        await tester.pump();
        expect(find.byKey(const ValueKey('tour-pill')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('tour-pill')));
        await tester.pump();
        expect(find.byKey(const ValueKey('tour-card')), findsOneWidget);
      });

      testWidgets('the mode choice and the demo label ($b)', (tester) async {
        await tester.pumpWidget(_app(const Column(children: [ReviewModeDialog(), DemoSimulatedLabel()]), b));
        expect(find.text('Use as a passenger'), findsOneWidget);
        expect(find.text('Use as a driver'), findsOneWidget);
        expect(find.text('Demo · simulated'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('demo money', () {
    test('top-up, pay and earn move the demo balances only', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final w = c.read(demoWalletProvider.notifier);
      w.topUp(50);
      expect(c.read(demoWalletProvider).wallet, demoWalletStart.wallet + 50);
      expect(w.pay(10000, 'too much'), isFalse);
      expect(w.pay(20, 'Demo ride'), isTrue);
      w.earn(12, 'Demo job');
      final s = c.read(demoWalletProvider);
      expect(s.wallet, demoWalletStart.wallet + 30);
      expect(s.credit, demoWalletStart.credit + 12);
      expect(s.history.map((t) => t.kind), ['earning', 'ride_payment', 'topup']);
      expect(s.balances.map((b) => b.walletType), ['get_wallet', 'get_coin', 'get_credit']);
    });

    for (final b in Brightness.values) {
      testWidgets('a demo ride: pay, rate, receipt ($b)', (tester) async {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: ThemeData(brightness: b, useMaterial3: true),
            home: const Scaffold(
              body: SingleChildScrollView(child: DemoTripFinish(fare: 18, driver: 'Patrick', route: 'KLCC to Mid Valley')),
            ),
          ),
        ));
        await tester.tap(find.byKey(const ValueKey('demo-pay-wallet')));
        await tester.pump();
        expect(c.read(demoWalletProvider).wallet, demoWalletStart.wallet - 18);
        await tester.tap(find.byKey(const ValueKey('demo-star-5')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('demo-rate')));
        await tester.pump();
        expect(find.byKey(const ValueKey('demo-receipt')), findsOneWidget);
        expect(find.textContaining('rated 5 of 5'), findsOneWidget);
      });
    }
  });

  group('admin card', () {
    test('reads the state', () {
      final s = StoreReviewState.fromJson({
        'enabled': true,
        'phone': '60608080',
        'accountReady': true,
        'allowedLast30Days': 3,
        'signIns': [
          {'at': '2026-11-02T01:00:00Z', 'outcome': 'allowed', 'platform': 'android', 'ip': '203.0.113.4'},
        ],
      });
      expect(s.enabled && s.accountReady, isTrue);
      expect(s.signIns.single['outcome'], 'allowed');
      expect(storeReviewOutcomeLabel('wrong_number'), 'Refused: another number');
    });

    for (final b in Brightness.values) {
      testWidgets('switch, number and the sign-in log ($b)', (tester) async {
        await tester.pumpWidget(_app(
          const StoreReviewCard(canEdit: true),
          b,
          overrides: [
            storeReviewStateProvider.overrideWith((ref) async => StoreReviewState.fromJson({
              'enabled': false,
              'phone': '60608080',
              'accountReady': true,
              'allowedLast30Days': 1,
              'signIns': [
                {'at': '2026-11-02T01:00:00Z', 'outcome': 'allowed', 'platform': 'android', 'device': 'Pixel 8',
                 'appVersion': '1.9.0', 'ip': '203.0.113.4'},
              ],
            })),
          ],
        ));
        await tester.pumpAndSettle();
        expect(find.text('Store review login'), findsOneWidget);
        expect(find.text('Off'), findsOneWidget);
        expect(find.textContaining('Signed in'), findsOneWidget);
        expect(find.textContaining('IP 203.0.113.4'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('store-review-on')));
        await tester.pump();
        expect(find.text('On'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('after sign-in', () {
    Future<void> pumpHost(WidgetTester tester,
        {required bool review, Brightness b = Brightness.light, List<bool>? saved}) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue('u-333'),
          storeReviewProvider.overrideWithValue(review),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: b, useMaterial3: true),
          builder: (_, child) => StoreReviewHost(
            location: () => '/',
            platform: () => NoticePlatform.android,
            saveNewsOffers: (on) async => saved?.add(on),
            child: child!,
          ),
          home: const Scaffold(body: Text('home')),
        ),
      ));
      await tester.pumpAndSettle();
    }

    for (final b in Brightness.values) {
      testWidgets('the reviewer: notice, mode, tour, label ($b)', (tester) async {
        SharedPreferences.setMockInitialValues({permissionNoticeKey('u-333'): permissionNoticeVersion});
        await pumpHost(tester, review: true, b: b);
        expect(find.byKey(const ValueKey('permissions-notice')), findsOneWidget, reason: 'every sign-in');
        expect(find.byKey(const ValueKey('demo-simulated-label')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('permissions-notice-ok')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('review-mode-driver')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('review-show-around-yes')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Step 1 of ${driverTour.length}: Go online'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('tour-skip')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tour-card')), findsNothing);
        expect(find.text('home'), findsOneWidget);
      });
    }

    testWidgets('everyone else: once, then not again until a new permission', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final saved = <bool>[];
      await pumpHost(tester, review: false, saved: saved);
      expect(find.byKey(const ValueKey('permissions-notice')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('permissions-notice-news')));
      await tester.tap(find.byKey(const ValueKey('permissions-notice-news')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('permissions-notice-ok')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('review-mode')), findsNothing);
      expect(find.byKey(const ValueKey('demo-simulated-label')), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(permissionNoticeKey('u-333')), permissionNoticeVersion);
      expect(saved, [true], reason: 'ticking "Send me news and offers" opts in');

      await tester.pumpWidget(const SizedBox());
      await pumpHost(tester, review: false);
      expect(find.byKey(const ValueKey('permissions-notice')), findsNothing);
    });
  });

  group('News and offers', () {
    test('off until chosen', () {
      expect(newsOffersOn(null), isFalse);
      expect(newsOffersOn({'news_offers': null}), isFalse);
      expect(newsOffersOn({'news_offers': true}), isTrue);
    });

    for (final b in Brightness.values) {
      testWidgets('the switch saves and says so ($b)', (tester) async {
        final saved = <bool>[];
        await tester.pumpWidget(_app(
          NewsOffersCard(save: (on) async => saved.add(on)),
          b,
          overrides: [currentUserIdProvider.overrideWithValue(null)],
        ));
        await tester.pumpAndSettle();
        expect(find.text('News and offers'), findsOneWidget);
        expect(find.textContaining('Trip, safety, payment and account messages always come'), findsOneWidget);
        expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('news-offers-switch'))).value, isFalse);
        await tester.tap(find.byKey(const ValueKey('news-offers-switch')));
        await tester.pumpAndSettle();
        expect(saved, [true]);
        expect(find.text('News and offers turned on.'), findsOneWidget, reason: 'a modal, not a bar');
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('passenger location check-ins', () {
    test('off: passengers never; on: only with their opt-in; drivers unchanged', () {
      expect(backgroundCheckinsAllowed(isPartner: false, switchOn: false, optedIn: true), isFalse);
      expect(backgroundCheckinsAllowed(isPartner: false, switchOn: true, optedIn: false), isFalse);
      expect(backgroundCheckinsAllowed(isPartner: false, switchOn: true, optedIn: true), isTrue);
      expect(backgroundCheckinsAllowed(isPartner: true, switchOn: false, optedIn: false), isTrue);
      final r = riderChecks(const PermissionChecks(locationAlways: true, locationAlwaysAndroid: true));
      expect(r.locationAlways || r.locationAlwaysAndroid, isFalse, reason: 'passengers are never asked for Always');
      expect(r.location, isTrue);
    });

    for (final b in Brightness.values) {
      testWidgets('opt in after the disclosure, opt out stops it ($b)', (tester) async {
        final saved = <bool>[];
        var asked = 0, stopped = 0;
        await tester.pumpWidget(_app(
          LocationCheckinsCard(
            save: (on) async => saved.add(on),
            askPhone: (_) async => asked++,
            stopNow: () async => stopped++,
          ),
          b,
          overrides: [
            locationCheckinsConfigProvider.overrideWith((ref) async => true),
            currentUserIdProvider.overrideWithValue(null),
          ],
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('location-checkins-switch')));
        await tester.pumpAndSettle();
        expect(find.textContaining('even when the app is closed or not in use'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('location-checkins-not-now')));
        await tester.pumpAndSettle();
        expect(saved, isEmpty, reason: 'Not now collects nothing');
        await tester.tap(find.byKey(const ValueKey('location-checkins-switch')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('location-checkins-continue')));
        await tester.pumpAndSettle();
        expect([asked, ...saved], [1, true]);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('location-checkins-switch')));
        await tester.pumpAndSettle();
        expect(saved, [true, false]);
        expect(stopped, 1);
      });

      testWidgets('hidden while the admin has it off ($b)', (tester) async {
        await tester.pumpWidget(_app(
          const LocationCheckinsCard(),
          b,
          overrides: [
            locationCheckinsConfigProvider.overrideWith((ref) async => false),
            currentUserIdProvider.overrideWithValue(null),
          ],
        ));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('location-checkins-switch')), findsNothing);
      });

      testWidgets('the admin switch warns about Google Play ($b)', (tester) async {
        await tester.pumpWidget(_app(
          const LocationCheckinsAdminCard(canEdit: true),
          b,
          overrides: [locationCheckinsConfigProvider.overrideWith((ref) async => false)],
        ));
        await tester.pumpAndSettle();
        expect(find.text(locationCheckinsWarning), findsOneWidget);
        expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('location-checkins-admin-switch'))).value, isFalse);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('store builds', () {
    test('coming soon is hidden, never re-flagged', () {
      const soon = (label: 'Driver mode', comingSoon: true);
      const live = (label: 'Driver mode', comingSoon: false);
      expect(hideSoon(soon, true), isNull);
      expect(hideSoon(soon, false), soon, reason: 'normal builds show it as before');
      expect(hideSoon(live, true), live);
      final c = ProviderContainer(overrides: [storeReviewProvider.overrideWithValue(true)]);
      addTearDown(c.dispose);
      expect(c.read(hideComingSoonProvider), isTrue);
    });

    test('the iPhone store build only', () {
      expect(iosStoreBuild(storeBuild: true, platform: TargetPlatform.iOS, web: false), isTrue);
      expect(iosStoreBuild(storeBuild: true, platform: TargetPlatform.android, web: false), isFalse);
      expect(iosStoreBuild(storeBuild: false, platform: TargetPlatform.iOS, web: false), isFalse);
      expect(backgroundLocationDisclosure.contains('Android'), isFalse, reason: 'shown on iPhone too');
      for (final i in permissionNoticeFor(NoticePlatform.ios)) {
        expect(i.why.contains('Android') || i.why.contains('Google Play'), isFalse, reason: i.id);
      }
    });
  });
}
