// Calls that didn't ring a closed iPhone: the "Notifications are off"
// warning and the VoIP token retries (push_service.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/widgets/notifications_off_banner.dart';

void main() {
  test('warned on the rider and driver screens only, while signed in and not dismissed', () {
    bool warn({bool off = true, bool signedIn = true, bool dismissed = false, String location = '/'}) =>
        shouldWarnNotificationsOff(off: off, signedIn: signedIn, dismissed: dismissed, location: location);
    expect(warn(), isTrue);
    expect(warn(location: '/drive'), isTrue);
    expect(warn(location: '/trips/abc'), isTrue);
    expect(warn(off: false), isFalse);
    expect(warn(signedIn: false), isFalse);
    expect(warn(dismissed: true), isFalse);
    expect(warn(location: '/admin/users'), isFalse);
    expect(warn(location: '/auth/phone'), isFalse);
  });

  test('the VoIP token is tried again for about two minutes', () {
    final total = voipRetryDelays.fold(Duration.zero, (a, b) => a + b);
    expect(total, greaterThanOrEqualTo(const Duration(minutes: 1)));
    expect(total, lessThanOrEqualTo(const Duration(minutes: 3)));
  });

  for (final dark in [false, true]) {
    testWidgets('the banner offers Settings and Not now (${dark ? 'dark' : 'light'})', (tester) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      var settings = 0, dismissed = 0;
      await tester.pumpWidget(
        MaterialApp(
          scaffoldMessengerKey: messenger,
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: const Scaffold(body: SizedBox()),
        ),
      );
      messenger.currentState!.showMaterialBanner(
        notificationsOffBanner(onSettings: () => settings++, onDismiss: () => dismissed++),
      );
      await tester.pumpAndSettle();
      expect(find.text(notificationsOffText), findsOneWidget);
      final icon = tester.widget<Icon>(find.byIcon(Icons.notifications_off_outlined));
      expect(icon.color, Theme.of(tester.element(find.byType(Scaffold))).colorScheme.error);
      await tester.tap(find.byKey(const ValueKey('notifications-off-settings')));
      await tester.tap(find.byKey(const ValueKey('notifications-off-later')));
      expect((settings, dismissed), (1, 1));
    });
  }
}
