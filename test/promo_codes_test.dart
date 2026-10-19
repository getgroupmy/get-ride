// Rider promo codes (migration 0242): the model, the admin's editor and its
// list, the driver's "Promo applied" mark and cash line, the receipt and
// history lines. The confirm bar and the home zone bar are in
// home_confirm_test.dart (they need the home screen).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/admin/screens/promo_codes_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/format.dart' show formatMoney;
import 'package:get_ride/src/core/promo_codes.dart';
import 'package:get_ride/src/core/trip_receipt.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/features/ride/promo_parts.dart';
import 'package:get_ride/src/features/ride/trip_history_view.dart' show tripListPromo;
import 'package:get_ride/src/providers.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));
final _now = DateTime.now().toUtc();

class _Admin extends AdminRepository {
  _Admin() : super(_db);

  List<PromoCode> codes = [
    PromoCode(id: 'p1', code: 'RIDE5', description: 'RM5 off', discountValue: 5, usesCount: 2, discountTotal: 7),
    PromoCode(
      id: 'p2',
      code: 'LATER',
      discountType: PromoDiscountType.percent,
      discountValue: 10,
      maxDiscount: 3,
      startsAt: _now.add(const Duration(days: 3)),
    ),
  ];
  final saved = <PromoCode>[];
  final deleted = <String>[];

  @override
  Future<List<PromoCode>> promoCodes() async => codes;

  @override
  Future<void> savePromoCode(PromoCode p) async => saved.add(p);

  @override
  Future<void> deletePromoCode(String id) async => deleted.add(id);

  @override
  Future<Map<String, ({int uses, double discount, DateTime? lastAt})>> promoRedemptionStats() async =>
      {'p1': (uses: 2, discount: 7, lastAt: _now)};

  @override
  Future<List<Map<String, dynamic>>> promoRedemptions(String codeId, {int limit = 30}) async => [
        {
          'ride_id': 'aaaa1111-0000-0000-0000-000000000001',
          'fare': 20,
          'discount': 5,
          'payable': 15,
          'created_at': _now.toIso8601String(),
        },
        {
          'ride_id': 'bbbb2222-0000-0000-0000-000000000002',
          'fare': 12,
          'discount': 2,
          'payable': 10,
          'created_at': _now.toIso8601String(),
        },
      ];

  @override
  Future<List<({String name, int trips})>> commissionServiceNames() async => const [(name: 'car', trips: 40)];

  @override
  Future<List<Map<String, dynamic>>> searchPeople(String query, {int limit = 20}) async => [
        {'id': 'u1', 'name': 'Aisha', 'phone': '60111111111'},
        {'id': 'u2', 'name': 'Aiman', 'phone': '60122222222'},
      ];

  @override
  Future<Map<String, Map<String, dynamic>>> peopleByIds(List<String> ids) async => const {};
}

final _regions = [
  RegionEntry(id: 'c', values: {'country': 'Malaysia'}),
  RegionEntry(id: 's', values: {'country': 'Malaysia', 'state': 'Selangor'}),
  RegionEntry(id: 'k', values: {'country': 'Malaysia', 'state': 'Selangor', 'city': 'Kajang'}),
  RegionEntry(id: 'b', values: {'country': 'Malaysia', 'state': 'Selangor', 'city': 'Bangi'}),
];

Future<_Admin> _pumpAdmin(WidgetTester tester, Brightness b, {List<AdminGrant>? grants}) async {
  final admin = _Admin();
  await tester.binding.setSurfaceSize(const Size(900, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider
            .overrideWith((_) async => AdminAccess(grants ?? const [AdminGrant(page: promoCodePage, edit: true)])),
        adminRepositoryProvider.overrideWithValue(admin),
        regionsProvider.overrideWith((_) async => _regions),
      ],
      child: MaterialApp(theme: appTheme(b), home: const AdminPromoCodesScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return admin;
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

RideRequest _ride(Map<String, dynamic> extra) => RideRequest({
      'id': 'r1',
      'rider_id': 'rider',
      'partner_id': 'driver',
      'status': 'open',
      'fare': 20,
      'ride_fare': 20,
      'currency': 'MYR',
      'payment_mode': 'Cash',
      'pickup_name': 'KLCC',
      'drop_name': 'KL Sentral',
      'created_at': _now.toIso8601String(),
      ...extra,
    });

class _Rides implements RideRepository {
  @override
  Future<void> markViewed(String requestId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => Future.value(null);
}

void main() {
  group('model', () {
    test('a code is read and written as the server has it', () {
      final p = PromoCode.fromRow({
        'id': 'x',
        'code': 'NIGHT',
        'discount_type': 'percent',
        'discount_value': 15,
        'max_discount': 4,
        'max_uses': 100,
        'max_uses_per_rider': 2,
        'budget': 300,
        'min_fare': 10,
        'applies_to': 'both',
        'regions': [
          {'country': 'Malaysia', 'city': 'Kajang'},
        ],
        'date_from': '2026-10-01',
        'date_to': '2026-10-31',
        'weekdays': [5, 6],
        'time_from': '22:00:00',
        'time_to': '06:00:00',
        'genders': ['female'],
        'rider_ids': ['u1'],
        'services': ['Car'],
        'first_ride_only': true,
        'auto_apply': true,
      });
      expect(p.discountLabel, '15% off (up to RM4.00)');
      expect(p.appliesTo, PromoAppliesTo.both);
      expect(p.regions.single.label, 'Kajang, Malaysia');
      expect((p.timeFrom, p.timeTo), (22 * 60, 6 * 60));
      final row = p.toRow();
      expect(row['time_from'], '22:00:00');
      expect(row['date_to'], '2026-10-31');
      expect(row['regions'], [
        {'country': 'Malaysia', 'city': 'Kajang'},
      ]);
      expect(row.containsKey('uses_count'), isFalse, reason: 'the counters are the server\'s');
      expect(p.problem, isNull);
      expect(PromoCode.fromRow({...row, 'discount_type': 'fixed'}).toRow()['max_discount'], isNull);
    });

    test('every gender ticked is everyone; every weekday ticked is every day', () {
      final row = const PromoCode(
        code: 'ALL',
        discountValue: 1,
        genders: ['male', 'female', 'other'],
        weekdays: [1, 2, 3, 4, 5, 6, 7],
      ).toRow();
      expect(row['genders'], isEmpty);
      expect(row['weekdays'], isEmpty);
    });

    test('a code shown in the app unless hidden; auto apply is always shown', () {
      expect(PromoCode.fromRow({'code': 'A1', 'discount_value': 1}).showInApp, isTrue);
      expect(PromoCode.fromRow({'code': 'A1', 'discount_value': 1, 'show_in_app': false}).showInApp, isFalse);
      expect(const PromoCode(code: 'A1', discountValue: 1, showInApp: false).toRow()['show_in_app'], isFalse);
      expect(const PromoCode(code: 'A1', discountValue: 1, showInApp: false, autoApply: true).toRow()['show_in_app'], isTrue);
    });

    test('problems the editor stops', () {
      expect(const PromoCode(code: 'a', discountValue: 1).problem, isNotNull);
      expect(const PromoCode(code: 'OK1', discountValue: 0).problem, isNotNull);
      expect(const PromoCode(code: 'OK1', discountType: PromoDiscountType.percent, discountValue: 120).problem, isNotNull);
      expect(PromoCode(code: 'OK1', discountValue: 1, startsAt: _now, endsAt: _now).problem, isNotNull);
      expect(const PromoCode(code: 'OK1', discountValue: 1, timeFrom: 60, timeTo: 60).problem, isNotNull);
    });

    test('status', () {
      expect(const PromoCode(code: 'A1', discountValue: 1, active: false).statusAt(_now), 'Off');
      expect(PromoCode(code: 'A1', discountValue: 1, endsAt: _now).statusAt(_now), 'Ended');
      expect(const PromoCode(code: 'A1', discountValue: 1, maxUses: 2, usesCount: 2).statusAt(_now), 'Used up');
      expect(const PromoCode(code: 'A1', discountValue: 1, budget: 10, discountTotal: 10).statusAt(_now), 'Used up');
      expect(const PromoCode(code: 'A1', discountValue: 1).statusAt(_now), 'Running');
    });

    test('a typed code: the server\'s reason, or the offer', () {
      final no = PromoCheckResult.fromJson({'ok': false, 'reason': 'expired', 'message': 'This code has expired.'});
      expect((no.ok, no.reason, no.message), (false, 'expired', 'This code has expired.'));
      final yes = PromoCheckResult.fromJson({'ok': true, 'code_id': 'c', 'code': 'X1', 'discount': 3, 'payable': 17});
      expect(yes.offer!.estimatedDiscount, 3);
      expect(yes.offer!.estimatedPayable, 17);
      expect(PromoCheckResult.fromJson({'ok': false, 'reason': 'used_by_you'}).message, "You've already used this code.");
    });

    test('after the offers are read again: the rider\'s pick, else the auto one unless removed', () {
      const a = PromoOffer(codeId: 'a', code: 'A1', estimatedDiscount: 2, autoApply: true);
      const b = PromoOffer(codeId: 'b', code: 'B1', estimatedDiscount: 1);
      expect(promoAfterOffers([a, b]).promo, a);
      expect(promoAfterOffers([a, b]).auto, isTrue);
      expect(promoAfterOffers([a, b], current: b).promo, b);
      expect(promoAfterOffers([a], current: b).promo, a, reason: 'the pick no longer applies');
      expect(promoAfterOffers([a, b], removed: true).promo, isNull);
      expect(promoAfterOffers(const []).promo, isNull);
    });

    test('the home bar asks again only on a meaningful move or when forced', () {
      const here = LatLng(3.1, 101.6);
      expect(promoZoneRecheckDue(null, here), isTrue);
      expect(promoZoneRecheckDue(here, const LatLng(3.1005, 101.6)), isFalse, reason: 'about 55 m');
      expect(promoZoneRecheckDue(here, const LatLng(3.104, 101.6)), isTrue, reason: 'about 440 m');
      expect(promoZoneRecheckDue(here, here, force: true), isTrue);
    });

    test('the trip key changes with the trip', () {
      String key(double fare, [String s = 'Car']) =>
          promoTripKey(pickup: const LatLng(1, 2), drop: const LatLng(3, 4), service: s, fare: fare);
      expect(key(10), key(10));
      expect(key(10), isNot(key(11)));
      expect(key(10), isNot(key(10, 'Bike')));
    });

    test('a ride\'s promo: estimate, settled, what is left to collect', () {
      expect(_ride({}).promo, isNull);
      expect(_ride({'promo_code_id': null, 'promo_error': 'outside_area'}).promo, isNull);
      final booked = _ride({'promo_code_id': 'c', 'promo_code': 'RIDE5', 'promo_estimate': 5});
      expect(booked.promo!.amount, 5);
      expect(booked.promo!.settled, isFalse);
      expect(booked.cashDue, 20, reason: 'nothing settled yet');
      expect(ridePromoLine(booked), 'Promo RIDE5 (about −${formatMoney(5)})');
      final done = _ride({
        'status': 'completed',
        'promo_code_id': 'c',
        'promo_code': 'RIDE5',
        'promo_estimate': 5,
        'promo_discount': 5,
        'promo_payable': 15,
        'promo_settled_at': _now.toIso8601String(),
      });
      expect(done.promo!.applied, isTrue);
      expect(done.cashDue, 15);
      expect(ridePromoLine(done), 'Promo RIDE5 −${formatMoney(5)}');
      expect(tripListPromo(done), 'Promo RIDE5 −${formatMoney(5)}');
      final receipt = TripReceipt.fromRide(done);
      expect(receipt.lines.last, (label: 'Promo RIDE5', amount: -5.0));
      expect(receipt.total, 15);
      final driver = TripReceipt.fromRide(done, asDriver: true);
      expect(driver.lines.last.label, 'Promo RIDE5 (to your GET.wallet)');
      expect(driver.gross, 20, reason: 'the driver\'s earnings keep the whole fare');
      final early = _ride({
        'status': 'completed',
        'ended_early_at': _now.toIso8601String(),
        'promo_code_id': 'c',
        'promo_code': 'RIDE5',
        'promo_discount': 0,
        'promo_settled_at': _now.toIso8601String(),
        'promo_error': 'ended_early',
      });
      expect(early.promo!.applied, isFalse);
      expect(early.cashDue, 20);
      expect(ridePromoLine(early), isNull);
      expect(tripListPromo(early), isNull);
    });
  });

  for (final b in Brightness.values) {
    group('Admin → Settings → Promocode (${b.name})', () {
      testWidgets('listed with what each gave; a code added with every rule', (tester) async {
        final admin = await _pumpAdmin(tester, b);
        expect(find.text('RIDE5'), findsOneWidget);
        expect(find.text('Running'), findsOneWidget);
        expect(find.text('Scheduled'), findsOneWidget);
        expect(find.textContaining('Used 2 · ${formatMoney(7)} given'), findsOneWidget);

        await _tapKey(tester, 'pc-add');
        expect(find.text('Add promo code'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('pc-code')), 'raya10');
        await tester.enterText(find.byKey(const ValueKey('pc-description')), 'Raya week');
        await tester.tap(find.text('Percentage'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('pc-value')), '10');
        await tester.enterText(find.byKey(const ValueKey('pc-max-discount')), '8');
        await tester.enterText(find.byKey(const ValueKey('pc-max-uses')), '100');
        await tester.enterText(find.byKey(const ValueKey('pc-per-rider')), '1');
        await tester.enterText(find.byKey(const ValueKey('pc-budget')), '500');
        await tester.enterText(find.byKey(const ValueKey('pc-min-fare')), '15');

        // Both points in Kajang, picked from the region lists.
        await tester.tap(find.text('Both'));
        await tester.pumpAndSettle();
        expect(find.text('Both the pickup and the drop-off must be inside.'), findsOneWidget);
        await _tapKey(tester, 'pc-region-country-');
        await tester.tap(find.text('Malaysia').last);
        await tester.pumpAndSettle();
        await _tapKey(tester, 'pc-region-state-Malaysia');
        await tester.tap(find.text('Selangor').last);
        await tester.pumpAndSettle();
        await _tapKey(tester, 'pc-region-city-Malaysia/Selangor');
        await tester.tap(find.text('Kajang').last);
        await tester.pumpAndSettle();
        await _tapKey(tester, 'pc-region-add');
        expect(find.byKey(const ValueKey('pc-region-0')), findsOneWidget);
        expect(find.text('Kajang, Selangor, Malaysia'), findsOneWidget);

        await _tapKey(tester, 'pc-day-6');
        await _tapKey(tester, 'pc-day-7');
        await _tapKey(tester, 'pc-hours');
        expect(find.text('Runs past midnight'), findsOneWidget);
        await _tapKey(tester, 'pc-gender-female');

        // Two riders picked with the people search, one taken off again.
        await _tapKey(tester, 'pc-riders-some');
        await tester.enterText(find.byKey(const ValueKey('pc-rider-search')), 'Ai');
        await _tapKey(tester, 'pc-rider-find');
        await _tapKey(tester, 'pc-rider-pick-u1');
        await _tapKey(tester, 'pc-rider-pick-u2');
        expect(find.byKey(const ValueKey('pc-rider-u2')), findsOneWidget);
        await _tapKey(tester, 'pc-rider-remove-u2');
        expect(find.byKey(const ValueKey('pc-rider-u2')), findsNothing);
        expect(find.byKey(const ValueKey('pc-rider-u1')), findsOneWidget);

        await _tapKey(tester, 'pc-service-car');
        await _tapKey(tester, 'pc-first-ride');
        await _tapKey(tester, 'pc-auto-apply');
        await _tapKey(tester, 'pc-save');

        final p = admin.saved.single;
        expect(p.id, isNull);
        expect(p.code, 'RAYA10');
        expect(p.description, 'Raya week');
        expect((p.discountType, p.discountValue, p.maxDiscount), (PromoDiscountType.percent, 10.0, 8.0));
        expect((p.maxUses, p.maxUsesPerRider, p.budget, p.minFare), (100, 1, 500.0, 15.0));
        expect(p.appliesTo, PromoAppliesTo.both);
        expect(p.regions, [const PromoRegion(country: 'Malaysia', state: 'Selangor', city: 'Kajang')]);
        expect(p.weekdays, [6, 7]);
        expect((p.timeFrom, p.timeTo), (22 * 60, 6 * 60));
        expect(p.genders, ['female']);
        expect(p.riderIds, ['u1']);
        expect(p.services, ['car']);
        expect((p.firstRideOnly, p.autoApply, p.active), (true, true, true));
        expect(tester.takeException(), isNull);
      });

      testWidgets('show in app: on by default, off for a typed-only code, always on with auto apply', (tester) async {
        final admin = await _pumpAdmin(tester, b);
        await _tapKey(tester, 'pc-add');
        await tester.enterText(find.byKey(const ValueKey('pc-code')), 'secret9');
        await tester.enterText(find.byKey(const ValueKey('pc-value')), '9');
        SwitchListTile show() => tester.widget<SwitchListTile>(find.byKey(const ValueKey('pc-show-in-app')));
        expect(show().value, isTrue);
        expect(find.text('Listed to riders who qualify on the confirm step.'), findsOneWidget);
        await _tapKey(tester, 'pc-show-in-app');
        expect(show().value, isFalse);
        expect(find.text('Hidden: works only when a rider types the code.'), findsOneWidget);
        await _tapKey(tester, 'pc-save');
        expect(admin.saved.single.showInApp, isFalse);
        expect(admin.saved.single.toRow()['show_in_app'], isFalse);

        // Auto apply turns it on and holds it there.
        await _tapKey(tester, 'pc-add');
        await tester.enterText(find.byKey(const ValueKey('pc-code')), 'auto9');
        await tester.enterText(find.byKey(const ValueKey('pc-value')), '9');
        await _tapKey(tester, 'pc-show-in-app');
        expect(show().value, isFalse);
        await _tapKey(tester, 'pc-auto-apply');
        expect(show().value, isTrue);
        expect(show().onChanged, isNull, reason: 'an auto-apply code can\'t be hidden');
        expect(find.text('Always shown: a code that applies by itself is listed to riders who qualify.'), findsOneWidget);
        await _tapKey(tester, 'pc-save');
        expect((admin.saved.last.autoApply, admin.saved.last.showInApp), (true, true));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a code that is no code is refused', (tester) async {
        final admin = await _pumpAdmin(tester, b);
        await _tapKey(tester, 'pc-add');
        await tester.enterText(find.byKey(const ValueKey('pc-code')), 'X');
        await _tapKey(tester, 'pc-save');
        expect(find.text('2 to 32 letters, digits, - or _'), findsOneWidget);
        expect(find.text('Above zero'), findsOneWidget);
        expect(admin.saved, isEmpty);
      });

      testWidgets('turned off, its trips, deleted only when never used', (tester) async {
        final admin = await _pumpAdmin(tester, b);
        await _tapKey(tester, 'pc-active-p1');
        expect(admin.saved.last.id, 'p1');
        expect(admin.saved.last.active, isFalse);

        await _tapKey(tester, 'pc-redemptions-p1');
        expect(find.text('RIDE5 · trips'), findsOneWidget);
        expect(
          find.descendant(of: find.byKey(const ValueKey('pc-red-count')), matching: find.text('2')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: find.byKey(const ValueKey('pc-red-total')), matching: find.text(formatMoney(7))),
          findsOneWidget,
        );
        expect(find.text('${formatMoney(5)} off ${formatMoney(20)}'), findsOneWidget);
        expect(find.textContaining('trip aaaa1111'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();

        // Used on trips: kept for their records.
        await tester.tap(find.byKey(const ValueKey('pc-delete-p1')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Turn it off instead'), findsOneWidget);
        await tester.tap(find.text('OK').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(admin.deleted, isEmpty);

        await tester.tap(find.byKey(const ValueKey('pc-delete-p2')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(admin.deleted, ['p2']);
      });

      testWidgets('a read-only grant changes nothing', (tester) async {
        await _pumpAdmin(tester, b, grants: const [AdminGrant(page: promoCodePage, edit: false)]);
        expect(find.text('RIDE5'), findsOneWidget);
        expect(find.byKey(const ValueKey('pc-add')), findsNothing);
        expect(find.byKey(const ValueKey('pc-delete-p1')), findsNothing);
        expect(tester.widget<Switch>(find.byKey(const ValueKey('pc-active-p1'))).onChanged, isNull);
      });

      testWidgets('another page\'s grant sees nothing', (tester) async {
        await _pumpAdmin(tester, b, grants: const [AdminGrant(page: 'admin-settings-commission', edit: true)]);
        expect(find.text('RIDE5'), findsNothing);
        expect(find.text('No access'), findsOneWidget);
      });
    });

    group('driver (${b.name})', () {
      Future<void> sheet(WidgetTester tester, RideRequest r) async {
        await tester.pumpWidget(ProviderScope(
          overrides: [rideRepositoryProvider.overrideWithValue(_Rides())],
          child: MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: RideRequestSheet(
                request: r,
                shown: Duration.zero,
                now: DateTime.now(),
                onAccept: () async {},
                onSkip: () {},
              ),
            ),
          ),
        ));
        await tester.pump();
      }

      testWidgets('the offer card marks a promo, with the full fare and a label for screen readers', (tester) async {
        final handle = tester.ensureSemantics();
        final r = _ride({'promo_code_id': 'c', 'promo_code': 'RIDE5', 'promo_estimate': 5});
        await sheet(tester, r);
        expect(find.byType(PromoAppliedIcon), findsOneWidget);
        expect(find.bySemanticsLabel('Promo applied'), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(const ValueKey('request-fare'))).data, r.fareText(20),
            reason: 'the actual fare, before the promo');
        await tester.pumpWidget(const SizedBox());
        await sheet(tester, _ride({}));
        expect(find.byType(PromoAppliedIcon), findsNothing);
        await tester.pumpWidget(const SizedBox());
        handle.dispose();
      });

      Future<void> line(WidgetTester tester, RideRequest r) async {
        await tester.pumpWidget(MaterialApp(theme: appTheme(b), home: Scaffold(body: DriverPromoLine(ride: r))));
      }

      testWidgets('cash: what to collect after the promo, and that the promo goes to the wallet', (tester) async {
        await line(tester, _ride({'status': 'on_trip', 'promo_code_id': 'c', 'promo_code': 'RIDE5', 'promo_estimate': 5}));
        expect(find.text('Promo RIDE5 applied'), findsOneWidget);
        expect(
          find.text('Collect about ${formatMoney(15)} in cash. The promo amount (about ${formatMoney(5)}) goes to your GET.wallet.'),
          findsOneWidget,
        );

        // Completed: the server's figures.
        await line(tester, _ride({
          'status': 'completed',
          'toll_charges': 2,
          'promo_code_id': 'c',
          'promo_code': 'RIDE5',
          'promo_estimate': 5,
          'promo_discount': 4,
          'promo_payable': 18,
          'promo_settled_at': _now.toIso8601String(),
        }));
        expect(find.text('Promo RIDE5: ${formatMoney(4)} to your GET.wallet'), findsOneWidget);
        expect(find.text('Collect ${formatMoney(18)} in cash'), findsOneWidget);

        // Ended early: no promo, the full amount.
        await line(tester, _ride({
          'status': 'completed',
          'ended_early_at': _now.toIso8601String(),
          'promo_code_id': 'c',
          'promo_code': 'RIDE5',
          'promo_discount': 0,
          'promo_settled_at': _now.toIso8601String(),
          'promo_error': 'ended_early',
        }));
        expect(find.text('Promo RIDE5 not applied'), findsOneWidget);
        expect(find.text('The trip ended early. Collect the full amount.'), findsOneWidget);

        await line(tester, _ride({}));
        expect(find.byKey(const ValueKey('trip-promo')), findsNothing);
      });

      testWidgets('paid in the app: only the wallet line', (tester) async {
        await line(tester, _ride({
          'status': 'on_trip',
          'payment_mode': 'Get Pay',
          'promo_code_id': 'c',
          'promo_code': 'RIDE5',
          'promo_estimate': 5,
        }));
        expect(find.text('The promo amount (about ${formatMoney(5)}) goes to your GET.wallet.'), findsOneWidget);
      });
    });
  }
}
