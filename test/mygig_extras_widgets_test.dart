// myGiG part C (migration 0331) on screen, light and dark: choosing the new
// driver (why, who, the ones who can't be chosen), the new driver's tick
// before Accept, the passenger's tick before Confirm (keep, cancel free),
// following a reassign, hotspots, the passenger's extras after the trip
// (rating, tip, split, e-Invoice, the app offer), a share's own page, and
// the admin's dashboard.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/mygig/mygig_dashboard.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/mygig_extras.dart';
import 'package:get_ride/src/data/mygig_repository.dart';
import 'package:get_ride/src/features/mygig/mygig_after_trip.dart';
import 'package:get_ride/src/features/mygig/mygig_hotspots_screen.dart';
import 'package:get_ride/src/features/mygig/mygig_reassign.dart';
import 'package:latlong2/latlong.dart';

class _FakeRepo implements MygigRepository {
  final calls = <String>[];

  @override
  Future<MygigReassign> reassignDriverAnswer(String id, {required bool accept, bool ack = false}) async {
    calls.add('driver $id $accept $ack');
    return MygigReassign(_reassign(stage: accept ? 'passenger' : 'declined'));
  }

  @override
  Future<MygigReassign> reassignStart({String? ride, String? booking, String? to, String? code, required String reason}) async {
    calls.add('start $ride $to $code $reason');
    return MygigReassign(_reassign());
  }

  @override
  Future<List<MygigReassign>> reassignsMine() async => const [];

  @override
  Future<Map<String, dynamic>> afterTip({String? ride, String? token, required double amount, String how = 'link'}) async {
    calls.add('tip $amount $how');
    return {'method': how, 'amount': amount};
  }

  @override
  Future<void> afterRate(String token, int stars, {String? comment}) async => calls.add('rate $stars');

  @override
  Future<Map<String, dynamic>> payPartView(String token) async => {
    'id': 'p2', 'amount': 12.72, 'no': 2, 'of': 2, 'paid': false, 'cancelled': false,
    'driver': {'name': 'Hafiz'}, 'pickup': 'Bangsar South', 'drop': 'KL Sentral',
    'appOffer': {'code': 'HAFIZ5', 'coins': 0, 'enabled': true, 'driver': 'Hafiz'},
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _reassign({String stage = 'driver', String way = 'sms', String me = 'to'}) => {
  'id': 'ra1',
  'rideId': 'r1',
  'stage': stage,
  'reason': 'Car problem',
  'way': way,
  'answerBy': DateTime.now().add(const Duration(minutes: 9)).toIso8601String(),
  'kind': 'trip',
  'kindName': 'myGiG ride',
  'when': 'now',
  'trip': {'pickup': {'name': 'Bangsar South'}, 'drop': {'name': 'KL Sentral'}},
  'pax': 1,
  'bags': {'small': 0},
  'total': 25.45,
  'pay': 'link',
  'paidMoves': 13.45,
  'noAnswer': 'keep',
  'from': {'id': 'd1', 'name': 'Hafiz', 'rating': 4.9, 'vehicle': 'Perodua Bezza', 'plate': 'WXY 2481'},
  'to': {'id': 'd2', 'name': 'Lee', 'rating': 4.8, 'vehicle': 'Toyota Innova', 'plate': 'VBC 7720'},
  'passenger': 'Ben',
  'registered': false,
  'plan': {'mode': 'trip', 'amount': 1, 'unit': 'RM'},
  'me': me,
};

Widget _app(Brightness b, Widget home, _FakeRepo repo, {List overrides = const []}) => ProviderScope(
  overrides: [
    mygigRepositoryProvider.overrideWithValue(repo),
    mygigReassignsMineProvider.overrideWith((ref) async => const <MygigReassign>[]),
    ...overrides.cast(),
  ],
  child: MaterialApp(theme: appTheme(b), home: home),
);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('${b.name}: choosing the new driver: why, who, and the ones who can''t be chosen', (tester) async {
      _tall(tester);
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, const MygigReassignScreen(rideId: 'r1'), repo, overrides: [
        mygigReassignOptionsProvider.overrideWith((ref, k) async => const MygigReassignOptions({
          'reasons': ['Car problem', 'Emergency', 'Other'],
          'drivers': [
            {'id': 'd2', 'name': 'Lee', 'rating': 4.8, 'vehicle': 'Toyota Innova', 'plate': 'VBC 7720', 'km': 0.3},
            {'id': 'd3', 'name': 'Tan', 'rating': 4.7, 'vehicle': 'Perodua Axia', 'plate': 'WRT 1189', 'km': 0.4,
             'why': 'Smaller vehicle'},
          ],
          'way': 'sms', 'answerMin': 10, 'noAnswer': 'keep', 'sameOrBigger': true, 'nearKm': 10,
        })),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Reassign the ride'), findsOneWidget);
      expect(find.textContaining('The price, the trip and the payment stay the same'), findsOneWidget);
      expect(find.textContaining('Smaller vehicle'), findsOneWidget);
      expect(tester.widget<RadioListTile<String>>(find.byKey(const ValueKey('mygig-reassign-driver-d3'))).enabled, isFalse,
          reason: 'a smaller car can''t be chosen');
      expect(tester.widget<FilledButton>(find.descendant(of: find.byKey(const ValueKey('mygig-reassign-send')),
          matching: find.byType(FilledButton))).onPressed, isNull, reason: 'choose the new driver first');
      await tester.tap(find.byKey(const ValueKey('mygig-reassign-reason-Emergency')));
      await tester.tap(find.byKey(const ValueKey('mygig-reassign-driver-d2')));
      await tester.pumpAndSettle();
      expect(find.text('Send to Lee'), findsOneWidget);
      await tester.tap(find.text('Send to Lee'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('start r1 d2 null Emergency'));
    });

    testWidgets('${b.name}: the new driver must tick "I accept this ride at the agreed price"', (tester) async {
      _tall(tester);
      final repo = _FakeRepo();
      await tester.pumpWidget(_app(b, const MygigReassignOfferScreen(id: 'ra1'), repo, overrides: [
        mygigReassignProvider.overrideWith((ref, id) async => MygigReassign(_reassign())),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('From Hafiz: car problem.'), findsOneWidget);
      expect(find.text('Agreed price RM25.45'), findsOneWidget);
      expect(find.textContaining('your own myGiG prices don’t apply. Payment: Pay by link; RM13.45 already paid moves to you.'),
          findsOneWidget);
      expect(find.text('Your myGiG plan: RM1.00 a trip'), findsOneWidget);
      Finder accept() => find.descendant(of: find.byKey(const ValueKey('mygig-reassign-accept')), matching: find.byType(FilledButton));
      expect(tester.widget<FilledButton>(accept()).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('mygig-reassign-ack')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(accept()).onPressed, isNotNull);
      await tester.tap(accept());
      await tester.pumpAndSettle();
      expect(repo.calls, contains('driver ra1 true true'));
    });

    testWidgets('${b.name}: the passenger ticks before Confirm; or keeps the first driver; or cancels free', (tester) async {
      _tall(tester);
      final answers = <String>[];
      await tester.pumpWidget(_app(b, Scaffold(
        body: SingleChildScrollView(
          child: MygigReassignConfirm(
            reassign: MygigReassign(_reassign(stage: 'passenger', me: 'passenger')),
            onAnswer: (a, ack) async => answers.add('$a $ack'),
          ),
        ),
      ), _FakeRepo()));
      await tester.pumpAndSettle();
      expect(find.text('Your driver is changing'), findsOneWidget);
      expect(find.textContaining('Hafiz can’t take your ride: car problem. Lee has accepted it at the same price.'), findsOneWidget);
      expect(find.text('Same price RM25.45, same payment'), findsOneWidget);
      expect(find.text('I understand my driver is now Lee'), findsOneWidget);
      expect(find.textContaining('I’ll check the plate before I get in.'), findsOneWidget);
      expect(find.textContaining('With no answer, Hafiz keeps your ride.'), findsOneWidget);
      Finder confirm() =>
          find.descendant(of: find.byKey(const ValueKey('mygig-reassign-pax-confirm')), matching: find.byType(FilledButton));
      expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('mygig-reassign-pax-ack')));
      await tester.pumpAndSettle();
      await tester.tap(confirm());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep Hafiz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel my ride (no charge)'));
      await tester.pumpAndSettle();
      expect(answers, ['confirm true', 'keep false', 'cancel false']);
    });

    testWidgets('${b.name}: following it: waiting for the passenger, the WhatsApp link, Stop', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(b, const MygigReassignFollow(id: 'ra1'), _FakeRepo(), overrides: [
        mygigReassignProvider.overrideWith((ref, id) async => MygigReassign(_reassign(stage: 'passenger', way: 'whatsapp', me: 'from'))),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Lee accepted. Waiting for the passenger'), findsOneWidget);
      expect(find.text('Send the link on WhatsApp'), findsOneWidget);
      expect(find.text('Stop reassigning'), findsOneWidget);
      expect(find.textContaining('Until then the ride is still yours.'), findsOneWidget);
    });

    testWidgets('${b.name}: hotspots: areas and hours, counts only', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(b, const Scaffold(
        body: MygigHotspotsBody(
          here: LatLng(3.11, 101.66),
          hotspots: MygigHotspots({
            'enabled': true, 'weeks': 4, 'hourNow': 10,
            'areas': [
              {'name': 'KL Sentral', 'lat': 3.134, 'lng': 101.686, 'count': 21, 'nowCount': 3, 'km': 3.4},
              {'name': 'Mid Valley', 'lat': 3.118, 'lng': 101.677, 'count': 14, 'nowCount': 0, 'km': 1.9},
            ],
            'hours': [{'hour': 18, 'count': 9}, {'hour': 8, 'count': 5}],
          }),
        ),
      ), _FakeRepo()));
      await tester.pump();
      expect(find.text('KL Sentral'), findsOneWidget);
      expect(find.textContaining('21 myGiG rides in the last 4 weeks, 3 around this hour · 3.4 km away'), findsOneWidget);
      expect(find.byKey(const ValueKey('mygig-hour-bars')), findsOneWidget);
      expect(find.textContaining('Busiest at 6 pm and 8 am.'), findsOneWidget);
      expect(find.textContaining('Counts only, no passenger details.'), findsOneWidget);
      expect(find.byTooltip('Drive to KL Sentral'), findsOneWidget);

      await tester.pumpWidget(_app(b, const Scaffold(
        body: MygigHotspotsBody(here: LatLng(3.11, 101.66), hotspots: MygigHotspots({'enabled': false})),
      ), _FakeRepo()));
      await tester.pump();
      expect(find.byKey(const ValueKey('mygig-hotspots-off')), findsOneWidget);
    });

    testWidgets('${b.name}: after the trip on the link: receipt, rating, tip, e-Invoice, the app offer', (tester) async {
      _tall(tester);
      final repo = _FakeRepo();
      var changed = 0;
      await tester.pumpWidget(_app(b, Scaffold(
        body: SingleChildScrollView(
          child: MygigAfterBody(
            token: 'tok331',
            onChanged: () => changed++,
            after: const MygigAfter({
              'rideId': 'r1', 'status': 'completed', 'inApp': false, 'registered': false,
              'driver': {'name': 'Hafiz'},
              'receipt': {'total': 27.45, 'tolls': 2, 'pay': 'cash', 'paymentStatus': 'paid'},
              'owed': 0,
              'can': {'rate': true, 'tip': true, 'split': false, 'einvoice': true, 'bookAgain': true},
              'tipMax': 100, 'tipPresets': [2, 5, 10], 'splitMax': 3,
              'appOffer': {'code': 'HAFIZ5', 'coins': 5, 'enabled': true, 'driver': 'Hafiz'},
            }),
          ),
        ),
      ), repo));
      await tester.pumpAndSettle();
      expect(find.text('Thanks for riding with Hafiz'), findsOneWidget);
      expect(find.text('RM27.45'), findsOneWidget);
      expect(find.text('Rate Hafiz'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-star-5')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('rate 5'));
      await tester.tap(find.byKey(const ValueKey('mygig-tip-5')));
      await tester.pumpAndSettle();
      expect(find.text('Tip RM5.00 by card, FPX or DuitNow'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-tip-cash')));
      // The button stays busy while the notice is open.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repo.calls, contains('tip 5.0 cash'));
      expect(find.textContaining('Hafiz is told you’ll tip RM5.00 in cash.'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Request e-Invoice'), findsOneWidget);
      expect(find.text('Book Hafiz again'), findsOneWidget);
      expect(find.textContaining('Sign up with Hafiz’s code HAFIZ5 and get 5 GET.coin.'), findsOneWidget);
      // The e-Invoice details are checked before they go.
      await tester.tap(find.byKey(const ValueKey('mygig-einvoice')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mygig-einvoice-send')));
      await tester.pumpAndSettle();
      expect(find.text('Enter the name on the invoice.'), findsOneWidget);
      expect(find.textContaining('get.ride sends it to LHDN MyInvois'), findsWidgets);
      expect(changed, greaterThan(0));
    });

    testWidgets('${b.name}: split the fare while something is owed; in the app the tip is from GET.wallet', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(b, Scaffold(
        body: SingleChildScrollView(
          child: MygigAfterBody(
            onChanged: () {},
            after: const MygigAfter({
              'rideId': 'r1', 'status': 'arrived', 'inApp': true, 'registered': true,
              'driver': {'name': 'Hafiz'},
              'receipt': {'total': 25.45, 'pay': 'link'},
              'owed': 25.45,
              'can': {'split': true},
              'splitMax': 3,
            }),
          ),
        ),
      ), _FakeRepo()));
      await tester.pumpAndSettle();
      expect(find.text('Split the fare'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-split-2')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Each pays about RM12.72. The others get a pay link by SMS.'), findsOneWidget);
      expect(find.byKey(const ValueKey('mygig-split-phone-0')), findsOneWidget);
      expect(find.text('Send links and pay my RM12.73'), findsOneWidget);

      await tester.pumpWidget(_app(b, Scaffold(
        body: SingleChildScrollView(
          child: MygigAfterBody(
            onChanged: () {},
            after: const MygigAfter({
              'rideId': 'r1', 'status': 'completed', 'inApp': true, 'registered': true,
              'driver': {'name': 'Hafiz'}, 'receipt': {'total': 25.45, 'pay': 'wallet', 'paymentStatus': 'paid'},
              'can': {'tip': true, 'bookAgain': true},
            }),
          ),
        ),
      ), _FakeRepo()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mygig-tip-10')));
      await tester.pumpAndSettle();
      expect(find.text('Tip RM10.00 from GET.wallet'), findsOneWidget);
      expect(find.byKey(const ValueKey('mygig-app-offer')), findsNothing, reason: 'registered: no app offer');
    });

    testWidgets('${b.name}: a share''s own page', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(b, const MygigPayPartScreen(token: 'tok'), _FakeRepo()));
      await tester.pumpAndSettle();
      expect(find.text('Your share of a ride with Hafiz'), findsOneWidget);
      expect(find.text('RM12.72'), findsOneWidget);
      expect(find.text('Pay RM12.72 by card, FPX or DuitNow'), findsOneWidget);
    });

    testWidgets('${b.name}: the admin dashboard: tiles, flags, reassigns', (tester) async {
      _tall(tester);
      const d = MygigDashboard({
        'tiles': {'rides': 128, 'completed': 120, 'takings': 3412, 'noShows': 4, 'viaApp': 46, 'viaLink': 38, 'viaHere': 16,
                  'reassigned': 3},
        'flags': {
          'priceGuard': [{'driver': 'Lee', 'from': 'KLIA', 'to': 'Putrajaya', 'total': 142, 'appPrice': 61}],
          'repeatNumbers': [{'phone': '+60178884040', 'rides': 4, 'driver': 'Hafiz'}],
          'dailyLimit': [{'driver': 'Tan', 'rides': 10, 'limit': 10}],
        },
      });
      await tester.pumpWidget(_app(b, Scaffold(
        body: ListView(children: [
          const MygigDashboardTiles(dashboard: d),
          const MygigFlagsCard(dashboard: d),
          MygigReassignHistory(reassigns: [
            MygigReassign(_reassign(stage: 'done')..['steps'] = [
              {'what': 'asked', 'to': 'Lee', 'reason': 'Car problem', 'at': DateTime(2026, 10, 30, 9).toIso8601String()},
            ]),
          ]),
        ]),
      ), _FakeRepo()));
      await tester.pumpAndSettle();
      expect(find.text('RM3412.00'), findsOneWidget);
      expect(find.text('46%'), findsOneWidget);
      expect(find.text('Price above the guard'), findsOneWidget);
      expect(find.textContaining('KLIA to Putrajaya · RM142.00 (app RM61.00)'), findsOneWidget);
      expect(find.text('Number with many myGiG rides'), findsOneWidget);
      expect(find.text('Driver at the daily limit'), findsOneWidget);
      expect(find.text('Hafiz to Lee · Car problem'), findsOneWidget);
      await tester.tap(find.text('Hafiz to Lee · Car problem'));
      await tester.pumpAndSettle();
      expect(find.text('Asked Lee (Car problem)'), findsOneWidget);
    });
  }
}
