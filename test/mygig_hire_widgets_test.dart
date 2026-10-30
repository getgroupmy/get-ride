// myGiG part B (migration 0330) on screen, light and dark: the package
// options and Now / Later (the date in day, month and year boxes, the
// time), the booking's terms where the passenger accepts, Scheduled myGiG
// (Start when due, cash, the pay link, cancel), the passenger's booking in
// their app, the hire card on the trip screen, and the driver's hire rates.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/mygig.dart';
import 'package:get_ride/src/core/mygig_hire.dart';
import 'package:get_ride/src/data/mygig_repository.dart';
import 'package:get_ride/src/features/mygig/mygig_scheduled_screen.dart';
import 'package:get_ride/src/features/mygig/mygig_settings_screen.dart';
import 'package:get_ride/src/features/mygig/mygig_when.dart';
import 'package:get_ride/src/widgets/date_boxes.dart';

class _FakeRepo implements MygigRepository {
  final calls = <String>[];
  MygigPrefs? saved;

  @override
  Future<String?> startBooking(String booking) async {
    calls.add('start $booking');
    return 'ride-9';
  }

  @override
  Future<double> bookingCash(String booking) async {
    calls.add('cash $booking');
    return 700;
  }

  @override
  Future<Map<String, dynamic>> cancelBooking({String? booking, String? token, String? reason}) async {
    calls.add('cancel $booking');
    return {'status': 'cancelled'};
  }

  @override
  Future<void> sendPayLink(String ride) async => calls.add('paylink $ride');

  @override
  Future<MygigPrefs> savePrefs(MygigPrefs p, {double? lat, double? lng}) async {
    calls.add('save');
    return saved = p;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _now = DateTime.now();

Map<String, dynamic> _booking({String status = 'booked', bool canStart = true, double due = 0, double linkOwed = 0}) => {
  'id': 'b1',
  'kind': 'weekly',
  'title': 'Weekly hire',
  'status': status,
  'firstAt': _now.add(const Duration(days: 3)).toIso8601String(),
  'days': 5,
  'price': 1900,
  'pay': 'link',
  'plan': 'full',
  'payNow': 1900,
  'paid': status == 'awaiting_payment' ? 0 : 1900,
  'due': due,
  'linkOwed': linkOwed,
  'canCancel': true,
  'cancelFree': true,
  'freeCancelUntil': _now.add(const Duration(days: 2)).toIso8601String(),
  'weekdays': [1, 2, 3, 4, 5],
  'hoursPerDay': 10,
  'trip': {'pickup': {'name': 'TTDI'}, 'drop': {'name': 'No drop-off · as directed'}, 'directed': true},
  'nextDay': {'day': 1, 'at': _now.add(const Duration(minutes: 30)).toIso8601String(), 'canStart': canStart,
              'startFrom': _now.toIso8601String()},
  'dayText': 'Day 1 of 5',
  'name': 'Ra**i',
  'driver': {'name': 'Hafiz', 'vehicle': 'Perodua Bezza', 'plate': 'WXY 2481'},
};

Widget _app(Brightness b, Widget home, _FakeRepo repo, {List overrides = const []}) => ProviderScope(
  overrides: [mygigRepositoryProvider.overrideWithValue(repo), ...overrides.cast()],
  child: MaterialApp(theme: appTheme(b), home: home),
);

void main() {
  for (final b in Brightness.values) {
    testWidgets('${b.name}: Now / Later: the day chips, another date in the boxes, the time', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var choice = const MygigBookingChoice();
      await tester.pumpWidget(_app(b, Scaffold(
        body: StatefulBuilder(builder: (c, set) => SingleChildScrollView(
          child: MygigWhenPicker(
            choice: choice,
            settings: const MygigHireSettings({}, {}),
            now: _now,
            onChanged: (v) => set(() => choice = v),
          ),
        )),
      ), _FakeRepo()));
      expect(find.text('Now'), findsOneWidget);
      expect(find.text('Today'), findsNothing);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(choice.later, isTrue);
      expect(choice.at, isNotNull, reason: 'a time past the lead time, to start from');
      expect(mygigWhenProblem(choice, const MygigHireSettings({}, {}), _now), isNull);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Tomorrow'), findsOneWidget);
      expect(find.byKey(const ValueKey('mygig-lead-note')), findsOneWidget);
      expect(find.textContaining('Later rides must be booked at least 30 min ahead'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-day-other')));
      await tester.pumpAndSettle();
      expect(find.byType(DateBoxesField), findsOneWidget, reason: 'another date: day, month and year boxes');
      expect(find.byTooltip('Choose from calendar'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('mygig-day-1')));
      await tester.pumpAndSettle();
      expect(choice.at!.day, _now.add(const Duration(days: 1)).day);
    });

    testWidgets('${b.name}: daily hire: days, hours a day, overnight; weekly: working days', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var choice = const MygigBookingChoice(kind: MygigKind.daily, later: true);
      await tester.pumpWidget(_app(b, Scaffold(
        body: StatefulBuilder(builder: (c, set) => SingleChildScrollView(
          child: MygigHireOptions(
            choice: choice,
            settings: const MygigHireSettings({}, {'maxDays': 3}),
            rates: const MygigHireRates(),
            kmIncluded: 400,
            onChanged: (v) => set(() => choice = v),
          ),
        )),
      ), _FakeRepo()));
      expect(find.text('Days in a row'), findsOneWidget);
      expect(find.text('8 hours'), findsOneWidget);
      expect(find.text('12 hours'), findsOneWidget);
      expect(find.textContaining('Includes 400 km and fuel. After that: overtime RM45.00 an hour, extra km RM1.00.'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('mygig-days')), matching: find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(choice.days, 3);
      expect(tester.widget<IconButton>(find.descendant(of: find.byKey(const ValueKey('mygig-days')),
          matching: find.widgetWithIcon(IconButton, Icons.add_circle_outline))).onPressed, isNull,
          reason: 'the admin''s most days');
      await tester.tap(find.text('12 hours'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mygig-overnight')));
      await tester.pumpAndSettle();
      expect((choice.hoursPerDay, choice.overnight), (12.0, true));
      expect(find.textContaining('RM80.00 a night'), findsOneWidget);

      choice = const MygigBookingChoice(kind: MygigKind.weekly, later: true);
      await tester.pumpWidget(_app(b, Scaffold(
        body: StatefulBuilder(builder: (c, set) => SingleChildScrollView(
          child: MygigHireOptions(
            choice: choice,
            settings: const MygigHireSettings({}, {}),
            rates: const MygigHireRates(),
            onChanged: (v) => set(() => choice = v),
          ),
        )),
      ), _FakeRepo()));
      expect(find.text('Working days'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-wd-6')));
      await tester.pumpAndSettle();
      expect(choice.weekdays, [1, 2, 3, 4, 5, 6]);
    });

    testWidgets('${b.name}: the booking where the passenger accepts', (tester) async {
      await tester.pumpWidget(_app(b, Scaffold(
        body: MygigBookingTerms(
          booking: {
            'kind': 'daily', 'when': 'later', 'at': DateTime(2026, 11, 2, 8).toIso8601String(), 'plan': 'deposit',
            'payNow': 252, 'payNowBy': 'link', 'balance': 588,
            'freeCancelUntil': DateTime(2026, 11, 1, 8).toIso8601String(),
          },
          total: 840,
          now: DateTime(2026, 10, 30, 9, 41),
          kmIncluded: 400,
        ),
      ), _FakeRepo()));
      expect(find.text('Daily hire · from Mon 2 Nov, 8:00 am'), findsOneWidget);
      expect(find.text('Deposit RM252.00 now by link; the balance RM588.00 before day 1.'), findsOneWidget);
      expect(find.text('Free to cancel until Sun 1 Nov, 8:00 am; after that what you paid now is kept.'), findsOneWidget);
      expect(find.textContaining('Includes 400 km'), findsOneWidget);
    });

    testWidgets('${b.name}: Scheduled myGiG: Start when due, day 1 of 5, Cancel', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, const MygigScheduledScreen(), repo, overrides: [
        mygigScheduledProvider.overrideWith((ref) async => [MygigBooking(_booking())]),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Scheduled myGiG'), findsOneWidget);
      expect(find.text('Day 1 of 5'), findsOneWidget);
      expect(find.text('Weekly hire · Mon to Fri, 10 h a day'), findsOneWidget);
      expect(find.text('Ra**i · from TTDI · RM1900.00'), findsOneWidget);
      expect(find.text('RM1900.00 paid'), findsOneWidget);
      expect(find.text('Start day 1'), findsOneWidget);
      // The buttons spin while their dialog is up: pumped, not settled.
      await tester.tap(find.byKey(const ValueKey('mygig-booking-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Cancel this booking?'), findsOneWidget);
      await tester.tap(find.text('Cancel booking'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repo.calls, ['cancel b1']);
      expect(find.text('Booking cancelled'), findsOneWidget, reason: 'a popup with OK, not a bar');
    });

    testWidgets('${b.name}: Scheduled myGiG: waiting for payment, the balance in cash, not yet due', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, const MygigScheduledScreen(), repo, overrides: [
        mygigScheduledProvider.overrideWith((ref) async => [
          MygigBooking({..._booking(status: 'awaiting_payment', canStart: false, linkOwed: 1900), 'id': 'b2'}),
          MygigBooking({..._booking(due: 700, canStart: false), 'id': 'b3', 'kind': 'daily', 'plan': 'deposit', 'paid': 300,
                        'days': 2, 'dayText': 'Day 1 of 2'}),
        ]),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for RM1900.00 by link'), findsOneWidget);
      expect(find.textContaining('Not confirmed until the passenger pays'), findsOneWidget);
      expect(find.text('Send pay link'), findsWidgets);
      expect(find.text('Received RM700.00 in cash'), findsOneWidget);
      await tester.tap(find.text('Received RM700.00 in cash'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Received'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repo.calls, contains('cash b3'));
      final start = tester.widgetList<Widget>(find.text('Start day 1'));
      expect(start, isNotEmpty);
    });

    testWidgets('${b.name}: the passenger\'s myGiG booking in their app', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, Scaffold(body: ListView(children: [MygigPassengerBookingCard(booking: MygigBooking(_booking()))])),
          repo));
      expect(find.text('Weekly hire · Mon to Fri, 10 h a day'), findsOneWidget);
      expect(find.text('Hafiz · Perodua Bezza · WXY 2481 · RM1900.00'), findsOneWidget);
      expect(find.textContaining('Free to cancel until'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-my-booking-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('It is free to cancel now. What you paid is refunded.'), findsOneWidget);
    });

    testWidgets('${b.name}: the hire card: time used today and overtime', (tester) async {
      final start = DateTime(2026, 10, 30, 8);
      await tester.pumpWidget(_app(b, Scaffold(
        body: MygigHireCard(
          row: {
            'hire_package': 'daily', 'hire_hours': 10, 'hire_step_min': 30, 'hire_overtime_rate': 45, 'hire_km_included': 200,
            'hire_extra_km_rate': 1, 'hire_started_at': start.toIso8601String(), 'mygig': {'dayNo': 2, 'days': 5},
          },
          now: () => start.add(const Duration(hours: 10, minutes: 20)),
        ),
      ), _FakeRepo()));
      expect(find.text('Daily hire · day 2 of 5'), findsOneWidget);
      expect(find.text('Time used today: 10 h 20 min of 10 h'), findsOneWidget);
      expect(find.text('Overtime 30 min · RM22.50 so far, paid before the day ends'), findsOneWidget);
      expect(find.text('200 km included today, then RM1.00 a km'), findsOneWidget);
    });

    testWidgets('${b.name}: the driver\'s hire rates in myGiG settings', (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, const MygigSettingsScreen(), repo, overrides: [
        mygigConfigProvider.overrideWith((ref, at) async => MygigConfig.fromJson({
          'ok': true,
          'fee': {'mode': 'none'},
          'settings': {
            'hire': {'packages': {'monthly': false}, 'ownLimits': {'hourMin': 20, 'hourMax': 100, 'dayMax': 800}},
          },
          'prefs': {'hire': {'own': false}},
        })),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Hire by time'), findsOneWidget);
      expect(find.text('Monthly hire'), findsNothing, reason: 'switched off by the admin');
      expect(find.text('get.ride hire rates'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-hire-own')));
      await tester.pumpAndSettle();
      expect(find.text('Per day, 10 h (RM)'), findsOneWidget);
      expect(find.textContaining('an hour from RM20.00 up to RM100.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-offer-weekly')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mygig-settings-save')));
      await tester.pumpAndSettle();
      expect(repo.saved?.raw['hire'], {'own': true, 'offer': {'weekly': false}});
    });
  }
}
