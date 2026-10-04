import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

/// Opens the meter when this launch should land on it. Called from the home
/// screen, which every sign-in and relaunch reaches first.
Future<void> maybeAutoLaunchMeter(BuildContext context, WidgetRef ref) async {
  final session = ref.read(meterLaunchSessionProvider);
  if (session == null || ref.read(meterLaunchHandledProvider) == session) return;
  ref.read(meterLaunchHandledProvider.notifier).mark(session);
  // Fresh answers for this sign-in, not ones cached from an earlier one.
  ref
    ..invalidate(rideInProgressProvider)
    ..invalidate(meterAutoLaunchProvider);
  final bool launch;
  try {
    launch = await ref.read(meterAutoLaunchProvider.future).timeout(meterLaunchTimeout);
  } catch (_) {
    return;
  }
  if (launch && context.mounted) unawaited(GoRouter.of(context).push('/meter'));
}
