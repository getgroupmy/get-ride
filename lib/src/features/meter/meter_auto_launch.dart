import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/launch_destination.dart';
import '../../core/meter_auto_launch.dart';
import '../../core/meter_sign_in.dart';
import '../../core/taxi_meter.dart';
import '../../data/meter_session_store.dart';
import '../../providers.dart';
import '../partner/partner_screen.dart' show partnerCanDrive;
import 'meter_providers.dart';
import 'meter_sign_in_prompt.dart';

/// Whether this account has a ride in progress, as a rider or a partner. A
/// seam so tests can answer it.
final rideInProgressProvider = FutureProvider<bool>((ref) async {
  final rides = ref.watch(rideRepositoryProvider);
  Future<bool> has(Future<Object?> Function() lookup) async {
    try {
      return await lookup() != null;
    } catch (_) {
      return false;
    }
  }

  final found = await Future.wait([has(rides.ongoingForRider), has(rides.ongoingForPartner)]);
  return found.contains(true);
});

/// The rider's and the driver's ride in progress, looked up for the launch
/// decision. A seam so tests can answer it.
final ongoingRidesProvider = FutureProvider<({bool rider, String? partnerTripId})>((ref) async {
  final rides = ref.watch(rideRepositoryProvider);
  Future<T?> safe<T>(Future<T?> Function() lookup) async {
    try {
      return await lookup();
    } catch (_) {
      return null;
    }
  }

  final rider = await safe(rides.ongoingForRider);
  final partner = await safe(rides.ongoingForPartner);
  return (rider: rider != null, partnerTripId: partner?.id);
});

/// Whether this launch opens on Meter Digital (Expo `resolveMeterAutoLaunch`
/// as gathered by the `welcome-back` buffer). Accounts that are not TEKSI
/// partners answer at once, without asking the network for cards or rides.
final meterAutoLaunchProvider = FutureProvider<bool>((ref) async {
  final partner = await ref.watch(partnerProvider.future);
  if (partner == null || !partnerCanDrive(partner) || !hasTeksiPartnerType(partner.raw['partner_types'])) {
    return false;
  }
  final cards = await ref.watch(meterCardsProvider.future);
  final geo = await ref.watch(meterLaunchStoreProvider).readGeo();
  final rideInProgress = await ref.watch(rideInProgressProvider.future);
  return resolveMeterAutoLaunch(
    profiles: cards,
    partnerTypes: partner.raw['partner_types'],
    canDrive: true,
    geo: geo,
    rideInProgress: rideInProgress,
  ).launch;
});

/// Identifies this sign-in: the account and when it signed in. A token
/// refresh keeps it; signing out and in again (or as someone else) does not.
final meterLaunchSessionProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  final user = ref.watch(supabaseProvider).auth.currentUser;
  return user == null ? null : '${user.id}|${user.lastSignInAt ?? ''}';
});

/// Where the driver's meter on/off for a sign-in is kept. A seam for tests.
final meterSessionStoreProvider = Provider((_) => MeterSessionStore());

/// The card's "Meter at sign-in" for this account (`off`, `ask` or
/// `always`): `off` for anyone who is not a TEKSI partner cleared to drive,
/// answered without asking the network.
final meterAtSignInProvider = FutureProvider<String>((ref) async {
  final partner = await ref.watch(partnerProvider.future);
  if (partner == null || !partnerCanDrive(partner) || !hasTeksiPartnerType(partner.raw['partner_types'])) {
    return 'off';
  }
  final cards = await ref.watch(meterCardsProvider.future);
  final geo = await ref.watch(meterLaunchStoreProvider).readGeo();
  return resolveMeterAtSignIn(profiles: cards, partnerTypes: partner.raw['partner_types'], canDrive: true, geo: geo);
});

/// The driver's meter on (true) or off (false) for this sign-in; null when
/// not chosen yet. Set by the sign-in question, "Always on", or the
/// "Meter on/off" switch in the meter and the driver menu.
class MeterSessionChoice extends AsyncNotifier<bool?> {
  @override
  Future<bool?> build() async {
    final session = ref.watch(meterLaunchSessionProvider);
    if (session == null) return null;
    return ref.watch(meterSessionStoreProvider).read(session);
  }

  Future<void> set(bool on) async {
    final session = ref.read(meterLaunchSessionProvider);
    if (session == null) return;
    await ref.read(meterSessionStoreProvider).save(session, on);
    state = AsyncData(on);
  }
}

final meterSessionChoiceProvider = AsyncNotifierProvider<MeterSessionChoice, bool?>(MeterSessionChoice.new);

/// The sign-in this app launch has already decided for. The decision is made
/// once per launch (and again only after signing in afresh), so a driver who
/// leaves the meter for the passenger side is never sent back.
class MeterLaunchHandled extends Notifier<String?> {
  @override
  String? build() => null;

  void mark(String session) => state = session;
}

final meterLaunchHandledProvider = NotifierProvider<MeterLaunchHandled, String?>(MeterLaunchHandled.new);

/// How long the decision may take. Its inputs are network reads, and a
/// launch is never held hostage to them: past this, the driver stays home.
const meterLaunchTimeout = Duration(seconds: 10);

/// Takes this launch where it should land (Expo's welcome-back buffer):
/// back into a driver's trip in progress, else onto the meter when the rate
/// card asks for it. Called from the home screen, which every sign-in and
/// relaunch reaches first; decided once per sign-in.
///
/// With the card's "Meter at sign-in" on `ask` or `always`, the first launch
/// after signing in asks the driver (or turns the meter on), and the answer
/// holds for that sign-in ([resolveMeterSignIn]). A trip in progress is
/// still restored first: the question then waits for a launch with none.
Future<void> maybeAutoLaunchMeter(BuildContext context, WidgetRef ref) async {
  final session = ref.read(meterLaunchSessionProvider);
  if (session == null || ref.read(meterLaunchHandledProvider) == session) return;
  ref.read(meterLaunchHandledProvider.notifier).mark(session);
  // Only the page the app launched on is a launch: started anywhere but
  // home, a later visit to home (the Ride tab, Go to home, a link) is the
  // person's own choice, and it stays.
  if (!AppLaunch.startedHome) return;
  // Fresh answers for this sign-in, not ones cached from an earlier one.
  ref
    ..invalidate(ongoingRidesProvider)
    ..invalidate(rideInProgressProvider)
    ..invalidate(meterAutoLaunchProvider)
    ..invalidate(meterAtSignInProvider)
    ..invalidate(meterSessionChoiceProvider);
  final size = MediaQuery.sizeOf(context);
  final tablet = isTabletSize(size.width, size.height, web: kIsWeb);
  final choices = ref.read(meterSessionChoiceProvider.notifier);
  ({bool rider, String? partnerTripId}) ongoing;
  bool busy;
  bool meter;
  var ask = false;
  try {
    ongoing = await ref.read(ongoingRidesProvider.future).timeout(meterLaunchTimeout);
    busy = ongoing.rider || ongoing.partnerTripId != null;
    final mode = await ref.read(meterAtSignInProvider.future).timeout(meterLaunchTimeout);
    final chosen = mode == 'off' ? null : await ref.read(meterSessionChoiceProvider.future).timeout(meterLaunchTimeout);
    final action = resolveMeterSignIn(mode: mode, choice: chosen);
    // "Always on" turns the meter on for the sign-in even when a trip in
    // progress takes this launch elsewhere.
    if (action == MeterSignInAction.meterOn) await choices.set(true);
    // The meter rule is only asked when no ride is in progress.
    meter = switch (action) {
      _ when busy => false,
      MeterSignInAction.meterOn => true,
      MeterSignInAction.stayOff || MeterSignInAction.ask => false,
      MeterSignInAction.autoLaunch => await ref.read(meterAutoLaunchProvider.future).timeout(meterLaunchTimeout),
    };
    ask = !busy && action == MeterSignInAction.ask;
  } catch (_) {
    return;
  }
  if (ask) {
    if (!context.mounted) return;
    final on = await showMeterSignInPrompt(context);
    if (on != null) await choices.set(on);
    meter = on ?? false;
  }
  final LaunchTarget target;
  try {
    // Nor whether a tablet's account is a partner's.
    // Only when this run launched on home: reaching home later (the Ride
    // tab, Go to home, Book a ride) must stay on the rider's home.
    final partnerTablet = !busy &&
        !meter &&
        tablet &&
        AppLaunch.startedHome &&
        await ref.read(partnerProvider.future).timeout(meterLaunchTimeout) != null;
    target = resolveLaunchTarget(
      riderRideInProgress: ongoing.rider,
      partnerTripId: ongoing.partnerTripId,
      meterAutoLaunch: meter,
      partnerTablet: partnerTablet,
    );
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  switch (target) {
    case LaunchPartnerTrip(:final requestId):
      unawaited(GoRouter.of(context).push('/drive/trip/$requestId'));
    case LaunchMeter():
      unawaited(GoRouter.of(context).push('/meter'));
    case LaunchPartnerConsole():
      GoRouter.of(context).go('/drive');
    case LaunchHome():
      break;
  }
}
