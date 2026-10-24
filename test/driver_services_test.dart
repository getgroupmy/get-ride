// Driver services (migration 0263), the rules without a screen: keys, why a
// service is greyed out, the lock that decides (most specific first; an
// expired one counts for nothing), what is on, the page's rows, street hail
// at the meter and the admin form's payload.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/driver_services.dart';
import 'package:get_ride/src/core/ride_option_settings.dart' show RideOptionKind;

ServiceFacts _svc(
  String name, {
  String? id,
  List<String> types = const ['Car'],
  int? pax,
  bool partnerOk = true,
  bool orderOk = true,
  bool permitMissing = false,
  bool on = true,
  ServiceLock? lock,
}) => ServiceFacts(
  id: id ?? name.toLowerCase(),
  name: name,
  typeNames: types,
  maxPax: pax,
  partnerOk: partnerOk,
  orderOk: orderOk,
  permitMissing: permitMissing,
  on: on,
  lock: lock,
);

LockRule _lock(
  LockScope scope,
  String key,
  bool on, {
  String? driver,
  String? type,
  String? fleet,
  String? country,
  String? state,
  String? city,
  DateTime? until,
  DateTime? at,
}) => LockRule(
  id: '${scope.id}-$key-$on',
  scope: scope,
  serviceKey: key,
  on: on,
  driverId: driver,
  partnerType: type,
  fleetId: fleet,
  country: country,
  state: state,
  city: city,
  until: until,
  updatedAt: at ?? DateTime.utc(2026, 10, 1),
);

void main() {
  final now = DateTime.utc(2026, 10, 21, 8);
  final subject = LockSubject(
    driverId: 'd1',
    fleetIds: ['f1'],
    partnerTypes: [' E-Hailing '],
    countries: ['Malaysia'],
    states: ['Selangor'],
    cities: ['Shah Alam'],
  );

  group('keys', () {
    test('a service by its name as the database compares it; street hail and add-ons as they are', () {
      expect(DriverServiceKey.service(' 6-Seater '), '6seater');
      expect(DriverServiceKey.normalise('Comfort Plus'), 'comfortplus');
      expect(DriverServiceKey.normalise(' HAIL:Meter '), 'hail:meter');
      expect(DriverServiceKey.extra('Child-Seat'), 'extra:child-seat');
      expect(DriverServiceKey.extraOf('extra:pet:dog'), 'pet:dog');
      expect(DriverServiceKey.extraOf('ride'), isNull);
    });
  });

  group('why a service is greyed out', () {
    final own = _svc('Ride', pax: 4);

    test('the Partner Service type comes first', () {
      expect(ineligibleReason(_svc('Teksi', partnerOk: false, permitMissing: true), own: own), 'Not in your Partner Service type');
      // 0288: paused for this car, with the server's reason.
      final paused = ServiceFacts.fromJson(const {
        'id': 'p',
        'name': 'Premium',
        'vehicle_block': {'status': 'paused_age', 'type': 'eHailing', 'max_age_years': 15},
      });
      expect(ineligibleReason(paused, own: own), 'eHailing paused: vehicle over the 15-year limit');
      final waiting = ServiceFacts.fromJson(const {
        'id': 'p',
        'name': 'Premium',
        'vehicle_block': {'status': 'waiting_permit', 'type': 'eHailing', 'permit_name': 'EVP'},
      });
      expect(ineligibleReason(waiting, own: own), 'eHailing waiting for the vehicle permit');
      expect(ServiceFacts.fromJson(const {'id': 'r', 'name': 'Ride', 'vehicle_block': null}).vehicleBlock, isNull);
    });

    test('seats and class only while the service order applies to every booking', () {
      final six = _svc('6-seater', pax: 6, orderOk: false);
      final premium = _svc('Premium', pax: 4, orderOk: false);
      expect(ineligibleReason(six, own: own, orderEnforced: true), 'This car has 4 seats');
      expect(ineligibleReason(premium, own: own, orderEnforced: true), 'Needs a premium car');
      expect(ineligibleReason(six, own: null, orderEnforced: true), "Your car's service isn't approved yet");
      expect(ineligibleReason(six, own: own), isNull, reason: 'the server takes any service while the order is off');
    });

    test('then a missing permit, then the region', () {
      expect(ineligibleReason(_svc('Comfort', permitMissing: true), own: own), 'Permit missing');
      expect(ineligibleReason(_svc('Comfort'), own: own, regionOk: false), 'Not offered in your area');
      expect(ineligibleReason(_svc('Comfort'), own: own), isNull);
    });
  });

  group('the lock that decides', () {
    test('most specific first: driver, fleet, city, state, country, Partner Service type, everyone', () {
      final locks = [
        _lock(LockScope.everyone, 'comfort', false),
        _lock(LockScope.partnerType, 'comfort', true, type: 'ehailing'),
        _lock(LockScope.region, 'comfort', false, country: 'malaysia'),
        _lock(LockScope.region, 'comfort', true, country: 'Malaysia', state: 'Selangor'),
        _lock(LockScope.region, 'comfort', false, country: 'Malaysia', state: 'Selangor', city: 'Shah Alam'),
        _lock(LockScope.fleet, 'comfort', true, fleet: 'f1'),
        _lock(LockScope.driver, 'comfort', false, driver: 'd1'),
      ];
      final order = <LockScope>[];
      final rest = [...locks];
      while (rest.isNotEmpty) {
        final w = winningLock(rest, subject, 'Comfort', now)!;
        order.add(w.scope);
        rest.remove(w);
      }
      expect(order, [
        LockScope.driver,
        LockScope.fleet,
        LockScope.region,
        LockScope.region,
        LockScope.region,
        LockScope.partnerType,
        LockScope.everyone,
      ]);
      expect(lockRank(locks[4], subject), 32, reason: 'a city');
      expect(lockRank(locks[3], subject), 31, reason: 'a state');
      expect(lockRank(locks[2], subject), 30, reason: 'a country, any case');
      expect(lockRank(locks[1], subject), 20, reason: 'the Partner Service type as its key');
    });

    test("locks for others don't apply", () {
      final locks = [
        _lock(LockScope.driver, 'ride', false, driver: 'd2'),
        _lock(LockScope.fleet, 'ride', false, fleet: 'f9'),
        _lock(LockScope.region, 'ride', false, country: 'Malaysia', state: 'Penang'),
        _lock(LockScope.partnerType, 'ride', false, type: 'teksi'),
      ];
      expect(winningLock(locks, subject, 'Ride', now), isNull);
      expect(serviceOnFor(locks, subject, 'Ride', now), isTrue);
    });

    test('an expired lock counts for nothing; one still running does', () {
      final locks = [
        _lock(LockScope.driver, 'ride', true, driver: 'd1', until: now.subtract(const Duration(minutes: 1))),
        _lock(LockScope.everyone, 'ride', false, until: now.add(const Duration(days: 3))),
      ];
      expect(winningLock(locks, subject, 'ride', now)!.scope, LockScope.everyone);
      expect(serviceOnFor(locks, subject, 'ride', now, pref: true), isFalse);
    });

    test('of two equals, the latest', () {
      final a = _lock(LockScope.everyone, 'ride', true, at: DateTime.utc(2026, 10, 1));
      final b = LockRule(id: 'b', scope: LockScope.everyone, serviceKey: 'ride', on: false, updatedAt: DateTime.utc(2026, 10, 2));
      expect(winningLock([a, b], subject, 'ride', now)!.id, 'b');
    });
  });

  group('what is on', () {
    test('a lock, else the switch for this car, else on', () {
      expect(effectiveOn(), isTrue);
      expect(effectiveOn(pref: false), isFalse);
      expect(effectiveOn(pref: false, lock: const ServiceLock(on: true)), isTrue);
      expect(effectiveOn(pref: true, lock: const ServiceLock(on: false)), isFalse);
    });

    test('the server read', () {
      final o = DriverServicesOverview.fromJson({
        'vehicle': {'id': 'v1', 'plate': 'WXY 1234', 'make': 'Perodua', 'model': 'Bezza', 'color': 'Silver',
          'vehicle_type': 'Sedan', 'energy': 'Petrol', 'service_id': 'r'},
        'types': ['eHailing'],
        'order_enforced': true,
        'services': [
          {'id': 'r', 'name': 'Ride', 'types': ['Car'], 'max_pax': 4, 'partner_ok': true, 'order_ok': true, 'pref': false,
            'on': false, 'lock': null},
          {'id': 'p', 'name': 'Premium', 'types': '["Car"]', 'max_pax': '4', 'partner_ok': true, 'order_ok': false,
            'on': true, 'lock': {'mode': 'on', 'until': '2026-11-01T00:00:00Z', 'scope': 'region'}},
        ],
        'keys': {'hail:meter': {'pref': false, 'lock': null, 'on': false}},
      });
      expect(o.car!.title, 'Perodua Bezza · Silver');
      expect(o.carDetails, 'eHailing · Sedan · Petrol');
      expect(o.own!.name, 'Ride');
      expect(o.services.first.pref, isFalse);
      expect(o.services[1].lock!.on, isTrue);
      expect(o.services[1].lock!.scope, LockScope.region);
      expect(o.services[1].maxPax, 4);
      expect(o.services[1].typeNames, ['Car'], reason: 'a list kept as a JSON string');
      expect(o.key(DriverServiceKey.hailMeter).on, isFalse);
      expect(o.key(DriverServiceKey.hailDestination).on, isTrue, reason: 'never set: on');
      expect(servicesPageAvailable(o), isTrue);
      expect(servicesPageAvailable(const DriverServicesOverview()), isFalse, reason: 'no car in use');
      expect(DriverServicesOverview.fromJson({'vehicle': null}).car, isNull);
    });
  });

  group('the page', () {
    DriverServicesOverview overview({List<ServiceFacts>? services, Map<String, KeyState> keys = const {}}) =>
        DriverServicesOverview(
          car: const DriverCar(id: 'v1', plate: 'WXY 1234', serviceId: 'ride'),
          orderEnforced: true,
          services: services ??
              [
                _svc('Ride', pax: 4, on: false),
                _svc('6-seater', pax: 6, orderOk: false),
                _svc('Comfort', lock: const ServiceLock(on: false)),
                _svc('Teksi', partnerOk: false),
                _svc('Delivery', types: ['Delivery']),
                _svc('Food', types: ['Food']),
              ],
          keys: keys,
        );
    const addOns = <AddOnGroup>[
      (option: RideOptionKind.childSeat, title: 'Child safety seat', items: [(key: 'child-seat', label: 'Child safety seat')]),
      (option: RideOptionKind.pet, title: 'Pet with me', items: [(key: 'pet:dog', label: 'Dog')]),
      (option: RideOptionKind.assistance, title: 'Assistance', items: [(key: 'assist:guide-dog', label: 'Guide dog')]),
    ];

    test('tabs: deliveries by name or by every master service', () {
      expect(serviceTabFor('Ride', ['Car']), ServiceTab.transport);
      expect(serviceTabFor('Mart', const []), ServiceTab.deliveries);
      expect(serviceTabFor('Express', ['Delivery', 'Food']), ServiceTab.deliveries);
      expect(serviceTabFor('Express', ['Delivery', 'Car']), ServiceTab.transport);
      expect(firstTab(overview()), ServiceTab.transport);
      expect(
        firstTab(overview(services: [_svc('Ride', partnerOk: false), _svc('Delivery', types: ['Delivery'])])),
        ServiceTab.deliveries,
        reason: 'a delivery-only Partner Service type opens on Deliveries',
      );
    });

    test('Transport: what the car can do first, then the greyed ones; street hail; add-ons', () {
      final s = servicesPageSections(
        overview(keys: {DriverServiceKey.hailDestination: const KeyState(lock: ServiceLock(on: true), on: true)}),
        ServiceTab.transport,
        addOns: addOns,
        extrasOff: {'pet:dog'},
      );
      expect([for (final x in s) x.title], ['Main services', 'Street hail', 'Add-ons']);
      final main = s[0].rows;
      expect([for (final r in main) r.title], ['Ride', 'Comfort', '6-seater', 'Teksi']);
      expect(main[0].on, isFalse);
      expect(main[0].switchable, isTrue);
      expect(main[1].lock!.on, isFalse);
      expect(main[1].switchable, isFalse, reason: 'locked');
      expect(main[2].reason, 'This car has 4 seats');
      expect(main[2].shownOn, isFalse, reason: 'greyed out shows off');
      expect(main[3].reason, 'Not in your Partner Service type');
      final hail = s[1].rows;
      expect(hail[0].key, DriverServiceKey.hailMeter);
      expect(hail[1].lock!.on, isTrue);
      final extras = s[2].rows;
      expect([for (final r in extras) r.key], ['extra:child-seat', 'extra:pet:dog', 'extra:assist:guide-dog']);
      expect(extras[0].title, 'Child safety seat');
      expect(extras[1].title, 'Dog');
      expect(extras[1].on, isFalse, reason: "the driver's own add-on list");
      expect(extras[2].on, isTrue);
      expect(extras[2].switchable, isTrue, reason: 'the guide dog may be turned off, as 0253');
    });

    test('an add-on lock wins over the driver list', () {
      final s = servicesPageSections(
        overview(keys: {'extra:pet:dog': const KeyState(lock: ServiceLock(on: true))}),
        ServiceTab.transport,
        addOns: addOns,
        extrasOff: {'pet:dog'},
      );
      final dog = s.last.rows.firstWhere((r) => r.key == 'extra:pet:dog');
      expect(dog.on, isTrue);
      expect(dog.switchable, isFalse);
    });

    test('Deliveries: their main services only', () {
      final s = servicesPageSections(overview(), ServiceTab.deliveries, addOns: addOns);
      expect(s.length, 1);
      expect([for (final r in s.single.rows) r.title], ['Delivery', 'Food']);
    });

    test('a service the region does not offer is greyed out', () {
      final s = servicesPageSections(overview(), ServiceTab.deliveries, regionOff: {'food'});
      expect(s.single.rows.last.reason, 'Not offered in your area');
    });
  });

  group('words', () {
    test('the toast and the padlock', () {
      expect(serviceToggleToast('Ride', true), "Ride on. You'll get these requests.");
      expect(serviceToggleToast('Ride', false), "Ride off. You won't get these requests.");
      expect(lockLabel(const ServiceLock(on: true)), 'Kept on by get.ride');
      expect(lockLabel(const ServiceLock(on: false)), 'Kept off by get.ride');
      expect(lockedServiceMessage, 'Set by get.ride. Contact support to change it.');
      for (final s in [servicesFooter, lockedServiceMessage]) {
        expect(s.contains('→'), isFalse);
      }
    });
  });

  group('street hail at the meter', () {
    test('unknown lets it start', () {
      expect(const HailGate().refusal(withDestination: true), isNull);
      expect(HailGate.of(null).refusal(), isNull);
    });

    test('the meter off stops every hire; the destination only one with a destination', () {
      const meterOff = HailGate(meter: KeyState(on: false, pref: false));
      expect(meterOff.refusal()!.title, 'Meter (street hail) is off');
      expect(meterOff.refusal()!.message, contains('Turn it on in Services'));
      const destOff = HailGate(destination: KeyState(on: false, lock: ServiceLock(on: false)));
      expect(destOff.refusal(), isNull);
      expect(destOff.refusal(withDestination: true)!.message, contains('get.ride keeps'));
      expect(destOff.destinationRefusal(), isNotNull);
    });
  });

  group('admin', () {
    test('targets compare as the database does', () {
      const a = LockTarget(scope: LockScope.partnerType, partnerType: 'E-Hailing');
      const b = LockTarget(scope: LockScope.partnerType, partnerType: 'ehailing');
      expect(a, b);
      const r = LockTarget(scope: LockScope.region, country: 'Malaysia', state: 'Selangor');
      expect(r.regionLabel, 'Selangor, Malaysia');
      expect(r.toJson(), {'scope': 'region', 'country': 'Malaysia', 'state': 'Selangor'});
      expect(const LockTarget.everyone().toJson(), {'scope': 'everyone'});
    });

    test('the form for a saved target, and what Save sends', () {
      const t = LockTarget(scope: LockScope.driver, driverId: 'd1');
      final rules = [
        _lock(LockScope.driver, 'ride', false, driver: 'd1'),
        _lock(LockScope.driver, 'hail:meter', true, driver: 'd1'),
        _lock(LockScope.driver, 'ride', true, driver: 'd2'),
      ];
      final choices = choicesFor(t, rules);
      expect(choices, {'ride': LockChoice.off, 'hail:meter': LockChoice.on});
      expect(lockRulesPayload(['Ride', 'Comfort', 'hail:meter'], choices), {
        'ride': 'off',
        'comfort': 'driver',
        'hail:meter': 'on',
      });
      final groups = groupLocks(rules);
      expect(groups.length, 2);
      expect(groups.firstWhere((g) => g.target == t).locks.length, 2);
    });

    test('a key in words', () {
      final names = {'ride': 'Ride'};
      expect(describeServiceKey('ride', names), 'Ride');
      expect(describeServiceKey('hail:meter', names), 'Meter (street hail)');
      expect(describeServiceKey('extra:pet:dog', names), 'Pet: dog');
      expect(describeServiceKey('extra:child-seat', names), 'child seat');
    });
  });
}
