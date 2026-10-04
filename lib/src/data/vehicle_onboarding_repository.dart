import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../admin/screens/people/people_logic.dart';
import '../core/vehicle_onboarding.dart';
import '../providers.dart';

/// The plate is already registered to another account. Partners can only
/// see their own vehicles, so it cannot be claimed from the app; an admin
/// assigns it instead.
class VehiclePlateTaken implements Exception {
  const VehiclePlateTaken(this.plate);
  final String plate;

  @override
  String toString() => '$plate is already registered to another account. If this is your vehicle, '
      'contact support so an admin can assign it to you.';
}

/// Reads and writes for vehicle onboarding (Expo `vehicleOnboardingStore`).
/// Row-level security limits every read to the partner's own vehicles, and
/// the 0088 guard stops a partner changing a vehicle's status or permit.
class VehicleOnboardingRepository {
  VehicleOnboardingRepository(this._db);
  final SupabaseClient _db;

  String get _uid {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw StateError('Not signed in');
    return id;
  }

  /// The partner's vehicles: owned through the partner row, or created by
  /// this login.
  Future<List<Map<String, dynamic>>> myVehicles(String partnerId) async => List<Map<String, dynamic>>.from(
        await _db
            .from('vehicle')
            .select()
            .or('owner_partner_id.eq.$partnerId,auth_user_id.eq.$_uid')
            .order('created_at'),
      );

  Future<Map<String, dynamic>?> vehicle(String id) => _db.from('vehicle').select().eq('id', id).maybeSingle();

  /// Starts a vehicle from its plate: one of the partner's own vehicles with
  /// that plate is resumed, otherwise a new row is created.
  Future<Map<String, dynamic>> startWithPlate(String plate, Map<String, dynamic> partner) async {
    final p = normalizePlate(plate);
    // Plates are stored upper-cased (Expo and admin both normalise them).
    final own = await _db.from('vehicle').select().eq('plate', p).limit(1).maybeSingle();
    if (own != null) return own;
    try {
      return await _db
          .from('vehicle')
          .insert(newVehicleStub(
            id: const Uuid().v4(),
            displayId: newDisplayId('VH'),
            plate: p,
            userId: _uid,
            partner: partner,
          ))
          .select()
          .single();
    } on PostgrestException catch (e) {
      // vehicle_plate_key: the plate exists, on a vehicle this login cannot see.
      if (e.code == '23505' && e.message.contains('plate')) throw VehiclePlateTaken(p);
      rethrow;
    }
  }

  /// Updates the vehicle and records the step it moves on to.
  Future<Map<String, dynamic>> patch(Map<String, dynamic> v, Map<String, dynamic> patch) {
    final step = firstVehicleStep({...v, ...patch});
    return _db
        .from('vehicle')
        .update({...patch, 'onboarding_step': step.key})
        .eq('id', v['id'] as Object)
        .select()
        .single();
  }

  /// Uploads one of the four photos to `vehicle-documents/<id>/photos/`.
  Future<String> uploadPhoto(String vehicleId, String slot, Uint8List bytes, String fileName) async {
    final ext = guessExt(fileName);
    final path = vehiclePhotoPath(vehicleId, slot, ext);
    await _db.storage.from('vehicle-documents').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(upsert: true, contentType: contentTypeFor(ext)),
        );
    return _db.storage.from('vehicle-documents').getPublicUrl(path);
  }
}

final vehicleOnboardingRepositoryProvider =
    Provider((ref) => VehicleOnboardingRepository(ref.watch(supabaseProvider)));
