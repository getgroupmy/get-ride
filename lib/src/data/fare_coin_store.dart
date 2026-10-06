import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/fare_coins.dart';
import 'models.dart';
import 'ride_repository.dart';

/// Remembers, on this device, which rides the rider booked with "Use
/// GET.coin" on. Expo carried the choice as a route param, which a relaunch
/// lost; kept here, the coins are still applied when the rider comes back to
/// the trip or opens its receipt.
class FareCoinChoiceStore {
  static String _key(String rideId) => 'fare_coins_$rideId';

  Future<void> choose(String rideId) async => (await SharedPreferences.getInstance()).setBool(_key(rideId), true);

  Future<bool> chosen(String rideId) async => (await SharedPreferences.getInstance()).getBool(_key(rideId)) ?? false;

  Future<void> clear(String rideId) async => (await SharedPreferences.getInstance()).remove(_key(rideId));
}

final fareCoinChoiceStoreProvider = Provider((ref) => FareCoinChoiceStore());

/// Applies GET.coin to a completed ride the rider booked with coins on.
/// Null when they didn't, the ride isn't done, or the call failed — the
/// choice is then kept, so a later visit tries again (the server redeems
/// once per ride either way).
Future<FareCoinRedemption?> redeemChosenFareCoins(RideRepository repo, FareCoinChoiceStore store, RideRequest r) async {
  if (r.status != RideStatus.completed) return null;
  try {
    if (!await store.chosen(r.id)) return null;
  } catch (_) {
    return null;
  }
  final result = await repo.redeemFareCoins(r);
  if (result != null) {
    try {
      await store.clear(r.id);
    } catch (_) {}
  }
  return result;
}
