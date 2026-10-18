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
import 'package:get_ride/src/admin/screens/commission_screen.dart' show commissionLevelLabel;
import 'package:get_ride/src/admin/screens/people/partner_screens.dart' show partnerDisplayId;
import 'package:get_ride/src/admin/screens/rides_screen.dart' show adminRideSubtitle;
import 'package:get_ride/src/admin/widgets/admin_widgets.dart' show DetailTable, humanKey;
import 'package:get_ride/src/core/contact_phone.dart' show formatPhoneDisplay;
import 'package:get_ride/src/core/dial_countries.dart' show dialCountries;
import 'package:get_ride/src/core/help_article.dart' show helpProblemField;
import 'package:get_ride/src/core/inbox.dart';
import 'package:get_ride/src/core/partner_onboarding.dart' show onboardingProgress;
import 'package:get_ride/src/core/partner_statement.dart' show EarningsBucket, StatementTotals;
import 'package:get_ride/src/core/profile_identity.dart' show idNumberProblem, profileEmailProblem;
import 'package:get_ride/src/core/recent_places.dart' show recentPlaces;
import 'package:get_ride/src/core/scheduled_rides.dart' show ScheduledRide, confirmedPickupAt;
import 'package:get_ride/src/core/trip_receipt.dart' show TripReceipt;
import 'package:get_ride/src/data/geo_service.dart' show Place;
import 'package:get_ride/src/data/help_repository.dart' show helpStarterViewer;
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/meter/landscape_stage.dart';
import 'package:get_ride/src/features/notifications/notifications_screen.dart' show InboxTile;
import 'package:get_ride/src/features/partner/earnings_chart.dart';
import 'package:get_ride/src/features/partner/partner_menu.dart' show partnerMenuRowShows, partnerRowsAfterApproval;
import 'package:get_ride/src/features/profile/emergency_contacts_screen.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart' show ConfirmAddressCard;
import 'package:get_ride/src/features/ride/trip_history_view.dart' show tripListFare;
import 'package:get_ride/src/features/wallet/wallet_history_screen.dart' show walletStatusLabel;
import 'package:get_ride/src/widgets/dial_country_picker.dart' show DialCountryButton;
import 'package:get_ride/src/widgets/route_title.dart' show pageTitleFor;
import 'package:latlong2/latlong.dart' show LatLng;

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

  _batch2();
}

// ---- Second round: forms, lists, admin, web and partner findings ---------------------------------

RideRequest _ride(Map<String, dynamic> extra) => RideRequest({
  'id': 'r1',
  'status': 'completed',
  'pickup_address': 'KLCC, Kuala Lumpur',
  'drop_address': 'Pavilion KL, Bukit Bintang',
  'currency': 'MYR',
  'fare': 57,
  'created_at': '2026-10-01T03:00:00Z',
  ...extra,
});

InboxItem _note(String id, {String? trip, String title = 'Driver arrived', DateTime? at, bool read = false}) => InboxItem(
  id: id,
  title: title,
  body: 'Your driver is waiting.',
  data: {'request_id': ?trip},
  kind: 'ride_status',
  createdAt: at ?? DateTime(2026, 10, 18, 9),
  readAt: read ? DateTime(2026, 10, 18, 10) : null,
);

void _batch2() {
  for (final b in Brightness.values) {
    for (final size in _sizes) {
      for (final scale in const [1.0, 1.3]) {
        final at = '${size.width.toInt()}x${size.height.toInt()} @$scale ${b.name}';

        testWidgets('Add contact keeps the dialog open with the reasons under the fields ($at)', (tester) async {
          await _at(tester, size);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                emergencyContactsProvider.overrideWith((ref) async => const <EmergencyContact>[]),
                contactPickerProvider.overrideWithValue(null),
              ],
              child: _app(const EmergencyContactsScreen(), b: b, scale: scale),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Add contact').last);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('contact-save')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(AlertDialog), findsOneWidget, reason: 'still open');
          expect(find.text('Enter a name'), findsOneWidget);
          expect(find.text('Enter a phone number'), findsOneWidget);
        });

        testWidgets('the confirm route card fits with 44-high targets ($at)', (tester) async {
          await _at(tester, size);
          const kl = LatLng(3.1579, 101.7116);
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ConfirmAddressCard(
                    pickup: const Place(name: 'Suria KLCC, Jalan Ampang, Kuala Lumpur City Centre', address: '', point: kl),
                    drop: const Place(name: 'Pavilion Kuala Lumpur, Jalan Bukit Bintang', address: '', point: kl),
                    stops: const [],
                    duration: '~25 min',
                    entrance: '',
                    onPickup: () {},
                    onDrop: () {},
                    onEntrance: () {},
                    onStops: () {},
                    onAddStop: () {},
                  ),
                ),
              ),
              b: b,
              scale: scale,
            ),
          );
          expect(tester.takeException(), isNull);
          for (final k in ['confirm-pickup', 'confirm-drop', 'confirm-entrance', 'confirm-add-stop']) {
            expect(tester.getSize(find.byKey(ValueKey(k))).height, greaterThanOrEqualTo(44), reason: k);
          }
          expect(find.bySemanticsLabel('Pickup'), findsOneWidget);
        });

        testWidgets('a quiet week draws no bar and the dates are evenly spaced ($at)', (tester) async {
          await _at(tester, size);
          final weeks = [
            for (var i = 0; i < 8; i++)
              EarningsBucket(DateTime(2026, 8, 24).add(Duration(days: 7 * i)), StatementTotals.zero),
          ];
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: SingleChildScrollView(child: WeeklyEarningsChart(weeks: weeks, money: (v) => 'RM${v.toStringAsFixed(2)}')),
              ),
              b: b,
              scale: scale,
            ),
          );
          expect(tester.takeException(), isNull);
          expect(find.textContaining('Week of'), findsOneWidget);
        });

        testWidgets('repeated trip notifications fold into one row with a count ($at)', (tester) async {
          await _at(tester, size);
          final rows = groupInbox([
            _note('a', trip: 't1'),
            _note('b', trip: 't1', read: true),
            _note('c', trip: 't1'),
          ]);
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: InboxTile(
                  item: rows.single.latest,
                  count: rows.single.count,
                  rowUnread: rows.single.unread,
                  now: DateTime(2026, 10, 18, 12),
                  onTap: () {},
                ),
              ),
              b: b,
              scale: scale,
            ),
          );
          expect(tester.takeException(), isNull);
          expect(
            find.byWidgetPredicate(
              (w) => w is Text && (w.textSpan?.toPlainText(includeSemanticsLabels: false) ?? '').contains('×3'),
            ),
            findsOneWidget,
          );
          expect(find.textContaining('3 times'), findsOneWidget, reason: 'read out in words');
        });

        testWidgets('a detail table reads out as "label, value" ($at)', (tester) async {
          await _at(tester, size);
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(
            _app(const Scaffold(body: DetailTable({'Fare': 'RM12.00', 'Empty': null})), b: b, scale: scale),
          );
          expect(tester.takeException(), isNull);
          expect(find.bySemanticsLabel('Fare'), findsOneWidget);
          expect(find.text('Empty'), findsNothing);
          handle.dispose();
        });
      }
    }
  }

  testWidgets('a non-admin on /admin is not offered a claim that can only fail', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AdminGate()));
    expect(find.text('Claim first-admin access'), findsNothing);
    expect(find.text('No admin access'), findsOneWidget);
  });

  testWidgets('an error with its own title says it, with Retry and no raw text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncView<int>(
            value: AsyncValue.error(Exception('PostgrestException: relation does not exist'), StackTrace.empty),
            errorTitle: "Couldn't load the report",
            onRetry: () {},
            data: (_) => const SizedBox(),
          ),
        ),
      ),
    );
    expect(find.text("Couldn't load the report"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('relation does not exist'), findsNothing);
  });

  testWidgets('the country-code button is named by its country, not its flag', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: DialCountryButton(country: dialCountries.first, onPressed: () {}))),
      ),
    );
    expect(find.bySemanticsLabel('Country code +60, Malaysia'), findsOneWidget);
    handle.dispose();
  });

  test('emergency contacts need a name and a whole number', () {
    expect(emergencyContactErrors('', ''), (name: 'Enter a name', phone: 'Enter a phone number'));
    expect(emergencyContactErrors('Mum', '123'), (name: null, phone: 'Enter a full phone number'));
    expect(emergencyContactErrors(' Mum ', '19-556 5525'), (name: null, phone: null));
  });

  test('phone numbers read the same everywhere; the stored value is untouched', () {
    expect(formatPhoneDisplay('+60195565525'), '+60 19-556 5525');
    expect(formatPhoneDisplay('0195565525'), '+60 19-556 5525');
    expect(formatPhoneDisplay('+601155565525'), '+60 11-5556 5525');
    expect(formatPhoneDisplay('+60321234567'), '+60 3-2123 4567');
    expect(formatPhoneDisplay('+6591234567'), '+65 91234567');
    expect(formatPhoneDisplay(null), '');
    expect(formatPhoneDisplay('12'), '12');
  });

  test('Edit profile checks the email and the ID each on its own', () {
    expect(profileEmailProblem(''), isNull);
    expect(profileEmailProblem('a@b.co'), isNull);
    expect(profileEmailProblem('a@b'), 'Enter a valid email address');
    expect(idNumberProblem(''), isNull);
    expect(idNumberProblem('900101-14-5678'), isNull);
    expect(idNumberProblem('A1234567'), isNull);
    expect(idNumberProblem('12'), isNotNull);
    expect(idNumberProblem('A12#45'), isNotNull);
  });

  test('a cancelled trip is not shown as charged; amounts have two decimals', () {
    expect(tripListFare(_ride({'status': 'cancelled'})), 'Not charged');
    expect(tripListFare(_ride({'status': 'expired'})), 'Not charged');
    expect(tripListFare(_ride({})), 'RM57.00');
    final receipt = TripReceipt.fromRide(_ride({
      'status': 'cancelled',
      'started_at': '2026-10-01T03:10:00Z',
      'distance_km': 4.2,
    }));
    final labels = [for (final (k, _) in receipt.details) k];
    expect(labels, isNot(contains('Picked up')));
    expect(labels, contains('Planned distance'));
    final done = TripReceipt.fromRide(_ride({'started_at': '2026-10-01T03:10:00Z', 'distance_km': 4.2}));
    expect([for (final (k, _) in done.details) k], containsAll(['Picked up', 'Distance']));
  });

  test('partner starter questions wait for approval', () {
    expect(helpStarterViewer(isAdmin: false, isPartner: true, partnerStatus: 'approved'), 'partner');
    expect(helpStarterViewer(isAdmin: false, isPartner: true, partnerStatus: 'unapproved'), 'rider');
    expect(helpStarterViewer(isAdmin: false, isPartner: false), 'rider');
    expect(helpStarterViewer(isAdmin: true, isPartner: true, partnerStatus: 'approved'), 'admin');
  });

  test('notifications fold only when trip, title and text all match', () {
    final rows = groupInbox([
      _note('a', trip: 't1'),
      _note('b', trip: 't2'),
      _note('c', trip: 't1', read: true),
      _note('d', trip: 't1', title: 'Trip started'),
      _note('e'),
      _note('f'),
    ]);
    expect([for (final r in rows) r.ids], [
      ['a', 'c'],
      ['b'],
      ['d'],
      ['e'],
      ['f'],
    ]);
    expect(rows.first.unread, isTrue);
    expect(rows.first.unreadIds, ['a']);
  });

  test('recent places: the same place twice is listed once', () {
    final rides = [
      _ride({'rider_id': 'me', 'drop_name': 'KLCC', 'drop_lat': 3.15790, 'drop_lng': 101.71160, 'created_at': '2026-10-03T00:00:00Z'}),
      _ride({'rider_id': 'me', 'drop_name': 'KLCC', 'drop_lat': 3.15900, 'drop_lng': 101.71300, 'created_at': '2026-10-02T00:00:00Z'}),
      _ride({'rider_id': 'me', 'drop_name': 'Pavilion', 'drop_lat': 3.1490, 'drop_lng': 101.7130, 'created_at': '2026-10-01T00:00:00Z'}),
    ];
    expect([for (final p in recentPlaces(rides, riderId: 'me', max: 8)) p.name], ['KLCC', 'Pavilion']);
  });

  test('admin words: levels, keys, ride rows, partner numbers', () {
    expect(commissionLevelLabel('master'), 'Master');
    expect(commissionLevelLabel('country'), 'Country');
    expect(commissionLevelLabel('user'), 'One person');
    expect(humanKey('sharedDevices'), 'Shared devices');
    expect(humanKey('device_ids'), 'Device IDs');
    expect(humanKey('ipAddress'), 'IP address');
    expect(adminRideSubtitle(_ride({'rider_name': 'Aisyah', 'partner_name': 'Ali'})), endsWith('Rider Aisyah · Driver Ali'));
    expect(adminRideSubtitle(_ride({})), endsWith('Rider unknown'));
    expect(partnerDisplayId({'id': '0b4c-uuid', 'display_id': 'GR-10482'}), 'GR-10482');
    expect(partnerDisplayId({'id': '0b4c-uuid'}), isNull);
  });

  test('a signed-out deep link comes back after sign-in, only to a page of this app', () {
    expect(signInNextPath('/trips/abc?x=1'), '/trips/abc?x=1');
    expect(signInNextPath('//evil.example/x'), isNull);
    expect(signInNextPath('https://evil.example'), isNull);
    expect(signInNextPath('/login/pin'), isNull);
    expect(signInNextPath('/'), isNull);
    expect(signInLocation('/wallet'), '/login?next=%2Fwallet');
    expect(signInLocation('/'), '/login');
  });

  test('each page names the browser tab', () {
    expect(pageTitleFor('/trips'), 'Trips · GET.ride');
    expect(pageTitleFor('/trips/abc'), 'Trip · GET.ride');
    expect(pageTitleFor('/trips/scheduled'), 'Scheduled rides · GET.ride');
    expect(pageTitleFor('/drive/vehicles/new'), 'Add vehicle · GET.ride');
    expect(pageTitleFor('/admin/fare-tariffs'), 'Fare tariffs · Admin · GET.ride');
    expect(pageTitleFor('/'), 'GET.ride');
    expect(pageTitleFor('/nowhere'), 'GET.ride');
  });

  test('a booking confirmation states the time picked when the server echoes none', () {
    final picked = DateTime(2026, 10, 20, 13, 15);
    final none = ScheduledRide.fromRow(const {'id': 's1'});
    expect(confirmedPickupAt(none, picked), picked);
    final echoed = ScheduledRide.fromRow(const {'id': 's1', 'pickup_at': '2026-10-20T06:00:00Z'});
    expect(confirmedPickupAt(echoed, picked), echoed.pickupAt);
  });

  test('wallet rows: a success says nothing, the rest say it in words', () {
    expect(walletStatusLabel('completed'), isNull);
    expect(walletStatusLabel('success'), isNull);
    expect(walletStatusLabel(null), isNull);
    expect(walletStatusLabel('pending'), 'Pending');
    expect(walletStatusLabel('FAILED'), 'Failed');
  });

  test('an unfinished application says where it stands', () {
    expect(onboardingProgress(null, const {}), (step: 1, of: 6, label: 'Profile photo', done: 0.0));
    final p = onboardingProgress(
      const {'avatar_url': 'a', 'ic': '1', 'address': 'x'},
      const {
        'service_countries': ['MY'],
        'service_states': ['KL'],
        'service_cities': ['KL'],
      },
    )!;
    expect('Step ${p.step} of ${p.of} · ${p.label}', 'Step 5 of 6 · Partner type');
  });

  test("the driver menu keeps an approved driver's pages until approval", () {
    for (final id in partnerRowsAfterApproval) {
      expect(
        partnerMenuRowShows(id, obdLinked: true, hasMyRideCode: true, scheduledRides: true, approved: false),
        isFalse,
        reason: id,
      );
    }
    for (final id in ['dashboard', 'vehicle', 'documents', 'wallet']) {
      expect(partnerMenuRowShows(id, obdLinked: false, hasMyRideCode: false, approved: false), isTrue, reason: id);
    }
    expect(partnerMenuRowShows('earnings', obdLinked: false, hasMyRideCode: false), isTrue);
    expect(Partner({'id': 'p', 'status': 'approved'}).approved, isTrue);
    expect(Partner({'id': 'p', 'status': 'permit-active'}).approved, isTrue);
    expect(Partner({'id': 'p', 'status': 'unapproved'}).approved, isFalse);
  });

  test('eight weeks get four evenly spaced dates, the newest among them', () {
    expect([for (var i = 0; i < 8; i++) if (weeklyChartLabelShown(i, 8)) i], [1, 3, 5, 7]);
    expect([for (var i = 0; i < 5; i++) if (weeklyChartLabelShown(i, 5)) i], [0, 1, 2, 3, 4]);
  });

  test('muted text keeps 4.5:1 even under a light admin grey', () {
    final light = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, onSurfaceVariant: const Color(0xFFBBBBBB)));
    expect(mutedTextColor(light), const Color(0xFF6B7280));
    expect(contrastRatio(mutedTextColor(light), light.colorScheme.surface), greaterThanOrEqualTo(4.5));
    final dark = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark, onSurfaceVariant: const Color(0xFF333333)),
    );
    expect(contrastRatio(mutedTextColor(dark), dark.colorScheme.surface), greaterThanOrEqualTo(4.5));
    final plain = ThemeData();
    expect(mutedTextColor(plain), plain.colorScheme.onSurfaceVariant);
  });

  test('a help article problem sits under its own field', () {
    expect(helpProblemField('Enter the question this article answers.'), 'question');
    expect(helpProblemField('Enter the answer.'), 'answer');
    expect(helpProblemField('The answer is too long (4000 characters at most).'), 'answer');
    expect(helpProblemField('Give the action button a label.'), isNull);
  });

  testWidgets('the meter on a portrait web page first asks to turn the phone', (tester) async {
    await _at(tester, const Size(390, 844));
    await tester.pumpWidget(
      const MaterialApp(home: LandscapeStage(showRotateHint: true, child: Text('METER'))),
    );
    expect(find.text('Turn your phone sideways'), findsOneWidget);
    expect(find.text('METER'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('meter-rotate-continue')));
    await tester.pump();
    expect(find.text('METER'), findsOneWidget);
  });

  testWidgets('a landscape page shows the meter straight away', (tester) async {
    await _at(tester, const Size(844, 390));
    await tester.pumpWidget(
      const MaterialApp(home: LandscapeStage(showRotateHint: true, child: Text('METER'))),
    );
    expect(find.text('METER'), findsOneWidget);
  });
}
