// Calls that didn't ring a closed iPhone: the "Notifications are off"
// warning and the VoIP token retries (push_service.dart).
import 'dart:async';

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
    testWidgets('a popup with an (x) and Open Settings (${dark ? 'dark' : 'light'})', (tester) async {
      late BuildContext ctx;
      var settings = 0, closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: Scaffold(body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          })),
        ),
      );
      unawaited(showNotificationsOffNotice(context: ctx, onSettings: () => settings++).then((_) => closed++));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(notificationsOffTitle), findsOneWidget);
      expect(find.text(notificationsOffText), findsOneWidget);
      final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      expect(icon.color, Theme.of(tester.element(find.byType(Scaffold))).colorScheme.error);
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect((settings, closed), (1, 1));
      expect(find.byType(AlertDialog), findsNothing);
      // Again, closed by its (x): no Settings.
      unawaited(showNotificationsOffNotice(context: ctx, onSettings: () => settings++).then((_) => closed++));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('notice-close')));
      await tester.pumpAndSettle();
      expect((settings, closed), (1, 2));
    });
  }
}
