// Hourly hire (migration 0326) on screen, light and dark: the booking
// panel's switch, the hours stepper and the hire cards with the server's
// prices, the driver's extension request modal on the rider's trip, the
// driver's hire timer, and the admin's Hourly hire settings form.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/hourly_hire_card.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/core/hourly_hire.dart';
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/data/geo_service.dart' show Place;
import 'package:get_ride/src/data/hourly_hire_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/hire_parts.dart';
import 'package:latlong2/latlong.dart';

String rm(double v) => 'RM ${v == v.roundToDouble() ? v.round() : v.toStringAsFixed(2)}';

const _config = HourlyHireConfig(enabled: true, minHours: 2, maxHours: 12);
const _pickup = Place(name: 'Hire Plaza', address: '1 Jalan Contoh', point: LatLng(3.1, 101.6));
const _services = [
  RideService('Saloon', 'A car', 1, 4),
  RideService('Van', 'Seven seats', 1.5, 7),
  RideService('Bike', 'One rider', 0.5, 1),
];

/// The server's quote: Saloon RM 40 / hr, Van RM 60 / hr, Bike not for hire;
/// a RM 5 pickup fee.
HireQuote _quote(HireQuoteArgs a) {
  final rate = switch (a.service) {
    'Saloon' => 40.0,
    'Van' => 60.0,
    _ => null,
  };
  if (rate == null) return const HireQuote(available: false, reason: 'HIRE_SERVICE_OFF', hours: 2);
  final base = rate * a.hours;
  return HireQuote(
    available: true,
    hours: a.hours,
    rate: rate,
    kmIncluded: 15 * a.hours,
    overtimePerHour: 50,
    extraKm: 1.2,
    base: base,
    placeFees: const [(name: 'Plaza pickup fee', amount: 5)],
    placeFeesTotal: 5,
    total: base + 5,
    hold: base + 5,
  );
}

class _FakeHire implements HourlyHireRepository {
  final answers = <(String, bool)>[];

  @override
  Future<void> answer(String rideId, String extensionId, {required bool approve}) async =>
      answers.add((extensionId, approve));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Brightness b, Widget child, {List overrides = const []}) => ProviderScope(
  overrides: [
    hireQuoteProvider.overrideWith((ref, a) async => _quote(a)),
    ...overrides.cast(),
  ],
  child: MaterialApp(
    theme: appTheme(b),
    home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
  ),
);

RideRequest _ride({required String status, DateTime? started, List<Map<String, dynamic>> ext = const []}) =>
    RideRequest({
      'id': 'r1',
      'status': status,
      'currency': 'MYR',
      'fare': 160,
      'hire_package': 'hourly',
      'hire_hours': 4,
      'hire_rate': 40,
      'hire_km_included': 60,
      'hire_overtime_rate': 50,
      'hire_step_min': 30,
      'hire_extra_km_rate': 1.2,
      'hire_quote': {'kmPerHour': 15, 'minHours': 2, 'hourStep': 1},
      'hire_started_at': started?.toUtc().toIso8601String(),
      'hire_ends_at': started?.add(const Duration(hours: 4)).toUtc().toIso8601String(),
      'hire_extensions': ext,
    });

void main() {
  for (final b in Brightness.values) {
    group('${b.name} mode', () {
      setUp(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.physicalSize = const Size(900, 2600);
        binding.platformDispatcher.views.first.devicePixelRatio = 1;
      });
      tearDown(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.resetPhysicalSize();
        binding.platformDispatcher.views.first.resetDevicePixelRatio();
      });

      testWidgets('the panel switch: Go somewhere / Hire by time', (tester) async {
        bool? hire;
        await tester.pumpWidget(_app(b, HireModeSwitch(config: _config, hire: false, onChanged: (v) => hire = v)));
        expect(find.text('Go somewhere'), findsOneWidget);
        expect(find.text('Hire by time'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hire-mode-hire')));
        expect(hire, isTrue);
      });

      testWidgets('hours, the vehicles that can be hired at the server\'s price, and booking', (tester) async {
        HireBooking? booked;
        DateTime? bookedAt;
        await tester.pumpWidget(_app(
          b,
          HireBookingPanel(
            config: _config,
            pickup: _pickup,
            drop: null,
            onPickup: () {},
            onDrop: () {},
            onClearDrop: () {},
            services: _services,
            place: (country: 'Malaysia', state: null, city: null, suburb: null),
            pricingFor: (_) => const RegionPricing(tax: RegionTax(name: 'SST', kind: TaxKind.percent, value: 10)),
            money: rm,
            payments: builtInPayments.where((p) => p.kind != PaymentKind.cash).toList(),
            payment: 'Get Pay',
            onPayment: (_) {},
            onBook: (bk, at) async {
              booked = bk;
              bookedAt = at;
            },
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.text('Where to? (optional)'), findsOneWidget);
        expect(find.text('2 hr'), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-card-Saloon')), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-card-Van')), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-card-Bike')), findsNothing, reason: 'not for hire: not shown');
        expect(find.text('RM 40 / hr · 30 km included'), findsOneWidget);
        // 2 × 40 + RM 5 place fee, SST 10% on the fare (the region's tax): 93.
        expect(find.descendant(of: find.byKey(const ValueKey('hire-total')), matching: find.text('RM 93')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('hire-terms')), findsOneWidget);
        expect(find.text('Overtime RM 50 / hr, extra km RM 1.20 / km, fuel included'), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-hold-note')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('hire-hours-plus')));
        await tester.pumpAndSettle();
        expect(find.text('3 hr'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hire-card-Van')));
        await tester.pumpAndSettle();
        // 3 × 60 + 5 = 185, SST 18: 203.
        expect(find.text('Hire · RM 203'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hire-book')));
        await tester.pumpAndSettle();
        expect(booked?.service.name, 'Van');
        expect(booked?.hours, 3);
        expect(booked?.total, 203);
        expect(bookedAt, isNull);
        // At least the least hours.
        await tester.tap(find.byKey(const ValueKey('hire-hours-minus')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<IconButton>(find.byKey(const ValueKey('hire-hours-minus'))).onPressed,
          isNull,
          reason: 'two hours is the least',
        );
      });

      testWidgets('cash where the admin doesn\'t allow it: not booked, and why', (tester) async {
        await tester.pumpWidget(_app(
          b,
          HireBookingPanel(
            config: _config,
            pickup: _pickup,
            drop: null,
            onPickup: () {},
            onDrop: () {},
            onClearDrop: () {},
            services: _services,
            place: (country: null, state: null, city: null, suburb: null),
            pricingFor: (_) => RegionPricing.none,
            money: rm,
            payments: builtInPayments,
            payment: 'Cash',
            onPayment: (_) {},
            onBook: (_, _) async => fail('cash is not allowed'),
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('hire-cash-note')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hire-book')));
        await tester.pumpAndSettle();
      });

      testWidgets('the driver asks for more time: a modal with Approve and Decline', (tester) async {
        final fake = _FakeHire();
        await tester.pumpWidget(_app(
          b,
          HireTripCard(
            ride: _ride(
              status: 'on_trip',
              started: DateTime.now().subtract(const Duration(minutes: 200)),
              ext: [
                {'id': 'e1', 'minutes': 30, 'amount': 25, 'asked_by': 'driver', 'status': 'pending'},
              ],
            ),
            config: _config,
            money: rm,
          ),
          overrides: [hourlyHireRepositoryProvider.overrideWithValue(fake)],
        ));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('hire-extend-request')), findsOneWidget);
        expect(find.text('30 min more for RM 25. It is added to the price when the hire ends.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hire-extend-approve')));
        await tester.pumpAndSettle();
        expect(fake.answers, [('e1', true)]);
        expect(find.byKey(const ValueKey('hire-used')), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-end')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('the driver\'s hire timer, and the reminder near the end', (tester) async {
        await tester.pumpWidget(_app(
          b,
          DriverHireCard(
            ride: _ride(status: 'on_trip', started: DateTime.now().subtract(const Duration(minutes: 80))),
            config: _config,
            money: rm,
          ),
        ));
        await tester.pump();
        expect(find.text('Time used: 1 hr 20 min of 4 hr'), findsOneWidget);
        expect(find.byKey(const ValueKey('driver-hire-near-end')), findsNothing);
        expect(find.byKey(const ValueKey('driver-hire-extend')), findsOneWidget);
        expect(find.byKey(const ValueKey('driver-hire-end')), findsOneWidget);
        await tester.pumpWidget(_app(
          b,
          DriverHireCard(
            ride: _ride(status: 'on_trip', started: DateTime.now().subtract(const Duration(minutes: 230))),
            config: _config,
            money: rm,
            showEnd: false,
          ),
        ));
        await tester.pump();
        expect(find.byKey(const ValueKey('driver-hire-near-end')), findsOneWidget);
        expect(find.byKey(const ValueKey('driver-hire-end')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('End hire asks the km, started from the phone\'s count', (tester) async {
        double? km;
        await tester.pumpWidget(_app(
          b,
          Builder(
            builder: (c) => TextButton(
              onPressed: () async => km = await showHireEndDialog(c, measuredKm: 42.36, kmIncluded: 60),
              child: const Text('open'),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('42.4'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('hire-end-km')), '75');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('hire-end-confirm')));
        await tester.pumpAndSettle();
        expect(km, 75);
      });

      testWidgets('admin: every setting, checked, saved', (tester) async {
        HourlyHireConfig? saved;
        await tester.pumpWidget(_app(
          b,
          HourlyHireForm(stored: _config, canEdit: true, onSave: (c) async => saved = c),
        ));
        expect(find.text('Hourly hire on'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('hire-admin-choices')), '15, 45');
        await tester.enterText(find.byKey(const ValueKey('hire-admin-min')), '3');
        await tester.tap(find.byKey(const ValueKey('hire-admin-cash')));
        await tester.tap(find.text('The hours used'));
        await tester.tap(find.text('Half hours'));
        await tester.enterText(find.byKey(const ValueKey('hire-admin-tile')), 'Book a driver');
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('hire-admin-save')));
        await tester.tap(find.byKey(const ValueKey('hire-admin-save')));
        await tester.pumpAndSettle();
        expect(saved?.minHours, 3);
        expect(saved?.extendChoices, [15, 45]);
        expect(saved?.allowCash, isTrue);
        expect(saved?.earlyEndPays, HireEarlyEndPays.used);
        expect(saved?.hourStep, 0.5);
        expect(saved?.tileTitle, 'Book a driver');

        // A wrong value is said, not saved.
        saved = null;
        await tester.enterText(find.byKey(const ValueKey('hire-admin-choices')), '1');
        await tester.tap(find.byKey(const ValueKey('hire-admin-save')));
        await tester.pumpAndSettle();
        expect(saved, isNull);
        expect(find.textContaining('Extension choices are minutes'), findsOneWidget);
      });
    });
  }
}
