// City to City money and reminders (migration 0309): the pure logic (rules
// by region, the give-up fee and its split, paying from the wallet and
// coins, the pay sheet's lines, the reminder schedule and words), and the
// screens in light and dark: the admin page (give-up and in-app payment
// rules, cancel fees owed, reminders), the rider's pay sheet (held, short
// with Top up and Switch to cash, a fee owed added), the driver's trip
// (paid in app, held; a fee to collect; the give-up rule), and Wallet's
// fees owed with Pay now. The server's twin is
// supabase/tests/city_to_city_money_0309.sql.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/city_to_city/city_to_city_money_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/city_to_city.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/inbox.dart' show InboxIcon, inboxIconFor;
import 'package:get_ride/src/core/push_logic.dart' show pushRouteFor;
import 'package:get_ride/src/data/city_to_city_repository.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/features/partner/city_to_city_driver_trip.dart';
import 'package:get_ride/src/features/ride/city_to_city_pay.dart';
import 'package:get_ride/src/features/ride/city_to_city_steps.dart' show c2cClockProvider;
import 'package:get_ride/src/features/ride/city_to_city_trip.dart';
import 'package:get_ride/src/features/wallet/c2c_owed_card.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// Wednesday 28 October 2026, 10:00.
final _now = DateTime(2026, 10, 28, 10);

const _my = 'Malaysia';
const _kl = Geo(country: _my, state: 'Kuala Lumpur', city: 'Kuala Lumpur', suburb: 'Ampang');
const _sabahGeo = Geo(country: _my, state: 'Sabah', city: 'Kota Kinabalu');
const _sabah = C2cPlace(level: 'state', country: _my, state: 'Sabah');
const _klCity = C2cPlace(level: 'city', country: _my, state: 'Kuala Lumpur', city: 'Kuala Lumpur');

Map<String, dynamic> _row({
  String id = 'b1',
  String status = 'open',
  String payment = 'cash',
  String? driver,
  double? agreed,
  String? payStatus,
  String? payMode,
  double? collect,
}) => {
  'id': id,
  'ref': 'CC-20481',
  'rider_id': 'r1',
  'pickup_name': '12 Jalan Ampang',
  'pickup_lat': 3.15,
  'pickup_lng': 101.7,
  'pickup_place': {'country': _my, 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur', 'suburb': 'Ampang'},
  'drop_name': '21 Jalan Sampel',
  'drop_lat': 4.6,
  'drop_lng': 101.08,
  'drop_place': {'country': _my, 'state': 'Perak', 'city': 'Ipoh'},
  'distance_km': 205,
  'duration_min': 160,
  'leave_at': DateTime(2026, 10, 28, 13).toUtc().toIso8601String(),
  'flexible': true,
  'passengers': 1,
  'luggage': 'small',
  'fare': 140,
  'currency': 'MYR',
  'quote': {'fareMode': 'card', 'suggested': 136.25, 'low': 130, 'high': 150, 'bookAheadDays': 14},
  'payment': payment,
  'status': status,
  'expires_at': DateTime(2026, 10, 28, 13).toUtc().toIso8601String(),
  'driver_id': driver,
  'agreed_fare': agreed,
  'commission_rate': driver == null ? null : 0.12,
  'pay_status': payStatus,
  'pay_mode': payMode,
  'collect_amount': collect,
};

Map<String, dynamic> _offer({String status = 'open'}) => {
  'id': 'o1',
  'booking_id': 'b1',
  'driver_id': 'd1',
  'price': 140,
  'leave_at': DateTime(2026, 10, 28, 13).toUtc().toIso8601String(),
  'driver_name': 'Hafiz Rahman',
  'driver_rating': 4.9,
  'driver_trips': 300,
  'car': 'Toyota Vios',
  'plate': 'WXY 1234',
  'status': status,
};

class _Repo extends CityToCityRepository {
  _Repo() : super(_db);

  C2cSettings stored = const C2cSettings();
  List<C2cGiveUpRule> give = [C2cGiveUpRule(id: 'g0')];
  List<C2cPayRule> payList = [C2cPayRule(id: 'p0'), C2cPayRule(id: 'p1', place: _sabah, when: C2cPayWhen.after)];
  final savedGive = <C2cGiveUpRule>[];
  final savedPay = <C2cPayRule>[];
  final savedSettings = <C2cSettings>[];
  Map<String, dynamic> row = _row(payment: 'in_app');
  List<Map<String, dynamic>> offerRows = [_offer()];
  Map<String, dynamic> info = {
    'when': 'hold', 'wallet': true, 'coin': true, 'mix': true, 'offerTopup': true, 'offerCash': true,
    'walletBalance': 100, 'coinBalance': 500, 'coinRate': 100, 'dues': [],
  };
  final accepted = <(String, String?, double?)>[];
  final paid = <(String, String, double)>[];
  final cashed = <String>[];
  final collected = <String>[];
  final cancelled = <String>[];
  int payOwedCalls = 0;
  C2cOwed owed = C2cOwed.none;

  @override
  Future<C2cSettings> settings() async => stored;
  @override
  Future<void> saveSettings(C2cSettings s) async => savedSettings.add(stored = s);
  @override
  Future<List<C2cGiveUpRule>> giveUpRules() async => give;
  @override
  Future<void> saveGiveUpRule(C2cGiveUpRule r) async => savedGive.add(r);
  @override
  Future<List<C2cPayRule>> payRules() async => payList;
  @override
  Future<void> savePayRule(C2cPayRule r) async => savedPay.add(r);
  @override
  Future<C2cBooking?> booking(String id) async => C2cBooking.fromRow(row);
  @override
  Future<List<C2cOffer>> offers(String bookingId) async => [for (final o in offerRows) C2cOffer.fromRow(o)];
  @override
  Future<C2cPayInfo> payInfo(String bookingId) async => C2cPayInfo.fromJson(info);
  @override
  Future<void> acceptOfferPay(String offerId, {C2cPayWay? way, double? expected}) async {
    accepted.add((offerId, way?.key, expected));
    row = {...row, 'status': 'booked', 'driver_id': 'd1', 'agreed_fare': 140, 'pay_status': 'held', 'pay_mode': 'hold'};
    offerRows = [_offer(status: 'accepted')];
  }

  @override
  Future<void> acceptOffer(String offerId) async {
    accepted.add((offerId, null, null));
    row = {...row, 'status': 'booked', 'driver_id': 'd1', 'agreed_fare': 140};
    offerRows = [_offer(status: 'accepted')];
  }

  @override
  Future<void> pay(String bookingId, C2cPayWay way, double expected) async {
    paid.add((bookingId, way.key, expected));
    row = {...row, 'pay_status': 'paid'};
  }

  @override
  Future<void> switchToCash(String bookingId) async {
    cashed.add(bookingId);
    row = {...row, 'payment': 'cash'};
  }

  @override
  Future<double> markCollected(String bookingId) async {
    collected.add(bookingId);
    row = {...row, 'collected_at': _now.toUtc().toIso8601String()};
    return 20;
  }

  @override
  Future<void> driverCancel(String bookingId, {String? reason}) async => cancelled.add(bookingId);
  @override
  Future<({String name, String? phone})?> contact(String bookingId) async => (name: 'Farah Tan', phone: '+60100000002');
  @override
  Future<C2cDriverFeed> driverFeed() async => C2cDriverFeed.empty;
  @override
  Future<List<C2cBooking>> driverTrips() async => [C2cBooking.fromRow(row)];
  @override
  Future<C2cOwed> myOwed() async => owed;
  @override
  Future<double> payOwed() async {
    payOwedCalls++;
    final v = owed.total;
    owed = C2cOwed.none;
    return v;
  }
}

final _regions = [
  RegionEntry(id: 'my', values: {'country': _my}),
  RegionEntry(id: 'kl', values: {'country': _my, 'state': 'Kuala Lumpur'}),
  RegionEntry(id: 'sb', values: {'country': _my, 'state': 'Sabah'}),
  RegionEntry(id: 'pn', values: {'country': _my, 'state': 'Penang'}),
];

Future<_Repo> _pump(
  WidgetTester tester,
  Widget home, {
  Brightness b = Brightness.light,
  _Repo? repo,
  Size size = const Size(420, 1000),
  bool canEdit = true,
  List<String>? toppedUp,
}) async {
  final r = repo ?? _Repo();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        ...quietLiveOverrides,
        cityToCityRepositoryProvider.overrideWithValue(r),
        pageAccessProvider.overrideWith((ref, page) => canEdit ? AccessLevel.edit : AccessLevel.read),
        regionsProvider.overrideWith((ref) async => _regions),
        c2cClockProvider.overrideWithValue(() => _now),
        currentUserIdProvider.overrideWithValue('d1'),
        c2cTopUpProvider.overrideWithValue((c) async {
          toppedUp?.add('top-up');
          r.info = {...r.info, 'walletBalance': 200};
        }),
      ],
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return r;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await closeAnyNotice(tester);
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, Key key) {
  final w = tester.widget(find.byKey(key));
  return w is Text ? (w.data ?? w.textSpan!.toPlainText()) : (w as RichText).text.toPlainText();
}

void main() {
  group('logic', () {
    test('the most specific region wins, else the default; inactive ones skipped', () {
      final def = C2cGiveUpRule(id: 'a');
      final my = C2cGiveUpRule(id: 'b', place: const C2cPlace(level: 'country', country: _my));
      final kl = C2cGiveUpRule(id: 'c', place: _klCity);
      expect(c2cRegionRuleFor([def, my, kl], _kl), same(kl));
      expect(c2cRegionRuleFor([def, my, kl], _sabahGeo), same(my));
      expect(c2cRegionRuleFor([def, my, kl], const Geo(country: 'Singapore')), same(def));
      expect(c2cRegionRuleFor([def, my, kl.copyWith(active: false)], _kl)!.id, 'b');
      expect(c2cRegionRuleFor(<C2cGiveUpRule>[], _kl), isNull);
    });

    test('the give-up fee: inside the hours, the split, the lines', () {
      final leave = DateTime(2026, 10, 30, 9);
      final r = C2cGiveUpRule(charge: true, amount: 30, dest: C2cFeeDest.split, splitPercent: 70);
      expect(c2cGiveUpFee(r, leave, leave.subtract(const Duration(hours: 3))), (fee: 30.0, toRider: 21.0, toPlatform: 9.0));
      expect(c2cGiveUpFee(r, leave, leave.subtract(const Duration(hours: 25))).fee, 0);
      expect(c2cGiveUpFee(r.copyWith(when: C2cGiveUpWhen.always), leave, leave.subtract(const Duration(days: 3))).fee, 30);
      expect(c2cGiveUpFee(r.copyWith(splitFixed: true, splitAmount: 40), leave, leave).toRider, 30);
      expect(c2cGiveUpFee(r.copyWith(dest: C2cFeeDest.platform), leave, leave).toPlatform, 30);
      expect(c2cGiveUpFee(r.copyWith(charge: false), leave, leave).fee, 0);
      expect(c2cGiveUpLine(r), 'Free until 24 hours before leaving, then RM 30.');
      expect(c2cGiveUpLine(r.copyWith(when: C2cGiveUpWhen.always)), 'Giving up this trip costs RM 30.');
      expect(c2cGiveUpLine(null), 'Giving up this trip is free.');
      expect(c2cGiveUpSummary(r), 'RM 30, inside 24 h, to split, may go negative');
      expect(c2cGiveUpSummary(r.copyWith(dest: C2cFeeDest.platform, shortMode: C2cShortMode.owed, when: C2cGiveUpWhen.always)),
          'RM 30, always, to get.ride, rest owed');
      expect(c2cGiveUpExample(r).$1, 'Driver charged RM 30: RM 21 to the rider, RM 9 to get.ride.');
      expect(c2cGiveUpExample(r.copyWith(shortMode: C2cShortMode.owed)).$2,
          'RM 12 taken now, RM 18 recorded as owed by the driver.');
      final row = r.copyWith(place: _sabah).toRow();
      expect(row['place'], {'level': 'state', 'country': _my, 'state': 'Sabah'});
      expect(C2cGiveUpRule.fromRow({...row, 'id': 'x'}).toRow()..remove('id'), row);
    });

    test('paying from the wallet and coins (the board\'s example), and the sheet\'s lines', () {
      expect(c2cPaySplit(140, C2cPayWay.mix, 100, 500, 100), (walletPart: 135.0, coinValue: 5.0, coins: 500.0, short: 35.0));
      expect(c2cPaySplit(140, C2cPayWay.wallet, 100, 500, 100).short, 40);
      expect(c2cPaySplit(140, C2cPayWay.coin, 100, 500, 100).short, 135);
      expect(c2cPaySplit(140, C2cPayWay.coin, 0, 14000, 100), (walletPart: 0.0, coinValue: 140.0, coins: 14000.0, short: 0.0));
      expect(c2cPaySplit(3.33, C2cPayWay.coin, 0, 10, 3).coins, 9.99);
      final info = C2cPayInfo.fromJson({
        'walletBalance': 100, 'coinBalance': 500, 'coinRate': 100,
        'dues': [{'id': 'x', 'ref': 'CC-20014', 'fee': 20, 'cancelledAt': DateTime(2026, 10, 17, 10).toIso8601String()}],
      });
      expect(info.ways, [C2cPayWay.mix, C2cPayWay.wallet, C2cPayWay.coin]);
      expect(c2cPayLines(140, C2cPayWay.mix, info), [
        ('Trip fare', 'RM 140'),
        ('Cancel fee owed', 'RM 20'),
        ('From coins', '- RM 5'),
        ('Short by', 'RM 55'),
      ]);
      expect(c2cPayButton(160, C2cPayWay.mix, info), 'Top up RM 55');
      expect(c2cDuesLine(info), 'Includes RM 20 cancel fee you owe from CC-20014 (Sat 17 Oct).');
      expect(c2cPayWayNote(C2cPayWay.mix, info, 160), '500 coins (RM 5) + RM 155 from the wallet');
      expect(c2cPayWayNote(C2cPayWay.coin, info, 160), '500 coins = RM 5: not enough');
      final rich = C2cPayInfo.fromJson({'walletBalance': 300, 'coinBalance': 0, 'coinRate': 100});
      expect(c2cPayLines(140, C2cPayWay.wallet, rich).last, ('Held from GET.wallet', 'RM 140'));
      expect(c2cPayLines(140, C2cPayWay.wallet, rich, after: true).last, ('You pay now', 'RM 140'));
      expect(c2cPayButton(140, C2cPayWay.wallet, rich), 'Accept and hold RM 140');
      expect(c2cPayButton(140, C2cPayWay.wallet, rich, after: true), 'Pay RM 140');
      expect(C2cPayInfo.fromJson({'coinRate': 0}).ways, [C2cPayWay.wallet], reason: 'no coin rate: no coins');
    });

    test('pay rules: mix needs both ways; the example and the summary', () {
      final r = C2cPayRule();
      expect(r.copyWith(coin: false).mix, isFalse);
      expect(r.copyWith(wallet: false, coin: false).problem, isNotNull);
      expect(c2cPayRuleSummary(r), 'Held at booking; wallet, coin, mix');
      expect(c2cPayExample(r), ('RM 5 in coins + RM 100 from the wallet: RM 35 short.',
          'Rider sees: Top up or Switch to cash, before the booking is made.'));
      expect(c2cPayExample(r.copyWith(when: C2cPayWhen.after, offerTopup: false, coin: false)).$2,
          'Rider sees: Switch to cash, when they pay after the trip.');
    });

    test('reminders: words, steps, schedule, the settings row', () {
      expect([1440, 2880, 120, 90, 30].map(c2cReminderWhen), ['1 day', '2 days', '2 h', '1 h 30 min', '30 min']);
      expect(c2cReminderStep(120, 1), 180);
      expect(c2cReminderStep(10, -1), 10);
      final leaves = DateTime(2026, 10, 28, 13);
      final s = c2cReminderSchedule(c2cDefaultReminders, leaves, leaves.subtract(const Duration(hours: 3)));
      expect([for (final x in s) (x.minutes, x.skipped)], [(1440, true), (120, false), (30, false)],
          reason: 'a trip booked 3 hours ahead gets only the 2 h and 30 min ones');
      final w = c2cReminderTexts(
        minutes: 1440, dropCity: 'Ipoh', driverName: 'Hafiz Rahman', riderName: 'Farah Tan Contoh',
        leaves: DateTime(2026, 10, 31, 8), pickup: '12 Jalan Ampang', car: 'Toyota Vios, WXY 1234', fare: 140,
        payLine: 'cash');
      expect(w.riderTitle, 'Your trip to Ipoh is in 1 day');
      expect(w.riderBody, 'Hafiz R. picks you up at 8:00 from 12 Jalan Ampang. Toyota Vios, WXY 1234. Tap to see the trip or chat.');
      expect(w.driverTitle, 'City to City trip in 1 day');
      expect(w.driverBody, 'Pick up Farah T. at 8:00, 12 Jalan Ampang, to Ipoh. RM 140, cash. Tap to start On my way.');
      expect(c2cRemindersProblem(const [C2cReminder(60), C2cReminder(60, 'rider')]), isNotNull);
      final st = C2cSettings.fromRow({
        'reminders': [{'minutes': 45, 'to': 'driver'}],
        'owed_block': true,
        'reminder_sms': true,
      });
      expect(st.reminders, const [C2cReminder(45, 'driver')]);
      expect(st.toRow()['reminders'], [{'minutes': 45, 'to': 'driver'}]);
      expect([st.owedBlock, st.owedFromTopup, st.reminderSms], [true, true, true]);
      expect(C2cSettings.fromRow({}).reminders, c2cDefaultReminders);
    });

    test('what the trips say; the push routes; the owed lines', () {
      expect(c2cDriverPayLine(C2cBooking.fromRow(_row(payment: 'in_app', payStatus: 'held'))), 'Paid in app, held');
      expect(c2cDriverPayLine(C2cBooking.fromRow(_row(payment: 'in_app', payMode: 'after'))), 'In app, paid after the trip');
      expect(c2cDriverPayLine(C2cBooking.fromRow(_row())), 'collect RM 140 in cash');
      expect(c2cCollectLine(C2cBooking.fromRow(_row(collect: 20))), 'Also collect RM 20 the rider owes for a cancelled trip.');
      expect(c2cRiderPayLabel(C2cBooking.fromRow(_row(payment: 'in_app', payStatus: 'held'))), 'In app, held');
      expect(pushRouteFor({'type': 'c2c_reminder', 'role': 'partner', 'c2c_booking_id': 'b'}), '/drive/city-to-city?tab=trips');
      expect(pushRouteFor({'type': 'c2c_pay', 'role': 'rider', 'c2c_booking_id': 'b'}), '/city-to-city');
      expect(inboxIconFor('c2c_reminder'), InboxIcon.ride);
      final o = C2cOwed.fromJson({
        'rider': [{'id': 'x', 'ref': 'CC-1', 'fee': 20}],
        'driver': [{'id': 'f', 'ref': 'CC-2', 'fee': 30, 'owed': 18}],
        'options': {'topup': true, 'nextInApp': true, 'block': true},
      });
      expect(o.total, 38);
      expect(o.howLine, 'Otherwise it is taken from your next top-up, or added to your next in-app payment. '
          'New City to City trips can be booked once it is paid.');
      expect(c2cOwedNote(const C2cSettings(owedBlock: true)), contains('booking shows "Pay RM 20 owed first".'));
    });

    test('listed under Services & catalogue, followed live', () {
      final e = allAdminEntries.firstWhere((e) => e.path == cityToCityMoneyPath);
      expect(e.section, 'Services & catalogue');
      expect(e.pages, [c2cPage]);
      expect(liveSettingTables, containsAll(['c2c_giveup_rules', 'c2c_pay_rules', 'c2c_driver_fees']));
    });
  });

  for (final b in Brightness.values) {
    testWidgets('admin: give-up and pay rules, fees owed, reminders (${b.name})', (tester) async {
      final repo = await _pump(tester, const CityToCityMoneyScreen(), b: b, size: const Size(1300, 3400));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('→'), findsNothing);
      expect(find.text('No charge'), findsOneWidget);
      expect(_text(tester, const ValueKey('c2c-give-driver-line')), contains('Giving up this trip is free.'));

      await _tap(tester, find.byKey(const ValueKey('c2c-give-charge')));
      expect(_text(tester, const ValueKey('c2c-give-driver-line')),
          contains('Free until 24 hours before leaving, then RM 30.'));
      await _tap(tester, find.descendant(of: find.byKey(const ValueKey('c2c-give-dest')), matching: find.text('Split')));
      expect(find.text('Driver charged RM 30: RM 21 to the rider, RM 9 to get.ride.'), findsOneWidget);
      expect(find.text('RM 12 from the GET wallet, RM 18 from GET.credit (below zero until paid back).'), findsOneWidget);
      await _tap(tester, find.byTooltip('Raise Fee'));
      await _tap(tester, find.byKey(const ValueKey('c2c-give-save')));
      expect([repo.savedGive.single.id, repo.savedGive.single.charge, repo.savedGive.single.amount, repo.savedGive.single.dest],
          ['g0', true, 35.0, C2cFeeDest.split]);

      // A rule for Sabah, from the searchable regions.
      await _tap(tester, find.byKey(const ValueKey('c2c-give-add')));
      await _tap(tester, find.text('Sabah · state'));
      expect(find.text('State, Malaysia'), findsWidgets);
      await _tap(tester, find.byKey(const ValueKey('c2c-give-save')));
      expect(repo.savedGive.last.place, _sabah);
      expect(repo.savedGive.last.id, isNull);

      // In-app payment: the Sabah rule pays after the trip.
      expect(find.text('Paid after the trip; wallet, coin, mix'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-p1')));
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-coin')));
      expect(find.text('RM 100 in the wallet: RM 40 short.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-save')));
      expect([repo.savedPay.single.id, repo.savedPay.single.coin, repo.savedPay.single.mix], ['p1', false, false]);

      // Fees owed: block until paid.
      await _tap(tester, find.byKey(const ValueKey('c2c-owed-block')));
      expect(_text(tester, const ValueKey('c2c-owed-note')), contains('Pay RM 20 owed first'));
      await _tap(tester, find.byKey(const ValueKey('c2c-owed-save')));
      expect(repo.savedSettings.last.owedBlock, isTrue);

      // Reminders: how the 1 day one reads; a new one; SMS.
      expect(find.text('Your trip to Ipoh is in 1 day'), findsOneWidget);
      expect(find.text('City to City trip in 1 day'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-rem-add')));
      expect(_text(tester, const ValueKey('c2c-rem-3-when')), '1 h');
      await _tap(tester, find.byKey(const ValueKey('c2c-rem-sms')));
      await _tap(tester, find.byKey(const ValueKey('c2c-rem-save')));
      expect(repo.savedSettings.last.reminders.map((r) => r.minutes), [1440, 120, 30, 60]);
      expect(repo.savedSettings.last.reminderSms, isTrue);
      expect(repo.savedSettings.last.owedBlock, isTrue, reason: 'the other card\'s save is kept');
    });
  }

  testWidgets('admin on a phone, read-only', (tester) async {
    await _pump(tester, const CityToCityMoneyScreen(), size: const Size(400, 4000), canEdit: false);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('c2c-give-save')), findsNothing);
    expect(find.byKey(const ValueKey('c2c-give-add')), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('c2c-give-charge'))).onChanged, isNull);
  });

  for (final b in Brightness.values) {
    testWidgets('rider: accept held, short, Top up, then hold (${b.name})', (tester) async {
      final topped = <String>[];
      final repo = await _pump(tester, const C2cTripScreen(bookingId: 'b1'), b: b, toppedUp: topped);
      await _tap(tester, find.byKey(const ValueKey('c2c-accept-o1')));
      expect(find.text("Accept Hafiz's offer"), findsOneWidget);
      expect(find.text('500 coins (RM 5) + RM 135 from the wallet'), findsOneWidget);
      expect(find.text('Short by'), findsOneWidget);
      expect(_text(tester, const ValueKey('c2c-pay-last')), 'RM 35');
      expect(find.text('Top up RM 35'), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-pay-cash')), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-primary')));
      expect(topped, ['top-up']);
      expect(find.text('Accept and hold RM 135'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-primary')));
      await closeNotice(tester);
      expect(repo.accepted.single, ('o1', 'mix', 140.0));
      expect(find.text('In app, held'), findsOneWidget);
    });

    testWidgets('rider: a fee owed added; Switch to cash (${b.name})', (tester) async {
      final repo = _Repo()
        ..info = {
          'when': 'hold', 'walletBalance': 50, 'coinBalance': 0, 'coinRate': 100, 'offerCash': true, 'offerTopup': true,
          'dues': [{'id': 'x', 'ref': 'CC-20014', 'fee': 20, 'cancelledAt': DateTime(2026, 10, 17, 10).toIso8601String()}],
        };
      await _pump(tester, const C2cTripScreen(bookingId: 'b1'), b: b, repo: repo);
      await _tap(tester, find.byKey(const ValueKey('c2c-accept-o1')));
      expect(find.byKey(const ValueKey('c2c-pay-dues')), findsOneWidget);
      expect(find.text('Cancel fee owed'), findsWidgets);
      expect(_text(tester, const ValueKey('c2c-pay-last')), 'RM 110');
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-cash')));
      await closeNotice(tester);
      expect(repo.cashed, ['b1']);
      expect(repo.accepted.single, ('o1', null, null), reason: 'accepted as cash');
    });

    testWidgets('rider: pay after the trip (${b.name})', (tester) async {
      final repo = _Repo()
        ..row = _row(payment: 'in_app', status: 'completed', driver: 'd1', agreed: 140, payMode: 'after', payStatus: 'unpaid')
        ..offerRows = [_offer(status: 'accepted')]
        ..info = {'when': 'after', 'walletBalance': 300, 'coinBalance': 0, 'coinRate': 100, 'dues': []};
      await _pump(tester, const C2cTripScreen(bookingId: 'b1'), b: b, repo: repo);
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-after-open')));
      expect(find.text('Pay for your trip'), findsWidgets);
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-way-get_wallet')));
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-primary')));
      await closeNotice(tester);
      expect(repo.paid.single, ('b1', 'get_wallet', 140.0));
    });

    testWidgets('driver: paid in app, held; a fee to collect; the give-up rule (${b.name})', (tester) async {
      final repo = _Repo()
        ..row = _row(status: 'booked', driver: 'd1', agreed: 140, payment: 'in_app', payStatus: 'held')
        ..give = [C2cGiveUpRule(id: 'g0', charge: true, amount: 30)];
      await _pump(tester, const C2cDriverTripScreen(bookingId: 'b1'), b: b, repo: repo);
      expect(find.textContaining('Paid in app, held'), findsOneWidget);
      expect(_text(tester, const ValueKey('c2c-driver-give-up-rule')), 'Free until 24 hours before leaving, then RM 30.');
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-give-up')));
      expect(_text(tester, const ValueKey('c2c-driver-cancel-fee')),
          contains('You pay RM 30 from your GET wallet for giving it up now.'));
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-cancel-confirm')));
      await closeAnyNotice(tester);
      expect(repo.cancelled, ['b1']);
    });

    testWidgets('driver: collects a fee the rider owes (${b.name})', (tester) async {
      final repo = _Repo()..row = _row(status: 'booked', driver: 'd1', agreed: 140, collect: 20);
      await _pump(tester, const C2cDriverTripScreen(bookingId: 'b1'), b: b, repo: repo);
      expect(find.text('Also collect RM 20 the rider owes for a cancelled trip.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-driver-collected')));
      await closeNotice(tester);
      expect(repo.collected, ['b1']);
      expect(find.byKey(const ValueKey('c2c-driver-collect')), findsNothing);
    });

    testWidgets('wallet: fees owed and Pay now (${b.name})', (tester) async {
      final repo = _Repo()
        ..owed = C2cOwed.fromJson({
          'rider': [{'id': 'x', 'ref': 'CC-20014', 'fee': 20, 'route': 'Kuala Lumpur to Ipoh'}],
          'options': {'topup': true},
        });
      await _pump(tester, const Scaffold(body: C2cOwedCard()), b: b, repo: repo);
      expect(find.text('City to City: you owe RM 20'), findsOneWidget);
      expect(find.textContaining('CC-20014 (Kuala Lumpur to Ipoh)'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-owed-pay')));
      await closeNotice(tester);
      expect(repo.payOwedCalls, 1);
      expect(find.byKey(const ValueKey('c2c-owed-card')), findsNothing);
    });
  }
}
