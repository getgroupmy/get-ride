// More than one device for chosen accounts (migration 0298): the admin's
// Devices section on an account, the list in Sign-in security, and what a
// phone signed out past its allowance is told.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/security/sign_in_security_card.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/sign_in_security.dart';

Future<void> _pump(WidgetTester tester, Brightness b, Widget child, {List overrides = const []}) async {
  await tester.binding.setSurfaceSize(const Size(700, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...overrides],
      child: MaterialApp(
        theme: appTheme(b),
        home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('the sign-out note says why, with the allowance', () {
    expect(signedOutElsewhereMessageFor(1), signedOutElsewhereMessage);
    expect(signedOutElsewhereMessageFor(3), contains('allowed number of devices (3)'));
    expect(signedOutElsewhereMessageFor(3), contains('signed in longest ago'));
  });

  for (final b in Brightness.values) {
    group('an account\'s Devices (${b.name})', () {
      testWidgets('one device by default: − and + show Save', (tester) async {
        await _pump(
          tester,
          b,
          const ActiveDeviceSection(userId: 'u1', canEdit: true),
          overrides: [
            deviceAllowanceProvider('u1').overrideWith((ref) async => (devices: 1, reason: null)),
            activeSessionProvider('u1').overrideWith(
              (ref) async => {'device_label': 'iPhone 15', 'platform': 'ios', 'app_version': '1.4.10'},
            ),
          ],
        );
        expect(find.text('App default: one device at a time.'), findsOneWidget);
        expect(find.textContaining('iPhone 15'), findsOneWidget);
        expect(find.byKey(const ValueKey('admin-user-devices-save')), findsNothing);
        final less = tester.widget<IconButton>(find.byKey(const ValueKey('devices-less')));
        expect(less.onPressed, isNull, reason: 'never below one');
        await tester.tap(find.byKey(const ValueKey('devices-more')));
        await tester.pumpAndSettle();
        expect(find.text('2'), findsOneWidget);
        expect(find.textContaining('up to 2 devices'), findsOneWidget);
        expect(find.byKey(const ValueKey('admin-user-devices-reason')), findsOneWidget);
        expect(find.byKey(const ValueKey('admin-user-devices-save')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('three allowed: each device listed with Sign out', (tester) async {
        await _pump(
          tester,
          b,
          const ActiveDeviceSection(userId: 'u1', canEdit: true),
          overrides: [
            deviceAllowanceProvider('u1').overrideWith((ref) async => (devices: 3, reason: 'Office tablets')),
            accountDevicesProvider('u1').overrideWith((ref) async => [
                  {'session_id': 's1', 'device_id': 'd1', 'device_label': 'Tablet A', 'platform': 'android'},
                  {'session_id': 's2', 'device_id': 'd2', 'device_label': 'Tablet B', 'platform': 'android'},
                ]),
            activeSessionProvider('u1').overrideWith((ref) async => null),
          ],
        );
        expect(find.text('Signed in now · 2 of 3'), findsOneWidget);
        expect(find.byKey(const ValueKey('admin-user-device-signout-s1')), findsOneWidget);
        expect(find.byKey(const ValueKey('admin-user-device-signout-s2')), findsOneWidget);
        expect(find.text('Office tablets'), findsOneWidget, reason: 'the reason in its box');
        expect(find.byKey(const ValueKey('admin-user-sign-out-everywhere')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('read only: shown, nothing to change', (tester) async {
        await _pump(
          tester,
          b,
          const ActiveDeviceSection(userId: 'u1', canEdit: false),
          overrides: [
            deviceAllowanceProvider('u1').overrideWith((ref) async => (devices: 2, reason: null)),
            accountDevicesProvider('u1').overrideWith((ref) async => const []),
            activeSessionProvider('u1').overrideWith((ref) async => null),
          ],
        );
        expect(tester.widget<IconButton>(find.byKey(const ValueKey('devices-more'))).onPressed, isNull);
        expect(find.byKey(const ValueKey('admin-user-sign-out-everywhere')), findsNothing);
      });
    });

    group('Sign-in security list (${b.name})', () {
      testWidgets('accounts allowed more, Change, and the search to add one', (tester) async {
        await _pump(
          tester,
          b,
          const DeviceAllowancesList(canEdit: true),
          overrides: [
            deviceAllowancesProvider.overrideWith((ref) async => [
                  {'user_id': 'u1', 'name': 'Fleet Office', 'display_id': 'U-1001', 'devices': 3, 'reason': 'Office tablets', 'in_use': 2},
                ]),
          ],
        );
        expect(find.text('Fleet Office · U-1001'), findsOneWidget);
        expect(find.text('3 devices · 2 in use · Office tablets'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('device-allowance-change-u1')));
        await tester.pumpAndSettle();
        expect(find.text('Devices for an account'), findsOneWidget);
        expect(find.text('Allow 3 devices'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('devices-less')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('devices-less')));
        await tester.pumpAndSettle();
        expect(find.text('Back to one device'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('device-allowance-add')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('allow-devices-search')), findsOneWidget);
        expect(find.byKey(const ValueKey('allow-devices-save')), findsNothing, reason: 'pick an account first');
        expect(tester.takeException(), isNull);
      });

      testWidgets('none yet', (tester) async {
        await _pump(
          tester,
          b,
          const DeviceAllowancesList(canEdit: false),
          overrides: [deviceAllowancesProvider.overrideWith((ref) async => const [])],
        );
        expect(find.text('None. Every account is held to one device.'), findsOneWidget);
        expect(find.byKey(const ValueKey('device-allowance-add')), findsNothing);
      });
    });
  }
}
