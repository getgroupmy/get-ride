import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../admin/screens/people/people_logic.dart';
import '../core/vehicle_onboarding.dart';
import '../providers.dart';
import 'doc_photos.dart';

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
  VehicleOnboardingRepository(this._db, {this.thumbnail});
  final SupabaseClient _db;

  /// Makes a photo's list thumbnail (an isolate by default).
  final ImageBytesJob? thumbnail;

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
            .order('created_at', ascending: false),
      );

  Future<Map<String, dynamic>?> vehicle(String id) => _db.from('vehicle').select().eq('id', id).maybeSingle();

  /// Deletes the caller's own draft vehicle [id] (0229's "vehicle own draft
  /// delete"). False when nothing was deleted: it is no longer a draft the
  /// caller may remove (submitted, in use, or not theirs).
  Future<bool> removeDraft(String id) async {
    final rows = await _db.from('vehicle').delete().eq('id', id).select('id');
    return rows.isNotEmpty;
  }

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

  /// A registration document of the vehicle (the owner's authorisation
  /// letter, the rental or hire-purchase agreement) to
  /// `vehicle-documents/<id>/<folder>/<side>-<ms>.<ext>`.
  Future<String> uploadFile(String vehicleId, String folder, String side, Uint8List bytes, String fileName) async {
    final ext = guessExt(fileName);
    final path = docFilePath(vehicleId, folder, side, ext);
    final files = _db.storage.from('vehicle-documents');
    await uploadStoredFile(files, path, bytes, contentType: contentTypeFor(ext), thumbnail: thumbnail);
    return files.getPublicUrl(path);
  }

  /// Each registered service's status on [vehicleId] (0288), by service.
  Future<List<Map<String, dynamic>>> serviceStatuses(String vehicleId) async => List<Map<String, dynamic>>.from(
        await _db.from('vehicle_service_status').select().eq('vehicle_id', vehicleId).order('service', ascending: true),
      );

  /// Replaces the service statuses of [vehicleId] with [rows] (while the
  /// vehicle is a draft; the server refuses it after).
  Future<void> saveServiceStatuses(String vehicleId, List<Map<String, dynamic>> rows) async {
    final keep = [for (final r in rows) '${r['service']}'];
    final old = await serviceStatuses(vehicleId);
    for (final o in old) {
      if (!keep.contains('${o['service']}')) {
        await _db.from('vehicle_service_status').delete().eq('vehicle_id', vehicleId).eq('service', '${o['service']}');
      }
    }
    if (rows.isNotEmpty) await _db.from('vehicle_service_status').upsert(rows, onConflict: 'vehicle_id,service');
  }

  /// Updates [v] without moving its step (partner registration keeps its own).
  Future<Map<String, dynamic>> update(String id, Map<String, dynamic> patch) =>
      _db.from('vehicle').update(patch).eq('id', id).select().single();

  /// Uploads one of the four photos to `vehicle-documents/<id>/photos/`,
  /// with its list thumbnail beside it.
  Future<String> uploadPhoto(String vehicleId, String slot, Uint8List bytes, String fileName) async {
    final ext = guessExt(fileName);
    final path = vehiclePhotoPath(vehicleId, slot, ext);
    final files = _db.storage.from('vehicle-documents');
    await uploadStoredFile(files, path, bytes, contentType: contentTypeFor(ext), thumbnail: thumbnail);
    return files.getPublicUrl(path);
  }
}

final vehicleOnboardingRepositoryProvider =
    Provider((ref) => VehicleOnboardingRepository(ref.watch(supabaseProvider)));
