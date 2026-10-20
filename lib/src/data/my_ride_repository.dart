// My Ride — favourite drivers (lib/src/core/my_ride.dart; migration 0160).
// Every call goes through the server's functions; on a database without them
// each one answers "not available" (null, an empty set or a dedicated
// variant) instead of throwing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/driver_request_radius.dart';
import '../core/my_ride.dart';
import '../providers.dart' show supabaseProvider, currentUserIdProvider;

class MyRideRepository {
  MyRideRepository(this._db);
  final SupabaseClient _db;

  // ---- The driver's code ---------------------------------------------------------

  /// The signed-in driver's My Ride code; null for an account that is not a
  /// driver, or on a database without My Ride.
  Future<String?> myCode() async {
    try {
      final v = await _db.rpc('my_ride_code');
      return v is String && v.isNotEmpty ? v : null;
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return null;
      rethrow;
    }
  }

  /// A new code for the signed-in driver (the old one stops working; riders
  /// who already added them keep them). Null on a database without My Ride.
  Future<String?> rotateCode() async {
    try {
      final v = await _db.rpc('rotate_my_ride_code');
      return v is String && v.isNotEmpty ? v : null;
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return null;
      rethrow;
    }
  }

  // ---- The rider's favourites ----------------------------------------------------

  /// Adds the driver whose code (or scanned QR) is [input]. A malformed
  /// entry is refused here without asking the server.
  Future<AddFavouriteResult> addByCode(String input) async {
    final code = parseMyRideCode(input);
    if (code == null) return const FavouriteNotAdded(AddFavouriteError.invalidCode);
    try {
      return AddFavouriteResult.fromJson(await _db.rpc('add_favourite_driver', params: {'p_code': code}));
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return const MyRideNotAvailable();
      rethrow;
    }
  }

  /// Removes a favourite (and takes them off the rider's open request).
  /// False when it wasn't one, or on a database without My Ride.
  Future<bool> remove(String driverId) async {
    try {
      return await _db.rpc('remove_favourite_driver', params: {'p_driver_id': driverId}) == true;
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return false;
      rethrow;
    }
  }

  /// The rider's favourites, available ones first. With a point, an online
  /// driver's distance to it (to the nearest 0.5 km). Null on a database
  /// without My Ride.
  Future<List<FavouriteDriver>?> favourites({double? lat, double? lng}) async {
    try {
      final rows = await _db.rpc('my_favourite_drivers', params: {'p_lat': lat, 'p_lng': lng});
      return [
        for (final r in rows is List ? rows : const [])
          if (r is Map) FavouriteDriver.fromRow(Map<String, dynamic>.from(r)),
      ];
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return null;
      rethrow;
    }
  }

  // ---- The driver's side ---------------------------------------------------------

  /// Riders who have the signed-in driver as a favourite. Null on a
  /// database without My Ride.
  Future<List<FavouriteRider>?> favouriteRiders() async {
    try {
      final rows = await _db.rpc('my_favourite_riders');
      return [
        for (final r in rows is List ? rows : const [])
          if (r is Map) FavouriteRider.fromRow(Map<String, dynamic>.from(r)),
      ];
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return null;
      rethrow;
    }
  }

  /// The riders whose requests get the driver's gold star (not hidden).
  /// Empty on a database without My Ride.
  Future<Set<String>> favouriteRiderIds() async {
    try {
      final rows = await _db.rpc('my_favourite_rider_ids');
      return {
        for (final r in rows is List ? rows : const [])
          if (r is String) r else if (r is Map && r.values.isNotEmpty) '${r.values.first}',
      };
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return const {};
      rethrow;
    }
  }

  /// Hides (or shows again) a rider who added the driver: their requests are
  /// no longer offered to or starred for the driver, and the driver is taken
  /// off their open request. Null on a database without My Ride; false when
  /// the rider hadn't added the driver.
  Future<bool?> hideRider(String riderId, {required bool hidden}) async {
    try {
      return await _db.rpc('hide_favourite_rider', params: {'p_rider_id': riderId, 'p_hidden': hidden}) == true;
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return null;
      rethrow;
    }
  }

  // ---- During the search ---------------------------------------------------------

  /// "Offer to all nearby": ends the favourites window of the rider's open
  /// request now. The database also does this on its own when the window
  /// runs out (within its dispatch tick), so calling it then is harmless.
  Future<OfferToAllOutcome> offerToAll(String requestId) async {
    try {
      return OfferToAllOutcome.fromJson(
        await _db.rpc('ride_request_offer_to_all', params: {'p_request_id': requestId}),
      );
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return OfferToAllOutcome.unavailable;
      rethrow;
    }
  }

  /// Adds favourites to the rider's open request while searching; the server
  /// keeps only the rider's own, not hidden ones within the distance cap (at
  /// most [myRideMaxTargets] in all) and pushes each one added. Returns the
  /// request's target list, or null on a database without My Ride. Throws
  /// when the request is no longer open.
  Future<List<String>?> addTargets(String requestId, List<String> driverIds) async {
    try {
      final v = await _db.rpc(
        'ride_request_add_targets',
        params: {'p_request_id': requestId, 'p_driver_ids': driverIds},
      );
      return [for (final id in v is List ? v : const []) '$id'];
    } on PostgrestException catch (e) {
      if (isMissingMyRide(e)) return null;
      rethrow;
    }
  }
}

/// A database without migration 0160: the function (PostgREST schema cache
/// or Postgres), the table or a column isn't there.
bool isMissingMyRide(PostgrestException e) =>
    e.code == 'PGRST202' ||
    e.code == '42883' ||
    e.code == 'PGRST205' ||
    e.code == '42P01' ||
    e.code == '42703' ||
    e.message.contains('Could not find the function');

final myRideRepositoryProvider = Provider((ref) => MyRideRepository(ref.watch(supabaseProvider)));

/// The signed-in rider's favourite drivers; null when My Ride isn't
/// available. Refresh with `ref.invalidate` after adding or removing.
final myFavouriteDriversProvider = FutureProvider.autoDispose<List<FavouriteDriver>?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const [];
  return ref.watch(myRideRepositoryProvider).favourites();
});

/// The same, with each online driver's distance to a point (the pickup).
final myFavouriteDriversNearProvider = FutureProvider.autoDispose
    .family<List<FavouriteDriver>?, ({double lat, double lng})>((ref, at) async {
      if (ref.watch(currentUserIdProvider) == null) return const [];
      return ref.watch(myRideRepositoryProvider).favourites(lat: at.lat, lng: at.lng);
    });

/// Riders who have the signed-in driver as a favourite; null when My Ride
/// isn't available.
final myFavouriteRidersProvider = FutureProvider.autoDispose<List<FavouriteRider>?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const [];
  return ref.watch(myRideRepositoryProvider).favouriteRiders();
});

/// The signed-in driver's My Ride code; null for a non-driver or when My
/// Ride isn't available.
final myRideCodeProvider = FutureProvider.autoDispose<String?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  return ref.watch(myRideRepositoryProvider).myCode();
});

/// Riders whose requests the signed-in driver stars (see [isStarredFor]).
/// Kept while the app runs; invalidate after hiding / showing a rider.
final favouriteRiderIdsProvider = FutureProvider<Set<String>>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return const {};
  try {
    return await ref.watch(myRideRepositoryProvider).favouriteRiderIds();
  } catch (_) {
    // A star is a nicety: never fail the request list over it.
    return const {};
  }
});

/// The vehicle services' dispatch settings (radii, windows) by service name
/// and entry id ([dispatchConfigsByService]), for the driver's request
/// radius. Empty — every service on the defaults — when the catalogue
/// cannot be read.
final serviceDispatchConfigsProvider = FutureProvider<Map<String, ServiceDispatchConfig>>((ref) async {
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('settings_entries')
        .select('id, values, position')
        .eq('category', 'vehicle-services')
        .order('position', ascending: true).order('created_at', ascending: true);
    return dispatchConfigsByService([
      for (final r in rows)
        (
          id: '${r['id']}',
          values: r['values'] is Map ? Map<String, dynamic>.from(r['values'] as Map) : <String, dynamic>{},
        ),
    ]);
  } catch (_) {
    return const {};
  }
});
