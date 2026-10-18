// What the testers found on web, iOS and Android: layouts that overflowed
// or clipped (checked at phone sizes, large text (1.3, the app's cap) and
// in both themes), and the small rules behind the other fixes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_shell.dart';
import 'package:get_ride/src/admin/screens/dashboard_screen.dart';
import 'package:get_ride/src/admin/screens/support_screens.dart' show ticketTitle;
import 'package:get_ride/src/admin/widgets/admin_widgets.dart' show StatusChip;
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/core/auth_utils.dart';
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/smart_address.dart' show isCoordinateLabel;
import 'package:get_ride/src/features/shell/app_side_menu.dart' show AppSideMenuHost;
import 'package:get_ride/src/features/settings/permissions_card.dart';
import 'package:get_ride/src/widgets/app_build_widgets.dart' show appBuildMissing;
import 'package:get_ride/src/widgets/common.dart';

const _sizes = [Size(412, 915), Size(360, 640), Size(320, 640)];

Future<void> _at(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Widget _app(Widget home, {required Brightness b, double scale = 1.3}) => MaterialApp(
  theme: ThemeData(brightness: b),
  home: Builder(
    builder: (c) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: home,
    ),
  ),
);

void main() {
  for (final b in Brightness.values) {
    for (final size in _sizes) {
      for (final scale in const [1.0, 1.3]) {
        final at = '${size.width.toInt()}x${size.height.toInt()} @$scale ${b.name}';

        testWidgets('admin dashboard tiles fit their captions ($at)', (tester) async {
          await _at(tester, size);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                dashboardCountsProvider.overrideWith(
                  (ref) async => {'partnersPending': 12345, 'vehicleDocsPending': 3, 'providerDocsPending': 7},
                ),
              ],
              child: _app(const AdminDashboardScreen(), b: b, scale: scale),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Partners awaiting approval'), findsOneWidget);
        });

        testWidgets('Settings → Permissions keeps the reason readable ($at)', (tester) async {
          await _at(tester, size);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                permissionStatusesProvider.overrideWith(
                  (ref) async => {for (final p in AppPermission.values) p: PermState.denied},
                ),
              ],
              child: _app(const Scaffold(body: SingleChildScrollView(child: PermissionsCard())), b: b, scale: scale),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('the admin rail scrolls on a short window instead of overflowing', (tester) async {
    await _at(tester, const Size(1180, 600));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
        ],
        child: const MaterialApp(home: AdminShell(location: '/admin/dashboard', child: Text('PANEL'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byTooltip('Exit admin'), findsOneWidget);
  });

  testWidgets('a segment label shrinks rather than breaking mid-word', (tester) async {
    await _at(tester, const Size(320, 640));
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: SegmentedButton<int>(
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: SegmentLabel('Everyone')),
              ButtonSegment(value: 1, label: SegmentLabel('Passengers')),
              ButtonSegment(value: 2, label: SegmentLabel('Partners')),
            ],
            selected: const {0},
          ),
        ),
        b: Brightness.light,
      ),
    );
    expect(tester.takeException(), isNull);
    for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(SegmentLabel), matching: find.byType(Text)))) {
      expect(t.maxLines, 1);
    }
  });

  test('error text: people get words, the raw error stays under details', () {
    expect(errorText(TypeError()), genericErrorMessage);
    expect(errorText(const FormatException('Unexpected character')), genericErrorMessage);
    expect(errorDetails(const FormatException('Unexpected character')), contains('Unexpected character'));
    expect(errorText(Exception('Your card was declined.')), 'Your card was declined.');
    expect(errorDetails(Exception('Your card was declined.')), 'Exception: Your card was declined.');
  });

  test('a sign-in step reloaded without its state starts again sensibly', () {
    expect(signInStepRedirect('/login/pin', const {}), '/login/phone');
    expect(signInStepRedirect('/login/otp', const {'next': 'set-pin'}), '/login/phone');
    expect(signInStepRedirect('/login/pin', const {'phone': '+60123456789'}), isNull);
    expect(signInStepRedirect('/login/otp', const {'phone': '+60123456789', 'next': 'set-pin'}), isNull);
    // A resync's PIN lives only in memory: after a reload, back to the PIN.
    expect(
      signInStepRedirect('/login/otp', const {'phone': '+60123456789', 'next': 'resync'}),
      '/login/pin?phone=%2B60123456789',
    );
    expect(signInStepRedirect('/login/otp', const {'phone': '+6012', 'next': 'resync'}, resyncPin: '123456'), isNull);
    expect(signInStepRedirect('/login/phone', const {}), isNull);
  });

  test('stored values read as the booking sheet says them', () {
    expect(paymentModeLabel('cash'), 'Cash');
    expect(paymentModeLabel('Get Pay'), 'GET.wallet');
    expect(paymentModeLabel('touch n go'), 'Touch n go');
    expect(StatusChip.labelFor('on_trip'), 'On trip');
    expect(StatusChip.labelFor('unapproved-docs'), 'Unapproved docs');
    expect(ticketTitle(const {'subject': 'Lost my phone'}), 'Lost my phone');
    expect(ticketTitle(const {'subject': 'Lost my phone', 'ticket_number': 12}), '#12 · Lost my phone');
    expect(isCoordinateLabel('3.15790, 101.71160'), isTrue);
    expect(isCoordinateLabel('Pavilion KL'), isFalse);
    expect(appBuildMissing(Exception('FunctionException(status: 404, details: Not found)')), isTrue);
    expect(appBuildMissing(Exception('FunctionException(status: 500)')), isFalse);
  });

  test('a phone on its side keeps the phone layout (side menu, not the rail)', () {
    expect(AppSideMenuHost.appliesAt(852, 393), isTrue);
    expect(AppSideMenuHost.appliesAt(1180, 820), isFalse);
    expect(AppSideMenuHost.appliesAt(400), isTrue);
  });
}
