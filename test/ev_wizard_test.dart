import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/ev_orders.dart';
import 'package:get_ride/src/core/ev_wizard.dart';

/// The JY AIR as production stores it: itemised taxes, priced options.
Map<String, dynamic> jyAir() => {
      'make': 'JUNEYAO',
      'model': 'JY AIR',
      'price': 75000,
      'taxes': jsonEncode([
        {'id': 't1', 'name': 'SST', 'amount': 7500, 'enabled': true},
        {'id': 't2', 'name': 'Road Tax', 'amount': 90, 'enabled': true},
        {'id': 't3', 'name': 'Old levy', 'amount': 999, 'enabled': false},
      ]),
      'features': jsonEncode([
        {'id': 'f1', 'name': 'Panoramic Sunroof', 'price': 3500, 'enabled': true},
      ]),
      'accessories': jsonEncode([
        {'id': 'a1', 'name': 'Wireless Charger', 'price': 450, 'enabled': true},
        {'id': 'a2', 'name': 'Roof Rack', 'price': 1200, 'enabled': false},
      ]),
      'exteriorColors': jsonEncode([
        {'id': 'e1', 'name': 'Pearl White', 'code': '#F5F5F5', 'enabled': true},
        {'id': 'e2', 'name': 'Cherry Red', 'code': '#B11226', 'enabled': false},
      ]),
      'interiorColors': jsonEncode([
        {'id': 'i1', 'name': 'Charcoal', 'code': '#2B2B2B', 'enabled': true},
      ]),
      'exteriorImages': jsonEncode(['https://x/e.jpg']),
    };

void main() {
  group('the catalogue', () {
    test('a model adds up its enabled tax lines and offers only enabled options', () {
      final v = EvVehicle('v1', jyAir());
      expect(v.name, 'JUNEYAO JY AIR');
      expect(v.tax, 7590, reason: 'Expo read a single tax figure and showed none for itemised taxes');
      expect(v.exteriorColours.map((c) => c.name), ['Pearl White']);
      expect(v.accessories.map((a) => a.name), ['Wireless Charger']);
      expect(v.gallery.single, (url: 'https://x/e.jpg', label: 'Exterior'));
    });

    test('a model without colour lists falls back to the legacy defaults', () {
      final v = EvVehicle('v', {'make': 'X', 'model': 'Y', 'tax': 100});
      expect(v.tax, 100);
      expect(v.exteriorColours.map((c) => c.name), ['Pearl White', 'Solid Black', 'Midnight Blue', 'Red']);
      expect(v.interiorColours.map((c) => c.name), ['Black', 'White', 'Cream']);
      expect(v.accessories.first, (id: 'Roof Rack', name: 'Roof Rack', price: 300.0));
      expect(EvVehicle('v', const {}).name, 'TEKSI EV');
    });

    test('a stock unit is priced from its model and lists what it was built with', () {
      final vehicles = {'v1': EvVehicle('v1', jyAir())};
      final u = EvInventoryUnit('u1', {
        'vehicleId': 'v1',
        'vin': 'VIN123',
        'featureIds': jsonEncode(['f1']),
        'accessoryIds': jsonEncode(['a1']),
      }, vehicles);
      expect(u.name, 'JUNEYAO JY AIR');
      expect(u.factoryWheels, evDefaultWheel);
      expect([...u.includedFeatures, ...u.includedAccessories].map((e) => e.price), [3500, 450]);
      expect(evPriceBreakdown(u.vehicle, [...u.includedFeatures, ...u.includedAccessories]).total, 75000 + 7590 + 3950);
    });

    test('a DA code finds its advisor, whatever the case or spacing', () {
      final advisors = [(id: 'a1', values: <String, dynamic>{'daNumber': 'DA-0001', 'name': 'Siti'})];
      expect(advisorByDaCode(advisors, ' da-0001 ')?.id, 'a1');
      expect(advisorByDaCode(advisors, 'DA-9'), isNull);
      expect(advisorByDaCode(advisors, ''), isNull);
    });
  });

  group('the order fee', () {
    final fees = [
      {'country': 'Malaysia', 'currency': 'RM', 'amount': 3000, 'isDefault': true, 'active': true},
      {'country': 'Singapore', 'currency': 'SGD', 'amount': 1000, 'active': true},
      {'country': 'Thailand', 'currency': 'THB', 'amount': 0, 'active': true},
      {'country': 'Brunei', 'currency': 'BND', 'amount': 500, 'active': false},
    ];

    test("the country's own fee, else the default", () {
      expect(resolveOrderFee(fees, 'singapore'), (amount: 1000.0, currency: 'SGD', country: 'Singapore'));
      expect(resolveOrderFee(fees, 'Brunei').country, 'Malaysia', reason: 'an inactive fee is not used');
      expect(resolveOrderFee(fees, null).amount, 3000);
    });

    test('a fee of 0 is free, and no fee at all is RM 3,000', () {
      expect(resolveOrderFee(fees, 'Thailand').amount, 0);
      expect(resolveOrderFee(const [], 'Japan'), (amount: 3000.0, currency: 'RM', country: 'Malaysia'));
    });

    test('money reads like a price tag', () {
      expect(evMoney(75000), 'RM 75,000');
      expect(evMoney(1234.5, 'SGD'), 'SGD 1,234.50');
    });
  });

  group('financing', () {
    final options = [
      (id: 'cash', values: <String, dynamic>{'name': 'Full Cash', 'type': 'Cash', 'paymentMode': 'Full Balance', 'displayPriority': 1}),
      (id: 'hp60', values: <String, dynamic>{'name': 'HP 60m', 'type': 'Hire Purchase', 'rate': '2.85', 'termValue': '60', 'termUnit': 'Month', 'paymentMode': 'Custom', 'paymentAmount': '1200', 'displayPriority': 3}),
      (id: 'hp84', values: <String, dynamic>{'name': 'HP 84m', 'type': 'hp', 'displayPriority': 2}),
      (id: 'old', values: <String, dynamic>{'name': 'Old lease', 'type': 'Leasing', 'active': false}),
    ];

    test('only types with an active plan are offered, plans in display order', () {
      expect(availableFinanceTypes([for (final o in options) o.values]), ['cash', 'hp']);
      expect(financePlansFor(options, 'hp').map((p) => p.id), ['hp84', 'hp60']);
      expect(describeFinancePlan(options[1].values), 'RM 1,200 · 2.85% · 60 Months');
      expect(describeFinancePlan(options[0].values), 'Full balance');
    });

    test('changing the type clears the old plan, so a half-done order is never complete', () {
      final v = <String, dynamic>{'financeType': 'cash', 'financeChoice': 'cash', 'cashBalanceConfirmed': true};
      expect(isEvFinancingComplete(v), isTrue);
      v.addAll(financeTypePatch('hp'));
      expect(isEvFinancingComplete(v), isFalse, reason: 'Expo kept the cash plan and called hire purchase done');
    });

    test('a confirmed balance or add-on completes the step; the back office records the money', () {
      expect(isEvFinancingComplete({'financeType': 'cash', 'financeChoice': 'c'}), isFalse);
      expect(isEvFinancingComplete({'financeType': 'cash', 'financeChoice': 'c', 'cashBalanceConfirmed': true}), isTrue);
      expect(isEvFinancingComplete({'financeType': 'Leasing', 'financeChoice': 'l', 'leasingAddonRequired': 'yes'}), isFalse);
      expect(
        isEvFinancingComplete(
            {'financeType': 'Leasing', 'financeChoice': 'l', 'leasingAddonRequired': 'yes', 'leasingAddonConfirmed': true}),
        isTrue,
      );
      expect(outstandingBalance(82590, 3000), 79590);
      expect(outstandingBalance(1000, 3000), 0);
    });
  });

  group('the order', () {
    test('placing it records the fee as due, never as paid', () {
      final v = EvVehicle('v1', jyAir());
      final values = newEvOrderValues(
        customerName: ' Aina ',
        customerPhone: '+60123',
        vehicle: v,
        exteriorColour: 'Pearl White',
        interiorColour: 'Charcoal',
        wheels: evDefaultWheel,
        extras: v.accessories,
        fee: (amount: 3000, currency: 'RM', country: 'Malaysia'),
      );
      expect(values['depositPaid'], isFalse);
      expect(values['depositStatus'], 'due');
      expect(values['depositAmount'], 3000);
      expect(values['status'], 'pending');
      expect(values['customerName'], 'Aina');
      expect(values['total'], 75000 + 7590 + 450);
      expect(values['wheelsSwapped'], isFalse);
      expect(deriveEvOrderStep(values), 'ownership');
    });

    test('a stock unit with its wheels changed is flagged for a re-fit', () {
      final vehicles = {'v1': EvVehicle('v1', jyAir())};
      final u = EvInventoryUnit('u1', {'vehicleId': 'v1', 'wheels': '18" Standard'}, vehicles);
      final values = newEvOrderValues(
        customerName: '',
        customerPhone: '',
        vehicle: u.vehicle,
        unit: u,
        exteriorColour: '',
        interiorColour: '',
        wheels: '20" Performance',
        extras: const [],
        fee: (amount: 3000, currency: 'RM', country: 'Malaysia'),
      );
      expect(values['mode'], 'inventory');
      expect(values['buildFlags'], 'Re-fit wheels');
      expect(values['factoryWheels'], '18" Standard');
      expect(values['customerName'], 'TEKSI Customer');
    });

    test('the newest unfinished order is the one resumed', () {
      final at = DateTime(2026, 10, 1);
      expect(
        resumableEvOrder([
          (id: 'old', values: <String, dynamic>{'status': 'pending'}, createdAt: at),
          (id: 'new', values: <String, dynamic>{'status': 'assigned'}, createdAt: at.add(const Duration(days: 1))),
          (id: 'done', values: <String, dynamic>{'status': 'delivered'}, createdAt: at.add(const Duration(days: 2))),
          (id: 'accepted', values: <String, dynamic>{'checklistAccepted': true}, createdAt: at.add(const Duration(days: 3))),
        ]),
        'new',
      );
      expect(resumableEvOrder(const []), isNull);
    });

    test('ownership needs the fields its owner type calls for', () {
      final f = {'fullName': 'Aina', 'idNumber': '900101-14-5678', 'address': 'KL'};
      expect(ownershipProblem(f, 'self'), isNull);
      expect(ownershipProblem(f, 'other'), 'Please fill in the relationship.');
      expect(ownershipProblem({...f, 'address': ' '}, 'company'),
          'Please fill in the address, company name, registration number, company address.');
      final patch = ownershipPatch({...f, 'companyName': 'Acme'}, 'company', 'passport', 'Singapore');
      expect(patch['ownerIdType'], 'company+passport');
      expect(patch['companyName'], 'Acme');
      expect(ownershipPatch(f, 'self', 'national', 'Malaysia')['companyName'], '');
    });

    test('delivery dates run 3 to 17 days out, in the local calendar', () {
      final slots = deliverySlots(DateTime(2026, 12, 30, 23, 30));
      expect(slots, hasLength(15));
      expect(isoDate(slots.first), '2027-01-02');
      expect(isoDate(slots.last), '2027-01-16');
    });

    test('what is still owed, and what marking it received writes', () {
      final v = <String, dynamic>{
        'depositAmount': 3000,
        'depositCurrency': 'RM',
        'financeType': 'cash',
        'cashBalanceConfirmed': true,
        'balanceDueAmount': 79590,
      };
      expect(evPaymentsDue(v).map((p) => (p.label, p.amount, p.received)),
          [('Order fee', 3000.0, false), ('Cash balance', 79590.0, false)]);
      final now = DateTime(2026, 10, 4);
      v.addAll(paymentReceivedPatch('deposit', v, now));
      v.addAll(paymentReceivedPatch('balance', v, now));
      expect(evPaymentsDue(v).every((p) => p.received), isTrue);
      expect(v['balancePaidAmount'], 79590);
      expect(evPaymentsDue(const {}), isEmpty);
    });
  });
}
