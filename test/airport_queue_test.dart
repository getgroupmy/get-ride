import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/core/airport_queue.dart';
import 'package:get_ride/src/core/vehicle_onboarding.dart'
    show vehicleServiceChoice;
import 'package:latlong2/latlong.dart';

void main() {
  group('doors', () {
    final doors = [
      AirportDoor.fromGate('d1', {
        'placeId': 'a',
        'name': 'Door 5',
        'mode': 'drop',
        'displayPriority': 2,
      }),
      AirportDoor.fromGate('d2', {
        'placeId': 'a',
        'name': 'Door 3',
        'mode': 'pickup',
        'displayPriority': 1,
        'guide': [
          {'photo': 'p.jpg', 'text': 'Turn right'},
          {'text': 'Go out'},
        ],
      }),
      AirportDoor.fromGate('d3', {
        'placeId': 'a',
        'name': 'Door 2',
        'mode': 'both',
        'displayPriority': 3,
      }),
      AirportDoor.fromGate('d4', {
        'placeId': 'a',
        'name': 'Old',
        'mode': 'both',
        'active': false,
      }),
      AirportDoor.fromGate('d5', {
        'placeId': 'b',
        'name': 'Elsewhere',
        'mode': 'both',
      }),
    ];

    test('kinds read from the gate mode and back', () {
      expect(doorKindOf('pickup'), DoorKind.pick);
      expect(doorKindOf('drop'), DoorKind.drop);
      expect(doorKindOf(null), DoorKind.both);
      expect(doorKindOf('anything'), DoorKind.both);
      for (final k in DoorKind.values) {
        expect(doorKindOf(doorMode(k)), k);
      }
    });

    test('a drop-off lists drop and both doors, a pickup pick and both, active, of that airport, in order', () {
      expect(doorsFor(doors, 'a', AirportSide.drop).map((d) => d.id), [
        'd1',
        'd3',
      ]);
      expect(doorsFor(doors, 'a', AirportSide.pick).map((d) => d.id), [
        'd2',
        'd3',
      ]);
      expect(doorsFor(doors, 'b', AirportSide.pick).map((d) => d.id), ['d5']);
    });

    test('guides', () {
      expect(doors[1].guide, const [
        GuideStep(photo: 'p.jpg', text: 'Turn right'),
        GuideStep(text: 'Go out'),
      ]);
      expect(guideLinkLabel(doors[1]), 'How to get there · 2 steps ›');
      expect(guideLinkLabel(doors[0]), isNull);
      expect(moveStep([1, 2, 3], 0, 1), [2, 1, 3]);
      expect(moveStep([1, 2, 3], 0, -1), [1, 2, 3]);
      expect(moveStep([1, 2, 3], 2, 1), [1, 2, 3]);
    });
  });

  group('settings', () {
    test('a row reads and writes back', () {
      final s = AirportSettings.fromRow({
        'airport_id': 'a',
        'restrict_pickups': true,
        'pickup_from': ['queue', 'zone'],
        'empty_action': 'nearby',
        'nearby_after_min': 0,
        'pick_fee_on': true,
        'pick_fee_name': 'Airport pickup fee',
        'pick_fee_amount': 6,
        'fares': {
          'base': {'Comfort': 8},
          'band': {
            'on': true,
            'tiers': [
              {'uptoKm': 20, 'flat': 60},
              {'uptoKm': 10, 'flat': 45},
            ],
            'extra': 'all',
            'applies': 'pick',
          },
          'roundUp': false,
        },
      });
      expect(s.pickupFrom, {PickupSource.queue, PickupSource.zone});
      expect(s.emptyAction, EmptyAction.nearby);
      expect(s.pickFee.applied, 6);
      expect(s.dropFee.applied, 0);
      expect(s.fares.baseFor('comfort'), 8);
      expect(s.fares.band.tiers.map((t) => t.uptoKm), [10, 20]);
      expect(s.fares.band.extra, BandExtra.all);
      expect(s.fares.roundUp, isFalse);
      final back = AirportSettings.fromRow(s.toRow());
      expect(back.toRow(), s.toRow());
    });

    test('defaults: door required, queue, wait, 60 / 3 minutes, back on decline, round up', () {
      final s = AirportSettings.fromRow({'airport_id': 'a'});
      expect(s.pickDoorRequired && s.dropDoorRequired, isTrue);
      expect(s.pickupFrom, {PickupSource.queue});
      expect(s.emptyAction, EmptyAction.wait);
      expect(s.joinWindowMin, 60);
      expect(s.leaveGraceMin, 3);
      expect(s.backOnDecline, isTrue);
      expect(s.needDropoff, isTrue);
      expect(s.fares.roundUp, isTrue);
    });

    test('at least one pickup source stays on', () {
      expect(togglePickupSource({PickupSource.queue}, PickupSource.queue), {
        PickupSource.queue,
      });
      expect(togglePickupSource({PickupSource.queue}, PickupSource.zone), {
        PickupSource.queue,
        PickupSource.zone,
      });
      expect(
        togglePickupSource({
          PickupSource.queue,
          PickupSource.zone,
        }, PickupSource.queue),
        {PickupSource.zone},
      );
    });

    test('band tiers: add, remove (never the last), problems', () {
      final one = [const BandTier(uptoKm: 10, flat: 45)];
      final two = addBandTier(one);
      expect(two.last, const BandTier(uptoKm: 20, flat: 60));
      expect(removeBandTier(one, 0), one);
      expect(removeBandTier(two, 0), [const BandTier(uptoKm: 20, flat: 60)]);
      expect(bandTiersProblem(two), isNull);
      expect(
        bandTiersProblem(const [
          BandTier(uptoKm: 10, flat: 1),
          BandTier(uptoKm: 10, flat: 2),
        ]),
        isNotNull,
      );
      expect(bandTiersProblem(const [BandTier(uptoKm: 0, flat: 1)]), isNotNull);
    });
  });

  group('charges', () {
    const pick = AirportSettings(
      airportId: 'a',
      pickFee: AirportCharge(on: true, name: 'Pickup fee', amount: 6),
    );
    const drop = AirportSettings(
      airportId: 'b',
      dropFee: AirportCharge(on: true, name: 'Airport fee', amount: 2.5),
    );
    test('the drop-off airport charge, then the pickup one; off or zero adds nothing', () {
      expect(airportCharges(pickAirport: pick), [
        (name: 'Pickup fee', amount: 6.0),
      ]);
      expect(airportCharges(dropAirport: drop), [
        (name: 'Airport fee', amount: 2.5),
      ]);
      expect(
        airportCharges(
          pickAirport: pick,
          dropAirport: drop,
        ).map((c) => c.amount),
        [2.5, 6.0],
      );
      expect(airportCharges(pickAirport: drop, dropAirport: pick), isEmpty);
      expect(const AirportCharge(on: true, amount: 0).applied, 0);
      expect(const AirportCharge(on: false, amount: 5).applied, 0);
    });
  });

  group('fares (as the SQL test)', () {
    const fares = AirportFares(
      base: {'comfort': 8},
      minPick: MinFare(on: true, amount: 35),
      minDrop: MinFare(on: true, amount: 30),
      band: DistanceBand(
        on: true,
        tiers: [BandTier(uptoKm: 10, flat: 45), BandTier(uptoKm: 20, flat: 60)],
        extra: BandExtra.extra,
        applies: BandApplies.both,
      ),
    );
    const fee = [(name: 'Airport pickup fee', amount: 6.0)];
    AirportQuote q({
      AirportFares f = fares,
      AirportSide side = AirportSide.pick,
      double km = 5,
      String service = 'Comfort',
      double normal = 20,
      ({String name, double amount})? zone,
      List<AirportChargeLine> charges = fee,
    }) => quoteAirportFare(
      fares: f,
      side: side,
      service: service,
      km: km,
      normal: normal,
      perKm: 1.5,
      zoneFare: zone,
      charges: charges,
    );

    test('a zone fare beats the band', () {
      final z = q(km: 30, zone: (name: 'City', amount: 80));
      expect(z.total, 94);
      expect(z.fare, 88);
      expect(z.charge, 6);
      expect(z.fixed, isTrue);
      expect(z.how, 'Fixed fare, City from the airport');
      expect(
        q(
          side: AirportSide.drop,
          km: 30,
          zone: (name: 'City', amount: 75),
          charges: const [],
        ).total,
        83,
      );
    });

    test('each tier, at its limit and past it', () {
      expect(q(km: 5).total, 59);
      expect(q(km: 10).total, 59, reason: 'exactly 10 km is the first tier');
      expect(q(km: 10.5).total, 74);
      expect(q(km: 20).total, 74, reason: 'exactly 20 km is the second tier');
    });

    test('past the last tier: the km past it, or the whole trip', () {
      final extra = q(km: 25);
      expect(extra.total, 82);
      expect(extra.fare, 76);
      expect(extra.lines.last, (
        label: 'Rounded up',
        amount: 0.5,
        charge: false,
      ));
      final all = q(
        f: fares.copyWith(band: fares.band.copyWith(extra: BandExtra.all)),
        km: 25,
      );
      expect(all.total, 112);
    });

    test('option charges (0248): after the minimum, before the airport charge, kept in the fare', () {
      final withPet = quoteAirportFare(
        fares: fares,
        side: AirportSide.pick,
        service: 'Comfort',
        km: 5,
        normal: 20,
        perKm: 1.5,
        charges: fee,
        options: const [(name: 'Pet charge', amount: 10.0)],
      );
      expect(withPet.total, 69);
      expect(withPet.fare, 63);
      expect(withPet.lines.map((l) => l.label), [
        'Flat fare up to 10 km',
        'Comfort airport base',
        'Pet charge',
        'Airport pickup fee',
      ]);
      final noBand = fares.copyWith(band: fares.band.copyWith(on: false));
      final min = quoteAirportFare(
        fares: noBand,
        side: AirportSide.drop,
        service: 'Ride',
        km: 5,
        normal: 12.4,
        perKm: 1.5,
        options: const [(name: 'Assistance charge', amount: 4.2)],
      );
      expect(
        min.total,
        35,
        reason: 'minimum 30 without the options, + 4.20, rounded up',
      );
    });

    test('round-up off keeps the cents', () {
      expect(q(f: fares.copyWith(roundUp: false), km: 25).total, 81.5);
    });

    test('a band for drop-offs only leaves pickups on the normal fare, raised to the minimum', () {
      final dropOnly = fares.copyWith(
        band: fares.band.copyWith(applies: BandApplies.drop),
      );
      final p = q(f: dropOnly);
      expect(p.total, 41);
      expect(p.fixed, isFalse);
      expect(
        p.lines.map((l) => l.label),
        contains('Raised to the pickup minimum'),
      );
      expect(
        q(f: dropOnly, side: AirportSide.drop, charges: const []).total,
        53,
      );
    });

    test('the drop-off minimum; no base for another service', () {
      final noBand = fares.copyWith(band: fares.band.copyWith(on: false));
      expect(
        q(
          f: noBand,
          side: AirportSide.drop,
          service: 'Ride',
          normal: 12.4,
          charges: const [],
        ).total,
        30,
      );
      expect(
        q(
          f: noBand,
          side: AirportSide.drop,
          service: 'Ride',
          normal: 31.2,
          charges: const [],
        ).total,
        32,
      );
      expect(
        q(
          f: noBand,
          side: AirportSide.drop,
          service: 'COMFORT',
          normal: 31.2,
          charges: const [],
        ).total,
        40,
        reason: 'the base is found whatever the case',
      );
    });

    test('the breakdown reads the server\'s stamp', () {
      final quote = AirportQuote.fromJson({
        'lines': [
          {'label': 'Flat fare up to 10 km', 'amount': 45},
          {'label': 'Airport pickup fee', 'amount': 6, 'charge': true},
        ],
        'fare': 53,
        'charge': 6,
        'total': 59,
        'fixed': true,
      })!;
      expect(quote.total, 59);
      expect(quote.lines.last.charge, isTrue);
      expect(AirportQuote.fromJson(null), isNull);
    });
  });

  group('the queue', () {
    final now = DateTime.utc(2026, 10, 20, 10);
    QueuePlace p(String id, int minAgo, {String service = 'Comfort'}) =>
        QueuePlace(
          driverId: id,
          placeAt: now.subtract(Duration(minutes: minAgo)),
          joinedAt: now,
          service: service,
        );

    test('who may join: a drop-off within the window, or none needed', () {
      expect(
        canJoinQueue(
          needDropoff: true,
          now: now,
          dropoffAt: now.subtract(const Duration(minutes: 30)),
          joinWindowMin: 60,
        ),
        isTrue,
      );
      expect(
        canJoinQueue(
          needDropoff: true,
          now: now,
          dropoffAt: now.subtract(const Duration(minutes: 61)),
          joinWindowMin: 60,
        ),
        isFalse,
      );
      expect(
        canJoinQueue(needDropoff: true, now: now, joinWindowMin: 60),
        isFalse,
      );
      expect(
        canJoinQueue(needDropoff: false, now: now, joinWindowMin: 60),
        isTrue,
      );
      expect(
        minutesLeftToJoin(now.subtract(const Duration(minutes: 20)), now, 60),
        40,
      );
      expect(
        minutesLeftToJoin(now.subtract(const Duration(minutes: 90)), now, 60),
        0,
      );
    });

    test('the earliest drop-off first; one line per service', () {
      final q = [p('b', 10), p('a', 20), p('c', 5, service: 'Ride')];
      expect(queueOrder(q).map((x) => x.driverId), ['a', 'b', 'c']);
      expect(queueOrder(q, service: 'comfort').map((x) => x.driverId), [
        'a',
        'b',
      ]);
      expect(queueOrder(q, service: 'Ride').map((x) => x.driverId), ['c']);
      expect(queueOrder(q, service: 'Ride', byService: false).length, 3);
    });

    test('a declined or missed offer sends the driver to the back, or keeps the place when off', () {
      final q = [p('a', 20), p('b', 10)];
      expect(
        queueOrder(afterRefusal(q, 'a', backOnDecline: true, now: now))
            .map((x) => x.driverId),
        ['b', 'a'],
      );
      expect(
        queueOrder(afterRefusal(q, 'a', backOnDecline: false, now: now))
            .map((x) => x.driverId),
        ['a', 'b'],
      );
    });

    test(
      'who is offered next: the queue in order, then the zone nearest first',
      () {
        final q = [p('a', 20), p('b', 10)];
        final zone = [
          (driverId: 'z2', km: 0.4, service: 'comfort'),
          (driverId: 'z1', km: 0.1, service: 'comfort'),
        ];
        expect(
          nextOffer(
            from: {PickupSource.queue},
            queue: q,
            inZone: zone,
            alreadyOffered: {},
          ).drivers,
          ['a'],
        );
        expect(
          nextOffer(
            from: {PickupSource.queue},
            queue: q,
            inZone: zone,
            alreadyOffered: {'a'},
          ).drivers,
          ['b'],
        );
        expect(
          nextOffer(
            from: {PickupSource.queue},
            queue: q,
            inZone: zone,
            alreadyOffered: {'a', 'b'},
          ).stage,
          isNull,
        );
        expect(
          nextOffer(
            from: {PickupSource.zone},
            queue: q,
            inZone: zone,
            alreadyOffered: {},
          ).drivers,
          ['z1', 'z2'],
        );
        final both = nextOffer(
          from: {PickupSource.queue, PickupSource.zone},
          queue: q,
          inZone: zone,
          alreadyOffered: {'a', 'b'},
        );
        expect(both.stage, PickupSource.zone);
        expect(
          nextOffer(
            from: {PickupSource.queue},
            queue: [p('r', 30)],
            inZone: const [],
            alreadyOffered: {},
            riderId: 'r',
          ).stage,
          isNull,
          reason: 'never to the rider',
        );
      },
    );

    test('nobody to offer it to', () {
      expect(emptyOutcome(EmptyAction.wait, 5), EmptyOutcome.waits);
      expect(emptyOutcome(EmptyAction.decline, 5), EmptyOutcome.declined);
      expect(emptyOutcome(EmptyAction.nearby, 5), EmptyOutcome.nearbyLater);
      expect(emptyOutcome(EmptyAction.nearby, 0), EmptyOutcome.nearbyNow);
    });
  });

  group('the driver\'s state', () {
    test('messages', () {
      expect(
        DriverAirportState.fromJson({
          'state': 'dropped',
          'code': 'KUL',
          'service': 'Comfort',
          'minutes_left': 42,
        }).message,
        'Go to the waiting zone within 42 min to join the Comfort queue.',
      );
      final q = DriverAirportState.fromJson({
        'state': 'queued',
        'position': 2,
        'total': 5,
        'service': 'Comfort',
      });
      expect(q.title, 'In the Comfort queue');
      expect(q.message, 'of 5 waiting · stay in the zone to keep your place');
      expect(
        DriverAirportState.fromJson({'state': 'refused', 'code': 'KUL'})
            .message,
        'Only drivers who dropped off at KUL can wait for airport orders.',
      );
      expect(
        DriverAirportState.fromJson({'state': 'around'}).message,
        'Go to the waiting zone to receive airport orders.',
      );
      expect(
        DriverAirportState.fromJson({
          'state': 'offer',
          'door': 'Arrivals, Door 3',
        }).message,
        'Arrivals, Door 3',
      );
      expect(DriverAirportState.fromJson(null).showCard, isFalse);
    });
  });

  group('service lines (as airport_line_gap / airport_queue_lineup)', () {
    // Ride < Comfort < 6-seater < Premium.
    const order = ServiceOrder(['ride', 'comfort', 'six', 'premium']);
    final now = DateTime.utc(2026, 10, 20, 10);
    QueuePlace p(String id, int minAgo, String service) => QueuePlace(
      driverId: id,
      placeAt: now.subtract(Duration(minutes: minAgo)),
      joinedAt: now,
      service: service,
    );
    final q = [
      p('dR', 30, 'ride'),
      p('dC', 40, 'comfort'),
      p('dP', 50, 'premium'),
      p('dX', 60, ''),
    ];

    test('a higher service may take a lower one, never the reverse', () {
      expect(order.lineGap('ride', 'ride'), 0);
      expect(order.lineGap('premium', 'ride'), 3);
      expect(order.lineGap('comfort', 'ride'), 1);
      expect(order.lineGap('ride', 'premium'), isNull);
      expect(
        order.lineGap('', 'ride'),
        isNull,
        reason: 'a vehicle without a service',
      );
      expect(order.lineGap('unranked', 'ride'), isNull);
      expect(
        order.lineGap('premium', null),
        0,
        reason: 'a ride of an unknown service',
      );
      expect(order.canTake('six', 'comfort'), isTrue);
      expect(order.canTake('comfort', 'six'), isFalse);
    });

    test(
      'the offer order: own line first, then each higher line, each by place',
      () {
        List<String> ids(String ride, {bool by = true}) => [
          for (final x in airportLineup(
            q,
            rideService: ride,
            order: order,
            byService: by,
          ))
            x.driverId,
        ];
        expect(ids('ride'), ['dR', 'dC', 'dP']);
        expect(ids('ride', by: false), [
          'dP',
          'dC',
          'dR',
        ], reason: 'one queue: by place only');
        expect(ids('comfort'), ['dC', 'dP']);
        expect(ids('premium'), ['dP']);
        expect(ids('six'), ['dP']);
      },
    );

    test('next offer follows the lines, and zone drivers by their service', () {
      final zone = [
        (driverId: 'zR', km: 0.1, service: 'ride'),
        (driverId: 'zP', km: 0.5, service: 'premium'),
      ];
      expect(
        nextOffer(
          from: {PickupSource.queue},
          queue: q,
          inZone: zone,
          alreadyOffered: {},
          rideService: 'ride',
          order: order,
        ).drivers,
        ['dR'],
      );
      expect(
        nextOffer(
          from: {PickupSource.queue},
          queue: q,
          inZone: zone,
          alreadyOffered: {'dR'},
          rideService: 'ride',
          order: order,
        ).drivers,
        ['dC'],
      );
      expect(
        nextOffer(
          from: {PickupSource.zone},
          queue: q,
          inZone: zone,
          alreadyOffered: {},
          rideService: 'premium',
          order: order,
        ).drivers,
        ['zP'],
      );
    });

    test('the admin list: ranked first, then the rest; moving one', () {
      final o = ServiceOrder.arrange(
        ['comfort', 'gone', 'ride'],
        ['ride', 'comfort', 'premium'],
      );
      expect(o.ids, ['comfort', 'ride', 'premium']);
      expect(o.moved(0, 1).ids, ['ride', 'comfort', 'premium']);
      expect(o.moved(2, 0).ids, ['premium', 'comfort', 'ride']);
      expect(o.rankOf('premium'), 3);
      expect(o.rankOf('nope'), isNull);
    });

    test('no service: told why', () {
      expect(
        DriverAirportState.fromJson({
          'state': 'refused',
          'reason': 'no_service',
          'code': 'KUL',
        }).message,
        startsWith('Your vehicle has no approved service type yet'),
      );
    });

    test(
      'a vehicle\'s service: the make & model\'s, else the driver\'s choice',
      () {
        expect(vehicleServiceChoice(mapped: 'm', chosen: 'c').serviceId, 'm');
        expect(vehicleServiceChoice(mapped: '', chosen: 'c').serviceId, 'c');
        expect(vehicleServiceChoice(mapped: '', chosen: '').problem, isNotNull);
      },
    );
  });

  group('zone outlines', () {
    test('a large outline is simplified on save, keeping its source', () {
      final ring = [
        for (var i = 0; i < 2000; i++)
          LatLng(3 + 0.1 * _sin(i), 101 + 0.1 * _cos(i)),
      ];
      final big = BoundaryShape(
        coords: ring,
        polygons: [ring],
        bbox: BBox.ofPoints(ring),
        source: 'osm',
      );
      final small = simplifyShape(big);
      expect(
        small.rings.fold<int>(0, (n, r) => n + r.length),
        lessThanOrEqualTo(zoneMaxPoints),
      );
      expect(small.source, 'osm');
      expect(shapeFromRegion(small, RegionLevel.city).source, 'region:city');
      final tiny = boundaryFromDraft(const [
        LatLng(0, 0),
        LatLng(0, 1),
        LatLng(1, 1),
      ])!;
      expect(simplifyShape(tiny), tiny);
    });
  });
}

double _wobble(int i) => 1 + 0.01 * ((i % 7) - 3);
double _sin(int i) => _wobble(i) * math.sin(i / 2000 * 2 * math.pi);
double _cos(int i) => _wobble(i) * math.cos(i / 2000 * 2 * math.pi);
