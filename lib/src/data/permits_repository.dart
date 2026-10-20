// Permits per country (migration 0254): the passenger's view of a ride's
// permits, the driver's own, and the admin's lists and settings.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/permits.dart';
import '../providers.dart';

/// A vehicle with its permits, as ride_permits / my_permits / the admin list give it.
class VehiclePermits {
  const VehiclePermits({
    this.vehicleId,
    this.plate,
    this.label,
    this.energy,
    this.types = const [],
    this.colours,
    this.status = PermitStatus.none,
    this.bypassUntil,
    this.joinedAt,
    this.permits = const [],
    this.active = false,
    this.countries = const [],
  });

  factory VehiclePermits.fromJson(Map<String, dynamic> j) => VehiclePermits(
    vehicleId: j['vehicle_id'] as String?,
    plate: (j['plate'] as String?)?.trim(),
    label: (j['label'] ?? j['vehicle']) as String?,
    energy: j['energy'] as String?,
    types: [for (final t in (j['types'] as List?) ?? const []) '$t'],
    colours: plateColoursFromJson(j['colours']),
    status: PermitStatus.parse(j['status']),
    bypassUntil: DateTime.tryParse('${j['bypass_until'] ?? ''}')?.toLocal(),
    joinedAt: DateTime.tryParse('${j['joined_at'] ?? ''}')?.toLocal(),
    permits: [
      for (final p in (j['permits'] as List?) ?? const [])
        if (p is Map) PermitItem.fromJson(p.cast<String, dynamic>()),
    ],
    active: j['active'] == true,
    countries: [for (final c in (j['countries'] as List?) ?? const []) '$c'],
  );

  final String? vehicleId;
  final String? plate;
  final String? label;
  final String? energy;
  final List<String> types;
  final PlateColours? colours;
  final PermitStatus status;
  final DateTime? bypassUntil;
  final DateTime? joinedAt;
  final List<PermitItem> permits;

  /// The vehicle the driver has taken now.
  final bool active;
  final List<String> countries;

  bool get onBypass => bypassUntil != null && bypassUntil!.isAfter(DateTime.now());
}

/// The driver's vehicles and own permits.
class MyPermits {
  const MyPermits({this.vehicles = const [], this.driverPermits = const [], this.problem});
  factory MyPermits.fromJson(Map<String, dynamic> j) => MyPermits(
    vehicles: [
      for (final v in (j['vehicles'] as List?) ?? const [])
        if (v is Map) VehiclePermits.fromJson(v.cast<String, dynamic>()),
    ],
    driverPermits: [
      for (final p in (j['driver_permits'] as List?) ?? const [])
        if (p is Map) PermitItem.fromJson(p.cast<String, dynamic>()),
    ],
    problem: j['problem'] as String?,
  );
  final List<VehiclePermits> vehicles;
  final List<PermitItem> driverPermits;

  /// Why the driver can't go online now, or null.
  final String? problem;

  /// The vehicle being driven, else the only one.
  VehiclePermits? get current =>
      vehicles.where((v) => v.active).firstOrNull ?? (vehicles.length == 1 ? vehicles.single : null);
}

class PermitsRepository {
  PermitsRepository(this._db);
  final SupabaseClient _db;

  /// The permits a ride's rider may see now; null outside acceptance to trip end.
  Future<VehiclePermits?> ridePermits(String rideId) async {
    final res = await _db.rpc('ride_permits', params: {'p_ride': rideId});
    return res is Map ? VehiclePermits.fromJson(res.cast<String, dynamic>()) : null;
  }

  Future<MyPermits> myPermits() async {
    final res = await _db.rpc('my_permits');
    return res is Map ? MyPermits.fromJson(res.cast<String, dynamic>()) : const MyPermits();
  }

  // ---- Admin ----------------------------------------------------------------

  Future<List<VehiclePermits>> adminVehicles(String country) async {
    final res = await _db.rpc('admin_vehicle_permits', params: {'p_country': country});
    return [
      for (final v in (res as List?) ?? const [])
        if (v is Map) VehiclePermits.fromJson(v.cast<String, dynamic>()),
    ];
  }

  Future<VehiclePermits?> adminVehicle(String vehicleId) async {
    final res = await _db.rpc('admin_vehicle_permit_card', params: {'p_vehicle': vehicleId});
    return res is Map ? VehiclePermits.fromJson(res.cast<String, dynamic>()) : null;
  }

  /// Starts ([on]) or ends a vehicle's bypass; when it ends.
  Future<DateTime?> setBypass(String vehicleId, bool on) async {
    final res = await _db.rpc('vehicle_permit_bypass', params: {'p_vehicle': vehicleId, 'p_on': on});
    return DateTime.tryParse('${res ?? ''}')?.toLocal();
  }

  Future<List<PermitType>> permitTypes() async {
    final rows = await _db.from('permit_types').select().order('position', ascending: true).order('name', ascending: true);
    return [for (final r in rows) PermitType.fromRow(r)];
  }

  Future<void> saveType(PermitType t) async {
    if (t.id == null) {
      await _db.from('permit_types').insert(t.toRow());
    } else {
      await _db.from('permit_types').update(t.toRow()).eq('id', t.id!);
    }
  }

  Future<void> deleteType(String id) => _db.from('permit_types').delete().eq('id', id);

  Future<List<PermitCountrySettings>> countrySettings() async {
    final rows = await _db.from('permit_country_settings').select().order('country', ascending: true);
    return [for (final r in rows) PermitCountrySettings.fromRow(r)];
  }

  Future<void> saveCountrySettings(String country, Map<String, dynamic> values) =>
      _db.from('permit_country_settings').upsert({'country': country, ...values}, onConflict: 'country');

  Future<List<ReminderDays>> reminderDays() async {
    final rows = await _db.from('document_reminder_days').select().order('scope', ascending: true);
    return [for (final r in rows) ReminderDays.fromRow(r)];
  }

  /// Saves a reminder list; empty [days] for a scope other than the
  /// default removes it (back to the default).
  Future<void> saveReminderDays(ReminderScope scope, String key, List<int> days) async {
    if (days.isEmpty && scope != ReminderScope.defaultDays) {
      await _db.from('document_reminder_days').delete().eq('scope', scope.wire).eq('scope_key', key);
      return;
    }
    await _db
        .from('document_reminder_days')
        .upsert({'scope': scope.wire, 'scope_key': key, 'days': days}, onConflict: 'scope,scope_key');
  }

  Future<List<Map<String, dynamic>>> expiringDocuments({int days = 45}) async {
    final res = await _db.rpc('admin_expiring_documents', params: {'p_days': days});
    return [
      for (final r in (res as List?) ?? const [])
        if (r is Map) r.cast<String, dynamic>(),
    ];
  }

  /// Saves an admin's upload of a vehicle permit (approved: it is GET.ride's own).
  Future<void> saveVehiclePermit({
    required String vehicleId,
    required PermitType type,
    required String fileUrl,
    required Map<String, String> values,
    Map<String, dynamic>? ai,
  }) async {
    String? byRole(PermitFieldRole role) {
      final f = type.fields.where((f) => f.role == role).firstOrNull;
      final v = f == null ? null : values[f.key]?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    final row = {
      'vehicle_id': vehicleId,
      'doc_id': 'permit:${type.key}',
      'doc_name': type.name,
      'permit_type_id': type.id,
      'document_number': byRole(PermitFieldRole.number),
      'start_date': byRole(PermitFieldRole.validFrom),
      'expiry_date': byRole(PermitFieldRole.validUntil),
      'file_url': fileUrl,
      'permit_fields': {for (final e in values.entries) if (e.value.trim().isNotEmpty) e.key: e.value.trim()},
      'status': 'Approved',
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
      'uploaded_at': DateTime.now().toUtc().toIso8601String(),
      'ai_verification': ?ai,
    };
    final existing = await _db
        .from('vehicle_documents')
        .select('id')
        .eq('vehicle_id', vehicleId)
        .eq('permit_type_id', type.id!)
        .maybeSingle();
    if (existing != null) {
      await _db.from('vehicle_documents').update(row).eq('id', existing['id'] as Object);
    } else {
      await _db.from('vehicle_documents').insert(row);
    }
  }
}

final permitsRepositoryProvider = Provider((ref) => PermitsRepository(ref.watch(supabaseProvider)));

/// The permits of a ride for its rider (null outside acceptance to trip end).
final ridePermitsProvider = FutureProvider.autoDispose.family<VehiclePermits?, String>(
  (ref, rideId) => ref.watch(permitsRepositoryProvider).ridePermits(rideId),
);

/// The driver's own permits.
final myPermitsProvider = FutureProvider.autoDispose<MyPermits>((ref) => ref.watch(permitsRepositoryProvider).myPermits());
