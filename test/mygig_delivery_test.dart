// myGiG Delivery (migration 0332): the checks the screens show before the
// server is asked (what can be sent, the sender and drop-offs, sending),
// who may pay how (recipient pays, COD), the price's lines and the
// deposit's words, the delivery as the driver reads it (Start delivery,
// what is due at the door, who pays waiting, the proof, the lines before a
// return), the admin's settings part and the Money safety panel.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/mygig.dart';
import 'package:get_ride/src/core/mygig_delivery.dart';

const _settings = MygigDeliverySettings({
  'enabled': true,
  'vehicles': {
    'bike': {'on': true, 'base': 5, 'perKm': 0.8, 'min': 7, 'maxKg': 10},
    'car': {'on': true, 'base': 6, 'perKm': 1.0, 'min': 9, 'maxKg': 30},
    'van': {'on': false, 'base': 15, 'perKm': 1.6, 'min': 25, 'maxKg': 300},
  },
  'sizes': {
    'small': {'bike': true, 'car': true, 'van': true},
    'medium': {'bike': true, 'car': true, 'van': true},
    'large': {'bike': false, 'car': true, 'van': true},
    'bulky': {'bike': false, 'car': false, 'van': true},
  },
  'itemTypes': ['Documents', 'Parcel', 'Food'],
  'prohibited': ['Weapons and explosives'],
  'maxDrops': 4,
  'senderPhone': 'required',
  'maxValue': 2000,
  'protection': {'fee': 0.5, 'free': 300, 'pct': 1},
  'guaranteeFee': 0.5,
  'waiting': {'freeMin': 5, 'perMin': 0.3, 'allowanceMin': 15},
  'recipientPays': true,
  'cod': {'on': true, 'feePct': 1.5, 'max': 1000},
  'proof': 'code',
});

const _registered = MygigLookup(state: MygigLookupState.latest, name: 'Ai**a');
const _stranger = MygigLookup(state: MygigLookupState.none);

Map<String, dynamic> _delivery({
  String status = 'pickup',
  String payer = 'sender',
  String pay = 'cash',
  bool inApp = false,
  List<Map<String, dynamic>> drops = const [],
  List<Map<String, dynamic>> returns = const [],
  List<Map<String, dynamic>> parts = const [],
  Map<String, dynamic> extra = const {},
}) => {
  'id': 'dv1', 'rideId': 'r1', 'status': status, 'payer': payer, 'pay': pay, 'inApp': inApp, 'retPayer': 'recipient',
  'parcel': {'type': 'Parcel', 'size': 'medium', 'kg': 7, 'value': 500, 'fragile': true},
  'sealCode': 'GR-48K2', 'sender': {'name': 'Ben Tamu', 'registered': false}, 'pickup': {'name': 'Bangsar South'},
  'total': 23.5, 'quote': {'total': 23.5, 'wait': {'freeMin': 5, 'perMin': 0.3}},
  'deposit': {'total': 11.0, 'paid': 11.0, 'waitLeft': 4.5}, 'rules': {'proof': 'code', 'pickupPhotos': 1, 'ackMin': 10},
  'pickupPhotos': ['d1/p.jpg'], 'itemMatches': true, 'sealed': true,
  'drops': drops, 'returns': returns, 'payParts': parts,
  ...extra,
};

void main() {
  group('the admin''s delivery settings', () {
    test('vehicles, sizes and limits', () {
      expect(_settings.vehicleOn('car'), isTrue);
      expect(_settings.vehicleOn('van'), isFalse);
      expect(_settings.sizesFor('bike'), ['small', 'medium']);
      expect(_settings.sizesFor('car'), ['small', 'medium', 'large']);
      expect(_settings.needsText('bulky'), 'needs a van');
      expect(_settings.needsText('large'), 'needs a car or van');
      expect(_settings.maxKg('bike'), 10);
      expect(_settings.senderPhoneRequired, isTrue);
      expect(const MygigDeliverySettings({'maxDrops': 9}).maxDrops, 5, reason: 'never more than 5 drop-offs');
    });

    test('the delivery part is one region part, with every field under it', () {
      expect(mygigParts.where((p) => p.$1 == 'delivery').single.$3, ['delivery']);
      final fields = mygigFields.where((f) => f.part == 'delivery').toList();
      expect(fields.every((f) => f.path.startsWith('delivery.')), isTrue);
      for (final p in ['delivery.proof', 'delivery.guaranteeFee', 'delivery.waiting.allowanceMin', 'delivery.cod.feePct',
                       'delivery.protection.fee', 'delivery.returnPctMax', 'delivery.ackMin', 'delivery.prohibited',
                       'delivery.sizes.large.bike', 'delivery.vehicles.van.maxKg', 'delivery.ownLimits.waitMax']) {
        expect(fields.any((f) => f.path == p), isTrue, reason: p);
      }
      expect(fields.where((f) => f.kind == MygigFieldKind.list).map((f) => f.path), ['delivery.itemTypes', 'delivery.prohibited']);
      expect({for (final f in mygigFields) f.path}.length, mygigFields.length, reason: 'every field once');
    });
  });

  group('before sending', () {
    String? parcel({String? type = 'Parcel', String size = 'small', double kg = 2, double value = 0, int photos = 1,
            bool ack = true, String vehicle = 'car', List<String> off = const []}) =>
        mygigParcelProblem(s: _settings, vehicle: vehicle, vehicleName: vehicle == 'bike' ? 'Motorbike' : 'Car', type: type,
            size: size, kg: kg, value: value, photos: photos, noProhibited: ack, offTypes: off);

    test('what can be sent', () {
      expect(parcel(), isNull);
      expect(parcel(type: null), 'Choose what is being sent.');
      expect(parcel(off: ['Parcel']), 'You don’t take parcel (Delivery settings).');
      expect(parcel(size: 'large', vehicle: 'bike'), 'Your motorbike can’t carry this size.');
      expect(parcel(kg: 11, vehicle: 'bike'), 'Too heavy for your motorbike (up to 10 kg).');
      expect(parcel(value: 2500), 'The declared value is over the RM2000.00 limit.');
      expect(parcel(photos: 0), 'Take a photo of the item.');
      expect(parcel(ack: false), 'The sender must confirm there are no prohibited items.');
    });

    test('the sender and the drop-offs', () {
      String? route({String phone = '0123456789', MygigLookup sender = _registered, String name = '',
              List<MygigDropDraft> drops = const [MygigDropDraft(placeSet: true, phone: '0177778888', lookup: _registered)]}) =>
          mygigRouteProblem(senderPhoneRequired: true, senderPhone: phone, sender: sender, senderName: name, drops: drops);
      expect(route(), isNull);
      expect(route(phone: ''), 'Enter the sender’s phone.');
      expect(route(sender: _stranger), 'Enter the sender’s name: this number isn’t registered.');
      expect(route(sender: _stranger, name: 'Ben'), isNull);
      expect(route(drops: const [MygigDropDraft(phone: '0177778888')]), 'Choose drop-off.');
      expect(route(drops: const [MygigDropDraft(placeSet: true, phone: '01')]), 'Enter the recipient’s phone for drop-off.');
      expect(route(drops: const [
        MygigDropDraft(placeSet: true, phone: '0177778888', lookup: _registered),
        MygigDropDraft(placeSet: true, phone: '0177778899', lookup: _stranger),
      ]), 'Enter the recipient’s name for drop-off 2.');
    });

    test('who may pay how: in-app, recipient pays, COD', () {
      const p = MygigDeliveryPrefs({'takeCod': true, 'takeRecipientPays': true});
      expect(mygigDeliveryInApp(registered: true, pay: MygigPay.wallet), isTrue);
      expect(mygigDeliveryInApp(registered: false, pay: MygigPay.link), isFalse);
      expect(mygigDeliveryPayOptions(_stranger), [MygigPay.cash, MygigPay.link]);
      expect(mygigDeliveryPayOptions(_registered), [MygigPay.cash, MygigPay.wallet, MygigPay.link]);
      expect(mygigRecipientPaysNo(s: _settings, p: p, pay: MygigPay.cash), isNull,
          reason: 'always guaranteed: the deposit holds the fare when the sender has no in-app payment');
      expect(mygigRecipientPaysNo(s: _settings, p: p, pay: MygigPay.business), 'A business account pays the delivery itself.');
      expect(mygigRecipientPaysNo(s: _settings, p: p.copyWith({'takeRecipientPays': false}), pay: MygigPay.cash),
          'You don’t take recipient pays (Delivery settings).');
      expect(mygigRecipientPaysNo(s: const MygigDeliverySettings({'recipientPays': false}), p: p, pay: MygigPay.cash),
          'get.ride has switched off recipient pays.');
      expect(mygigCodNo(s: _settings, p: p, senderRegistered: true), isNull);
      expect(mygigCodNo(s: _settings, p: p, senderRegistered: false), startsWith('Cash on delivery needs a registered sender'));
      expect(mygigCodNo(s: _settings, p: p.copyWith({'takeCod': false}), senderRegistered: true),
          'You don’t take cash on delivery (Delivery settings).');
    });

    test('sending', () {
      const q = MygigDeliveryQuote({'total': 13, 'deposit': {'total': 11}});
      String? send({MygigDeliveryQuote? quote = q, bool cod = false, double amount = 0, MygigWay? way = MygigWay.sms,
              bool inApp = false, bool phone = true}) =>
          mygigDeliverySendProblem(quote: quote, codOn: cod, codAmount: amount, codMax: 1000, way: way, inApp: inApp, hasPhone: phone);
      expect(send(), isNull);
      expect(send(quote: null), 'Working out the price…');
      expect(send(cod: true), 'Enter the amount to collect, or switch cash on delivery off.');
      expect(send(cod: true, amount: 1500), 'Cash on delivery is up to RM1000.00.');
      expect(send(phone: false), contains('refundable deposit by link'));
      expect(send(phone: false, inApp: true), isNull);
      expect(send(way: null), 'Choose how the sender accepts.');
    });
  });

  group('the price and the deposit', () {
    const q = MygigDeliveryQuote({
      'km': 6, 'fare': 12, 'size': 2, 'kg': 1, 'fragile': 3, 'extraDrops': 3, 'drops': 2, 'cover': 2.5, 'coverFree': 300,
      'coverPct': 1, 'coverUpTo': 500, 'tax': 0, 'showTax': true, 'rounded': 0.5, 'total': 24, 'vehicleName': 'Car',
      'retPct': 50, 'maxFail': 5.55, 'maxReturn': 11.1,
      'deposit': {'ret': 5.55, 'wait': 4.5, 'fare': 24, 'fee': 0.5, 'total': 34.55, 'waitMin': 15},
    });

    test('every line, as the prototype shows it', () {
      expect(q.lines(sizeKey: 'medium', weight: 7, freeKg: 5), [
        ('Delivery · Car · 6.0 km · 2 drop-offs', 12.0),
        ('Size · Medium', 2.0),
        ('Weight over 5 kg · 7 kg', 1.0),
        ('Fragile handling', 3.0),
        ('Extra drop-offs · 1', 3.0),
        ('Cover · 1% above RM300.00', 2.5),
        ('Rounded up', 0.5),
      ]);
    });

    test('the deposit in words, and what is paid when accepting', () {
      expect(mygigDepositText(q.deposit!), 'No app account to charge later, so a refundable deposit of RM34.55 is paid by link '
          'when the sender accepts: return up to RM5.55, waiting up to 15 min RM4.50, the delivery fare RM24.00 in case the '
          'recipient doesn’t pay, and a RM0.50 guarantee fee that isn’t refunded. The rest is refunded once it isn’t needed.');
      expect(mygigDeliveryPayNow(q: q, senderPays: true, pay: MygigPay.link), 24 + 34.55);
      expect(mygigDeliveryPayNow(q: q, senderPays: true, pay: MygigPay.cash), 34.55);
      expect(mygigDeliveryAcceptLabel(payNow: 34.55, total: 24), 'Accept and pay RM34.55');
      expect(mygigDeliveryAcceptLabel(payNow: 0, total: 24), 'Accept · RM24.00');
      expect(mygigComesBackText(q: q, inApp: false, payName: 'Cash', recipientPaysAsked: true, drops: 1),
          'Nobody there or refused: you pay RM5.55 at most, from the RM34.55 deposit paid now and refunded when it’s '
          'delivered. If the recipient asks to send it back: they pay the return fare first. You’ll be asked to acknowledge any return.');
    });
  });

  group('the delivery, as the driver reads it', () {
    test('Start delivery waits for the pickup check and the payment', () {
      expect(MygigDelivery(_delivery()).startProblem, 'Collect RM23.50 in cash from the sender first.');
      expect(MygigDelivery(_delivery(extra: {'senderCashAt': 'x'})).startProblem, isNull);
      expect(MygigDelivery(_delivery(pay: 'link', parts: [
        {'id': 'p1', 'purpose': 'accept', 'amount': 34.5, 'paidAt': null},
      ])).startProblem, 'The sender pays RM34.50 by link first.');
      expect(MygigDelivery(_delivery(extra: {'pickupPhotos': <String>[]})).startProblem, 'Take a photo of the item first.');
      expect(MygigDelivery(_delivery(extra: {'sealed': false, 'senderCashAt': 'x'})).startProblem,
          'Check the item matches and write the seal code on it first.');
      expect(MygigDelivery(_delivery(payer: 'recipient')).senderCashDue, isFalse, reason: 'the recipient pays at the door');
    });

    test('who pays the waiting at a drop-off', () {
      final drop = MygigDeliveryDrop(const {'n': 1, 'name': 'Mei Ling', 'status': 'arrived'});
      expect(MygigDelivery(_delivery(payer: 'recipient')).waitLine(drop, 5),
          'Waiting after 5 min: added to what Mei Ling pays.');
      expect(MygigDelivery(_delivery(inApp: true, pay: 'wallet')).waitLine(drop, 5),
          'Waiting after 5 min: charged to GET.wallet.');
      expect(MygigDelivery(_delivery()).waitLine(drop, 5), startsWith('Waiting after 5 min: paid from the sender’s deposit (RM4.50 left)'));
      expect(MygigDelivery(_delivery(extra: {'deposit': {'waitLeft': 0}})).waitUsedUp, isTrue,
          reason: 'used up: the driver is told to start the return');
      expect(MygigDelivery(_delivery(inApp: true)).waitUsedUp, isFalse);
    });

    test('the proof the admin asks for', () {
      expect(mygigProofOk(rule: 'code', code: '4827', handOther: false, name: '', photo: false), isTrue);
      expect(mygigProofOk(rule: 'code', code: '48', handOther: true, name: 'Ali', photo: true), isFalse);
      expect(mygigProofOk(rule: 'codeOrPhoto', code: '', handOther: true, name: 'Ali', photo: true), isTrue);
      expect(mygigProofOk(rule: 'codeOrPhoto', code: '', handOther: true, name: '', photo: true), isFalse);
      expect(mygigProofOk(rule: 'photo', code: '4827', handOther: false, name: '', photo: false), isFalse);
      final due = MygigDeliveryDrop(const {'n': 1, 'due': {'total': 30}});
      expect(mygigHandoverProblem(d: due, rule: 'code', proofOk: true), 'Collect the payment first.');
      expect(mygigHandoverProblem(d: MygigDeliveryDrop(const {'n': 1}), rule: 'photo', proofOk: false), 'Take the hand-over photo.');
    });

    test('every line before a return starts', () {
      final failed = MygigDeliveryReturn(const {
        'n': 1, 'kind': 'failed', 'payer': 'sender', 'method': 'deposit', 'amount': 5.55,
        'checks': {'pay': true, 'payerAck': false, 'photo': false, 'sender': false},
      });
      final lines = mygigReturnLines(failed, sender: 'Ben', recipient: 'Mei', payName: 'Cash', senderInApp: false);
      expect(lines.map((l) => (l.ok, l.title)), [(true, 'Return fee RM5.55'), (false, 'Photo of the item now'), (false, 'Ben acknowledges')]);
      expect(lines.first.sub, 'From the sender’s return deposit');
      expect(failed.checks.all, isFalse);
      final cash = MygigDeliveryReturn(const {
        'n': 1, 'kind': 'asked', 'payer': 'recipient', 'method': 'cash', 'amount': 11.1, 'driverCashAt': 'x',
        'checks': {'pay': false, 'payerAck': true, 'photo': true, 'sender': true},
      });
      final first = mygigReturnLines(cash, sender: 'Ben', recipient: 'Mei', payName: 'Cash', senderInApp: false).first;
      expect(first.ok, isFalse, reason: 'cash counts only when both confirm');
      expect(first.sub, 'You confirmed it · waiting for Mei to confirm on the link');
    });
  });

  test('the Money safety panel keeps every promise, with the admin''s numbers', () {
    final items = mygigMoneySafety(_settings);
    expect(items.map((i) => i.$1), [
      'Paid before it moves', 'Every return is paid for', 'Recipient pays is guaranteed', 'Waiting is never unpaid',
      'Deposits cost nothing', 'COD is settled at once', 'Cover pays for itself', 'Disputes have proof', 'Fees come off GET.credit',
    ]);
    expect(items[3].$2, contains('up to 15 min'));
    expect(items[4].$2, contains('RM0.50 guarantee fee'));
    expect(items.any((i) => i.$2.contains('get.ride covers') || i.$2.contains('driver covers')), isFalse);
  });
}
