import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/launch_destination.dart';
import '../../core/meter_auto_launch.dart';
import '../../core/taxi_meter.dart';
import '../../providers.dart';
import '../partner/partner_screen.dart' show partnerCanDrive;
import 'meter_providers.dart';

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
Future<void> maybeAutoLaunchMeter(BuildContext context, WidgetRef ref) async {
  final session = ref.read(meterLaunchSessionProvider);
  if (session == null || ref.read(meterLaunchHandledProvider) == session) return;
  ref.read(meterLaunchHandledProvider.notifier).mark(session);
  // Fresh answers for this sign-in, not ones cached from an earlier one.
  ref
    ..invalidate(ongoingRidesProvider)
    ..invalidate(rideInProgressProvider)
    ..invalidate(meterAutoLaunchProvider);
  final LaunchTarget target;
  try {
    final ongoing = await ref.read(ongoingRidesProvider.future).timeout(meterLaunchTimeout);
    // The meter rule is only asked when no ride is in progress.
    final meter = ongoing.rider || ongoing.partnerTripId != null
        ? false
        : await ref.read(meterAutoLaunchProvider.future).timeout(meterLaunchTimeout);
    target = resolveLaunchTarget(
      riderRideInProgress: ongoing.rider,
      partnerTripId: ongoing.partnerTripId,
      meterAutoLaunch: meter,
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
    case LaunchHome():
      break;
  }
}
