import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../providers.dart';
import 'people_logic.dart';

/// Data access for the People add/edit forms. Every call runs as the signed-in
/// admin, so the RLS policies (`caller_is_admin()`) are the real gate.
class PeopleRepository {
  PeopleRepository(this._db);
  final SupabaseClient _db;

  String get _now => DateTime.now().toUtc().toIso8601String();

  // ---- Profiles ------------------------------------------------------------

  Future<Map<String, dynamic>?> profile(String id) => _db.from('profiles').select().eq('id', id).maybeSingle();

  Future<List<Map<String, dynamic>>> profiles() async =>
      List<Map<String, dynamic>>.from(await _db.from('profiles').select().order('joined_at', ascending: false));

  /// Updates one profile and fails loudly when nothing changed: the live
  /// `profiles` table has only a self-update policy, so a refused admin write
  /// matches zero rows instead of raising (Expo reported "Saved" regardless).
  Future<Map<String, dynamic>> updateProfile(String id, Map<String, dynamic> patch) async {
    final rows = await _db.from('profiles').update({...patch, 'updated_at': _now}).eq('id', id).select();
    if (rows.isEmpty) {
      throw StateError(
          'The database did not apply this change. Profiles can currently only be edited by their owner '
          '(there is no admin UPDATE policy on public.profiles).');
    }
    return rows.first;
  }

  Future<void> deleteProfile(String id) async {
    final rows = await _db.from('profiles').delete().eq('id', id).select('id');
    if (rows.isEmpty) {
      throw StateError('The database did not delete this profile (no admin DELETE policy on public.profiles).');
    }
  }

  /// Profiles with an uploaded ID image for the review screen.
  Future<List<Map<String, dynamic>>> idDocuments(String tab) async {
    var q = _db
        .from('profiles')
        .select('id, name, phone, email, ic, id_image, id_verified, id_expiry_date, documents_ok, nationality, updated_at')
        .not('id_image', 'is', null);
    q = switch (tab) {
      'Verified' || 'Failed' || 'Expired' => q.eq('id_verified', tab),
      'Pending' => q.isFilter('id_verified', null),
      _ => q,
    };
    return List<Map<String, dynamic>>.from(await q.order('updated_at', ascending: false).limit(200));
  }

  // ---- Partners ------------------------------------------------------------

  Future<Map<String, dynamic>?> partner(String id) => _db.from('partners').select().eq('id', id).maybeSingle();

  Future<List<Map<String, dynamic>>> partners() async =>
      List<Map<String, dynamic>>.from(await _db.from('partners').select().order('joined_at', ascending: false));

  Future<String?> partnerIdForDisplayId(String displayId) async {
    final r = await _db.from('partners').select('id').eq('display_id', displayId).maybeSingle();
    return r?['id'] as String?;
  }

  /// Inserts a partner row (Expo `upsertPartner`, new-row branch).
  Future<Map<String, dynamic>> addPartner({
    required Map<String, dynamic> user,
    required Map<String, dynamic>? vehicle,
    required List<String> partnerTypes,
    required ServiceArea area,
    required bool autoApprove,
  }) async {
    final row = newPartnerRow(
      id: const Uuid().v4(),
      displayId: newDisplayId('PR'),
      user: user,
      vehicle: vehicle,
      partnerTypes: partnerTypes,
      area: area,
      autoApprove: autoApprove,
      joinedAt: _now,
    );
    await _db.from('partners').insert(row);
    return row;
  }

  /// Updates an existing partner (never upserts: see Expo `upsertPartner`).
  Future<void> updatePartner(String id, Map<String, dynamic> patch) async {
    final rows = await _db.from('partners').update({...patch, 'updated_at': _now}).eq('id', id).select('id');
    if (rows.isEmpty) throw StateError('The partner could not be updated on the server.');
  }

  Future<void> deletePartner(String id) => _db.from('partners').delete().eq('id', id);

  // ---- Vehicles ------------------------------------------------------------

  Future<Map<String, dynamic>?> vehicle(String id) => _db.from('vehicle').select().eq('id', id).maybeSingle();

  Future<List<Map<String, dynamic>>> vehicles() async =>
      List<Map<String, dynamic>>.from(await _db.from('vehicle').select().order('joined_at', ascending: false));

  Future<void> addVehicle(Map<String, dynamic> columns) => _db.from('vehicle').insert({
        'id': const Uuid().v4(),
        'display_id': newDisplayId('VH'),
        ...columns,
        'joined_at': _now,
      });

  Future<void> updateVehicle(String id, Map<String, dynamic> patch) async {
    final rows = await _db.from('vehicle').update({...patch, 'updated_at': _now}).eq('id', id).select('id');
    if (rows.isEmpty) throw StateError('The vehicle could not be updated on the server.');
  }

  Future<void> deleteVehicle(String id) => _db.from('vehicle').delete().eq('id', id);

  Future<List<Map<String, dynamic>>> vehicleDocuments(String vehicleId) async => List<Map<String, dynamic>>.from(
      await _db.from('vehicle_documents').select().eq('vehicle_id', vehicleId).order('uploaded_at', ascending: false));

  Future<List<Map<String, dynamic>>> makeModels() async => List<Map<String, dynamic>>.from(
      await _db.from('vehicle_make_models').select().eq('status', true).order('position'));

  // ---- Settings & geo ------------------------------------------------------

  Future<List<({String id, Map<String, dynamic> values})>> _entries(String table, {String? category}) async {
    var q = _db.from(table).select('id, values');
    if (category != null) q = q.eq('category', category);
    final rows = await q.order('position');
    return [
      for (final r in rows) (id: r['id'] as String, values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {})),
    ];
  }

  Future<List<({String id, Map<String, dynamic> values})>> partnerTypes() =>
      _entries('settings_entries', category: 'partner-type');
  Future<List<({String id, Map<String, dynamic> values})>> requiredDocuments() => _entries('required_document');
  Future<List<({String id, Map<String, dynamic> values})>> documentTypes() => _entries('document_type');
  Future<List<({String id, Map<String, dynamic> values})>> insuranceProviders() => _entries('insurance_providers');

  Future<GeoOptions> geoOptions({Iterable<ServiceArea> inUse = const []}) async {
    Future<List<Map<String, dynamic>>> rows(String t, String cols) async {
      try {
        return List<Map<String, dynamic>>.from(await _db.from(t).select(cols).order('position'));
      } catch (_) {
        return const [];
      }
    }

    final r = await Future.wait([
      rows('countries', 'name'),
      rows('states', 'country, name'),
      rows('cities', 'country, state, name'),
    ]);
    return GeoOptions.build(countryRows: r[0], stateRows: r[1], cityRows: r[2], inUse: inUse);
  }

  // ---- Provider documents --------------------------------------------------

  Future<List<Map<String, dynamic>>> providerDocuments(String partnerId) async => List<Map<String, dynamic>>.from(
      await _db.from('provider_documents').select().eq('partner_id', partnerId).order('uploaded_at', ascending: false));

  /// Update the partner's existing row for this doc, else insert (Expo
  /// `upsertProviderDocument`).
  Future<void> saveProviderDocument(Map<String, dynamic> payload) async {
    final existing = await _db
        .from('provider_documents')
        .select('id')
        .eq('partner_id', payload['partner_id'] as Object)
        .eq('doc_id', payload['doc_id'] as Object)
        .maybeSingle();
    if (existing != null) {
      await _db.from('provider_documents').update(payload).eq('id', existing['id'] as Object);
    } else {
      await _db.from('provider_documents').insert(payload);
    }
  }

  // ---- Storage -------------------------------------------------------------

  Future<String> upload(String bucket, String path, PickedPeopleFile file) async {
    await _db.storage.from(bucket).uploadBinary(
          path,
          file.bytes,
          fileOptions: FileOptions(upsert: true, contentType: contentTypeFor(guessExt(file.name))),
        );
    return _db.storage.from(bucket).getPublicUrl(path);
  }
}

final peopleRepositoryProvider = Provider((ref) => PeopleRepository(ref.watch(supabaseProvider)));

/// A picked file with its bytes loaded.
typedef PickedPeopleFile = ({Uint8List bytes, String name});

/// Picks one image (Expo only ever stores images in these buckets: PDFs are
/// rasterised to PNG before upload, which this port does not do).
Future<PickedPeopleFile?> pickPeopleFile() async {
  final files = await FilePicker.pickFiles(type: FileType.image);
  final f = files.firstOrNull;
  if (f == null) return null;
  return (bytes: await f.readAsBytes(), name: f.name);
}
