import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../providers.dart';
import '../../admin_providers.dart';
import '../../admin_settings_models.dart';
import 'catalogue_logic.dart';
import '../../../data/live_tables.dart';

/// Settings categories owned by this module. Only `key`/`table` matter to the
/// shared repository's `settings()` / `saveSetting()` / `deleteSetting()`.
const serviceSettingsCategory = SettingsCategory(
  key: serviceSettingsKey,
  page: 'admin-settings-service',
  title: 'Service Settings',
  subtitle: 'Core service configuration',
  table: 'settings_entries',
  fields: [],
);
const vehicleServicesCategory = SettingsCategory(
  key: vehicleServicesKey,
  page: 'admin-settings-vehicle-services',
  title: 'Vehicle Services',
  subtitle: 'Manage vehicle services',
  table: 'settings_entries',
  fields: [],
);
const partnerTypeCategory = SettingsCategory(
  key: partnerTypeKey,
  page: 'admin-settings-partner-type',
  title: 'Partner Type',
  subtitle: 'Categories & nested sub-services',
  table: 'settings_entries',
  fields: [],
);
const documentTypeCategory = SettingsCategory(
  key: documentTypeKey,
  page: 'admin-settings-document-type',
  title: 'Document Type',
  subtitle: 'Categorize required documents',
  table: 'document_type',
  fields: [],
);
const requiredDocumentsCategory = SettingsCategory(
  key: requiredDocumentsKey,
  page: 'admin-settings-required-documents',
  title: 'Required Documents',
  subtitle: 'Partner onboarding docs',
  table: 'required_document',
  fields: [],
);

/// Entries of one category, refreshed by invalidating with the category key.
final catalogueEntriesProvider = FutureProvider.autoDispose.family<List<SettingEntry>, SettingsCategory>(
  (ref, c) {
  ref.watchLive('settings_entries');
  return ref.watch(adminRepositoryProvider).settings(c);
},
);

final catalogueRepositoryProvider = Provider((ref) => CatalogueRepository(ref.watch(supabaseProvider)));

final vehicleMakeModelsProvider = FutureProvider.autoDispose<List<VehicleMakeModel>>(
  (ref) {
  ref.watchLive('vehicle_make_models');
  return ref.watch(catalogueRepositoryProvider).vehicleMakeModels();
},
);

final regionOptionsProvider = FutureProvider.autoDispose<List<RegionSelection>>(
  (ref) {
  ref.watchLive('countries');
  ref.watchLive('states');
  return ref.watch(catalogueRepositoryProvider).regionOptions();
},
);

final apiProvidersProvider = FutureProvider.autoDispose<List<ApiProviderInfo>>(
  (ref) {
  ref.watchLive('app_settings');
  return ref.watch(catalogueRepositoryProvider).apiProviders();
},
);

final assignmentsProvider = FutureProvider.autoDispose<AssignmentsMap>((ref) => AssignmentStore.load());
final documentSourcesProvider = FutureProvider.autoDispose<Map<String, String>>((ref) => AssignmentStore.loadDocSources());

/// Data access for the catalogue screens that are not plain settings entries.
class CatalogueRepository {
  CatalogueRepository(this._db);
  final SupabaseClient _db;

  static const _uuid = Uuid();
  String newId() => _uuid.v4();

  /// Whole catalogue, paged so PostgREST's row cap never truncates it.
  Future<List<VehicleMakeModel>> vehicleMakeModels() async {
    const page = 1000;
    final out = <VehicleMakeModel>[];
    for (var from = 0;; from += page) {
      final rows = await _db
          .from('vehicle_make_models')
          .select()
          .order('position')
          .order('id')
          .range(from, from + page - 1);
      out.addAll(rows.map(VehicleMakeModel.fromRow));
      if (rows.length < page) break;
    }
    return out;
  }

  Future<void> upsertVehicleMakeModel(Map<String, dynamic> row) =>
      _db.from('vehicle_make_models').upsert(row, onConflict: 'id');

  /// Renames a category level across its rows (Expo upserts each row).
  Future<void> renameVehicleMakeModels(List<String> ids, int level, String name) async {
    if (ids.isEmpty) return;
    final column = switch (level) { 0 => 'vehicle_type', 1 => 'energy_type', _ => 'make' };
    await _db.from('vehicle_make_models').update({column: name}).inFilter('id', ids);
  }

  Future<void> deleteVehicleMakeModels(List<String> ids) async {
    if (ids.isEmpty) return;
    await _db.from('vehicle_make_models').delete().inFilter('id', ids);
  }

  /// Countries and states (the Expo region picker's `country-states-cities`
  /// entries with no city/suburb).
  Future<List<RegionSelection>> regionOptions() async {
    final results = await Future.wait([
      _db.from('countries').select('name'),
      _db.from('states').select('country, name'),
    ]);
    final seen = <String>{};
    final countries = <RegionSelection>[];
    for (final r in results[0]) {
      final c = '${r['name'] ?? ''}'.trim();
      final s = RegionSelection(type: 'country', country: c);
      if (c.isNotEmpty && seen.add(s.key)) countries.add(s);
    }
    final states = <RegionSelection>[];
    for (final r in results[1]) {
      final c = '${r['country'] ?? ''}'.trim();
      final n = '${r['name'] ?? ''}'.trim();
      final s = RegionSelection(type: 'state', country: c, state: n);
      if (c.isNotEmpty && n.isNotEmpty && seen.add(s.key)) states.add(s);
    }
    countries.sort((a, b) => a.label.compareTo(b.label));
    states.sort((a, b) => a.label.compareTo(b.label));
    return [...countries, ...states];
  }

  /// Uploads a partner-type icon to the public `partner-type-icons` bucket
  /// and returns its public URL.
  Future<String> uploadPartnerTypeIcon(Uint8List bytes, String fileName) async {
    final path = partnerTypeIconPath(iconExt(fileName));
    final bucket = _db.storage.from(partnerTypeIconsBucket);
    await bucket.uploadBinary(path, bytes,
        fileOptions: FileOptions(upsert: true, contentType: imageContentType(fileName)));
    return bucket.getPublicUrl(path);
  }

  /// Provider/service structure for the service picker. Key values are
  /// discarded on parse; this screen never writes the row back.
  Future<List<ApiProviderInfo>> apiProviders() async {
    final row = await _db.from('app_settings').select('value').eq('key', 'api_providers').maybeSingle();
    return providersFromStored(row?['value']);
  }
}

/// Device-local assignment storage (Expo keeps these in AsyncStorage).
class AssignmentStore {
  static Future<AssignmentsMap> load() async {
    final prefs = await SharedPreferences.getInstance();
    final m = migrateLegacyPageIds(parseAssignments(prefs.getString(serviceAssignmentsPrefsKey)));
    if (m.changed) await save(m.next);
    return m.next;
  }

  static Future<void> save(AssignmentsMap map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(serviceAssignmentsPrefsKey, _encode(map));
  }

  static Future<Map<String, String>> loadDocSources() async {
    final prefs = await SharedPreferences.getInstance();
    return parseDocumentSources(prefs.getString(documentSourcePrefsKey));
  }

  static Future<Map<String, String>> setDocSource(String featureId, String? requiredDocumentId) async {
    final next = {...await loadDocSources()};
    if (requiredDocumentId == null) {
      next.remove(featureId);
    } else {
      next[featureId] = requiredDocumentId;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(documentSourcePrefsKey, _encode(next));
    return next;
  }

  static String _encode(Object o) => jsonEncode(o);
}

/// Picks one image and returns its bytes and file name, or null.
Future<({Uint8List bytes, String name})?> pickImageFile() async {
  final files = await FilePicker.pickFiles(type: FileType.image);
  final f = files.firstOrNull;
  if (f == null) return null;
  return (bytes: await f.readAsBytes(), name: f.name);
}
