// Edit Partner › Change status (migration 0286), on the partner's phone: a
// `partner_remote_action` push (or the app coming back with one open) is run
// through the driver's own buttons, so every rule they apply applies here
// (documents, approved vehicle, credit, vehicle in use, region rules,
// permits); then the phone says done, or refused with the words the driver
// saw. Going online needs the Drive screen: without it the driver is asked
// first ("Support asked you to go online. Tap to confirm") and the request
// waits for the tap.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/partner_remote_action.dart';
import '../../data/partner_remote_repository.dart';
import '../../data/vehicle_assignment_repository.dart';
import 'driver_online.dart';
import 'vehicle_picker.dart' show driverHandBackVehicle, driverTakeVehicle;

/// What became of a request on this phone.
enum RemoteOutcome { none, done, refused, waitingDriver }

/// What a button that threw shows instead.
const remoteActionFailed = "Couldn't do it on the phone. Try again.";

/// Runs one request at a time through the driver's own code.
class RemoteActionHandler {
  RemoteActionHandler({
    required this.inbox,
    required this.screen,
    required this.background,
    required this.askDriver,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RemoteActionInbox inbox;

  /// The Drive screen's own buttons while it is up, else null.
  final DriverRemoteActions? Function() screen;

  /// The same buttons' code where it runs without the Drive screen (the
  /// vehicle card's Select / Hand back, the switch's state going off).
  final DriverRemoteActions background;

  /// Asks the driver to open the Drive screen for [request].
  final void Function(RemoteActionRequest request) askDriver;

  final DateTime Function() _clock;
  final _running = <String>{};

  /// Runs request [id], or this account's open one when null.
  Future<RemoteOutcome> handle([String? id]) async {
    if (id != null && !_running.add(id)) return RemoteOutcome.none;
    String? taken;
    try {
      final req = await inbox.mine(id);
      if (req == null || !req.status.open) return RemoteOutcome.none;
      if (req.id != id) {
        // Found by asking for any open one: not if it is already running.
        if (!_running.add(req.id)) return RemoteOutcome.none;
        taken = req.id;
      }
      final drive = screen();
      if (req.action == RemoteAction.goOnline && drive == null) {
        // Online is a screen of its own (the requests, the map): asked first.
        await inbox.seen(req.id, waitingDriver: true);
        askDriver(req);
        return RemoteOutcome.waitingDriver;
      }
      await inbox.seen(req.id, waitingDriver: false);
      final buttons = drive ?? background;
      String? reason;
      try {
        reason = await switch (req.action) {
          RemoteAction.goOnline => buttons.goOnline(),
          RemoteAction.goOffline => buttons.goOffline(),
          RemoteAction.linkVehicle => buttons.linkVehicle(req.vehicleId ?? ''),
          RemoteAction.unlinkVehicle => buttons.unlinkVehicle(),
        };
      } catch (_) {
        reason = remoteActionFailed;
      }
      await inbox.report(req.id, reason: reason, localTime: remoteLocalTime(_clock()));
      return reason == null ? RemoteOutcome.done : RemoteOutcome.refused;
    } finally {
      if (id != null) _running.remove(id);
      if (taken != null) _running.remove(taken);
    }
  }
}

/// The Drive screen's buttons, while it is up (PartnerScreen sets them).
final driverScreenActionsProvider =
    NotifierProvider<DriverScreenActions, DriverRemoteActions?>(DriverScreenActions.new);

class DriverScreenActions extends Notifier<DriverRemoteActions?> {
  @override
  DriverRemoteActions? build() => null;

  void set(DriverRemoteActions actions) {
    if (ref.mounted) state = actions;
  }

  /// Only [actions]' own screen takes them away (a new one may be up).
  void clear(DriverRemoteActions actions) {
    if (ref.mounted && identical(state, actions)) state = null;
  }
}

/// A request waiting for the driver's tap (the app shows it).
final remoteActionAskProvider = NotifierProvider<RemoteActionAsk, RemoteActionRequest?>(RemoteActionAsk.new);

class RemoteActionAsk extends Notifier<RemoteActionRequest?> {
  @override
  RemoteActionRequest? build() => null;

  void ask(RemoteActionRequest r) {
    if (ref.mounted) state = r;
  }
}

/// Without the Drive screen: the vehicle card's own calls, and the switch's
/// state for going offline (as the update gate takes a driver offline).
class BackgroundDriverActions implements DriverRemoteActions {
  BackgroundDriverActions(this.ref);
  final Ref ref;

  VehicleAssignmentRepository get _vehicles => ref.read(vehicleAssignmentRepositoryProvider);

  @override
  Future<String?> goOnline() async => 'Open the Drive screen to go online.';

  @override
  Future<String?> goOffline() async {
    ref.read(driverOnlineProvider.notifier).set(false);
    return null;
  }

  @override
  Future<String?> linkVehicle(String vehicleId) async {
    final why = await driverTakeVehicle(_vehicles, vehicleId);
    ref.invalidate(assignableVehiclesProvider);
    return why;
  }

  @override
  Future<String?> unlinkVehicle() async {
    final why = await driverHandBackVehicle(_vehicles);
    ref.invalidate(assignableVehiclesProvider);
    return why;
  }
}

final remoteActionHandlerProvider = Provider<RemoteActionHandler>((ref) => RemoteActionHandler(
      inbox: ref.watch(partnerRemoteRepositoryProvider),
      screen: () => ref.read(driverScreenActionsProvider),
      background: BackgroundDriverActions(ref),
      askDriver: (r) => ref.read(remoteActionAskProvider.notifier).ask(r),
    ));
