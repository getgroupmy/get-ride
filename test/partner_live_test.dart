import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/partner_live.dart';
import 'package:get_ride/src/admin/screens/people/partner_live_card.dart';
import 'package:get_ride/src/admin/screens/people/partner_screens.dart';
import 'package:get_ride/src/admin/screens/people/people_widgets.dart';

final _now = DateTime.utc(2026, 10, 23, 15);
String _ago(Duration d) => _now.subtract(d).toIso8601String();

PartnerLive _st(PartnerLiveRows r, {bool hasVehicle = true}) =>
    partnerLiveOf(r, hasVehicle: hasVehicle, now: _now).status;

final _vehicles = <Map<String, dynamic>>[
  {'id': 'v1', 'make': 'Proton', 'model': 'S70', 'plate': 'SYL25', 'owner_name': 'Melinda', 'auth_user_id': 'me'},
  {'id': 'v2', 'make': 'Audi', 'model': 'A3', 'plate': 'ABC', 'owner_name': 'Kabeer', 'auth_user_id': 'k'},
  {'id': 'v3', 'make': 'Honda', 'model': 'CB500F', 'plate': '123', 'owner_name': 'Kabeer', 'auth_user_id': 'k'},
  {'id': 'v4', 'make': 'BMW', 'model': '530i', 'plate': 'HBB1234', 'owner_name': 'Kabeer', 'auth_user_id': 'k'},
];

void main() {
  group('status', () {
    test('offline, online, offering, by presence and offers', () {
      expect(_st(const PartnerLiveRows()), PartnerLive.offline);
      expect(_st(PartnerLiveRows(presence: {'online': true, 'updated_at': _ago(const Duration(minutes: 1))})),
          PartnerLive.online);
      expect(_st(PartnerLiveRows(presence: {'online': true, 'updated_at': _ago(const Duration(minutes: 10))})),
          PartnerLive.offline, reason: 'a quiet phone is not online');
      expect(
        _st(PartnerLiveRows(
          presence: {'online': true, 'updated_at': _ago(const Duration(seconds: 20))},
          offers: [
            {'status': 'pending', 'amount': 18, 'expires_at': _now.add(const Duration(minutes: 1)).toIso8601String()},
          ],
        )),
        PartnerLive.offering,
      );
      expect(
        _st(PartnerLiveRows(
          presence: {'online': true, 'updated_at': _ago(const Duration(seconds: 20))},
          offers: [
            {'status': 'pending', 'amount': 18, 'expires_at': _ago(const Duration(minutes: 1))},
          ],
        )),
        PartnerLive.online,
        reason: 'an expired offer',
      );
    });

    test('a job runs pickup, waiting, trip, payment pending; SOS first; no vehicle', () {
      PartnerLiveRows ride(Map<String, dynamic> r) => PartnerLiveRows(rides: [r]);
      expect(_st(ride({'status': 'accepted', 'drop_name': 'KLCC'})), PartnerLive.pickup);
      expect(_st(ride({'status': 'arrived', 'arrived_at': _ago(const Duration(minutes: 2))})), PartnerLive.waiting);
      expect(_st(ride({'status': 'on_trip'})), PartnerLive.trip);
      expect(
          _st(ride({'status': 'completed', 'payment_status': 'due', 'completed_at': _ago(const Duration(minutes: 5))})),
          PartnerLive.unpaid);
      expect(
          _st(ride({'status': 'completed', 'payment_status': 'paid', 'completed_at': _ago(const Duration(minutes: 5))})),
          PartnerLive.offline);
      expect(
          _st(ride({'status': 'completed', 'payment_status': 'due', 'completed_at': _ago(const Duration(days: 1))})),
          PartnerLive.offline, reason: 'an old unpaid ride is a support case, not the status');
      expect(
        _st(PartnerLiveRows(rides: const [
          {'status': 'on_trip'},
        ], incidents: [
          {'status': 'open', 'created_at': _ago(const Duration(minutes: 1))},
        ])),
        PartnerLive.sos,
      );
      expect(_st(const PartnerLiveRows(), hasVehicle: false), PartnerLive.noVehicle);
      expect(_st(ride({'status': 'on_trip'}), hasVehicle: false), PartnerLive.trip, reason: 'a running job still shows');
    });

    test('a vehicle can be taken only while nobody else is online with it', () {
      const off = (userId: 'k', name: 'Kabeer', status: PartnerLive.offline, detail: '');
      const on = (userId: 'a', name: 'Arif', status: PartnerLive.online, detail: '');
      const trip = (userId: 'k', name: 'Kabeer', status: PartnerLive.trip, detail: '');
      expect(vehicleLinkable(const []), isTrue);
      expect(vehicleLinkable(const [off]), isTrue);
      expect(vehicleLinkable(const [on]), isFalse);
      expect(vehicleLinkable(const [off, trip]), isFalse);
      expect(vehicleUseLine(const []), 'Not linked to anyone');
      expect(vehicleUseLine(const [off]), 'Linked to Kabeer · Offline');
      expect(vehicleUseLine(const [off, trip]), 'In use by Kabeer · On trip');
    });

    test('own vehicles first; a search finds anyone\'s', () {
      bool own(Map<String, dynamic> v) => vehicleIsOwn(v, userId: 'me', partnerId: 'pa');
      expect(vehiclesToShow(_vehicles, '', isOwn: own).map((v) => v['id']), ['v1']);
      expect(vehiclesToShow(_vehicles, 'kabeer', isOwn: own).map((v) => v['id']), ['v2', 'v3', 'v4']);
      expect(vehiclesToShow(_vehicles, 'bmw', isOwn: own).map((v) => v['id']), ['v4']);
      expect(vehicleIsOwn({'owner_partner_id': 'pa'}, userId: 'me', partnerId: 'pa'), isTrue);
    });
  });

  for (final b in Brightness.values) {
    testWidgets('the picker: own first, others by search, in use can\'t be taken (${b.name})', (tester) async {
      Map<String, dynamic>? picked;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: b),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => VehicleSelector(
                vehicles: _vehicles,
                selected: null,
                onChanged: (v) => picked = v,
                isOwn: (v) => vehicleIsOwn(v, userId: 'me', partnerId: 'pa'),
                holders: const {
                  'v2': [(userId: 'k', name: 'Kabeer', status: PartnerLive.offline, detail: '')],
                  'v4': [(userId: 'a', name: 'Arif', status: PartnerLive.online, detail: '')],
                },
              ),
            ),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('vehicle-v1')), findsOneWidget);
      expect(find.byKey(const ValueKey('vehicle-v2')), findsNothing, reason: 'not own, no search');
      expect(find.text('Not linked to anyone'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'kabeer');
      await tester.pump();
      expect(find.byKey(const ValueKey('vehicle-v2')), findsOneWidget);
      expect(find.text('Linked to Kabeer · Offline'), findsOneWidget);
      expect(find.text('In use by Arif · Online'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('vehicle-v4')));
      expect(picked, isNull, reason: 'Arif is online with it');
      await tester.tap(find.byKey(const ValueKey('vehicle-v2')));
      expect(picked?['id'], 'v2', reason: 'Kabeer is offline');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the status card shows the job strip (${b.name})', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          partnerLiveProvider.overrideWith(
              (ref, k) async => (status: PartnerLive.waiting, detail: 'At the pickup for 2 min', ride: null)),
          partnerVehicleHoldersProvider.overrideWith((ref, uid) async => const {}),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: b),
          home: const Scaffold(body: PartnerLiveCard(userId: 'me', hasVehicle: true)),
        ),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('partner-live-waiting')), findsOneWidget);
      expect(find.text('Waiting for passenger'), findsOneWidget);
      expect(find.text('At the pickup for 2 min'), findsOneWidget);
      expect(find.text('Payment pending'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
