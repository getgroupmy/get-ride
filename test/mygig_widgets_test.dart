// myGiG (migration 0329) on screen, light and dark: the driver's myGiG
// sheet, the waiting screen and the agree page on the driver's phone, the
// driver's myGiG settings with its live example, the trip card's
// "Passenger didn't come" and Change destination, the collect card (pay by
// link, the per-trip fee, Block this number), the passenger's accept
// screen with its Family row, the trip link page, and the admin's places.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/mygig/mygig_module.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/family.dart' show FamilyPayOption;
import 'package:get_ride/src/core/mygig.dart';
import 'package:get_ride/src/data/family_repository.dart' show familyPayOptionProvider;
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/mygig_repository.dart';
import 'package:get_ride/src/features/mygig/mygig_entry.dart';
import 'package:get_ride/src/features/mygig/mygig_passenger.dart';
import 'package:get_ride/src/features/mygig/mygig_settings_screen.dart';
import 'package:get_ride/src/features/mygig/mygig_trip_parts.dart';
import 'package:get_ride/src/features/mygig/mygig_waiting_screen.dart';

class _FakeRepo implements MygigRepository {
  final calls = <String>[];
  MygigPrefs? saved;
  Map<String, dynamic> link = {};
  MygigOffer offerNow = MygigOffer(_offer());

  @override
  Future<MygigPrefs> savePrefs(MygigPrefs p, {double? lat, double? lng}) async {
    calls.add('save');
    return saved = p;
  }

  @override
  Future<MygigOffer> offer(String id) async => offerNow;

  @override
  Future<void> cancelOffer(String id) async => calls.add('cancel $id');

  @override
  Future<String?> answerHere(String id, {required bool accept}) async {
    calls.add('here $id $accept');
    return 'ride-1';
  }

  @override
  Future<String?> answer(String id, {required bool accept}) async {
    calls.add('answer $id $accept');
    return null;
  }

  @override
  Future<Map<String, dynamic>> linkView(String token) async => link;

  @override
  Future<String?> linkAnswer(String token, {required bool accept}) async {
    calls.add('link $token $accept');
    link = {...link, 'status': 'accepted', 'ride': {'status': 'accepted', 'shareToken': 's1', 'canCancel': true, 'cancelFee': 0}};
    return 'ride-1';
  }

  @override
  Future<void> takeCash(String ride) async => calls.add('cash $ride');

  @override
  Future<void> approachCash(String ride) async => calls.add('approach $ride');

  @override
  Future<void> sendPayLink(String ride) async => calls.add('paylink $ride');

  @override
  Future<Map<String, dynamic>> complete(String ride, {double? tolls, double? other, String? note}) async {
    calls.add('complete $ride');
    return {'needsPayment': false};
  }

  @override
  Future<void> block({String? phone, String? ride}) async => calls.add('block $ride');

  @override
  Future<List<Map<String, dynamic>>> adminPlaces() async => [
    {'id': 'a1', 'name': 'KLIA Terminal 1', 'rule': 'pickup'},
    {'id': 'a2', 'name': 'Mid Valley', 'rule': null},
  ];

  @override
  Future<void> adminPlaceSet(String area, String? rule) async => calls.add('place $area $rule');

  final savedRules = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> rules() async => [
    {'id': 'd', 'level': 'default', 'settings': {
      'enabled': true, 'fare': {'base': 4, 'perKm': 0.95, 'perMin': 0.25, 'min': 8}, 'allowOwnFare': true,
      'dailyLimit': 10, 'guard': 1.5, 'busy': {'allowed': true, 'nightFrom': '00:00'},
    }},
    {'id': 'm', 'level': 'country', 'country': 'Malaysia', 'settings': {'dailyLimit': 5, 'guard': 2}},
  ];

  @override
  Future<void> saveRule({String? id, required String level, String? country, String? state, String? city, String? suburb,
      required Map<String, dynamic> settings}) async =>
      savedRules.add({'id': id, 'level': level, 'country': country, 'settings': settings});

  @override
  Future<Map<String, dynamic>> global() async => {'who': 'selected', 'fee': {'mode': 'month', 'amount': 30, 'unit': 'RM'}};

  @override
  Future<List<Map<String, dynamic>>> adminDrivers(String search) async => [
    {'id': 'd1', 'name': 'Hafiz', 'phone': '+60100329001', 'plate': 'WXY 2481', 'allowed': true, 'charge': 'default',
     'custom': {'mode': null}, 'today': 3},
    {'id': 'd2', 'name': 'Lee Wei', 'phone': '+60100329002', 'plate': 'VBC 7720', 'allowed': null, 'charge': 'custom',
     'custom': {'mode': 'trip', 'amount': 5, 'unit': '%'}, 'today': 0},
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _offer({String pay = 'cash', String status = 'waiting', String way = 'sms', bool guard = false}) => {
  'id': 'o1',
  'kind': 'new',
  'status': status,
  'way': way,
  'phone': '+60178884040',
  'name': 'Ben',
  'lookup': 'none',
  'registered': false,
  'trip': {
    'pickup': {'name': 'Bangsar South'},
    'drop': {'name': 'KL Sentral'},
    'stops': [],
    'pax': 2,
    'bags': {'small': 0, 'medium': 1, 'large': 0},
    'pay': pay,
  },
  'quote': {
    'km': 6.6, 'min': 16, 'fare': 14.27, 'luggage': 2, 'tax': 0.98, 'taxName': 'SST', 'showTax': true, 'total': 17.25,
    'appPrice': 11, 'guard': guard, 'terms': {'canCharge': pay == 'wallet' || pay == 'family', 'cancelFee': 5, 'noShowFee': 5},
  },
  'total': 17.25,
  'expiresAt': DateTime.now().add(const Duration(seconds: 90)).toIso8601String(),
  'driver': {'name': 'Hafiz', 'rating': 4.9, 'plate': 'WXY 2481', 'vehicle': 'Perodua Bezza'},
};

MygigConfig _config({Map<String, dynamic> prefs = const {}}) => MygigConfig.fromJson({
  'ok': true,
  'today': 3,
  'limit': 10,
  'fee': {'mode': 'trip', 'amount': 1, 'unit': 'RM'},
  'settings': {
    'fare': {'base': 4, 'perKm': 0.95, 'perMin': 0.25, 'min': 8},
    'allowOwnFare': true,
    'qrChoice': true,
  },
  'prefs': {'showTax': true, 'roundUp': false, ...prefs},
  'blocked': ['60190000000'],
  'pricing': {'taxName': 'SST', 'taxKind': 'percent', 'taxValue': 6},
});

Widget _app(Brightness b, Widget home, _FakeRepo repo, {List overrides = const []}) => ProviderScope(
  overrides: [
    mygigRepositoryProvider.overrideWithValue(repo),
    mygigConfigProvider.overrideWith((ref, at) async => _config()),
    ...overrides.cast(),
  ],
  child: MaterialApp(theme: appTheme(b), home: home),
);

RideRequest _ride(String status, Map<String, dynamic> mygig, {Map<String, dynamic> more = const {}}) => RideRequest({
  'id': 'r1',
  'status': status,
  'rider_name': 'Ben',
  'pickup_lat': 3.11,
  'pickup_lng': 101.66,
  'drop_lat': 3.13,
  'drop_lng': 101.68,
  'drop_name': 'KL Sentral',
  'stops': [],
  'mygig': mygig,
  ...more,
});

void main() {
  for (final b in Brightness.values) {
    testWidgets('${b.name}: the myGiG sheet', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, Builder(
        builder: (c) => Scaffold(body: TextButton(onPressed: () => showMygigSheet(c, _config()), child: const Text('open'))),
      ), repo));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('A passenger stopped you. Do they have the get.ride app with them?'), findsOneWidget);
      expect(find.text('Yes, show my booking QR'), findsOneWidget);
      expect(find.text('No, I\'ll enter the trip'), findsOneWidget);
      expect(find.text('myGiG settings'), findsOneWidget);
      expect(find.text('myGiG fee: RM1.00 a trip, from your GET.credit when each ride ends.'), findsOneWidget);
    });

    testWidgets('${b.name}: waiting for the passenger, and Cancel', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(
              builder: (_) => MygigWaitingScreen(sent: MygigSent(offerId: 'o1', way: MygigWay.sms,
                  expiresAt: DateTime.now().add(const Duration(seconds: 90)))),
            )),
            child: const Text('open'),
          ),
        ),
      ), repo));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Waiting for the passenger'), findsOneWidget);
      expect(find.textContaining('Sent to SMS +60178884040'), findsOneWidget);
      expect(find.text('RM17.25'), findsOneWidget);
      expect(find.textContaining('Ends in 1:'), findsOneWidget);
      expect(find.text('Resend'), findsOneWidget);
      expect(find.text('Use another way'), findsOneWidget);
      expect(find.text('Show on this phone'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(repo.calls, contains('cancel o1'));
      expect(find.text('Waiting for the passenger'), findsNothing);
    });

    testWidgets('${b.name}: the agree page on the driver\'s phone', (tester) async {
      final repo = _FakeRepo();
      String? popped;
      await tester.pumpWidget(_app(b, Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () async {
              popped = await Navigator.of(c).push<String>(MaterialPageRoute(
                builder: (_) => MygigAgreeScreen(offer: MygigOffer(_offer(way: 'here', guard: true))),
              ));
            },
            child: const Text('open'),
          ),
        ),
      ), repo));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Your trip'), findsOneWidget);
      expect(find.byKey(const ValueKey('mygig-agree-total')), findsOneWidget);
      expect(find.textContaining('Usual app price about RM11.00'), findsOneWidget);
      expect(find.text('SST'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-agree-yes')));
      await tester.pumpAndSettle();
      expect(repo.calls, ['here o1 true']);
      expect(popped, 'ride-1');
    });

    testWidgets('${b.name}: the driver\'s myGiG settings and the live example', (tester) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, const MygigSettingsScreen(), repo));
      await tester.pumpAndSettle();
      expect(find.text('Your myGiG plan: RM1.00 a trip'), findsOneWidget);
      expect(find.text('get.ride myGiG fare'), findsOneWidget);
      expect(find.text('+60 19 000 0000'), findsOneWidget);
      // 4 + 0.95 × 6.6 + 0.25 × 16 = 14.27, SST 0.86: 15.13.
      expect(find.text('RM15.13'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-round-up')));
      await tester.pumpAndSettle();
      expect(find.text('RM16.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-fare-own')));
      await tester.pumpAndSettle();
      expect(find.text('Base fare (RM)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-settings-save')));
      await tester.pumpAndSettle();
      expect(repo.saved?.roundUp, isTrue);
      expect(repo.saved?.ownFare, isTrue);
      expect(find.text('Settings saved'), findsOneWidget);
    });

    testWidgets('${b.name}: the trip card: passenger didn\'t come, change the destination', (tester) async {
      final repo = _FakeRepo();
      final g = {
        'way': 'app', 'pay': 'wallet', 'registered': true,
        'terms': {'canCharge': true, 'noShowFee': 5, 'cancelFee': 10},
        'quote': {'total': 17, 'wait': {'on': true, 'freeMin': 3, 'perMin': 0.3}},
      };
      await tester.pumpWidget(_app(b, Scaffold(body: Column(children: [
        MygigTripCard(ride: _ride('arrived', g, more: {
          'arrived_at': DateTime.now().subtract(const Duration(minutes: 6)).toUtc().toIso8601String(),
        })),
        MygigTripCard(ride: _ride('on_trip', {...g, 'stopWaitCharge': 1.2}, more: {'waiting_charge': 2.1})),
      ])), repo));
      await tester.pump();
      expect(find.text('Passenger didn’t come · charge RM5.00'), findsOneWidget);
      expect(find.text('Following in their app'), findsNWidgets(2));
      expect(find.text('Change destination'), findsOneWidget);
      expect(find.text('Add stop'), findsOneWidget);
      expect(find.text('Waiting at a stop'), findsOneWidget);
      expect(find.text('Waiting so far: RM3.30 (the passenger sees it)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-no-show')));
      await tester.pumpAndSettle();
      expect(find.textContaining('The no-show fee of RM5.00 is charged to GET.wallet.'), findsOneWidget);
    });

    testWidgets('${b.name}: the collect card: pay by link not paid, take cash, block the number', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, Scaffold(body: SingleChildScrollView(child: MygigCollectCard(ride: _ride('completed', {
        'way': 'sms', 'pay': 'link', 'phone': '+60178884040', 'tripFee': {'mode': 'trip', 'amount': 1}, 'tripFeeAmount': 1,
      }, more: {'payment_status': 'due'})))), repo));
      await tester.pumpAndSettle();
      expect(find.text('Your myGiG fee (RM1.00 a trip), from GET.credit'), findsOneWidget);
      expect(find.text('Waiting for the passenger to pay'), findsOneWidget);
      expect(find.text('Didn’t pay? Take cash'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-take-cash')));
      await tester.pumpAndSettle();
      expect(repo.calls, ['cash r1']);
      await tester.tap(find.byKey(const ValueKey('mygig-block')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mygig-block-ok')));
      await tester.pumpAndSettle();
      expect(repo.calls.last, 'block r1');
      expect(find.text('Number blocked'), findsOneWidget);
    });

    testWidgets('${b.name}: the passenger accepts in the app, with the Family row', (tester) async {
      final repo = _FakeRepo()..offerNow = MygigOffer(_offer(pay: 'family', way: 'app'));
      await tester.pumpWidget(_app(b, const MygigOfferScreen(offerId: 'o1'), repo, overrides: [
        familyPayOptionProvider.overrideWith((ref, m) async => const FamilyPayOption(available: true, hostName: 'Farid', left: 150)),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Hafiz · ★ 4.9'), findsOneWidget);
      expect(find.byKey(const ValueKey('mygig-offer-family')), findsOneWidget);
      expect(find.textContaining('Farid'), findsWidgets);
      expect(find.textContaining('RM5.00 cancellation fee'), findsOneWidget);
      expect(find.text('Accept fare RM17.25'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    });

    testWidgets('${b.name}: the trip link: accept, then follow the ride', (tester) async {
      final repo = _FakeRepo()..link = {
        'status': 'waiting', 'kind': 'new', 'name': 'Ben',
        'driver': {'name': 'Hafiz', 'rating': 4.9, 'plate': 'WXY 2481'},
        'trip': _offer()['trip'], 'quote': _offer()['quote'],
      };
      await tester.pumpWidget(_app(b, const MygigLinkScreen(token: 't1', poll: Duration(hours: 1)), repo));
      await tester.pumpAndSettle();
      expect(find.text('Hi Ben, here is your trip'), findsOneWidget);
      expect(find.text('Accept fare RM17.25'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-link-accept')));
      await tester.pumpAndSettle();
      expect(repo.calls, ['link t1 true']);
      expect(find.text('Follow the ride live'), findsOneWidget);
      expect(find.text('Cancel ride'), findsOneWidget);
    });

    testWidgets('${b.name}: the admin\'s places where myGiG isn\'t allowed', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, const MygigPlacesAdminScreen(), repo, overrides: [
        pageAccessProvider.overrideWith((ref, p) => AccessLevel.edit),
        moduleAccessProvider.overrideWith((ref, m) => AccessLevel.edit),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('KLIA Terminal 1'), findsOneWidget);
      expect(find.text('Mid Valley'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('mygig-place-a2')), matching: find.text('Neither')));
      await tester.pumpAndSettle();
      expect(repo.calls, ['place a2 both']);
    });
  }

  for (final b in Brightness.values) {
    testWidgets('${b.name}: the admin\'s myGiG settings: Default and a region rule', (tester) async {
      // Tall: the Default rule lists every part, hire by time too (0330).
      tester.view.physicalSize = const Size(1000, 12000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, const MygigSettingsAdminScreen(), repo, overrides: [
        pageAccessProvider.overrideWith((ref, p) => AccessLevel.edit),
        moduleAccessProvider.overrideWith((ref, m) => AccessLevel.edit),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Default (everywhere)'), findsOneWidget);
      expect(find.text('Malaysia'), findsOneWidget);
      expect(find.textContaining('Sets: Limits and the price guard'), findsOneWidget);
      expect(find.text('Per km (RM)'), findsOneWidget);
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('mygig-field-default-dailyLimit')),
          matching: find.byType(TextField)), '12');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mygig-admin-save')));
      await tester.pumpAndSettle();
      expect(repo.savedRules.firstWhere((r) => r['level'] == 'default')['settings']['dailyLimit'], 12);
      expect(repo.savedRules.firstWhere((r) => r['level'] == 'country')['settings'], {'dailyLimit': 5, 'guard': 2});
    });

    testWidgets('${b.name}: the admin\'s myGiG access: who, the charge, each driver', (tester) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, const MygigAccessAdminScreen(), repo, overrides: [
        pageAccessProvider.overrideWith((ref, p) => AccessLevel.edit),
        moduleAccessProvider.overrideWith((ref, m) => AccessLevel.edit),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Only the drivers you switch on below.'), findsOneWidget);
      expect(find.textContaining('Drivers buy a pass from GET.credit or GET.wallet'), findsOneWidget);
      expect(find.textContaining('Allowed · Default: RM30.00 a month'), findsOneWidget);
      expect(find.textContaining('Not selected · Own charge: 5% of each fare'), findsOneWidget);
    });
  }

  for (final b in Brightness.values) {
    testWidgets('${b.name}: no losses: pay by link before the trip, what is added before the end, the pickup in cash', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, Scaffold(body: SingleChildScrollView(child: Column(children: [
        MygigPayFirst(ride: _ride('arrived', {'pay': 'link', 'quote': {'total': 17.25}, 'linkPaid': 0})),
        MygigPayFirst(ride: _ride('on_trip', {'pay': 'link', 'quote': {'total': 17.25}, 'linkPaid': 17.25,
            'pendingFinal': {'due': 20.25, 'tolls': 3}, 'payUrl': 'https://pay.example/x'})),
        MygigPayFirst(ride: _ride('arrived', {'pay': 'cash', 'quote': {'total': 30, 'approach': 12}})),
        MygigPayFirst(ride: _ride('arrived', {'pay': 'cash', 'quote': {'total': 30, 'approach': 12}, 'approachCashAt': 'x'})),
      ]))), repo));
      await tester.pumpAndSettle();
      expect(find.text('The passenger pays RM17.25 by link before the trip starts'), findsOneWidget);
      expect(find.text('Collect RM3.00 more before you complete (tolls, parking, waiting or a changed route)'), findsOneWidget);
      expect(find.text('Send payment link'), findsOneWidget);
      expect(find.text('Send it again'), findsOneWidget);
      expect(find.text('Received RM12.00 for coming to the pickup'), findsOneWidget);
      await tester.tap(find.text('Send payment link'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Received RM3.00 in cash'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mygig-approach-cash')));
      await tester.pumpAndSettle();
      expect(repo.calls, ['paylink r1', 'cash r1', 'complete r1', 'approach r1']);
    });

    testWidgets('${b.name}: the trip link asks for the payment before the trip', (tester) async {
      final repo = _FakeRepo()..link = {
        'status': 'accepted', 'kind': 'new', 'name': 'Ben',
        'driver': {'name': 'Hafiz', 'rating': 4.9}, 'trip': _offer(pay: 'link')['trip'], 'quote': _offer(pay: 'link')['quote'],
        'ride': {'status': 'accepted', 'shareToken': 's1', 'canCancel': true, 'cancelFee': 0, 'owed': 17.25,
                 'payUrl': 'https://pay.example/x'},
      };
      await tester.pumpWidget(_app(b, const MygigLinkScreen(token: 't1', poll: Duration(hours: 1)), repo));
      await tester.pumpAndSettle();
      expect(find.text('Pay RM17.25 by card, FPX or DuitNow'), findsOneWidget);
    });
  }

  test('the button shows where the type allows myGiG and there is no active trip', () {
    expect(mygigButtonShows(null), isFalse);
    expect(mygigButtonShows(MygigConfig.fromJson({'ok': true})), isTrue);
    expect(mygigButtonShows(MygigConfig.fromJson({'code': 'LIMIT'})), isTrue, reason: 'it explains');
    expect(mygigButtonShows(MygigConfig.fromJson({'code': 'ACTIVE_TRIP'})), isFalse);
    expect(mygigButtonShows(MygigConfig.fromJson({'code': 'TYPE'})), isFalse);
  });

  test('the passenger\'s cancellation fee now', () {
    final g = MygigRide.of({'mygig': {'terms': {'canCharge': true, 'cancelFee': 10, 'cancelFreeMin': 2}}})!;
    final now = DateTime(2026, 10, 30, 10);
    expect(mygigCancelFeeNow(g, now.subtract(const Duration(minutes: 1)).toIso8601String(), now), 0);
    expect(mygigCancelFeeNow(g, now.subtract(const Duration(minutes: 3)).toIso8601String(), now), 10);
    final cash = MygigRide.of({'mygig': {'terms': {'canCharge': false, 'cancelFee': 10}}})!;
    expect(mygigCancelFeeNow(cash, now.subtract(const Duration(minutes: 9)).toIso8601String(), now), 0);
  });
}
