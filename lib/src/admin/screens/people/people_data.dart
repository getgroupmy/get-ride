import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/image_crop.dart';
import '../../admin_filters.dart' show RowsPage, adminPeoplePageSize, rowsPage, searchOrFilter;
import '../../../data/doc_photos.dart';
import '../../../providers.dart';
import '../meterapp/pick_image.dart';
import 'partner_live.dart';
import 'people_logic.dart';

/// Data access for the People add/edit forms. Every call runs as the signed-in
/// admin, so the RLS policies (`caller_is_admin()`) are the real gate.
class PeopleRepository {
  PeopleRepository(this._db, {this.thumbnail});
  final SupabaseClient _db;

  /// Makes a document image's list thumbnail (an isolate by default).
  final ImageBytesJob? thumbnail;

  String get _now => DateTime.now().toUtc().toIso8601String();

  // ---- Profiles ------------------------------------------------------------

  Future<Map<String, dynamic>?> profile(String id) => _db.from('profiles').select().eq('id', id).maybeSingle();

  /// The newest [limit] profiles, or those matching [query] by name, phone,
  /// email or IC (PERF-55: a page at a time, never the whole table).
  Future<RowsPage> profiles({int limit = adminPeoplePageSize, String query = ''}) async {
    var q = _db.from('profiles').select();
    final or = searchOrFilter(query, partnerUserSearchColumns);
    if (or != null) q = q.or(or);
    final rows = await q.order('joined_at', ascending: false).order('id', ascending: false).range(0, limit);
    return rowsPage(List<Map<String, dynamic>>.from(rows), limit);
  }

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

  // ---- Live status (Edit Partner) ---------------------------------------------

  /// What [userIds] (profile ids) are doing now, for [partnerLiveOf]: their
  /// presence, the active ride and those ended in the last 12 hours, open
  /// offers and open SOS incidents. Four reads, whatever the count.
  Future<Map<String, PartnerLiveRows>> liveRows(Iterable<String> userIds) async {
    final ids = {...userIds}.where((s) => s.isNotEmpty).toList();
    if (ids.isEmpty) return const {};
    final since = DateTime.now().toUtc().subtract(partnerUnpaidWindow).toIso8601String();
    final results = await Future.wait<List<Map<String, dynamic>>>([
      _rows(_db.from('driver_presence').select('profile_id, online, updated_at').inFilter('profile_id', ids)),
      _rows(_db
          .from('ride_requests')
          .select('id, status, partner_id, arrived_at, completed_at, payment_status, drop_name, created_at')
          .inFilter('partner_id', ids)
          .or('status.in.(accepted,arrived,on_trip),and(status.eq.completed,completed_at.gt.$since)')
          .order('created_at', ascending: false)
          .limit(50)),
      _rows(_db
          .from('ride_offers')
          .select('partner_id, status, amount, expires_at')
          .inFilter('partner_id', ids)
          .eq('status', 'pending')),
      _rows(_db
          .from('safety_incidents')
          .select('partner_id, status, created_at')
          .inFilter('partner_id', ids)
          .inFilter('status', ['open', 'acknowledged'])
          .order('created_at', ascending: false)),
    ]);
    List<Map<String, dynamic>> of(List<Map<String, dynamic>> rows, String key, String id) =>
        [for (final r in rows) if ('${r[key]}' == id) r];
    return {
      for (final id in ids)
        id: PartnerLiveRows(
          presence: of(results[0], 'profile_id', id).firstOrNull,
          rides: of(results[1], 'partner_id', id),
          offers: of(results[2], 'partner_id', id),
          incidents: of(results[3], 'partner_id', id),
        ),
    };
  }

  /// A read the admin may not have (an older database): empty, not an error.
  Future<List<Map<String, dynamic>>> _rows(Future<List<Map<String, dynamic>>> q) async {
    try {
      return List<Map<String, dynamic>>.from(await q);
    } on PostgrestException catch (e) {
      debugPrint('[partner-live] $e');
      return const [];
    }
  }

  /// Who else has each vehicle: partners with its plate and drivers with a
  /// session on it (vehicle_active_session), as profile id to name, by
  /// vehicle id. [exceptUserId], the partner being edited, is left out.
  Future<Map<String, Map<String, String>>> vehicleHolders(
    List<Map<String, dynamic>> vehicles, {
    String? exceptUserId,
  }) async {
    final plates = {
      for (final v in vehicles)
        if ('${v['plate'] ?? ''}'.trim().isNotEmpty) '${v['plate']}'.trim().toUpperCase(): '${v['id']}',
    };
    final vehicleIds = [for (final v in vehicles) '${v['id']}'];
    if (vehicleIds.isEmpty) return const {};
    final results = await Future.wait<List<Map<String, dynamic>>>([
      _rows(_db.from('partners').select('auth_user_id, name, plate').not('plate', 'is', null)),
      _rows(_db.from('vehicle_active_session').select('vehicle_id, user_id').inFilter('vehicle_id', vehicleIds)),
    ]);
    final out = <String, Map<String, String>>{};
    final names = <String, String>{};
    for (final p in results[0]) {
      final uid = '${p['auth_user_id'] ?? ''}';
      final vid = plates['${p['plate'] ?? ''}'.trim().toUpperCase()];
      if (uid.isEmpty || vid == null || uid == exceptUserId) continue;
      names[uid] = '${p['name'] ?? ''}';
      (out[vid] ??= {})[uid] = names[uid]!;
    }
    for (final s in results[1]) {
      final uid = '${s['user_id'] ?? ''}';
      if (uid.isEmpty || uid == exceptUserId) continue;
      (out['${s['vehicle_id']}'] ??= {})[uid] = names[uid] ?? '';
    }
    final unnamed = {for (final m in out.values) ...m.entries.where((e) => e.value.isEmpty).map((e) => e.key)};
    if (unnamed.isNotEmpty) {
      final rows = await _rows(_db.from('profiles').select('id, name').inFilter('id', unnamed.toList()));
      final byId = {for (final r in rows) '${r['id']}': '${r['name'] ?? ''}'};
      for (final m in out.values) {
        for (final k in m.keys.toList()) {
          if (m[k]!.isEmpty) m[k] = byId[k]?.trim().isNotEmpty == true ? byId[k]! : 'another driver';
        }
      }
    }
    return out;
  }

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

  /// The vehicle's per-service checks (vehicle_service_status, 0288/0301).
  Future<List<Map<String, dynamic>>> vehicleServiceStatus(String vehicleId) async => List<Map<String, dynamic>>.from(
      await _db.from('vehicle_service_status').select().eq('vehicle_id', vehicleId).order('service', ascending: true));

  /// What the server's checks would make of them (0301), changing nothing.
  Future<List<Map<String, dynamic>>> vehicleServiceChecksPreview(String vehicleId) async => List<Map<String, dynamic>>.from(
      await _db.rpc('admin_vehicle_service_checks_preview', params: {'p_vehicle': vehicleId}) as List);

  /// Writes the server's checks for the vehicle (rows an admin set are kept).
  Future<void> applyVehicleServiceChecks(String vehicleId) =>
      _db.rpc('admin_vehicle_service_checks_apply', params: {'p_vehicle': vehicleId});

  Future<List<Map<String, dynamic>>> vehicleDocuments(String vehicleId) async => List<Map<String, dynamic>>.from(
      await _db.from('vehicle_documents').select().eq('vehicle_id', vehicleId).order('uploaded_at', ascending: false));

  Future<List<Map<String, dynamic>>> makeModels() async => List<Map<String, dynamic>>.from(
      await _db.from('vehicle_make_models').select().eq('status', true).order('position', ascending: true).order('created_at', ascending: true));

  // ---- Settings & geo ------------------------------------------------------

  Future<List<({String id, Map<String, dynamic> values})>> _entries(String table, {String? category}) async {
    var q = _db.from(table).select('id, values');
    if (category != null) q = q.eq('category', category);
    final rows = await q.order('position', ascending: true).order('created_at', ascending: true);
    return [
      for (final r in rows) (id: r['id'] as String, values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {})),
    ];
  }

  Future<List<({String id, Map<String, dynamic> values})>> partnerTypes() =>
      _entries('settings_entries', category: 'partner-type');
  /// Admin → Vehicle Services: what a vehicle is registered for (0249).
  Future<List<({String id, Map<String, dynamic> values})>> vehicleServices() =>
      _entries('settings_entries', category: 'vehicle-services');
  Future<List<({String id, Map<String, dynamic> values})>> requiredDocuments() => _entries('required_document');
  Future<List<({String id, Map<String, dynamic> values})>> documentTypes() => _entries('document_type');
  Future<List<({String id, Map<String, dynamic> values})>> insuranceProviders() => _entries('insurance_providers');

  Future<GeoOptions> geoOptions({Iterable<ServiceArea> inUse = const []}) async {
    Future<List<Map<String, dynamic>>> rows(String t, String cols) async {
      try {
        return List<Map<String, dynamic>>.from(await _db.from(t).select(cols).order('position', ascending: true).order('created_at', ascending: true));
      } catch (_) {
        return const [];
      }
    }

    final r = await Future.wait([
      rows('countries', 'name, values'),
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

  /// Upserts a vehicle document by (vehicle_id, doc_id), like
  /// [saveProviderDocument] (Expo `upsertVehicleDocument`).
  Future<void> saveVehicleDocument(Map<String, dynamic> payload) async {
    final existing = await _db
        .from('vehicle_documents')
        .select('id')
        .eq('vehicle_id', payload['vehicle_id'] as Object)
        .eq('doc_id', payload['doc_id'] as Object)
        .maybeSingle();
    if (existing != null) {
      await _db.from('vehicle_documents').update(payload).eq('id', existing['id'] as Object);
    } else {
      await _db.from('vehicle_documents').insert(payload);
    }
  }

  // ---- Storage -------------------------------------------------------------

  /// Uploads [file] (and, for a document image, its list thumbnail beside
  /// it) and returns its public-form URL. [path] is always new (it carries
  /// the upload time), so the file is cached for a year.
  Future<String> upload(String bucket, String path, PickedPeopleFile file) async {
    final files = _db.storage.from(bucket);
    await uploadStoredFile(files, path, file.bytes,
        contentType: contentTypeFor(guessExt(file.name)), thumbnail: thumbnail);
    return files.getPublicUrl(path);
  }
}

/// What the partner form's user picker searches.
const partnerUserSearchColumns = ['name', 'phone', 'email', 'ic'];

final peopleRepositoryProvider = Provider((ref) => PeopleRepository(ref.watch(supabaseProvider)));

/// A picked file with its bytes loaded.
typedef PickedPeopleFile = ({Uint8List bytes, String name});

/// Picks one image (Expo only ever stores images in these buckets; a PDF is
/// rasterised to its first page first, see doc_pdf.dart), scaled down for
/// storage ([pickDocumentImage]). With [context], a phone asks whether to
/// take the photo or choose one (see [pickImage]).
Future<PickedPeopleFile?> pickPeopleFile([BuildContext? context]) async {
  final img = await pickDocumentImage(context);
  return img == null ? null : (bytes: img.bytes, name: img.name);
}

/// The document photo picker behind a seam, so widget tests run without
/// plugins.
final docPhotoPickerProvider = Provider<Future<PickedPeopleFile?> Function(BuildContext context)>(
  (_) => pickPeopleFile,
);

/// Cuts a region out of a document photo off the UI thread.
typedef CropImageRegion = Future<Uint8List?> Function(Uint8List bytes, FractionBox box);

/// The crop behind a seam, so widget tests run without an isolate.
final docImageCropProvider = Provider<CropImageRegion>(
  (_) => (bytes, box) => compute(cropImageRegionJob, (bytes: bytes, box: box)),
);
