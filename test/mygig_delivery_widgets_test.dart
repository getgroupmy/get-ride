// myGiG Delivery (migration 0332) on screen, light and dark: "A delivery"
// on the myGiG sheet only where the vehicle may, the driver's Delivery
// settings, the sender's accept page (the tick before Accept, the deposit,
// the Family row), the driver's pickup (Start waits for the check and the
// cash), the door (pay first, then the code), a return's lines before it
// starts, the recipient's and the sender's link pages, and the admin's
// Money safety panel.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/mygig/mygig_delivery_admin.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/mygig.dart';
import 'package:get_ride/src/core/mygig_delivery.dart';
import 'package:get_ride/src/data/family_repository.dart' show familyPayOptionProvider;
import 'package:get_ride/src/data/models.dart' show RideRequest;
import 'package:get_ride/src/features/mygig/mygig_delivery_link.dart';
import 'package:get_ride/src/features/mygig/mygig_delivery_settings.dart';
import 'package:get_ride/src/features/mygig/mygig_delivery_trip.dart';
import 'package:get_ride/src/features/mygig/mygig_entry.dart';

Widget _app(Brightness b, Widget home) => ProviderScope(
  overrides: [familyPayOptionProvider.overrideWith((ref, module) async => null)],
  child: MaterialApp(theme: appTheme(b), home: home),
);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

FilledButton _filled(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(FilledButton)));

const _config = MygigDeliveryConfig({
  'ok': true, 'offered': true, 'vehicle': 'car', 'vehicleName': 'Car',
  'settings': {
    'allowOwnRates': true, 'allowOwnWait': true, 'itemTypes': ['Documents', 'Parcel', 'Food'], 'returnPctMax': 100,
    'sizes': {'small': {'car': true}, 'medium': {'car': true}, 'large': {'car': true}, 'bulky': {'car': false}},
    'waiting': {'freeMin': 5, 'perMin': 0.3}, 'ownLimits': {'base': 20, 'perKmMin': 0.5, 'perKmMax': 3, 'extraMax': 30, 'waitMax': 1},
  },
  'prefs': {'own': false, 'rates': {'base': 6, 'perKm': 1, 'min': 9, 'medium': 2, 'large': 5}, 'returnPct': 50, 'maxKm': 25,
            'offTypes': ['Food'], 'takeCod': true, 'takeRecipientPays': true, 'showTax': true},
  'gcard': {'base': 6, 'perKm': 1, 'min': 9, 'medium': 2, 'large': 5, 'bulky': 15},
});

Map<String, dynamic> _offer({String pay = 'cash', String payer = 'sender'}) => {
  'id': 'o1', 'status': 'waiting', 'total': 13,
  'driver': {'name': 'Hafiz', 'rating': 4.9, 'vehicle': 'Perodua Bezza', 'plate': 'WXY 2481'},
  'quote': {'km': 6, 'fare': 12, 'cover': 1, 'coverFree': 300, 'coverUpTo': 300, 'total': 13, 'vehicleName': 'Car',
            'maxFail': 5.55, 'retPct': 50,
            'deposit': pay == 'wallet' || pay == 'family' ? null : {'ret': 5.55, 'wait': 4.5, 'fare': 0, 'fee': 0.5, 'total': 10.55, 'waitMin': 15}},
  'delivery': {'pay': pay, 'payer': payer, 'inApp': pay == 'wallet' || pay == 'family', 'retPayer': 'recipient',
               'parcel': {'type': 'Parcel', 'size': 'small', 'kg': 2, 'value': 0},
               'drops': [{'n': 1, 'name': 'Mei', 'place': {'name': 'Sentral 332'}}]},
};

Map<String, dynamic> _delivery({String status = 'pickup', List<Map<String, dynamic>> drops = const [],
    List<Map<String, dynamic>> returns = const [], Map<String, dynamic> extra = const {}}) => {
  'id': 'dv1', 'rideId': 'r1', 'status': status, 'payer': 'sender', 'pay': 'cash', 'inApp': false, 'retPayer': 'recipient',
  'parcel': {'type': 'Parcel', 'size': 'small', 'kg': 2, 'value': 0}, 'sealCode': 'GR-48K2',
  'sender': {'name': 'Ben Tamu'}, 'pickup': {'name': 'Bangsar South'}, 'driver': {'name': 'Hafiz', 'rating': 4.9},
  'total': 13, 'quote': {'total': 13, 'wait': {'freeMin': 5, 'perMin': 0.3}},
  'deposit': {'total': 10.55, 'paid': 10.55, 'waitLeft': 4.5}, 'rules': {'proof': 'code', 'pickupPhotos': 1, 'ackMin': 10},
  'pickupPhotos': <String>[], 'itemMatches': false, 'sealed': false, 'drops': drops, 'returns': returns, 'payParts': const [],
  ...extra,
};

void main() {
  for (final b in Brightness.values) {
    testWidgets('${b.name}: "A delivery" on the myGiG sheet only where the vehicle may', (tester) async {
      _tall(tester);
      for (final offered in [true, false]) {
        await tester.pumpWidget(_app(b, Builder(builder: (c) => Scaffold(body: TextButton(
          onPressed: () => showMygigSheet(c, const MygigConfig(ok: true),
              delivery: MygigDeliveryConfig({..._config.raw, 'offered': offered})),
          child: const Text('open'),
        )))));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('mygig-sheet-delivery')), offered ? findsOneWidget : findsNothing);
        expect(find.text('Delivery settings'), offered ? findsOneWidget : findsNothing);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('${b.name}: Delivery settings: get.ride''s rates or the driver''s own, item types, the limits', (tester) async {
      _tall(tester);
      var p = _config.prefs;
      var saved = false;
      await tester.pumpWidget(_app(b, Scaffold(body: StatefulBuilder(builder: (c, set) => MygigDeliveryPrefsForm(
        config: _config,
        prefs: p,
        onChanged: (v) => set(() => p = v),
        onSave: () async => saved = true,
      )))));
      expect(find.textContaining('RM6.00 + RM1.00/km, min. RM9.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('mygig-dprefs-base')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mygig-dprefs-own')));
      await tester.pumpAndSettle();
      expect(p.own, isTrue);
      expect(find.byKey(const ValueKey('mygig-dprefs-base')), findsOneWidget);
      expect(find.textContaining('base up to RM20.00, per km RM0.50 to RM3.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('mygig-dprefs-bulky')), findsNothing, reason: 'a car carries no bulky items');
      expect(tester.widget<FilterChip>(find.byKey(const ValueKey('mygig-dprefs-type-Food'))).selected, isFalse);
      await tester.tap(find.byKey(const ValueKey('mygig-dprefs-type-Food')));
      await tester.pumpAndSettle();
      expect(p.offTypes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('mygig-dprefs-save')));
      await tester.pumpAndSettle();
      expect(saved, isTrue);
    });

    testWidgets('${b.name}: the sender ticks before Accept; the deposit and "If it comes back"', (tester) async {
      _tall(tester);
      final answers = <bool>[];
      await tester.pumpWidget(_app(b, Scaffold(body: MygigDeliveryAgree(offer: _offer(), onAnswer: (a) async => answers.add(a)))));
      await tester.pumpAndSettle();
      expect(find.text('Your delivery with Hafiz'), findsOneWidget);
      expect(find.textContaining('refundable deposit of RM10.55'), findsOneWidget);
      expect(find.textContaining('Nobody there or refused: you pay RM5.55 at most'), findsOneWidget);
      expect(find.text('Accept and pay RM10.55'), findsOneWidget);
      expect(_filled(tester, 'mygig-delivery-agree-yes').onPressed, isNull, reason: 'the tick first');
      await tester.tap(find.byKey(const ValueKey('mygig-delivery-agree-ack')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mygig-delivery-agree-yes')));
      await tester.pumpAndSettle();
      expect(answers, [true]);
    });

    testWidgets('${b.name}: a Family sender sees the Family row and pays nothing now', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(b, Scaffold(body: MygigDeliveryAgree(offer: _offer(pay: 'family'), onAnswer: (_) async {}))));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mygig-delivery-family')), findsOneWidget);
      expect(find.text('Accept · RM13.00'), findsOneWidget);
    });

    testWidgets('${b.name}: the pickup: Start delivery waits for the check and the sender''s cash', (tester) async {
      _tall(tester);
      final acts = <String>[];
      final code = TextEditingController(), name = TextEditingController(), rc = TextEditingController();
      addTearDown(() {
        code.dispose();
        name.dispose();
        rc.dispose();
      });
      Widget view(Map<String, dynamic> d) => _app(b, Scaffold(body: SingleChildScrollView(child: MygigDeliveryDriverView(
        delivery: MygigDelivery(d), arrivedAtPickup: true, code: code, otherName: name, returnCode: rc,
        handOther: false, handPhoto: false, onHandOther: (_) {}, onAction: (a, {drop, ret}) => acts.add(a),
      ))));
      await tester.pumpWidget(view(_delivery()));
      expect(find.text('Seal code written on the parcel: GR-48K2'), findsOneWidget);
      expect(find.text('Take a photo of the item first.'), findsOneWidget);
      expect(_filled(tester, 'mygig-delivery-start').onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('mygig-delivery-sender-cash')));
      expect(acts, ['senderCash']);
      await tester.pumpWidget(view(_delivery(extra: {'pickupPhotos': ['d/p.jpg'], 'itemMatches': true, 'sealed': true,
                                                    'senderCashAt': 'x'})));
      await tester.pumpAndSettle();
      expect(_filled(tester, 'mygig-delivery-start').onPressed, isNotNull);
      expect(find.byKey(const ValueKey('mygig-delivery-refuse')), findsOneWidget);
    });

    testWidgets('${b.name}: at the door: paid first, then the code; a return''s lines before it starts', (tester) async {
      _tall(tester);
      final acts = <String>[];
      final code = TextEditingController(), name = TextEditingController(), rc = TextEditingController();
      addTearDown(() {
        code.dispose();
        name.dispose();
        rc.dispose();
      });
      final d = _delivery(status: 'delivering', drops: [
        {'n': 1, 'name': 'Mei', 'status': 'arrived', 'place': {'name': 'Sentral 332'},
         'due': {'fare': 13, 'cod': 40, 'wait': 0, 'total': 53}, 'wait': {'min': 2, 'over': 0, 'charge': 0}},
      ], extra: {'payer': 'recipient'});
      await tester.pumpWidget(_app(b, Scaffold(body: SingleChildScrollView(child: MygigDeliveryDriverView(
        delivery: MygigDelivery(d), arrivedAtPickup: true, code: code, otherName: name, returnCode: rc,
        handOther: false, handPhoto: false, onHandOther: (_) {}, onAction: (a, {drop, ret}) => acts.add(a),
      )))));
      expect(find.text('Collect from Mei'), findsOneWidget);
      expect(find.text('RM53.00'), findsOneWidget);
      expect(find.text('Collect the payment first.'), findsOneWidget);
      expect(_filled(tester, 'mygig-delivery-delivered').onPressed, isNull);
      expect(find.text('Waiting after 5 min: added to what Mei pays.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-delivery-door-link')));
      await tester.tap(find.byKey(const ValueKey('mygig-delivery-not-here')));
      expect(acts, ['doorLink', 'notHere']);

      final withReturn = _delivery(status: 'delivering', drops: [
        {'n': 1, 'name': 'Mei', 'status': 'returning', 'place': {'name': 'Sentral 332'}},
      ], returns: [
        {'id': 'rt1', 'n': 1, 'kind': 'failed', 'reason': 'Nobody there, or refused at the door', 'payer': 'sender',
         'method': 'deposit', 'amount': 5.55, 'status': 'waiting',
         'checks': {'pay': true, 'payerAck': false, 'photo': false, 'sender': false}},
      ]);
      await tester.pumpWidget(_app(b, Scaffold(body: SingleChildScrollView(child: MygigDeliveryDriverView(
        delivery: MygigDelivery(withReturn), arrivedAtPickup: true, code: code, otherName: name, returnCode: rc,
        handOther: false, handPhoto: false, onHandOther: (_) {}, onAction: (a, {drop, ret}) => acts.add(a),
      )))));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t deliver to Mei'), findsOneWidget);
      expect(find.text('Return fee RM5.55'), findsOneWidget);
      expect(find.text('Ben Tamu acknowledges'), findsOneWidget);
      expect(_filled(tester, 'mygig-delivery-return-start-1').onPressed, isNull, reason: 'every line first');
    });

    testWidgets('${b.name}: the recipient''s page: their code and what they pay; the sender acknowledges a return', (tester) async {
      _tall(tester);
      final paid = <String?>[];
      await tester.pumpWidget(_app(b, Scaffold(body: MygigDeliveryFollow(
        delivery: MygigDelivery(_delivery(status: 'delivering', drops: [
          {'n': 1, 'name': 'Mei', 'status': 'arrived', 'code': '4827', 'place': {'name': 'Sentral 332'},
           'due': {'fare': 13, 'cod': 0, 'wait': 0, 'total': 13}},
        ])),
        recipient: true,
        onPay: (w) async => paid.add(w),
        onAck: (_) async => null,
        onCancel: () async => null,
        onChanged: () {},
      ))));
      await tester.pumpAndSettle();
      expect(find.text('4827'), findsOneWidget);
      expect(find.text('Pay RM13.00 on delivery'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mygig-delivery-pay-door')));
      await tester.pumpAndSettle();
      expect(paid, ['door']);

      final acks = <String>[];
      await tester.pumpWidget(_app(b, Scaffold(body: MygigDeliveryFollow(
        delivery: MygigDelivery(_delivery(status: 'delivering', drops: [
          {'n': 1, 'name': 'Mei', 'status': 'returning', 'place': {'name': 'Sentral 332'}},
        ], returns: [
          {'id': 'rt1', 'n': 1, 'kind': 'failed', 'reason': 'Nobody there', 'payer': 'sender', 'method': 'deposit',
           'amount': 5.55, 'status': 'waiting', 'checks': {'pay': true}},
        ], extra: {'returnCode': '5521'})),
        recipient: false,
        onPay: (w) async {},
        onAck: (r) async {
          acks.add(r.id);
          return null;
        },
        onCancel: () async => null,
        onChanged: () {},
      ))));
      await tester.pumpAndSettle();
      expect(find.text('Your parcel is coming back'), findsOneWidget);
      expect(find.text('5521'), findsOneWidget);
      expect(find.textContaining('RM5.55 from your return deposit, as agreed.'), findsOneWidget);
      expect(_filled(tester, 'mygig-delivery-ack-go-1').onPressed, isNull, reason: 'the tick first');
      await tester.tap(find.byKey(const ValueKey('mygig-delivery-ack-tick-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mygig-delivery-ack-go-1')));
      await tester.pumpAndSettle();
      expect(acks, ['rt1']);
    });

    testWidgets('${b.name}: the admin''s Money safety panel', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(b, const Scaffold(body: SingleChildScrollView(child: MygigMoneySafetyPanel(
        settings: MygigDeliverySettings({'guaranteeFee': 0.5, 'waiting': {'allowanceMin': 15}}),
      )))));
      expect(find.text('Money safety: no losses to get.ride or the driver'), findsOneWidget);
      expect(find.text('Recipient pays is guaranteed'), findsOneWidget);
      expect(find.textContaining('a RM0.50 guarantee fee'), findsOneWidget);
    });
  }

  test('a delivery is told apart from a myGiG ride', () {
    expect(isMygigDelivery(RideRequest({'mygig': {'kind': 'delivery'}})), isTrue);
    expect(isMygigDelivery(RideRequest({'mygig': {'pay': 'cash'}})), isFalse);
    expect(isMygigDelivery(RideRequest({})), isFalse);
  });
}
