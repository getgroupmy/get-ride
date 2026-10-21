// Driver services (migration 0263): the driver's Services page reads what
// the car they drive can do (`driver_services_for`) and keeps their switches
// per car (`driver_service_prefs`); Admin > Driver service locks keeps a
// service on or off for some drivers (`driver_service_locks`, saved through
// `driver_service_locks_set`) and reads who changed what.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/driver_services.dart';
import '../core/service_tree.dart';
import '../providers.dart';
import 'app_display_repository.dart' show serviceBoxNamesProvider;
import 'geo_service.dart' show currentPosition;
import 'live_tables.dart';

const driverServicePrefsTable = 'driver_service_prefs';
const driverServiceLocksTable = 'driver_service_locks';
const driverServiceLockEventsTable = 'driver_service_lock_events';

/// One change in the locks' log.
class LockEvent {
  const LockEvent({
    required this.action,
    required this.scope,
    required this.target,
    required this.serviceKey,
    this.on,
    this.until,
    this.note,
    this.actorId,
    this.at,
  });

  factory LockEvent.fromRow(Map<String, dynamic> r) {
    final t = r['target'] is Map ? Map<String, dynamic>.from(r['target'] as Map) : const <String, dynamic>{};
    String? s(String k) => '${t[k] ?? ''}'.trim().isEmpty ? null : '${t[k]}'.trim();
    final scope = LockScope.parse(r['scope']) ?? LockScope.everyone;
    return LockEvent(
      action: '${r['action'] ?? ''}',
      scope: scope,
      target: LockTarget(
        scope: scope,
        driverId: s('driver_id'),
        partnerType: s('partner_type'),
        fleetId: s('fleet_id'),
        country: s('country'),
        state: s('state'),
        city: s('city'),
      ),
      serviceKey: '${r['service_key'] ?? ''}',
      on: r['mode'] == null ? null : r['mode'] == 'on',
      until: DateTime.tryParse('${r['until'] ?? ''}'),
      note: r['note'] as String?,
      actorId: r['actor_id'] as String?,
      at: DateTime.tryParse('${r['at'] ?? ''}'),
    );
  }

  /// added / changed / removed.
  final String action;
  final LockScope scope;
  final LockTarget target;
  final String serviceKey;
  final bool? on;
  final DateTime? until;
  final String? note;
  final String? actorId;
  final DateTime? at;
}

class DriverServicesRepository {
  DriverServicesRepository(this._db);
  final SupabaseClient _db;

  String? get _uid => _db.auth.currentUser?.id;

  /// What the Services page shows for [vehicleId] (null: the car in use).
  Future<DriverServicesOverview> overview({String? vehicleId}) async =>
      DriverServicesOverview.fromJson(await _db.rpc('driver_services_for', params: {'p_vehicle': vehicleId}));

  /// The signed-in driver's switch for [key] with [vehicleId].
  Future<void> setSwitch(String vehicleId, String key, bool on) async {
    final uid = _uid;
    if (uid == null) throw StateError('Not signed in');
    await _db.from(driverServicePrefsTable).upsert(
      {'driver_id': uid, 'vehicle_id': vehicleId, 'service_key': DriverServiceKey.normalise(key), 'enabled': on},
      onConflict: 'driver_id,vehicle_id,service_key',
    );
  }

  // ---- Admin ---------------------------------------------------------------------

  Future<List<LockRule>> locks() async => [
    for (final r in await _db.from(driverServiceLocksTable).select().order('updated_at', ascending: false))
      LockRule.fromRow(Map<String, dynamic>.from(r)),
  ];

  /// Saves [rules] (key to on / off / driver) for each of [targets], until
  /// [until] (null: no end).
  Future<int> saveLocks(List<LockTarget> targets, Map<String, String> rules, {DateTime? until, String? note}) async {
    final n = await _db.rpc('driver_service_locks_set', params: {
      'p_targets': [for (final t in targets) t.toJson()],
      'p_rules': rules,
      'p_until': until?.toUtc().toIso8601String(),
      'p_note': (note ?? '').trim().isEmpty ? null : note!.trim(),
    });
    return n is num ? n.toInt() : 0;
  }

  Future<void> removeLocks(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db.from(driverServiceLocksTable).delete().inFilter('id', list);
  }

  /// How many drivers switched each key off.
  Future<Map<String, int>> offCounts() async {
    final rows = await _db.rpc('driver_service_off_counts');
    return {
      for (final r in (rows is List ? rows : const []))
        if (r is Map) '${r['service_key']}': (r['drivers'] as num?)?.toInt() ?? 0,
    };
  }

  Future<List<LockEvent>> events({int limit = 100}) async => [
    for (final r in await _db.from(driverServiceLockEventsTable).select().order('at', ascending: false).limit(limit))
      LockEvent.fromRow(Map<String, dynamic>.from(r)),
  ];
}

final driverServicesRepositoryProvider = Provider((ref) => DriverServicesRepository(ref.watch(supabaseProvider)));

/// The signed-in driver's Services page for the car they drive. Empty
/// (no car) when it can't be read, so a menu row or the meter never waits
/// on it.
final myDriverServicesProvider = FutureProvider.autoDispose<DriverServicesOverview>((ref) async {
  ref.watchLive(driverServicePrefsTable);
  ref.watchLive(driverServiceLocksTable);
  ref.watchLive('settings_entries');
  return ref.watch(driverServicesRepositoryProvider).overview();
});

/// Whether the driver menu shows Services.
final servicesPageAvailableProvider = Provider.autoDispose<bool>((ref) {
  if (ref.watch(partnerProvider).value == null) return false;
  return servicesPageAvailable(ref.watch(myDriverServicesProvider).value);
});

/// Street hail as the meter checks it: unknown (still loading, no car, not
/// a partner) lets the hire start.
final hailGateProvider = Provider.autoDispose<HailGate>((ref) {
  final o = ref.watch(myDriverServicesProvider);
  return o.hasError ? const HailGate() : HailGate.of(o.value);
});

/// Where the driver is, for the region's services; a provider so tests can
/// place them.
final driverServicesPositionProvider = Provider((_) => currentPosition);

/// The ids of the services the driver's region doesn't offer where they are
/// now (Admin > Country / States / Cities: services, sub-service switches
/// and availability rules). Empty when the place or the regions can't be
/// read.
final driverServicesRegionOffProvider = FutureProvider.autoDispose<Set<String>>((ref) async {
  final overview = await ref.watch(myDriverServicesProvider.future);
  if (overview.services.isEmpty) return const {};
  try {
    final at = await ref.read(driverServicesPositionProvider)();
    if (at == null) return const {};
    final rules = await ref.read(rideRepositoryProvider).ruleContextFor(at, () async => null);
    if (rules.around.isEmpty) return const {};
    final masters = await ref.watch(serviceBoxNamesProvider.future);
    final idsByName = {for (final e in masters.entries) e.value.trim().toLowerCase(): e.key};
    final tree = ServiceTree.build(
      [for (final e in masters.entries) ServiceEntry(id: e.key, name: e.value, category: masterServiceCategory)],
      [
        for (final s in overview.services)
          ServiceEntry(id: s.id, name: s.name, category: 'vehicle-services', parentIds: s.parentIds, typeNames: s.typeNames),
      ],
    );
    final now = DateTime.now().toUtc();
    return {
      for (final s in overview.services)
        if (!rules.available(
          types: {for (final t in s.typeNames) ?idsByName[t.trim().toLowerCase()]},
          vehicleType: s.id,
          lineage: tree.lineage(s.id),
          nowUtc: now,
        ))
          s.id,
    };
  } catch (_) {
    return const {};
  }
});
