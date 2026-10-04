import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/commerce_logic.dart';
import 'package:get_ride/src/admin/screens/commerce/countries.dart';
import 'package:get_ride/src/admin/screens/commerce/ev_orders.dart';
import 'package:get_ride/src/admin/screens/commerce/get_coin.dart';

const _r = EvChecklistResult.new;

void main() {
  // ---- Mirrors expo/utils/__tests__/evOrders.test.ts ----------------------

  group('normalizeEvOrderStatus', () {
    test('passes through the canonical statuses', () {
      for (final s in evOrderStatuses) {
        expect(normalizeEvOrderStatus(s), s);
      }
    });

    test('accepts the spelling variants that reached stored data', () {
      expect(normalizeEvOrderStatus('ready-for-delivery'), 'ready_for_delivery');
      expect(normalizeEvOrderStatus('Ready For Delivery'), 'ready_for_delivery');
      expect(normalizeEvOrderStatus('in progress'), 'in-progress');
      expect(normalizeEvOrderStatus('canceled'), 'cancelled');
      expect(normalizeEvOrderStatus('completed'), 'delivered');
    });

    test('falls back to pending for anything unknown', () {
      expect(normalizeEvOrderStatus(null), 'pending');
      expect(normalizeEvOrderStatus(''), 'pending');
      expect(normalizeEvOrderStatus('wat'), 'pending');
    });

    test('labels and tones every status it can produce', () {
      expect(evOrderStatusLabel('ready-for-delivery'), 'Ready for delivery');
      expect(evOrderStatusLabel('nonsense'), 'Pending DA');
      expect(evOrderStatusTone('delivered'), EvOrderStatusTone.success);
      expect(evOrderStatusTone('pending'), EvOrderStatusTone.warning);
      expect(evOrderStatusTone('cancelled'), EvOrderStatusTone.error);
    });
  });

  group('evOrderStatusAtLeast', () {
    test('orders the lifecycle', () {
      expect(evOrderStatusAtLeast('ready_for_delivery', 'assigned'), isTrue);
      expect(evOrderStatusAtLeast('assigned', 'ready_for_delivery'), isFalse);
      expect(evOrderStatusAtLeast('delivered', 'delivered'), isTrue);
    });

    test('keeps cancelled outside the progression', () {
      expect(evOrderStatusAtLeast('cancelled', 'assigned'), isFalse);
      expect(evOrderStatusAtLeast('cancelled', 'cancelled'), isTrue);
    });
  });

  test('evFlag reads booleans however they were stored', () {
    expect(evFlag(true), isTrue);
    expect(evFlag('true'), isTrue);
    expect(evFlag('1'), isTrue);
    expect(evFlag('yes'), isTrue);
    expect(evFlag(false), isFalse);
    expect(evFlag('false'), isFalse);
    expect(evFlag(null), isFalse);
    expect(evFlag(''), isFalse);
  });

  group('parseChecklistResults', () {
    test('returns an empty list for missing or invalid JSON', () {
      expect(parseChecklistResults(null), isEmpty);
      expect(parseChecklistResults(''), isEmpty);
      expect(parseChecklistResults('{not json'), isEmpty);
      expect(parseChecklistResults('{"name":"x"}'), isEmpty);
    });

    test('parses items and defaults done to true when absent', () {
      expect(parseChecklistResults('[{"name":"Charge cable","note":"in boot"},{"name":"Tyres","done":false}]'), [
        _r(name: 'Charge cable', done: true, note: 'in boot'),
        _r(name: 'Tyres', done: false),
      ]);
    });

    test('drops nameless rows', () {
      expect(parseChecklistResults('[{"done":true},{"name":"Keys","done":true}]'), [_r(name: 'Keys', done: true)]);
    });

    test('round-trips through serialize', () {
      final items = [_r(name: 'Keys', done: false, note: 'one missing')];
      expect(parseChecklistResults(serializeChecklistResults(items)), items);
    });
  });

  test('isChecklistSubmitted / isChecklistAccepted read both forms', () {
    expect(isChecklistSubmitted({'checklistSubmitted': true}), isTrue);
    expect(isChecklistSubmitted({'checklistSubmitted': 'true'}), isTrue);
    expect(isChecklistSubmitted({}), isFalse);
    expect(isChecklistAccepted({'checklistAccepted': '1'}), isTrue);
    expect(isChecklistAccepted({'checklistAccepted': false}), isFalse);
  });

  group('buildChecklistDraft', () {
    test('starts every template item unticked when nothing is saved', () {
      expect(buildChecklistDraft(['Keys', 'Charge cable'], {}),
          [_r(name: 'Keys', done: false), _r(name: 'Charge cable', done: false)]);
    });

    test('resumes from what the advisor already submitted', () {
      expect(
        buildChecklistDraft(['Keys', 'Charge cable'], {'checklistResults': '[{"name":"Keys","done":true,"note":"2 fobs"}]'}),
        [_r(name: 'Keys', done: true, note: '2 fobs'), _r(name: 'Charge cable', done: false)],
      );
    });

    test('keeps submitted items that have since left the template', () {
      expect(
        buildChecklistDraft(['Keys'], {'checklistResults': '[{"name":"Retired check","done":true,"note":""}]'}),
        [_r(name: 'Keys', done: false), _r(name: 'Retired check', done: true)],
      );
    });

    test('ignores blank template names', () {
      expect(buildChecklistDraft(['', '  ', 'Keys'], {}), [_r(name: 'Keys', done: false)]);
    });
  });

  test('mapAdminTypeToFinanceType maps the admin labels', () {
    expect(mapAdminTypeToFinanceType('Cash'), 'cash');
    expect(mapAdminTypeToFinanceType('Hire Purchase'), 'hp');
    expect(mapAdminTypeToFinanceType('HP'), 'hp');
    expect(mapAdminTypeToFinanceType('Leasing'), 'leasing');
    expect(mapAdminTypeToFinanceType('Long term rental'), 'rental');
    expect(mapAdminTypeToFinanceType(''), isNull);
    expect(mapAdminTypeToFinanceType('balloon'), isNull);
  });

  group('step predicates', () {
    test('requires all three identity fields for ownership', () {
      expect(isEvOwnershipConfirmed({'ownerFullName': 'A', 'ownerIdNumber': '1', 'ownerAddress': 'x'}), isTrue);
      expect(isEvOwnershipConfirmed({'ownerFullName': 'A', 'ownerIdNumber': '1'}), isFalse);
      expect(isEvOwnershipConfirmed({}), isFalse);
    });

    test('requires a plate number only when transferring', () {
      expect(isEvPlateAnswered({'plateTransfer': 'no'}), isTrue);
      expect(isEvPlateAnswered({'plateTransfer': 'yes'}), isFalse);
      expect(isEvPlateAnswered({'plateTransfer': 'yes', 'plateNumber': 'WXY 1234'}), isTrue);
      expect(isEvPlateAnswered({}), isFalse);
    });

    test('gates financing on the per-type payment', () {
      expect(isEvFinancingComplete({'financeType': 'cash', 'financeChoice': 'f1'}), isFalse);
      expect(isEvFinancingComplete({'financeType': 'cash', 'financeChoice': 'f1', 'cashBalancePaid': true}), isTrue);
      expect(isEvFinancingComplete({'financeType': 'hp', 'financeChoice': 'f1'}), isTrue);
      expect(isEvFinancingComplete({'financeType': 'hp'}), isFalse);
      expect(isEvFinancingComplete({'financeType': 'leasing', 'financeChoice': 'f1'}), isFalse);
      expect(isEvFinancingComplete({'financeType': 'leasing', 'financeChoice': 'f1', 'leasingAddonRequired': 'no'}), isTrue);
      expect(isEvFinancingComplete({'financeType': 'leasing', 'financeChoice': 'f1', 'leasingAddonRequired': 'yes'}), isFalse);
      expect(
        isEvFinancingComplete(
            {'financeType': 'leasing', 'financeChoice': 'f1', 'leasingAddonRequired': 'yes', 'leasingAddonPaid': true}),
        isTrue,
      );
    });
  });

  group('deriveEvOrderStep', () {
    test('floors at ownership — an order row only exists after the deposit', () {
      expect(deriveEvOrderStep({}), 'ownership');
      expect(deriveEvOrderStep({'depositPaid': true}), 'ownership');
    });

    test('walks forward as each step is satisfied', () {
      final owned = {'ownerFullName': 'A', 'ownerIdNumber': '1', 'ownerAddress': 'x'};
      expect(deriveEvOrderStep(owned), 'plate');
      final plated = {...owned, 'plateTransfer': 'no'};
      expect(deriveEvOrderStep(plated), 'financing');
      final financed = {...plated, 'financeType': 'hp', 'financeChoice': 'f1'};
      expect(deriveEvOrderStep(financed), 'advisor');
      expect(deriveEvOrderStep({...financed, 'advisorId': 'da1'}), 'schedule');
      expect(deriveEvOrderStep({...financed, 'advisorId': 'da1', 'deliveryDate': '2026-09-01'}), 'delivery');
    });

    test('returns delivery once the customer has accepted handover', () {
      expect(deriveEvOrderStep({'checklistAccepted': true}), 'delivery');
    });
  });

  // ---- Admin orders back office -------------------------------------------

  group('admin order helpers', () {
    final now = DateTime.utc(2026, 10, 4, 9);

    test('advisor assignment snapshots the DA and marks the order assigned', () {
      final p = advisorAssignmentPatch('da-1', {'name': 'Aisyah', 'dealership': 'KL EV', 'city': 'KL'}, now);
      expect(p['advisorId'], 'da-1');
      expect(p['advisorName'], 'Aisyah');
      expect(p['advisorDaNumber'], 'da-1');
      expect(p['advisorEmail'], '');
      expect(p['status'], 'assigned');
      expect(p['assignedAt'], '2026-10-04T09:00:00.000Z');
    });

    test('checklist submission readies the order but never un-delivers it', () {
      final draft = [_r(name: 'Keys', done: true)];
      final p = checklistSubmissionPatch(draft, 'assigned', now);
      expect(p['status'], 'ready_for_delivery');
      expect(p['checklistSubmitted'], true);
      expect(jsonDecode(p['checklistResults'] as String), [
        {'name': 'Keys', 'done': true, 'note': ''},
      ]);
      expect(checklistSubmissionPatch(draft, 'Delivered', now)['status'], 'delivered');
    });

    test('filters by status, re-fit and search', () {
      final a = {'status': 'ready-for-delivery', 'customerName': 'Ali', 'wheelsSwapped': true};
      final b = {'status': 'pending', 'customerName': 'Bea'};
      expect(evOrderMatches(a, 'x1', 'ready_for_delivery', ''), isTrue);
      expect(evOrderMatches(b, 'x2', 'ready_for_delivery', ''), isFalse);
      expect(evOrderMatches(a, 'x1', 'refit', ''), isTrue);
      expect(evOrderMatches(b, 'x2', 'refit', ''), isFalse);
      expect(evOrderMatches(b, 'abc123', 'all', 'ABC1'), isTrue);
      expect(evOrderMatches(b, 'x2', 'all', 'ali'), isFalse);
      final stats = evOrderStats([a, b]);
      expect(stats['total'], 2);
      expect(stats['refit'], 1);
      expect(stats['pending'], 1);
      expect(stats['ready_for_delivery'], 1);
    });

    test('short order id and gallery parsing', () {
      expect(shortOrderId('0f9a-12ab34cd'), 'AB34CD');
      expect(shortOrderId('abc'), 'ABC');
      expect(parseStringList('["a","","b"]'), ['a', 'b']);
      expect(parseStringList('nope'), isEmpty);
    });
  });

  // ---- GET.coin (utils/getCoinStore.ts) -----------------------------------

  group('GET.coin', () {
    test('row parsing clamps and defaults like Expo', () {
      final s = GetCoinSettings.fromRow({
        'coins_per_currency': 0,
        'earn_coins_per_currency': -3,
        'market_max_swing': null,
        'max_supply': '21000000',
        'currency': 'RM',
      });
      expect(s.coinsPerCurrency, 1);
      expect(s.earnCoinsPerCurrency, 0);
      expect(s.maxSwingPct, 50);
      expect(s.maxSupply, 21000000);
      expect(s.signalTrading, isTrue);
      expect(s.referralEnabled, isTrue);
    });

    test('save validation and clamping', () {
      expect(const GetCoinSettings(coinsPerCurrency: 0).toSaveRow().error, 'Enter a rate greater than 0.');
      expect(const GetCoinSettings(earnCoinsPerCurrency: -1).toSaveRow().error, 'Enter a reward rate of 0 or more.');
      final row = const GetCoinSettings(coinsPerCurrency: 10, maxSwingPct: 200, maxSupply: -5).toSaveRow().row!;
      expect(row['id'], 'master');
      expect(row['coins_per_currency'], 10);
      expect(row['market_max_swing'], 95);
      expect(row['max_supply'], 0);
    });

    test('market rate sits at the peg when market pricing is off', () {
      final r = computeMarketRate(const GetCoinSettings(coinsPerCurrency: 10), const CoinMarketStats(tradeBuyGc: 1000));
      expect(r.ratePerGC, closeTo(0.1, 1e-9));
      expect(r.changePct, 0);
      expect(r.contributions, isEmpty);
    });

    test('market rate follows signals and is clamped to the swing', () {
      const s = GetCoinSettings(coinsPerCurrency: 10, marketEnabled: true, maxSwingPct: 5);
      final r = computeMarketRate(s, const CoinMarketStats(tradeBuyGc: 10000, commissionRevenue: 100000));
      expect(r.multiplier, closeTo(1.05, 1e-9));
      expect(r.changePct, 5);
      expect(r.contributions.map((c) => c.key), ['trading', 'revenue', 'services', 'signups', 'minting']);
      final down = computeMarketRate(s.copyWith(maxSwingPct: 50, signalTrading: false, signalRevenue: false),
          const CoinMarketStats(mintedGc: 9999));
      expect(down.multiplier, lessThan(1));
    });

    test('conversions and formatting', () {
      expect(coinsToCurrency(100, 10), 10);
      expect(coinsToCurrency(1, 0), 0);
      expect(currencyToCoins(1.5, 10), 15);
      expect(rideRewardCoins(25, 2), 50);
      expect(rideRewardCoins(0, 2), 0);
      expect(formatRate(10), '10');
      expect(formatRate(10.123456), '10.1235');
      expect(formatCoins(1250), '1,250 GC');
      expect(formatCoins(12.5), '12.50 GC');
      expect(parseLooseNumber('RM 1,000.5'), 1000.5);
      expect(parseLooseNumber(''), 0);
    });
  });

  // ---- Payment gateways & types -------------------------------------------

  group('payment gateways', () {
    test('secret credentials are never collected or written', () {
      final form = GatewayForm(providerId: 'stripe', accountName: ' Stripe MY ', credentials: {
        'publishableKey': 'pk_live_1',
        'secretKey': 'sk_live_should_not_be_written',
      });
      final r = buildGatewayValues(form);
      expect(r.error, isNull);
      expect(r.values!['stripe_publishableKey'], 'pk_live_1');
      expect(r.values!.containsKey('stripe_secretKey'), isFalse);
      expect(r.values!['providerName'], 'Stripe');
      expect(r.values!['accountName'], 'Stripe MY');
    });

    test('validates provider, account name and required public fields', () {
      expect(buildGatewayValues(GatewayForm(providerId: 'nope')).error, contains('provider'));
      expect(buildGatewayValues(GatewayForm(providerId: 'stripe')).error, contains('account name'));
      expect(buildGatewayValues(GatewayForm(providerId: 'stripe', accountName: 'x')).error, contains('Publishable Key'));
      // HitPay has only secret fields, so public config alone is enough.
      expect(buildGatewayValues(GatewayForm(providerId: 'hitpay', accountName: 'x')).error, isNull);
    });

    test('detects and strips stored secrets', () {
      final v = {'providerId': 'fiuu', 'fiuu_merchantId': 'm', 'fiuu_secretKey': 's', 'fiuu_verifyKey': ''};
      expect(storedSecretKeys(v), ['fiuu_secretKey']);
      expect(stripSecrets(v), {'providerId': 'fiuu', 'fiuu_merchantId': 'm'});
      expect(GatewayForm.fromValues(v).credentials, {'merchantId': 'm', 'callbackUrl': ''});
    });

    test('picker and default resolution', () {
      final entries = [
        (id: 'b', values: <String, dynamic>{'providerName': 'Stripe', 'accountName': 'B', 'active': true}),
        (id: 'a', values: <String, dynamic>{'providerName': 'Fiuu', 'accountName': 'A', 'isDefault': true, 'active': false}),
        (id: 'c', values: <String, dynamic>{'providerName': 'Billplz', 'accountName': 'C', 'isDefault': true}),
      ];
      expect(pickableGateways(entries).map((g) => g.id), ['c', 'b']);
      expect(resolveDefaultGateway(entries)!.id, 'c');
      expect(resolveDefaultGateway([entries[0]])!.id, 'b');
      expect(resolveDefaultGateway([]), isNull);
    });

    test('payment type writes the gateway reference keys', () {
      const g = SelectedGateway(id: 'g1', providerId: 'stripe', providerName: 'Stripe', accountName: 'MY', mode: 'Live');
      final r = buildPaymentTypeValues(name: ' Card ', code: 'CARD', enabled: true, gateway: g, existing: {'extra': 1});
      expect(r.values, {
        'extra': 1,
        'name': 'Card',
        'code': 'CARD',
        'enabled': true,
        'gatewayId': 'g1',
        'gatewayProviderId': 'stripe',
        'gatewayProviderName': 'Stripe',
        'gatewayAccountName': 'MY',
        'gatewayMode': 'Live',
      });
      expect(SelectedGateway.fromReference(r.values!)!.label, 'Stripe · MY (Live)');
      expect(buildPaymentTypeValues(name: '', code: '', enabled: true).error, 'Please fill in Name.');
      expect(gatewayReference(null)['gatewayId'], '');
    });
  });

  // ---- EV catalogue ---------------------------------------------------------

  group('EV order fee', () {
    final others = [(id: 'my', values: <String, dynamic>{'country': 'Malaysia', 'isDefault': true})];

    test('validates and rejects duplicate countries', () {
      expect(buildOrderFeeValues(country: '', currency: '', amount: '1', isDefault: false, active: true, others: others).error,
          'Please select a Country.');
      expect(
          buildOrderFeeValues(country: 'SG', currency: '', amount: 'x', isDefault: false, active: true, others: others).error,
          'Please enter a valid order fee amount.');
      expect(
          buildOrderFeeValues(country: 'malaysia', currency: '', amount: '1', isDefault: false, active: true, others: others)
              .error,
          contains('already exists'));
      final ok = buildOrderFeeValues(
          country: 'Malaysia', currency: '', amount: '3000', isDefault: true, active: true, others: others, editingId: 'my');
      expect(ok.values!['currency'], 'RM');
      expect(ok.values!['amount'], 3000);
      expect(ok.values!['gatewayId'], '');
    });

    test('Malaysia cannot be deleted; default sorts first', () {
      expect(canDeleteOrderFee({'country': 'Malaysia'}), isFalse);
      expect(canDeleteOrderFee({'country': 'Singapore'}), isTrue);
      final sorted = sortOrderFees([
        {'country': 'Brunei'},
        {'country': 'Malaysia', 'isDefault': true},
        {'country': 'Algeria'},
      ], (v) => v);
      expect(sorted.map((v) => v['country']), ['Malaysia', 'Algeria', 'Brunei']);
    });

    test('currency prefers the saved country entry, then the world list', () {
      final saved = [
        {'country': 'Malaysia', 'currencySymbol': 'RM'},
        {'country': 'Malaysia', 'state': 'Selangor', 'currencySymbol': 'X'},
      ];
      expect(resolveCurrencyForCountry('Malaysia', saved, worldCountryCurrencies), 'RM');
      expect(resolveCurrencyForCountry('Singapore', saved, worldCountryCurrencies), 'SGD');
      expect(resolveCurrencyForCountry('Atlantis', saved, worldCountryCurrencies), '');
    });
  });

  group('EV finance options', () {
    test('validation and value shape', () {
      ({Map<String, dynamic>? values, String? error}) build({String name = 'HP', String mode = 'Custom', String amount = '1200'}) =>
          buildFinanceOptionValues(
            name: name,
            type: 'Hire Purchase',
            country: 'Malaysia',
            paymentMode: mode,
            paymentAmount: amount,
            rate: '2.85',
            termValue: '60',
            termUnit: 'Month',
            details: ' x ',
            active: true,
            displayPriority: 3,
          );
      expect(build(name: ' ').error, 'Please fill in Plan Name.');
      expect(build(amount: '0').error, 'Please enter a valid custom payment amount.');
      final v = build().values!;
      expect(v['paymentAmount'], 1200);
      expect(v['rate'], 2.85);
      expect(v['termValue'], 60);
      expect(v['details'], 'x');
      expect(build(mode: 'Full Balance', amount: '').values!['paymentAmount'], 0);
      expect(financeOptionMeta(v), 'Pay: 1200 • Rate: 2.85% • Term: 60 Months');
      expect(financeOptionMeta({'paymentMode': 'Full Balance'}), 'Pay: Full Balance • Rate: — • Term: —');
    });

    test('reordering rewrites only the priorities that change', () {
      final sorted = [
        (id: 'a', values: <String, dynamic>{'displayPriority': 1}),
        (id: 'b', values: <String, dynamic>{'displayPriority': 2}),
        (id: 'c', values: <String, dynamic>{'displayPriority': 3}),
      ];
      expect(reorderPriorities(sorted, 'c', -1), {'c': 2, 'b': 3});
      expect(reorderPriorities(sorted, 'a', -1), isEmpty);
      expect(sortByPriority(<Map<String, dynamic>>[{'displayPriority': 2}, {}, {'displayPriority': 1}], (v) => v).map((v) => v['displayPriority']),
          [1, 2, null]);
    });
  });

  group('EV vehicle details & inventory', () {
    test('normalises item lists into the stored JSON strings', () {
      final f = VehicleDetailsForm(make: 'TEKSI', model: 'EV One', price: '150000', exteriorColors: [
        {'id': 'c1', 'name': ' White ', 'code': '#fff', 'enabled': true},
        {'id': 'c2', 'name': '', 'code': '', 'enabled': true},
      ], features: [
        {'id': 'f1', 'name': 'Roof', 'price': '1500.5', 'enabled': false},
        {'id': 'f2', 'name': ' ', 'price': '1', 'enabled': true},
      ]);
      f.setGallerySlot('storageImages', 3, 'data:x');
      f.setGallerySlot('exteriorImages', 1, 'data:y');
      final v = buildVehicleDetailsValues(f).values!;
      expect(v['price'], 150000);
      expect(jsonDecode(v['exteriorColors'] as String), [
        {'id': 'c1', 'name': 'White', 'code': '#fff', 'enabled': true},
      ]);
      expect(jsonDecode(v['features'] as String), [
        {'id': 'f1', 'name': 'Roof', 'price': 1500.5, 'enabled': false},
      ]);
      expect(jsonDecode(v['exteriorImages'] as String), ['data:y']);
      expect(jsonDecode(v['storageImages'] as String), isEmpty); // slot 3 is past the limit of 2
      expect(buildVehicleDetailsValues(VehicleDetailsForm(make: 'x')).error, 'Please fill in Make and Model.');
      final round = VehicleDetailsForm.fromValues(v);
      expect(round.exteriorColors.single['name'], 'White');
      expect(round.gallery['exteriorImages'], ['data:y']);
      expect(newItemId(), matches(RegExp(r'^i-[a-z0-9]{7}$')));
    });

    test('inventory snapshots the names of the chosen options', () {
      final vehicle = {
        'make': 'TEKSI',
        'model': 'EV One',
        'exteriorColors': jsonEncode([
          {'id': 'w', 'name': 'White', 'enabled': true},
          {'id': 'k', 'name': 'Black', 'enabled': false},
        ]),
        'features': jsonEncode([
          {'id': 'r', 'name': 'Roof', 'enabled': true},
        ]),
      };
      expect(enabledItems(vehicle, 'exteriorColors').map((c) => c['id']), ['w']);
      final r = buildInventoryValues(
        vehicleId: 'v1',
        vehicle: vehicle,
        vin: ' vin1 ',
        exteriorColorIds: ['w', 'k'],
        interiorColorIds: [],
        featureIds: ['r'],
        accessoryIds: [],
      );
      expect(r.values!['vin'], 'vin1');
      expect(r.values!['make'], 'TEKSI');
      expect(r.values!['exteriorColor'], 'White');
      expect(r.values!['features'], 'Roof');
      expect(r.values!['exteriorColorIds'], '["w","k"]');
      expect(parseIdList(r.values!['exteriorColorIds']), ['w', 'k']);
      expect(
          buildInventoryValues(vehicleId: '', vehicle: null, vin: 'x', exteriorColorIds: [], interiorColorIds: [], featureIds: [], accessoryIds: [])
              .error,
          'Please select a vehicle.');
      expect(
          buildInventoryValues(vehicleId: 'v', vehicle: vehicle, vin: ' ', exteriorColorIds: [], interiorColorIds: [], featureIds: [], accessoryIds: [])
              .error,
          'Please enter a VIN number.');
    });

    test('misc formatting', () {
      expect(groupedNumber(1234567), '1,234,567');
      expect(groupedNumber(1500.5), '1,500.5');
      expect(valuesMatch({'country': 'Malaysia', 'amount': 3000}, 'MALAY'), isTrue);
      expect(valuesMatch({'country': 'Malaysia'}, 'sing'), isFalse);
    });
  });
}
