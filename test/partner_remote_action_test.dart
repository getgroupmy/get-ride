// Edit Partner › Change status (0286) on the partner's phone: the request is
// run through the driver's own buttons (the Drive switch with every check it
// makes, the vehicle card's Select / Hand back) and the answer reported,
// refusals with the words the driver's own flow showed.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/partner_doc_check.dart';
import 'package:get_ride/src/core/partner_remote_action.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/partner_remote_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/driver_online.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/features/partner/remote_action.dart';
import 'package:get_ride/src/features/partner/vehicle_picker.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

const _id = '5c0d5e7a-1a2b-4c3d-8e9f-0a1b2c3d4e5f';

RemoteActionRequest _req(RemoteAction a, {String? vehicle, RemoteStatus status = RemoteStatus.sent}) =>
    RemoteActionRequest(id: _id, action: a, status: status, vehicleId: vehicle);

/// The phone's side of the requests, in memory.
class _Inbox implements PartnerRemoteRepository {
  _Inbox(this.open);
  RemoteActionRequest? open;
  final log = <String>[];
  String? reported;
  bool get answered => log.any((l) => l.startsWith('report'));

  @override
  Future<RemoteActionRequest?> mine([String? id]) async {
    log.add('mine:${id ?? '*'}');
    final r = open;
    return r != null && r.status.open && (id == null || id == r.id) ? r : null;
  }

  @override
  Future<void> seen(String id, {required bool waitingDriver}) async => log.add('seen:$waitingDriver');

  @override
  Future<void> report(String id, {String? reason, required String localTime}) async {
    log.add('report:${reason == null ? 'done' : 'refused'}:$localTime');
    reported = reason;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A driver's buttons that say what they were asked.
class _Buttons implements DriverRemoteActions {
  _Buttons(this.name, {this.answer});
  final String name;
  final String? answer;
  final calls = <String>[];

  @override
  Future<String?> goOnline() async {
    calls.add('$name.goOnline');
    return answer;
  }

  @override
  Future<String?> goOffline() async {
    calls.add('$name.goOffline');
    return answer;
  }

  @override
  Future<String?> linkVehicle(String vehicleId) async {
    calls.add('$name.link:$vehicleId');
    return answer;
  }

  @override
  Future<String?> unlinkVehicle() async {
    calls.add('$name.unlink');
    return answer;
  }
}

class _Throws extends _Buttons {
  _Throws() : super('throws');
  @override
  Future<String?> goOffline() => Future.error(StateError('boom'));
}

/// The vehicles the driver may drive, and what claim / release say.
class _Vehicles implements VehicleAssignmentRepository {
  _Vehicles(this.list, {this.claimError});
  final List<AssignableVehicle> list;
  final Object? claimError;
  final calls = <String>[];

  @override
  Future<List<AssignableVehicle>> assignable() async => list;

  @override
  Future<void> claim(String vehicleId) async {
    calls.add('claim:$vehicleId');
    if (claimError != null) throw claimError!;
  }

  @override
  Future<void> release() async => calls.add('release');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AssignableVehicle _v(String id, AssignableStatus s) =>
    AssignableVehicle(vehicle: {'id': id, 'plate': 'P$id', 'make': 'Proton', 'model': 'Saga'}, role: VehicleRole.driver, status: s);

class _NoTrip implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final clock = DateTime(2026, 10, 24, 15, 12);

  group('what each side shows', () {
    test('the card: waiting, app closed, done, refused with the reason, no answer', () {
      final t0 = DateTime.utc(2026, 10, 24, 7);
      RemoteActionRequest r(RemoteStatus s, {DateTime? sent, bool waiting = false, String? reason}) => RemoteActionRequest(
            id: _id,
            action: RemoteAction.goOnline,
            status: s,
            sentAt: sent,
            waitingDriver: waiting,
            reason: reason,
          );
      expect(remoteRequestLine(r(RemoteStatus.queued), now: t0).text, 'Waiting for their phone…');
      expect(remoteRequestLine(r(RemoteStatus.sent, sent: t0), now: t0.add(const Duration(seconds: 5))).text,
          'Waiting for their phone…');
      expect(remoteRequestLine(r(RemoteStatus.sent, sent: t0), now: t0.add(const Duration(seconds: 20))).text,
          'Waiting for the driver (app closed)', reason: 'no answer 15 s after the push: the app is closed');
      expect(remoteRequestLine(r(RemoteStatus.sent, sent: t0, waiting: true), now: t0).text,
          'Waiting for the driver (app closed)');
      expect(remoteRequestLine(r(RemoteStatus.done)).text, 'Done: the driver is online');
      expect(remoteRequestLine(r(RemoteStatus.refused, reason: 'Update your PSV permit')).text,
          'Refused: Update your PSV permit');
      expect(remoteRequestLine(r(RemoteStatus.expired)).text, 'No answer (expired)');
    });

    test('the row the server gives, and the words for the driver', () {
      final r = RemoteActionRequest.fromJson({
        'id': _id,
        'action': 'link_vehicle',
        'status': 'sent',
        'vehicle_id': 'v1',
        'vehicle_plate': 'VJK 1',
        'waiting_driver': true,
        'sent_at': '2026-10-24T07:00:00Z',
      })!;
      expect((r.action, r.status, r.vehicleId, r.vehiclePlate, r.waitingDriver),
          (RemoteAction.linkVehicle, RemoteStatus.sent, 'v1', 'VJK 1', true));
      expect(RemoteActionRequest.fromJson({'id': _id, 'action': 'start_trip'}), isNull);
      expect(RemoteAction.goOnline.prompt, 'Support asked you to go online');
      expect(remoteDoneNotice(RemoteAction.goOffline, '3:12 PM'), 'Support set you offline at 3:12 PM.');
      expect(remoteLocalTime(DateTime(2026, 10, 24, 15, 12)), '3:12 PM');
      expect(remoteLocalTime(DateTime(2026, 10, 24, 0, 5)), '12:05 AM');
    });

    test('the push, the Android notification link and the tap open the Drive page that runs it', () {
      final push = {'type': 'partner_remote_action', 'id': _id, 'title': 'x', 'body': 'y'};
      expect(remoteActionIdFromPush(push), _id);
      expect(remoteActionIdFromPush({'type': 'partner_remote_action', 'id': 'nope'}), isNull);
      expect(pushRouteFor(push), '/drive?remote=$_id');
      expect(pushRouteFor({'type': 'partner_remote_action', 'action_id': _id}), '/drive',
          reason: 'the line kept in Notifications opens Drive');
      expect(remoteActionLinkLocation(Uri.parse('getride://remote/$_id')), '/drive?remote=$_id');
      expect(remoteActionLinkLocation(Uri.parse('getride://remote/x')), isNull);
      expect(remoteActionLinkLocation(Uri.parse('getride://trip/$_id')), isNull);
    });
  });

  group('the handler', () {
    RemoteActionHandler handler(_Inbox inbox, {DriverRemoteActions? screen, required DriverRemoteActions bg, List<RemoteActionRequest>? asked}) =>
        RemoteActionHandler(
          inbox: inbox,
          screen: () => screen,
          background: bg,
          askDriver: (r) => asked?.add(r),
          clock: () => clock,
        );

    test('go online runs the Drive screen\'s own switch and reports done with the phone\'s time', () async {
      final inbox = _Inbox(_req(RemoteAction.goOnline));
      final screen = _Buttons('screen'), bg = _Buttons('bg');
      expect(await handler(inbox, screen: screen, bg: bg).handle(_id), RemoteOutcome.done);
      expect(screen.calls, ['screen.goOnline']);
      expect(bg.calls, isEmpty);
      expect(inbox.log, ['mine:$_id', 'seen:false', 'report:done:3:12 PM']);
    });

    test('a refusal reports the words the driver\'s own flow showed', () async {
      const why = 'Before you can go online, please update the following: • PSV permit (expired)';
      final inbox = _Inbox(_req(RemoteAction.goOnline));
      final out = await handler(inbox, screen: _Buttons('screen', answer: why), bg: _Buttons('bg')).handle(_id);
      expect(out, RemoteOutcome.refused);
      expect(inbox.reported, why);
    });

    test('go online without the Drive screen asks the driver first and waits', () async {
      final inbox = _Inbox(_req(RemoteAction.goOnline));
      final asked = <RemoteActionRequest>[];
      final bg = _Buttons('bg');
      expect(await handler(inbox, bg: bg, asked: asked).handle(_id), RemoteOutcome.waitingDriver);
      expect(asked.single.id, _id);
      expect(inbox.log, ['mine:$_id', 'seen:true'], reason: 'it stays sent until the tap');
      expect(bg.calls, isEmpty);
    });

    test('offline and the vehicle run without the Drive screen through the same buttons', () async {
      final bg = _Buttons('bg');
      final off = _Inbox(_req(RemoteAction.goOffline));
      expect(await handler(off, bg: bg).handle(), RemoteOutcome.done);
      final link = _Inbox(_req(RemoteAction.linkVehicle, vehicle: 'v9'));
      expect(await handler(link, bg: bg).handle(_id), RemoteOutcome.done);
      final unlink = _Inbox(_req(RemoteAction.unlinkVehicle));
      expect(await handler(unlink, bg: bg).handle(_id), RemoteOutcome.done);
      expect(bg.calls, ['bg.goOffline', 'bg.link:v9', 'bg.unlink']);
      expect(off.log.first, 'mine:*', reason: 'the app coming back looks for an open one');
    });

    test('nothing open, an answered request, a button that throws, the same request twice', () async {
      final bg = _Buttons('bg');
      expect(await handler(_Inbox(null), bg: bg).handle(_id), RemoteOutcome.none);
      expect(await handler(_Inbox(_req(RemoteAction.goOffline, status: RemoteStatus.done)), bg: bg).handle(_id),
          RemoteOutcome.none);
      expect(bg.calls, isEmpty);

      final inbox = _Inbox(_req(RemoteAction.goOffline));
      expect(await handler(inbox, bg: _Throws()).handle(_id), RemoteOutcome.refused);
      expect(inbox.reported, remoteActionFailed);

      final slow = Completer<String?>();
      final twice = _Inbox(_req(RemoteAction.goOffline));
      final h = handler(twice, bg: _Slow(slow.future));
      final first = h.handle(_id);
      expect(await h.handle(_id), RemoteOutcome.none, reason: 'already running');
      slow.complete(null);
      expect(await first, RemoteOutcome.done);
    });
  });

  group('the vehicle card\'s own calls', () {
    test('link claims only a vehicle the picker would offer, with the card\'s words', () async {
      final repo = _Vehicles([_v('a', AssignableStatus.available), _v('b', AssignableStatus.pendingReview)]);
      expect(await driverTakeVehicle(repo, 'a'), isNull);
      expect(await driverTakeVehicle(repo, 'b'), 'An admin is still reviewing this vehicle.', reason: 'as the picker says why');
      expect(await driverTakeVehicle(repo, 'z'), "You're not assigned to this vehicle.");
      expect(repo.calls, ['claim:a']);
      final busy = _Vehicles([_v('a', AssignableStatus.available)], claimError: Exception('vehicle_in_use'));
      expect(await driverTakeVehicle(busy, 'a'), claimVehicleErrorMessage(Exception('vehicle_in_use')));
      expect(await driverHandBackVehicle(repo), isNull);
      expect(repo.calls.last, 'release');
    });

    test('without the Drive screen: claim / release, and the switch goes off', () async {
      final repo = _Vehicles([_v('a', AssignableStatus.available)]);
      final c = ProviderContainer(overrides: [
        vehicleAssignmentRepositoryProvider.overrideWithValue(repo),
        assignableVehiclesProvider.overrideWith((ref) async => repo.list),
      ]);
      addTearDown(c.dispose);
      c.read(driverOnlineProvider.notifier).set(true);
      final bg = BackgroundDriverActions(c.read(_refProvider));
      expect(await bg.linkVehicle('a'), isNull);
      expect(await bg.unlinkVehicle(), isNull);
      expect(repo.calls, ['claim:a', 'release']);
      expect(await bg.goOffline(), isNull);
      expect(c.read(driverOnlineProvider), isFalse);
      expect(await bg.goOnline(), isNotNull, reason: 'online needs the Drive screen');
    });
  });

  group('the Drive screen', () {
    Future<(ProviderContainer, _Inbox)> pump(WidgetTester tester, PartnerDocCheck check) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1400);
      addTearDown(tester.view.reset);
      final inbox = _Inbox(_req(RemoteAction.goOnline));
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, _) => const PartnerScreen()),
        GoRoute(path: '/drive/onboarding', builder: (_, _) => const Scaffold(body: Text('onboarding'))),
      ]);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
          rideRepositoryProvider.overrideWithValue(_NoTrip()),
          openRequestsProvider.overrideWith((ref) => const Stream<List<RideRequest>>.empty()),
          assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
          partnerTypeEntriesProvider.overrideWith(
            (ref) async => [
              (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
            ],
          ),
          partnerDocCheckProvider.overrideWithValue(check),
          partnerRemoteRepositoryProvider.overrideWithValue(inbox),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();
      return (ProviderScope.containerOf(tester.element(find.byType(PartnerScreen))), inbox);
    }

    testWidgets('support\'s go online runs the switch: an expired document refuses with its dialog\'s words',
        (tester) async {
      final (c, inbox) = await pump(
        tester,
        (partner, {required teksi}) async => [
          (id: 'psv', name: 'PSV permit', compulsory: true, reason: DocIssueReason.expired),
        ],
      );
      expect(c.read(driverScreenActionsProvider), isNotNull, reason: 'the screen lends its buttons');
      final out = c.read(remoteActionHandlerProvider).handle(_id);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('docs-blocked')), findsOneWidget, reason: 'the driver sees the same dialog');
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(await out, RemoteOutcome.refused);
      expect(inbox.reported, contains('PSV permit (expired)'));
      expect(inbox.reported, startsWith('Before you can go online'));
      expect(find.text('You are offline'), findsOneWidget);
    });

    testWidgets('with nothing in the way it goes online and reports done', (tester) async {
      final (c, inbox) = await pump(tester, (partner, {required teksi}) async => const <DocIssue>[]);
      final out = c.read(remoteActionHandlerProvider).handle(_id);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await out, RemoteOutcome.done);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('You are online'), findsOneWidget);
      expect(c.read(driverOnlineProvider), isTrue);
      expect(inbox.log.where((l) => l.startsWith('report')).single, matches(RegExp(r'^report:done:\d{1,2}:\d{2} [AP]M$')));
    });
  });
}

/// A button that answers when told.
class _Slow extends _Buttons {
  _Slow(this.answerLater) : super('slow');
  final Future<String?> answerLater;
  @override
  Future<String?> goOffline() => answerLater;
}

/// A [Ref] for [BackgroundDriverActions] in a plain container.
final _refProvider = Provider<Ref>((ref) => ref);
