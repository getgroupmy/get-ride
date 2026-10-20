// Order dispatch (migration 0251): the pure rules the console, the admin
// pages and the driver's card share, mirroring the server's
// (supabase/tests/order_dispatch_0251.sql checks the same numbers).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/dispatch.dart';
import 'package:get_ride/src/core/trip_receipt.dart';
import 'package:get_ride/src/features/dispatch/dispatch_ticket.dart' show dispatchTicketText;
import 'package:get_ride/src/features/partner/stand_order_label.dart';
import 'package:get_ride/src/data/models.dart';

void main() {
  group('ticket numbers', () {
    test('the stand code and at least four digits', () {
      expect(formatTicketNo('PAV', 1), 'PAV-0001');
      expect(formatTicketNo('PAV', 41), 'PAV-0041');
      expect(formatTicketNo('TBS', 12345), 'TBS-12345');
    });
    test('a stand code is 2 to 6 letters or digits', () {
      expect(isStandCode('pav'), isTrue);
      expect(isStandCode('KLCC01'), isTrue);
      expect(isStandCode('P'), isFalse);
      expect(isStandCode('PAV-1'), isFalse);
      expect(isStandCode('TOOLONG7'), isFalse);
    });
  });

  group('fees', () {
    test('fixed, or a percentage rounded to the sen', () {
      expect(feeAmount(FeeType.fixed, 3, 25), 3);
      expect(feeAmount(FeeType.percent, 15, 33.33), 5.0);
      expect(feeAmount(FeeType.percent, 150, 10), 10, reason: 'never over 100%');
      expect(feeAmount(FeeType.none, 9, 25), 0);
    });

    DispatchSplit split(double fare, FeeType t, double v, FeePayer payer, FeeType pt, double pv) =>
        dispatchSplit(fare: fare, feeType: t, feeValue: v, payer: payer, platformType: pt, platformValue: pv);

    test('fixed fee, customer pays, platform takes a percentage', () {
      final s = split(25, FeeType.fixed, 3, FeePayer.customer, FeeType.percent, 20);
      expect([s.fee, s.platform, s.stand, s.customer, s.driver], [3, 0.6, 2.4, 28, 25]);
    });
    test('percentage fee, driver pays, platform takes a fixed amount', () {
      final s = split(40, FeeType.percent, 10, FeePayer.driver, FeeType.fixed, 0.5);
      expect([s.fee, s.platform, s.stand, s.customer, s.driver], [4, 0.5, 3.5, 40, 36]);
    });
    test('fixed fee, driver pays, a fixed platform fee never over the fee', () {
      final s = split(25, FeeType.fixed, 3, FeePayer.driver, FeeType.fixed, 5);
      expect([s.fee, s.platform, s.stand, s.customer, s.driver], [3, 3, 0, 25, 22]);
    });
    test('percentage fee, customer pays, platform takes a percentage', () {
      final s = split(33.33, FeeType.percent, 15, FeePayer.customer, FeeType.percent, 50);
      expect([s.fee, s.platform, s.stand, s.customer, s.driver], [5, 2.5, 2.5, 38.33, 33.33]);
    });
    test('no fee: nothing for the platform either', () {
      final s = split(25, FeeType.none, 0, FeePayer.customer, FeeType.fixed, 1);
      expect([s.fee, s.platform, s.stand, s.customer, s.driver], [0, 0, 0, 25, 25]);
    });

    test('who may set it: admins always, the stand admin when allowed, staff never', () {
      const byAdmin = StandFee(type: FeeType.fixed, value: 3);
      const byStand = StandFee(type: FeeType.fixed, value: 3, setByStand: true);
      expect(canSetStandFee(admin: true, standAdmin: false, fee: byAdmin), isTrue);
      expect(canSetStandFee(admin: false, standAdmin: true, fee: byAdmin), isFalse);
      expect(canSetStandFee(admin: false, standAdmin: true, fee: byStand), isTrue);
      expect(canSetStandFee(admin: false, standAdmin: false, fee: byStand), isFalse);
    });

    test('labels', () {
      expect(const StandFee().label, 'No fee');
      expect(const StandFee(type: FeeType.fixed, value: 3).label, 'RM 3.00 per order, paid by the customer');
      expect(
        const StandFee(type: FeeType.percent, value: 10, payer: FeePayer.driver).label,
        '10% of the fare, paid by the driver',
      );
      expect(const StandFee(platformType: FeeType.percent, platformValue: 20).platformLabel, '20% of the stand fee');
    });

    test('the customer total on an order adds the fee they pay', () {
      final o = DispatchOrder({'fare': 25, 'fee_type': 'fixed', 'fee_value': 3, 'fee_bearer': 'customer'});
      expect(o.customerTotal, 28);
      final d = DispatchOrder({'fare': 25, 'fee_amount': 3, 'fee_bearer': 'driver'});
      expect(d.customerTotal, 25);
      expect(DispatchOrder({'fare_mode': 'meter'}).customerTotal, isNull);
    });
  });

  group('who an order is offered to', () {
    final now = DateTime(2026, 10, 20, 12);

    test('assigned: the driver, inside 30 seconds, until it comes back', () {
      bool ok({String? driver = 'd1', DateTime? until, DateTime? returned}) => dispatchOfferOk(
        driver: driver,
        mode: DispatchMode.assign,
        target: 'd1',
        member: true,
        now: now,
        offerUntil: until ?? now.add(const Duration(seconds: 10)),
        returnedAt: returned,
      );
      expect(ok(), isTrue);
      expect(ok(driver: 'd2'), isFalse);
      expect(ok(until: now.subtract(const Duration(seconds: 1))), isFalse);
      expect(ok(returned: now), isFalse);
      expect(ok(driver: null), isFalse);
    });

    test('closed group and fleet: members only', () {
      expect(dispatchOfferOk(driver: 'd1', mode: DispatchMode.broadcast, target: null, member: true, now: now), isTrue);
      expect(
        dispatchOfferOk(driver: 'd2', mode: DispatchMode.broadcast, target: null, member: false, now: now),
        isFalse,
      );
    });

    test('open group: members first, then anyone; widened: anyone', () {
      final later = now.add(const Duration(seconds: 30));
      bool outsider(DateTime at, {DateTime? widened}) => dispatchOfferOk(
        driver: 'd9',
        mode: DispatchMode.broadcast,
        target: null,
        member: false,
        now: at,
        openAfter: later,
        widenedAt: widened,
      );
      expect(outsider(now), isFalse);
      expect(outsider(later), isTrue);
      expect(outsider(now, widened: now), isTrue);
      expect(membersOnlySecondsLeft(later, now), 30);
      expect(membersOnlySecondsLeft(later, later.add(const Duration(seconds: 5))), 0);
      expect(assignSecondsLeft(now.add(assignWindow), now), 30);
    });
  });

  group('the board', () {
    final now = DateTime.utc(2026, 10, 20, 12);
    DispatchOrder o(String id, String status, {Map<String, dynamic> extra = const {}}) => DispatchOrder({
      'id': id,
      'stand_id': 's1',
      'ticket_no': 'PAV-$id',
      'status': status,
      'created_at': now.toIso8601String(),
      ...extra,
    });

    test('columns by status', () {
      final cols = boardColumns([
        o('1', 'open'),
        o('2', 'arrived'),
        o('3', 'on_trip'),
        o('4', 'cancelled'),
        o('5', 'completed'),
      ]);
      expect(cols[BoardColumn.waiting]!.map((e) => e.id), ['1']);
      expect(cols[BoardColumn.coming]!.map((e) => e.id), ['2']);
      expect(cols[BoardColumn.onTheWay]!.map((e) => e.id), ['3']);
      expect(cols[BoardColumn.done]!.map((e) => e.id).toSet(), {'4', '5'});
    });

    test('the waiting pill counts up, and an unanswered assignment says so', () {
      final w = o(
        '1',
        'open',
        extra: {
          'mode': 'broadcast',
          'offered_at': now.subtract(const Duration(seconds: 18)).toIso8601String(),
          'group_name': 'Pavilion stand drivers',
        },
      );
      expect(w.pill(now), 'Sent 18 s ago');
      expect(w.sentTo(now), 'Pavilion stand drivers');
      final a = o(
        '2',
        'open',
        extra: {
          'mode': 'assign',
          'driver_target_name': 'Ali',
          'offer_until': now.subtract(const Duration(seconds: 1)).toIso8601String(),
        },
      );
      expect(a.pill(now), 'No answer · back to you');
      expect(a.sentTo(now), 'Ali');
      expect(
        o('3', 'open', extra: {'mode': 'broadcast', 'widened_at': now.toIso8601String()}).sentTo(now),
        'any nearby driver',
      );
    });

    test('the actions follow the access', () {
      const broadcastOnly = StandPerms(broadcast: true);
      final waiting = o('1', 'open');
      final coming = o('2', 'accepted');
      expect(orderActions(waiting, broadcastOnly).resend, isTrue);
      expect(orderActions(waiting, broadcastOnly).cancel, isFalse);
      expect(orderActions(coming, broadcastOnly).reassign, isFalse);
      expect(orderActions(coming, broadcastOnly).pickedUp, isTrue);
      expect(orderActions(coming, StandPerms.all).reassign, isTrue);
      expect(orderActions(coming, StandPerms.all).cancel, isTrue);
      expect(orderActions(o('3', 'on_trip'), StandPerms.all).complete, isTrue);
      expect(orderActions(o('3', 'on_trip'), StandPerms.all).cancel, isFalse);
    });

    test('fares read as the console shows them', () {
      expect(DispatchOrder({'fare_mode': 'fixed', 'fare': 28}).fareText, 'Fixed RM 28.00');
      expect(DispatchOrder({'fare_mode': 'meter'}).fareText, 'Meter');
      expect(DispatchOrder({'fare_mode': 'estimate', 'fare': 22}).fareText, 'App fare RM 22.00');
    });
  });

  group('the new order', () {
    const stand = DispatchStand(
      id: 's1',
      name: 'Pavilion KL',
      code: 'PAV',
      perms: StandPerms(broadcast: true),
      groups: [DispatchGroup(id: 'g1', name: 'Pavilion stand drivers', kind: GroupKind.closed)],
    );

    test('send modes and fare modes follow the access and the stand', () {
      expect(sendModes(const StandPerms(broadcast: true)), [DispatchMode.broadcast]);
      expect(sendModes(StandPerms.all), [DispatchMode.broadcast, DispatchMode.assign]);
      expect(fareModes(stand), [FareMode.meter, FareMode.estimate]);
      const fixed = DispatchStand(
        id: 's',
        name: 'x',
        code: 'XX',
        allowFixedFare: true,
        perms: StandPerms(fixedFare: true),
      );
      expect(fareModes(fixed), contains(FareMode.fixed));
      const admin = DispatchStand(id: 's', name: 'x', code: 'XX', admin: true);
      expect(fareModes(admin), contains(FareMode.fixed));
    });

    test('what stops it', () {
      expect(const NewOrder(standId: 's1').problemFor(stand), 'Say where the customer is going.');
      expect(const NewOrder(standId: 's1', dropName: 'KLCC').problemFor(stand), 'Pick a group.');
      expect(const NewOrder(standId: 's1', dropName: 'KLCC', groupId: 'g1').problemFor(stand), isNull);
      expect(
        const NewOrder(standId: 's1', dropName: 'KLCC', mode: DispatchMode.assign, driverId: 'd').problemFor(stand),
        "You can't assign drivers here.",
      );
      expect(
        const NewOrder(
          standId: 's1',
          dropName: 'KLCC',
          groupId: 'g1',
          fareMode: FareMode.fixed,
          fare: 20,
        ).problemFor(stand),
        "You can't set a fixed fare here.",
      );
      expect(
        const NewOrder(standId: 's1', dropName: 'KLCC', groupId: 'g1', fareMode: FareMode.estimate).problemFor(stand),
        'Enter the fare.',
      );
      expect(
        const NewOrder(standId: 's1', dropName: 'KLCC', groupId: 'g1', customerPhone: '12').problemFor(stand),
        "The phone number doesn't look right.",
      );
    });

    test('what is sent', () {
      final j = const NewOrder(
        standId: 's1',
        dropName: ' KLCC ',
        groupId: 'g1',
        driverId: 'ignored',
        fareMode: FareMode.meter,
        fare: 99,
        payment: CounterPayment.cash,
      ).toJson();
      expect(j['drop_name'], 'KLCC');
      expect(j['group_id'], 'g1');
      expect(j['driver_id'], isNull);
      expect(j['fare'], isNull, reason: 'a metered order has no fare yet');
      expect(j['payment'], 'cash');
    });
  });

  group('drivers near the stand', () {
    test('free drivers first, the asked-for service first, then nearest', () {
      const a = NearbyDriver(id: 'a', name: 'Ali', service: 'Taxi', km: 2, state: DriverState.free);
      const b = NearbyDriver(id: 'b', name: 'Siti', service: 'Taxi', km: 0.1, state: DriverState.onTrip);
      const c = NearbyDriver(id: 'c', name: 'Mei', service: 'Comfort', km: 0.3, state: DriverState.atStand);
      expect(sortNearest([a, b, c]).map((d) => d.id), ['c', 'a', 'b']);
      expect(sortNearest([a, b, c], service: 'taxi').map((d) => d.id), ['a', 'c', 'b']);
      expect(a.subtitle, 'Taxi · 2.0 km · Free');
    });
  });

  group("the driver's card", () {
    test('assigned to me, or a group order, with the stand and ticket', () {
      final row = <String, dynamic>{
        'id': 'r1',
        'stand_id': 's1',
        'dispatch_stand_name': 'Pavilion KL',
        'ticket_no': 'PAV-0041',
        'dispatch_mode': 'assign',
        'dispatch_driver_id': 'me',
        'dispatch_payment': 'counter',
        'fare_mode': 'fixed',
      };
      final mine = StandOrderInfo.of(row, me: 'me')!;
      expect(mine.title, 'Assigned to you');
      expect(mine.details, 'Pavilion KL · Ticket PAV-0041 · Paid at counter');
      final group = StandOrderInfo.of({
        ...row,
        'dispatch_mode': 'broadcast',
        'dispatch_group_name': 'TBS taxis',
      }, me: 'me')!;
      expect(group.title, 'Stand order · TBS taxis');
      expect(StandOrderInfo.of({'id': 'r2'}, me: 'me'), isNull);
    });

    test('an order assigned to me goes to the top', () {
      final list = [
        RideRequest({'id': 'a', 'status': 'open'}),
        RideRequest({
          'id': 'b',
          'status': 'open',
          'stand_id': 's',
          'dispatch_mode': 'assign',
          'dispatch_driver_id': 'me',
        }),
      ];
      expect(pinAssignedFirst(list, 'me').map((r) => r.id), ['b', 'a']);
    });

    test('who approves a join request', () {
      expect(approverOf(GroupKind.fleet), 'the fleet owner');
      expect(approverOf(GroupKind.closed), 'an admin');
      expect(JoinState.parse('pending'), JoinState.pending);
    });
  });

  group('stand people', () {
    test('access chips toggle one at a time and keep the rest', () {
      const p = StandPerms(broadcast: true);
      final q = p.toggled(StaffAccess.cancel);
      expect(q.cancel, isTrue);
      expect(q.broadcast, isTrue);
      expect(q.toStaffRow(), {
        'can_assign': false,
        'can_broadcast': true,
        'can_fixed_fare': false,
        'can_cancel': true,
        'can_reassign': false,
        'can_reports': false,
      });
      expect(StandPerms.fromStaffRow(q.toStaffRow()).cancel, isTrue);
    });

    test('a stand row reads back what was written', () {
      const s = DispatchStand(
        id: 's',
        name: ' Pavilion ',
        code: 'pav',
        kind: StandKind.busTerminal,
        lat: 3.1,
        lng: 101.7,
        settleInApp: false,
        fee: StandFee(type: FeeType.percent, value: 10, payer: FeePayer.driver, setByStand: true),
      );
      final row = s.toRow();
      expect(row['code'], 'PAV');
      expect(row['kind'], 'bus_terminal');
      expect(row['settlement'], 'outside');
      expect(row['fee_set_by'], 'stand');
      final back = DispatchStand.fromJson({'id': 's', ...row});
      expect(back.kind, StandKind.busTerminal);
      expect(back.fee.payer, FeePayer.driver);
      expect(back.settleInApp, isFalse);
      expect(const DispatchStand(id: 's', name: 'x', code: 'X').problem, 'The short code is 2 to 6 letters or digits.');
      expect(const DispatchStand(id: 's', name: 'x', code: 'XX').problem, 'Pick the stand on the map.');
    });
  });

  test("the driver's receipt takes off a stand fee they bear, not one the customer pays", () {
    Map<String, dynamic> row(String bearer) => {
      'id': '00000000-0000-0000-0000-000000000001',
      'status': 'completed',
      'fare': 40,
      'ride_fare': 40,
      'currency': 'MYR',
      'payment_mode': 'Paid at counter',
      'stand_id': 's1',
      'stand_fee_bearer': bearer,
      'stand_fee_amount': 4,
    };
    final driver = TripReceipt.fromRide(RideRequest(row('driver')), asDriver: true);
    expect(driver.standFee, 4);
    expect(driver.earnings, 36);
    expect(driver.text, contains('Stand fee: −'));
    expect(TripReceipt.fromRide(RideRequest(row('customer')), asDriver: true).earnings, 40);
  });

  test("the driver's car: colour, make and model, then the plate; labelled lines on the order", () {
    expect(dispatchCarLine('Silver Toyota Vios', 'VBA 8821'), 'Silver Toyota Vios · VBA 8821');
    expect(dispatchCarLine(null, 'VBA 8821'), 'VBA 8821');
    expect(dispatchCarLine(' ', null), isNull);
    final o = DispatchOrder({
      'status': 'accepted',
      'partner_name': 'Mei Ling',
      'partner_vehicle': 'Silver Toyota Vios',
      'partner_plate': 'VBA 8821',
    });
    expect(o.driverLines, ['Driver: Mei Ling', 'Car: Silver Toyota Vios', 'Plate: VBA 8821']);
    expect(o.carLine, 'Silver Toyota Vios · VBA 8821');
    expect(DispatchOrder({'partner_name': 'Ali'}).driverLines, ['Driver: Ali']);
    const d = NearbyDriver(id: 'd', name: 'Mei Ling', vehicle: 'Silver Toyota Vios', plate: 'VBA 8821');
    expect(d.carLine, 'Silver Toyota Vios · VBA 8821');
    expect(NearbyDriver.fromJson({'id': 'd', 'name': 'x', 'vehicle': 'Red Proton Saga'}).vehicle, 'Red Proton Saga');
  });

  test('the ticket text has the driver, the car and the plate on their own lines', () {
    final o = DispatchOrder({
      'status': 'on_trip',
      'stand_name': 'Pavilion KL',
      'ticket_no': 'PAV-0041',
      'drop_name': 'KLCC',
      'fare_mode': 'meter',
      'payment': 'counter',
      'partner_name': 'Mei Ling',
      'partner_vehicle': 'Silver Toyota Vios',
      'partner_plate': 'VBA 8821',
    });
    expect(dispatchTicketText(o), contains('Driver: Mei Ling\nCar: Silver Toyota Vios\nPlate: VBA 8821'));
  });

  group('the Call centre and bookings ahead', () {
    test('a pickup from the date boxes and a time', () {
      expect(parsePickupAt('2026-10-21', '14:30'), DateTime(2026, 10, 21, 14, 30));
      expect(parsePickupAt('2026-10-21', '9.05'), DateTime(2026, 10, 21, 9, 5));
      expect(parsePickupAt('2026-10-21', '0930'), DateTime(2026, 10, 21, 9, 30));
      expect(parsePickupAt('2026-10-21', '24:00'), isNull);
      expect(parsePickupAt('', '14:30'), isNull);
      expect(formatPickupAt(DateTime(2026, 10, 21, 5, 30)), 'Wed 21 Oct, 05:30');
    });

    const call = DispatchStand(id: 'c', name: 'Call centre', code: 'CALL', adminOnly: true, admin: true);
    final now = DateTime(2026, 10, 20, 12);

    test('a phone booking needs how they booked, the pickup, the name and the phone', () {
      expect(
        const NewOrder(standId: 'c', dropName: 'KLCC', mode: DispatchMode.nearby).problemFor(call, now: now),
        'Say how the customer booked.',
      );
      const base = NewOrder(standId: 'c', dropName: 'KLCC', mode: DispatchMode.nearby, bookedVia: BookedVia.sms);
      expect(base.problemFor(call, now: now), 'Find the pickup address.');
      const placed = NewOrder(
        standId: 'c',
        dropName: 'KLCC',
        mode: DispatchMode.nearby,
        bookedVia: BookedVia.sms,
        pickupName: 'Menara A',
        pickupLat: 3.1,
        pickupLng: 101.7,
      );
      expect(placed.problemFor(call, now: now), "A phone booking needs the customer's name and phone.");
      const full = NewOrder(
        standId: 'c',
        dropName: 'KLCC',
        mode: DispatchMode.nearby,
        bookedVia: BookedVia.whatsapp,
        pickupName: 'Menara A',
        pickupLat: 3.1,
        pickupLng: 101.7,
        customerName: 'Nur',
        customerPhone: '+60100000021',
      );
      expect(full.problemFor(call, now: now), isNull);
      final j = full.toJson();
      expect(j['mode'], 'nearby');
      expect(j['booked_via'], 'whatsapp');
      expect(j['pickup_lat'], 3.1);
      expect(j['group_id'], isNull);
      expect(
        const NewOrder(standId: 's1', dropName: 'x', mode: DispatchMode.nearby).problemFor(
          const DispatchStand(id: 's1', name: 'x', code: 'XX'),
          now: now,
        ),
        'Pick a group.',
        reason: 'nearby drivers are the Call centre\'s',
      );
    });

    test('a booking ahead: at least its lead time and five minutes out', () {
      final soon = NewOrder(
        standId: 's1',
        dropName: 'KLIA',
        groupId: 'g',
        pickupAt: now.add(const Duration(minutes: 20)),
      );
      const stand = DispatchStand(id: 's1', name: 'x', code: 'XX', perms: StandPerms(broadcast: true));
      expect(soon.problemFor(stand, now: now), 'Pick a time at least 35 minutes from now.');
      final later = NewOrder(
        standId: 's1',
        dropName: 'KLIA',
        groupId: 'g',
        pickupAt: now.add(const Duration(hours: 3)),
        leadMinutes: 15,
      );
      expect(later.problemFor(stand, now: now), isNull);
      expect(later.toJson()['lead_minutes'], 15);
    });

    test('a booking ahead on the board', () {
      final o = DispatchOrder({
        'kind': 'scheduled',
        'status': 'scheduled',
        'mode': 'assign',
        'driver_target_name': 'Ali',
        'offer_status': 'pending',
        'lead_minutes': 15,
        'pickup_at': DateTime(2026, 10, 21, 5, 30).toUtc().toIso8601String(),
      });
      expect(o.column, BoardColumn.scheduled);
      expect(o.scheduleState, 'Waiting for Ali to confirm');
      expect(o.pill(now), 'Wed 21 Oct, 05:30');
      final a = orderActions(o, const StandPerms(broadcast: true));
      expect([a.sendNow, a.editTime, a.cancel, a.resend], [true, true, false, false]);
      expect(DispatchOrder({'kind': 'scheduled', 'driver_confirmed': true}).scheduleState, 'Driver confirmed');
      expect(DispatchOrder({'kind': 'scheduled', 'lead_minutes': 60}).scheduleState, 'Goes out 60 min before');
      expect(DispatchMode.parse('nearby'), DispatchMode.nearby);
      expect(DispatchOrder({'mode': 'nearby'}).sentTo(now), 'nearby drivers');
      expect(
        DispatchOrder({'pickup_name': 'Menara A', 'drop_name': 'KLCC', 'booked_via': 'sms'}).routeLine,
        'Menara A to KLCC',
      );
      expect(StandKind.parse('call_centre'), StandKind.callCentre);
    });
  });
}
