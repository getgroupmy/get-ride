// Daily hire (migration 0327) on screen, light and dark: the package chips,
// the days side of the booking panel (the first day in boxes, the days,
// the hours a day, the same driver, the overnight tick, the vehicles at
// their day price), the review (total, deposit now, on day 1, the free
// cancel time, the rates), the rider's booking card, the driver's card for
// a whole booking and the admin's Daily hire settings form.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/hourly_hire_card.dart';
import 'package:get_ride/src/admin/screens/multi_hire_card.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/core/hourly_hire.dart';
import 'package:get_ride/src/core/multi_day_hire.dart';
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/data/geo_service.dart' show Place;
import 'package:get_ride/src/features/ride/multi_hire_parts.dart';
import 'package:latlong2/latlong.dart';

String rm(double v) => 'RM ${v == v.roundToDouble() ? v.round() : v.toStringAsFixed(2)}';

const _config = MultiHireConfig(enabled: true, mealAllowance: 20);
const _pickup = Place(name: 'Day Plaza', address: '1 Jalan Contoh', point: LatLng(3.1, 101.6));
const _services = [
  RideService('Saloon', 'A car', 1, 4),
  RideService('Bike', 'One rider', 0.5, 1),
];
final _now = DateTime(2026, 11, 1, 10);

/// The server's quote: Saloon RM 300 a day for 10 hours, a RM 5 pickup fee,
/// RM 20 meals, RM 80 a night away; the Bike can't be hired by the day.
MultiHireQuote _quote(MultiHireQuoteArgs a) {
  if (a.service != 'Saloon') return const MultiHireQuote(available: false, reason: 'HIRE_SERVICE_OFF');
  final perDay = 300 * a.hours / 10;
  return MultiHireQuote(
    available: true,
    days: a.days,
    hours: a.hours,
    dayRate: 300,
    perDay: perDay,
    kmPerDay: 150,
    overtimePerHour: 45,
    extraKm: 1.5,
    overnight: a.overnight,
    nights: a.overnight ? a.days - 1 : 0,
    overnightAllowance: 80,
    mealAllowance: 20,
    placeFees: const [(name: 'Plaza pickup fee', amount: 5)],
    placeFeesPerDay: 5,
    base: perDay * a.days,
    depositPercent: 30,
  );
}

Widget _app(Brightness b, Widget child) => ProviderScope(
  overrides: [multiHireQuoteProvider.overrideWith((ref, a) async => _quote(a))],
  child: MaterialApp(
    theme: appTheme(b),
    home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
  ),
);

void main() {
  for (final b in Brightness.values) {
    group('${b.name} mode', () {
      setUp(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.physicalSize = const Size(900, 3200);
        binding.platformDispatcher.views.first.devicePixelRatio = 1;
      });
      tearDown(() {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.platformDispatcher.views.first.resetPhysicalSize();
        binding.platformDispatcher.views.first.resetDevicePixelRatio();
      });

      testWidgets('the package chips', (tester) async {
        String? picked;
        await tester.pumpWidget(_app(
          b,
          HirePackageChips(
            packages: const [(key: 'hourly', label: 'Hourly'), (key: 'daily', label: 'Daily')],
            selected: 'hourly',
            onChanged: (k) => picked = k,
          ),
        ));
        expect(find.text('Hourly'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hire-package-daily')));
        expect(picked, 'daily');
      });

      testWidgets('days, hours, the day price, the review and booking with the deposit', (tester) async {
        MultiHireBooking? booked;
        await tester.pumpWidget(_app(
          b,
          MultiHirePanel(
            config: _config,
            pickup: _pickup,
            drop: null,
            onPickup: () {},
            onDrop: () {},
            onClearDrop: () {},
            stops: const [],
            onAddStop: () {},
            onRemoveStop: (_) {},
            services: _services,
            place: (country: 'Malaysia', state: null, city: null, suburb: null),
            pricingFor: (_) => RegionPricing.none,
            money: rm,
            payments: builtInPayments.where((p) => p.kind == PaymentKind.wallet).toList(),
            payment: 'Get Pay',
            onPayment: (_) {},
            onBook: (x) async => booked = x,
            clock: () => _now,
          ),
        ));
        await tester.pumpAndSettle();
        // Two days from 2 Nov, 9:00 am; the Bike isn't offered by the day.
        expect(find.text('2 days'), findsOneWidget);
        expect(find.text('10 hr'), findsOneWidget);
        expect(find.text('Starts at 9:00 am each day'), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-days-card-Saloon')), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-days-card-Bike')), findsNothing);
        expect(find.text('RM 650'), findsOneWidget, reason: '2 × (300 + 5 + 20)');
        // Three days, a night away each of the first two.
        await tester.tap(find.byKey(const ValueKey('hire-days-count-plus')));
        await tester.tap(find.byKey(const ValueKey('hire-days-overnight')));
        await tester.pumpAndSettle();
        expect(find.text('RM 1135'), findsOneWidget);
        expect(find.textContaining('RM 80 a night'), findsOneWidget);
        // Same driver on by default.
        expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('hire-days-same-driver'))).value, isTrue);
        await tester.tap(find.byKey(const ValueKey('hire-days-review')));
        // The button spins while the review is open.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(const ValueKey('hire-days-review-sheet')), findsOneWidget);
        expect(find.descendant(of: find.byKey(const ValueKey('hire-review-total')), matching: find.text('RM 1135')),
            findsOneWidget);
        expect(find.descendant(of: find.byKey(const ValueKey('hire-review-now')), matching: find.text('RM 340.50')),
            findsOneWidget);
        expect(find.descendant(of: find.byKey(const ValueKey('hire-review-balance')), matching: find.text('RM 794.50')),
            findsOneWidget);
        expect(find.textContaining('Free cancellation until'), findsOneWidget);
        expect(find.textContaining('Overtime RM 45 / hr, extra km RM 1.50 / km'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hire-review-book')));
        await tester.pumpAndSettle();
        expect(booked, isNotNull);
        expect((booked!.days, booked!.hours, booked!.overnight, booked!.sameDriver, booked!.plan),
            (3, 10.0, true, true, HirePayPlan.deposit));
        expect(booked!.firstAt, DateTime(2026, 11, 2, 9));
      });

      testWidgets('paying it all now, where the admin allows it', (tester) async {
        await tester.pumpWidget(_app(
          b,
          MultiHireReview(
            config: _config,
            quote: _quote((
              package: 'daily', lat: 0, lng: 0, dropLat: null, dropLng: null, service: 'Saloon', days: 2,
              hours: 10, firstAt: DateTime(2026, 11, 2, 9), overnight: false, country: null, state: null,
              city: null, suburb: null,
            )),
            pricing: RegionPricing.none,
            money: rm,
            service: 'Saloon',
            firstAt: DateTime(2026, 11, 2, 9),
            sameDriver: false,
            business: false,
          ),
        ));
        await tester.tap(find.text('Pay it all now'));
        await tester.pumpAndSettle();
        expect(find.descendant(of: find.byKey(const ValueKey('hire-review-now')), matching: find.text('RM 650')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('hire-review-balance')), findsNothing);
        expect(find.text('Book · pay RM 650 now'), findsOneWidget);
      });

      testWidgets('the rider\'s booking with its days', (tester) async {
        final booking = HireDaysBooking.fromRow({
          'id': 'b1',
          'service': 'Saloon',
          'status': 'assigned',
          'first_at': DateTime(2026, 11, 2, 9).toUtc().toIso8601String(),
          'days': 2,
          'hours_per_day': 10,
          'payment_plan': 'deposit',
          'payment_state': 'deposit_paid',
          'price': 650,
          'deposit_amount': 195,
          'balance_amount': 455,
          'paid_amount': 195,
          'quote': {'title': 'Daily hire'},
        });
        await tester.pumpWidget(_app(
          b,
          HireBookingCard(
            booking: booking,
            money: rm,
            days: [
              (day: 1, at: DateTime(2026, 11, 2, 9), status: 'Driver confirmed'),
              (day: 2, at: DateTime(2026, 11, 3, 9), status: 'Driver confirmed'),
            ],
          ),
        ));
        expect(find.text('Daily hire'), findsOneWidget);
        expect(find.text('Driver confirmed'), findsOneWidget);
        expect(find.text('Deposit RM 195 paid, RM 455 on day 1'), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-booking-day-b1-2')), findsOneWidget);
        expect(find.textContaining('Day 2 of 2 · Tue 3 Nov, 9:00 am'), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-booking-cancel-b1')), findsOneWidget);
      });

      testWidgets('a whole booking on the driver\'s Upcoming', (tester) async {
        final o = OpenHireBooking.fromRow({
          'id': 'b1',
          'title': 'Daily hire',
          'service': 'Saloon',
          'first_at': DateTime(2026, 11, 2, 9).toUtc().toIso8601String(),
          'days': 2,
          'hours_per_day': 10,
          'km_per_day': 150,
          'fare': 600,
          'pickup_address': '1 Jalan Contoh',
          'day_list': [
            {'day': 1, 'pickup_at': DateTime(2026, 11, 2, 9).toUtc().toIso8601String(), 'fare': 300},
            {'day': 2, 'pickup_at': DateTime(2026, 11, 3, 9).toUtc().toIso8601String(), 'fare': 300},
          ],
        });
        await tester.pumpWidget(_app(b, OpenHireBookingCard(booking: o, money: rm)));
        expect(find.text('Daily hire · 2 days'), findsOneWidget);
        expect(find.textContaining('Day 1 of 2 · Mon 2 Nov, 9:00 am · RM 300'), findsOneWidget);
        expect(find.text('Take every day'), findsOneWidget);
      });

      testWidgets('the admin\'s Daily hire settings save every value', (tester) async {
        MultiHireConfig? saved;
        await tester.pumpWidget(_app(
          b,
          MultiHireForm(stored: const MultiHireConfig(), canEdit: true, onSave: (c) async => saved = c),
        ));
        await tester.tap(find.byKey(const ValueKey('daily-admin-enabled')));
        await tester.enterText(find.byKey(const ValueKey('daily-admin-maxDays')), '5');
        await tester.enterText(find.byKey(const ValueKey('daily-admin-depositPercent')), '40');
        await tester.tap(find.text('A percent of the price'));
        await tester.pump();
        await tester.enterText(find.byKey(const ValueKey('daily-admin-lateCancelPercent')), '15');
        await tester.enterText(find.byKey(const ValueKey('daily-admin-mealAllowance')), '25');
        await tester.tap(find.byKey(const ValueKey('daily-admin-split')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('daily-admin-save')));
        await tester.pump();
        expect(saved, isNotNull);
        expect((saved!.enabled, saved!.maxDays, saved!.depositPercent, saved!.lateCancel, saved!.lateCancelPercent),
            (true, 5, 40.0, HireLateCancel.percent, 15.0));
        expect((saved!.mealAllowance, saved!.splitDays), (25.0, false));
      });

      testWidgets('the hourly settings say what a cash booking does after cash is turned off', (tester) async {
        HourlyHireConfig? saved;
        await tester.pumpWidget(_app(
          b,
          HourlyHireForm(stored: const HourlyHireConfig(), canEdit: true, onSave: (c) async => saved = c),
        ));
        await tester.tap(find.text('Switch to GET.wallet'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('hire-admin-save')));
        await tester.pump();
        expect(saved?.cashOffLater, HireCashOffLater.wallet);
      });
    });
  }
}
