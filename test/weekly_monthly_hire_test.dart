// Weekly and monthly hire (migration 0328): the settings as the server keeps
// them, the quote's days at their own price, the totals, a booking's span,
// the weekdays in plain words; on screen (light and dark) the weeks and
// weekdays on the booking panel, the review, the driver's card, the admin's
// Weekly and Monthly settings and the public holidays.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/multi_hire_card.dart';
import 'package:get_ride/src/admin/screens/public_holidays_card.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/core/multi_day_hire.dart';
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/data/geo_service.dart' show Place;
import 'package:get_ride/src/data/hourly_hire_repository.dart';
import 'package:get_ride/src/features/ride/multi_hire_parts.dart';
import 'package:latlong2/latlong.dart';

String rm(double v) => 'RM ${v == v.roundToDouble() ? v.round() : v.toStringAsFixed(2)}';

const _pickup = Place(name: 'Week Plaza', address: '1 Jalan Contoh', point: LatLng(3.1, 101.6));
final _now = DateTime(2026, 11, 1, 10);

/// The server's weekly quote: 1500 a week for 5 weekdays of 10 hours, a
/// week's price shared over its working days, 800 km a week.
MultiHireQuote _weekly(MultiHireQuoteArgs a) {
  final days = a.weekdays.split(',').map(int.parse).toList();
  final price = 1500 * days.length / 5 * a.hours / 10;
  final first = DateTime(2026, 11, 2, 9);
  final list = [
    for (var w = 0; w < a.periods; w++)
      for (var d = 0; d < 7; d++)
        if (days.contains(d + 1))
          (at: first.add(Duration(days: w * 7 + d)), period: w + 1, perDay: price / days.length, km: 800 / days.length),
  ];
  return MultiHireQuote(
    available: true,
    package: 'weekly',
    title: 'Weekly hire',
    days: list.length,
    hours: a.hours,
    dayRate: 300,
    perDay: price / days.length,
    overtimePerHour: 45,
    extraKm: 1.5,
    base: price * a.periods,
    depositPercent: 30,
    dateList: list,
    periods: a.periods,
    weekdays: days,
    periodPrice: price,
    kmPerPeriod: 800,
    kmByPeriod: true,
  );
}

void main() {
  group('settings', () {
    test('weekly and monthly defaults, as the server keeps them', () {
      final w = MultiHireConfig.fromJson('weekly', const {});
      expect((w.enabled, w.maxDays, w.leadHours, w.allowDeposit, w.allowPrepay), (false, 8, 24, false, true));
      expect((w.kmPerDayDefault, w.rateWeekdays), (1000, 5));
      expect(w.weekdaysDefault, [1, 2, 3, 4, 5]);
      expect((w.skipHolidays, w.kmByPeriod, w.noticeDays), (true, true, 0));
      expect((w.chipLabel, w.title, w.periodWord, w.byPeriod), ('Weekly', 'Weekly hire', 'week', true));
      expect(w.defaultPlan, HirePayPlan.prepay);
      final m = MultiHireConfig.fromJson('monthly', const {});
      expect((m.maxDays, m.leadHours, m.noticeDays, m.kmPerDayDefault), (3, 72, 7, 4000));
      expect(m.periodsText(2), '2 months');
      final d = MultiHireConfig.fromJson('daily', const {});
      expect((d.allowDeposit, d.byPeriod, d.defaultPlan), (true, false, HirePayPlan.deposit));
    });

    test('the package keys round trip; always some payment', () {
      final w = MultiHireConfig.fromJson('weekly', {
        'maxWeeks': 99,
        'kmPerWeekDefault': 900,
        'allowPrepay': false,
        'allowDeposit': false,
        'weekdaysDefault': [9, 3, 1],
        'holidays': 'work',
        'kmMode': 'day',
      });
      expect((w.maxDays, w.kmPerDayDefault, w.allowPrepay), (26, 900, true));
      expect(w.weekdaysDefault, [1, 3]);
      expect((w.skipHolidays, w.kmByPeriod), (false, false));
      final json = w.toJson();
      expect(json['maxWeeks'], 26);
      expect(json['kmPerWeekDefault'], 900);
      expect(json.containsKey('maxDays'), isFalse);
      expect(MultiHireConfig.fromJson('weekly', json).toJson(), json);
      expect(MultiHireConfig.fromJson('monthly', {'noticeDays': 99}).toJson()['noticeDays'], 60);
    });
  });

  group('the price', () {
    test('each day at its own price, summed', () {
      final q = _weekly((
        package: 'weekly', lat: 0, lng: 0, dropLat: null, dropLng: null, service: 'Saloon', days: 1, hours: 8,
        firstAt: DateTime(2026, 11, 2, 9), overnight: false, country: null, state: null, city: null, suburb: null,
        periods: 2, weekdays: '1,2,3,4,5',
      ));
      expect(q.days, 10);
      expect(q.dayPrice(1), 240);
      final x = multiHireTotals(q, RegionPricing.none, HirePayPlan.prepay);
      expect((x.total, x.payNow, x.balance), (2400, 2400, 0));
    });

    test('a booking\'s span and its weekdays in plain words', () {
      expect(hireWeekdaysText([1, 2, 3, 4, 5]), 'Mon to Fri');
      expect(hireWeekdaysText([5, 1, 3]), 'Mon, Wed, Fri');
      expect(hireWeekdaysText([1, 2, 3, 4, 5, 6, 7]), 'Every day');
      expect(hirePeriodSpan('weekly', 2, [1, 2, 3, 4, 5], DateTime(2026, 11, 2, 9), 8),
          '2 weeks from Mon 2 Nov, 9:00 am · Mon to Fri · 8 hr a day');
      final b = HireDaysBooking.fromRow({
        'id': 'b1',
        'package': 'monthly',
        'status': 'in_progress',
        'first_at': DateTime(2026, 11, 2, 9).toUtc().toIso8601String(),
        'days': 21,
        'hours_per_day': 8,
        'periods': 1,
        'weekdays': [1, 2, 3, 4, 5],
        'km_mode': 'period',
        'km_per_period': 4000,
        'notice_until': '2026-11-10T01:00:00Z',
        'quote': {'title': 'Monthly hire'},
      });
      expect(b.span, '1 month from Mon 2 Nov, 9:00 am · Mon to Fri · 8 hr a day');
      expect(b.statusLabel, 'Ending early, with notice');
      expect((b.kmByPeriod, b.kmPerPeriod), (true, 4000));
    });

    test('the server\'s new refusals', () {
      expect(multiHireRefusalText('HIRE_WEEKDAYS'), contains('days of the week'));
      expect(multiHireRefusalText('HIRE_DEPOSIT_OFF'), 'This hire is paid in full when you book it.');
      expect(multiHireRefusalText('HIRE_PERIODS'), contains('weeks or months'));
    });
  });

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

      Widget app(Widget child, {List overrides = const []}) => ProviderScope(
        overrides: [
          multiHireQuoteProvider.overrideWith((ref, a) async => _weekly(a)),
          ...overrides.cast(),
        ],
        child: MaterialApp(
          theme: appTheme(b),
          home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
        ),
      );

      testWidgets('weeks and weekdays on the panel, the review paid in full', (tester) async {
        MultiHireBooking? booked;
        await tester.pumpWidget(app(MultiHirePanel(
          config: const MultiHireConfig(package: 'weekly', enabled: true, allowDeposit: false, maxDays: 8,
              minHoursPerDay: 4, hoursPerDayDefault: 8, leadHours: 24, bookAheadDays: 60, chipLabel: 'Weekly',
              title: 'Weekly hire'),
          pickup: _pickup,
          drop: null,
          onPickup: () {},
          onDrop: () {},
          onClearDrop: () {},
          stops: const [],
          onAddStop: () {},
          onRemoveStop: (_) {},
          services: const [RideService('Saloon', 'A car', 1, 4)],
          place: (country: 'Malaysia', state: null, city: null, suburb: null),
          pricingFor: (_) => RegionPricing.none,
          money: rm,
          payments: builtInPayments.where((p) => p.kind == PaymentKind.wallet).toList(),
          payment: 'Get Pay',
          onPayment: (_) {},
          onBook: (x) async => booked = x,
          clock: () => _now,
        )));
        await tester.pumpAndSettle();
        expect(find.text('How many weeks?'), findsOneWidget);
        expect(find.text('1 week'), findsOneWidget);
        expect(find.byKey(const ValueKey('hire-days-count')), findsNothing, reason: 'weeks, not days');
        expect(find.text('RM 1200'), findsOneWidget, reason: '5 weekdays, 8 of 10 hours');
        // Monday, Wednesday and Friday, for two weeks.
        await tester.tap(find.byKey(const ValueKey('hire-weekday-2')));
        await tester.tap(find.byKey(const ValueKey('hire-weekday-4')));
        await tester.tap(find.byKey(const ValueKey('hire-days-periods-plus')));
        await tester.pumpAndSettle();
        expect(find.text('2 weeks'), findsOneWidget);
        expect(find.text('RM 1440'), findsOneWidget, reason: '2 × 3/5 of 1200');
        expect(find.byKey(const ValueKey('hire-days-period-summary')), findsOneWidget);
        expect(find.textContaining('6 working days · 800 km a week included'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hire-days-review')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(const ValueKey('hire-review-plan')), findsNothing, reason: 'paid in full only');
        expect(find.descendant(of: find.byKey(const ValueKey('hire-review-now')), matching: find.text('RM 1440')),
            findsOneWidget);
        expect(find.textContaining('800 km a week included, extra km settled at the end of each week'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hire-review-book')));
        await tester.pumpAndSettle();
        expect((booked!.periods, booked!.plan, booked!.days), (2, HirePayPlan.prepay, 6));
        expect(booked!.weekdays, [1, 3, 5]);
      });

      testWidgets('a whole month on the driver\'s Upcoming: its weekdays and km', (tester) async {
        final o = OpenHireBooking.fromRow({
          'id': 'm1',
          'package': 'monthly',
          'title': 'Monthly hire',
          'service': 'Saloon',
          'first_at': DateTime(2026, 11, 2, 9).toUtc().toIso8601String(),
          'days': 9,
          'hours_per_day': 8,
          'fare': 2160,
          'periods': 1,
          'weekdays': [1, 2, 3, 4, 5],
          'km_per_period': 4000,
          'day_list': [
            for (var i = 0; i < 9; i++)
              {'day': i + 1, 'pickup_at': DateTime(2026, 11, 2 + i, 9).toUtc().toIso8601String(), 'fare': 240},
          ],
        });
        await tester.pumpWidget(app(OpenHireBookingCard(booking: o, money: rm)));
        expect(find.text('Monthly hire · 1 month, 9 days'), findsOneWidget);
        expect(find.text('Mon to Fri · 4000 km a month'), findsOneWidget);
        expect(find.textContaining('and 2 more days'), findsOneWidget);
      });

      testWidgets('the admin\'s Monthly hire settings save every value', (tester) async {
        MultiHireConfig? saved;
        await tester.pumpWidget(app(MultiHireForm(
          stored: MultiHireConfig.fromJson('monthly', const {}),
          canEdit: true,
          onSave: (c) async => saved = c,
        )));
        await tester.tap(find.byKey(const ValueKey('monthly-admin-enabled')));
        await tester.enterText(find.byKey(const ValueKey('monthly-admin-maxDays')), '6');
        await tester.enterText(find.byKey(const ValueKey('monthly-admin-noticeDays')), '14');
        await tester.tap(find.byKey(const ValueKey('monthly-admin-weekday-6')));
        await tester.tap(find.byKey(const ValueKey('monthly-admin-holidays')));
        await tester.tap(find.byKey(const ValueKey('monthly-admin-deposit')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('monthly-admin-save')));
        await tester.pump();
        expect(saved, isNotNull);
        expect((saved!.enabled, saved!.maxDays, saved!.noticeDays), (true, 6, 14));
        expect(saved!.weekdaysDefault, [1, 2, 3, 4, 5, 6]);
        expect((saved!.skipHolidays, saved!.allowDeposit), (false, true));
        expect(saved!.toJson()['maxMonths'], 6);
      });

      testWidgets('public holidays, listed and added with the date in boxes', (tester) async {
        await tester.pumpWidget(app(
          const PublicHolidaysCard(canEdit: true),
          overrides: [
            publicHolidaysProvider.overrideWith((ref) async => [
              (id: 'h1', day: DateTime(2026, 8, 31), name: 'Hari Merdeka', country: 'Malaysia'),
              (id: 'h2', day: DateTime(2026, 12, 25), name: 'Christmas', country: ''),
            ]),
          ],
        ));
        await tester.pumpAndSettle();
        expect(find.text('Hari Merdeka'), findsOneWidget);
        expect(find.textContaining('Every country'), findsOneWidget);
        expect(find.byKey(const ValueKey('public-holiday-day')), findsOneWidget);
        expect(find.byKey(const ValueKey('public-holiday-add')), findsOneWidget);
      });
    });
  }
}
