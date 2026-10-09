import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/payment_types.dart';

void main() {
  group('Admin → Payment Type in the confirm sheet', () {
    test('only the enabled methods, in order, each once', () {
      final c = paymentChoicesFrom([
        {'name': 'Cash', 'enabled': true},
        {'name': 'Card', 'enabled': true, 'code': 'CARD'},
        {'name': 'Wallet', 'enabled': false},
        {'name': ' '},
        {'name': 'cash'},
        {'name': 'DuitNow', 'enabled': 'true'},
      ]);
      expect([for (final x in c) x.value], ['Cash', 'Card', 'DuitNow']);
      expect(c[1].kind, PaymentKind.card);
      expect(c[2].kind, PaymentKind.other);
    });

    test('a method with no switch counts as on; "off" strings as off', () {
      expect(paymentChoicesFrom([{'name': 'Cash'}]).single.value, 'Cash');
      expect(paymentChoicesFrom([{'name': 'Cash', 'enabled': 'false'}, {'name': 'Card', 'enabled': 0}]), isEmpty);
    });

    test('the kind comes from the code first, then the name', () {
      expect(paymentKindOf('Tunai', 'cash'), PaymentKind.cash);
      expect(paymentKindOf('Get Pay'), PaymentKind.wallet);
      expect(paymentKindOf('E-Wallet'), PaymentKind.wallet);
      expect(paymentKindOf('Debit card'), PaymentKind.card);
      expect(paymentKindOf('FPX'), PaymentKind.other);
    });

    test('a pick the admin switched off falls back to the first method offered', () {
      const offered = [PaymentChoice('Cash', 'Cash', PaymentKind.cash), PaymentChoice('Card', 'Card', PaymentKind.card)];
      expect(resolvePayment('Card', offered), 'Card');
      expect(resolvePayment('Get Pay', offered), 'Cash');
      expect(resolvePayment('Get Pay', const []), 'Get Pay');
    });

    test('a stored value is labelled from the list, else the first method', () {
      expect(paymentChoiceFor('Get Pay', builtInPayments).label, 'GET.wallet');
      expect(paymentChoiceFor('Unknown', const []).value, 'Cash');
    });
  });
}
