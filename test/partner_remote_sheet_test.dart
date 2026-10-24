// Admin › Edit Partner › Change status (0286): the sheet's actions (greyed
// with why where they can't be asked), its vehicle picker (own first, a
// vehicle another driver is online with can't be taken) and each state of
// the request on the status card. Light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/partner_live.dart';
import 'package:get_ride/src/admin/screens/people/partner_live_card.dart';
import 'package:get_ride/src/admin/screens/people/partner_remote_sheet.dart';
import 'package:get_ride/src/admin/screens/people/partner_screens.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/core/partner_remote_action.dart';
import 'package:get_ride/src/data/partner_remote_repository.dart';

const _id = '5c0d5e7a-1a2b-4c3d-8e9f-0a1b2c3d4e5f';

final _vehicles = <Map<String, dynamic>>[
  {'id': 'v1', 'make': 'Proton', 'model': 'S70', 'plate': 'SYL25', 'owner_name': 'Melinda', 'auth_user_id': 'me'},
  {'id': 'v2', 'make': 'Audi', 'model': 'A3', 'plate': 'ABC', 'owner_name': 'Kabeer', 'auth_user_id': 'k'},
  {'id': 'v4', 'make': 'BMW', 'model': '530i', 'plate': 'HBB1234', 'owner_name': 'Kabeer', 'auth_user_id': 'k'},
];

class _Repo implements PartnerRemoteRepository {
  final asked = <String>[];

  @override
  Future<RemoteActionRequest?> request(String profileId, RemoteAction action, {String? vehicleId}) async {
    asked.add('$profileId:${action.wire}${vehicleId == null ? '' : ':$vehicleId'}');
    return RemoteActionRequest(id: _id, action: action, status: RemoteStatus.queued, vehicleId: vehicleId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('what is offered for each status', () {
    String? why(PartnerLive? s, RemoteAction a, {bool hasVehicle = true}) =>
        remoteChoices(s, hasVehicle: hasVehicle).firstWhere((c) => c.action == a).why;
    expect(why(PartnerLive.online, RemoteAction.goOnline), 'Already online');
    expect(why(PartnerLive.online, RemoteAction.goOffline), isNull);
    expect(why(PartnerLive.offline, RemoteAction.goOnline), isNull);
    expect(why(PartnerLive.offline, RemoteAction.goOffline), 'Already offline');
    expect(why(PartnerLive.trip, RemoteAction.goOnline), 'On a job already');
    expect(why(null, RemoteAction.goOnline), isNull, reason: 'status not known: the phone decides');
    expect(why(PartnerLive.offline, RemoteAction.unlinkVehicle, hasVehicle: false), 'No vehicle linked');
    final never = remoteChoices(PartnerLive.online, hasVehicle: true).where((c) => c.action == null).toList();
    expect([for (final c in never) (c.label, c.why)], [
      ('Start trip', "Needs the rider's code"),
      ('End a metered hire', 'Must be ended on the meter'),
    ]);
  });

  for (final b in Brightness.values) {
    Future<_Repo> pumpSheet(WidgetTester tester, PartnerLive status) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 1200);
      addTearDown(tester.view.reset);
      final repo = _Repo();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          partnerRemoteRepositoryProvider.overrideWithValue(repo),
          partnerFormDataProvider.overrideWith((ref) async => PartnerFormData(
                typeValues: const [],
                vehicles: _vehicles,
                geo: const GeoOptions(),
                requiredDocs: const [],
              )),
          partnerVehicleHoldersProvider.overrideWith((ref, uid) async => const {
                'v2': [(userId: 'k', name: 'Kabeer', status: PartnerLive.offline, detail: '')],
                'v4': [(userId: 'a', name: 'Arif', status: PartnerLive.online, detail: '')],
              }),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: b),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPartnerRemoteSheet(
                  context,
                  userId: 'me',
                  status: status,
                  hasVehicle: true,
                  isOwn: (v) => vehicleIsOwn(v, userId: 'me', partnerId: 'pa'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return repo;
    }

    ListTile tile(WidgetTester tester, String key) => tester.widget<ListTile>(find.byKey(ValueKey('remote-$key')));

    testWidgets('the sheet: offered and greyed actions, go offline sent (${b.name})', (tester) async {
      final repo = await pumpSheet(tester, PartnerLive.online);
      expect(find.text('Change status'), findsOneWidget);
      expect(tile(tester, 'go_online').enabled, isFalse);
      expect(find.text('Already online'), findsOneWidget);
      expect(tile(tester, 'go_offline').enabled, isTrue);
      expect(tile(tester, 'link_vehicle').enabled, isTrue);
      expect(tile(tester, 'unlink_vehicle').enabled, isTrue);
      expect(tile(tester, 'Start trip').enabled, isFalse);
      expect(find.text("Needs the rider's code"), findsOneWidget);
      expect(tile(tester, 'End a metered hire').enabled, isFalse);
      expect(find.text('Must be ended on the meter'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('remote-go_online')));
      await tester.pump();
      expect(repo.asked, isEmpty, reason: 'greyed');
      await tester.tap(find.byKey(const ValueKey('remote-go_offline')));
      await tester.pumpAndSettle();
      expect(repo.asked, ['me:go_offline']);
      expect(find.text('Change status'), findsNothing, reason: 'the sheet closes once asked');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the sheet: link vehicle, own first, one in use can\'t be taken (${b.name})', (tester) async {
      final repo = await pumpSheet(tester, PartnerLive.offline);
      await tester.tap(find.byKey(const ValueKey('remote-link_vehicle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('vehicle-v1')), findsOneWidget, reason: 'own vehicles first');
      expect(find.byKey(const ValueKey('vehicle-v2')), findsNothing);
      await tester.enterText(find.byType(TextField), 'kabeer');
      await tester.pump();
      expect(find.text('In use by Arif · Online'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vehicle-v4')));
      await tester.pump();
      expect(repo.asked, isEmpty, reason: 'Arif is online with it');
      await tester.tap(find.byKey(const ValueKey('vehicle-v2')));
      await tester.pumpAndSettle();
      expect(repo.asked, ['me:link_vehicle:v2']);
      expect(tester.takeException(), isNull);
    });

    final t0 = DateTime.utc(2026, 10, 24, 7);
    final states = <String, (RemoteActionRequest, String)>{
      'queued': (
        RemoteActionRequest(id: _id, action: RemoteAction.goOnline, status: RemoteStatus.queued, serverNow: t0),
        'Waiting for their phone…',
      ),
      'app closed': (
        RemoteActionRequest(
          id: _id,
          action: RemoteAction.goOnline,
          status: RemoteStatus.sent,
          sentAt: t0,
          serverNow: t0.add(const Duration(seconds: 30)),
        ),
        'Waiting for the driver (app closed)',
      ),
      'done': (
        RemoteActionRequest(
            id: _id, action: RemoteAction.goOffline, status: RemoteStatus.done, answeredAt: t0, serverNow: t0),
        'Done: the driver is offline',
      ),
      'refused': (
        RemoteActionRequest(
          id: _id,
          action: RemoteAction.goOnline,
          status: RemoteStatus.refused,
          reason: 'Before you can go online, please update the following: PSV permit (expired)',
          answeredAt: t0,
          serverNow: t0,
        ),
        'Refused: Before you can go online, please update the following: PSV permit (expired)',
      ),
      'expired': (
        RemoteActionRequest(
            id: _id, action: RemoteAction.goOnline, status: RemoteStatus.expired, answeredAt: t0, serverNow: t0),
        'No answer (expired)',
      ),
    };
    for (final e in states.entries) {
      testWidgets('the card: ${e.key} (${b.name})', (tester) async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            partnerLiveProvider.overrideWith(
                (ref, k) async => (status: PartnerLive.offline, detail: 'Last online 5 min ago', ride: null)),
            partnerVehicleHoldersProvider.overrideWith((ref, uid) async => const {}),
            partnerRemoteStatusProvider.overrideWith((ref, uid) async => e.value.$1),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: b),
            home: const Scaffold(body: PartnerLiveCard(userId: 'me', hasVehicle: true, canChange: true)),
          ),
        ));
        await tester.pump();
        await tester.pump();
        expect(find.text(e.value.$2), findsOneWidget);
        final button = tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('partner-change-status')));
        expect(button.onPressed == null, e.value.$1.status.open, reason: 'one open request at a time');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('the card re-reads every 3 s and refreshes the status once done (${b.name})', (tester) async {
      var reads = 0, liveReads = 0;
      var current = RemoteActionRequest(id: _id, action: RemoteAction.goOnline, status: RemoteStatus.sent, serverNow: t0);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          partnerLiveProvider.overrideWith((ref, k) async {
            liveReads++;
            return (status: PartnerLive.offline, detail: '', ride: null);
          }),
          partnerVehicleHoldersProvider.overrideWith((ref, uid) async => const {}),
          partnerRemoteStatusProvider.overrideWith((ref, uid) async {
            reads++;
            return current;
          }),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: b),
          home: const Scaffold(body: PartnerLiveCard(userId: 'me', hasVehicle: true, canChange: true)),
        ),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('Waiting for their phone…'), findsOneWidget);
      final before = liveReads;
      current = RemoteActionRequest(
          id: _id, action: RemoteAction.goOnline, status: RemoteStatus.done, answeredAt: t0, serverNow: t0);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump();
      expect(reads, greaterThanOrEqualTo(2));
      expect(find.text('Done: the driver is online'), findsOneWidget);
      expect(liveReads, greaterThan(before), reason: 'the status card is read again after Done');
      final settled = reads;
      await tester.pump(const Duration(seconds: 7));
      expect(reads, settled, reason: 'no polling once answered');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the card without edit has no Change status (${b.name})', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          partnerLiveProvider.overrideWith((ref, k) async => (status: PartnerLive.online, detail: 'Free', ride: null)),
          partnerVehicleHoldersProvider.overrideWith((ref, uid) async => const {}),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: b),
          home: const Scaffold(body: PartnerLiveCard(userId: 'me', hasVehicle: true)),
        ),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('partner-change-status')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
