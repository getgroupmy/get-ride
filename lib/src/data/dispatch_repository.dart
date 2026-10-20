// Order dispatch (migration 0251): the console's, the stand admin's, the
// fleet owner's, the admin's and the driver's reads and writes. Every rule is
// the server's (RLS and the dispatch_* RPCs); this only asks.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/dispatch.dart';
import '../providers.dart';
import 'realtime_backup.dart';
import 'realtime_hub.dart';

/// What the signed-in person does in dispatch: the stands they work at and
/// the fleets they own. Empty for everyone else.
class DispatchRoles {
  const DispatchRoles({this.stands = const [], this.fleets = const []});
  static const none = DispatchRoles();

  final List<DispatchStand> stands;
  final List<DispatchGroup> fleets;

  bool get any => stands.isNotEmpty || fleets.isNotEmpty;
  bool get standAdmin => stands.any((s) => s.isStandAdmin);
}

/// Thrown when a phone needs an account and the dispatch-account function
/// answered with a refusal.
class DispatchAccountError implements Exception {
  const DispatchAccountError(this.code);
  final String code;

  @override
  String toString() => switch (code) {
    'not_authorized' => "You can't give that role.",
    'DISPATCH_ALREADY_ADMIN' => 'They are already the stand admin there.',
    'DISPATCH_SELF' => "You can't add yourself as staff.",
    'bad_request' => 'Check the name and phone number.',
    _ => "Couldn't create the ID ($code). Try again.",
  };
}

class DispatchRepository {
  DispatchRepository(this._db);
  final SupabaseClient _db;

  static List<Map<String, dynamic>> _list(Object? v) => [
    if (v is List)
      for (final e in v)
        if (e is Map) Map<String, dynamic>.from(e),
  ];

  static Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};

  // ---- Roles ------------------------------------------------------------------------

  /// The caller's stands and fleets. Quiet (no roles) on a database without
  /// 0251, or when the read fails.
  Future<DispatchRoles> myRoles() async {
    if (_db.auth.currentUser == null) return DispatchRoles.none;
    try {
      final r = await Future.wait([_db.rpc('dispatch_my_stands'), _db.rpc('dispatch_my_fleets')]);
      return DispatchRoles(
        stands: [for (final s in _list(r[0])) DispatchStand.fromJson(s)],
        fleets: [
          for (final g in _list(r[1])) DispatchGroup.fromJson({...g, 'kind': 'fleet'}),
        ],
      );
    } catch (_) {
      return DispatchRoles.none;
    }
  }

  // ---- The console ---------------------------------------------------------------------

  Future<List<DispatchOrder>> board({String? standId, int hours = 12}) async => [
    for (final o in _list(await _db.rpc('dispatch_board', params: {'p_stand': standId, 'p_hours': hours})))
      DispatchOrder.fromJson(o),
  ];

  Future<DispatchOrder> order(String id) async =>
      DispatchOrder.fromJson(_map(await _db.rpc('dispatch_order', params: {'p_request': id})));

  Future<List<NearbyDriver>> drivers(String standId) async => [
    for (final d in _list(await _db.rpc('dispatch_drivers', params: {'p_stand': standId}))) NearbyDriver.fromJson(d),
  ];

  Future<DispatchOrder> create(NewOrder o) async => DispatchOrder.fromJson(
    _map(await _db.rpc('dispatch_create_order', params: {'p_stand': o.standId, 'p_order': o.toJson()})),
  );

  /// 'widen', 'resend_group', 'resend_driver', 'reassign', 'picked_up',
  /// 'complete', 'cancel' (dispatch_order_action).
  Future<DispatchOrder> act(String id, String action, [Map<String, dynamic> args = const {}]) async =>
      DispatchOrder.fromJson(
        _map(await _db.rpc('dispatch_order_action', params: {'p_request': id, 'p_action': action, 'p_args': args})),
      );

  /// A booking ahead: 'release' (send now), 'reschedule' ({pickup_at,
  /// lead_minutes}), 'cancel' (dispatch_scheduled_action).
  Future<void> scheduledAction(String id, String action, [Map<String, dynamic> args = const {}]) =>
      _db.rpc('dispatch_scheduled_action', params: {'p_booking': id, 'p_action': action, 'p_args': args});

  /// The Call centre: whether the phone has a GET.ride account, and its name.
  Future<({bool found, String? name})> lookupCustomer(String phone) async {
    final m = _map(await _db.rpc('dispatch_lookup_customer', params: {'p_phone': phone}));
    return (found: m['found'] == true, name: m['name'] as String?);
  }

  Future<Map<String, dynamic>> report(String standId, {int days = 1}) async =>
      _map(await _db.rpc('dispatch_report', params: {'p_stand': standId, 'p_days': days}));

  Future<StandStatement> statement(String standId, DateTime from, DateTime to) async => StandStatement.fromJson(
    _map(
      await _db.rpc(
        'dispatch_statement',
        params: {'p_stand': standId, 'p_from': from.toUtc().toIso8601String(), 'p_to': to.toUtc().toIso8601String()},
      ),
    ),
  );

  /// The board live: re-read whenever a stand order changes (the read policy
  /// lets each person receive only their stands' rows), and every 15 s for
  /// the waiting ages and anything realtime dropped.
  Stream<List<DispatchOrder>> watchBoard({String? standId}) {
    final controller = StreamController<List<DispatchOrder>>();
    RealtimeListen? channel;
    RealtimeBackup? backup;
    Timer? debounce;
    Future<void> refresh() async {
      try {
        final list = await board(standId: standId);
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    controller.onListen = () {
      refresh();
      backup = RealtimeBackup(refresh, every: const Duration(seconds: 15));
      channel = RealtimeHub.of(_db).listen(
        table: 'ride_requests',
        filter: standId == null
            ? null
            : PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'stand_id', value: standId),
        onChange: (p) {
          final row = p.newRecord.isNotEmpty ? p.newRecord : p.oldRecord;
          if (standId == null && row['stand_id'] == null) return;
          debounce?.cancel();
          debounce = Timer(const Duration(milliseconds: 400), refresh);
        },
        onStatus: backup!.onStatus,
      );
    };
    controller.onCancel = () async {
      debounce?.cancel();
      backup?.dispose();
      channel?.cancel();
      await controller.close();
    };
    return controller.stream;
  }

  // ---- The stand admin -------------------------------------------------------------------

  /// The staff of the caller's stands (their own rows, by RLS).
  Future<List<Map<String, dynamic>>> staff(String standId) async => List<Map<String, dynamic>>.from(
    await _db.from('dispatch_stand_people').select().eq('stand_id', standId).eq('role', 'staff').order('created_at'),
  );

  Future<void> setStaff(String standId, String userId, {StandPerms? perms, bool? active}) => _db
      .from('dispatch_stand_people')
      .update({...?perms?.toStaffRow(), 'active': ?active})
      .eq('stand_id', standId)
      .eq('user_id', userId);

  Future<void> removeStaff(String standId, String userId) =>
      _db.from('dispatch_stand_people').delete().eq('stand_id', standId).eq('user_id', userId);

  Future<void> setStandFee(String standId, StandFee fee) => _db.rpc(
    'dispatch_set_stand_fee',
    params: {'p_stand': standId, 'p_type': fee.type.name, 'p_value': fee.value, 'p_payer': fee.payer.name},
  );

  /// Gives someone a dispatch role by phone: straight away when the number
  /// has an account, else through the dispatch-account function, which makes
  /// the account (they set their PIN on first sign-in). Returns true when an
  /// account was made.
  Future<bool> grant({
    required String kind,
    required String name,
    required String phone,
    List<String> standIds = const [],
    String? groupId,
    StandPerms perms = const StandPerms(),
  }) async {
    final done = _map(
      await _db.rpc(
        'dispatch_grant_existing',
        params: {
          'p_kind': kind,
          'p_name': name.trim(),
          'p_phone': phone.trim(),
          'p_stand_ids': standIds,
          'p_group': groupId,
          'p_perms': perms.toJson(),
        },
      ),
    );
    if (done['needs_account'] != true) return false;
    try {
      final res = await _db.functions.invoke(
        'dispatch-account',
        body: {
          'kind': kind,
          'name': name.trim(),
          'phone': phone.trim(),
          'stand_ids': standIds,
          'group_id': groupId,
          'perms': perms.toJson(),
        },
      );
      return _map(res.data)['created'] == true;
    } on FunctionException catch (e) {
      throw DispatchAccountError('${_map(e.details)['error'] ?? e.status}');
    }
  }

  // ---- The admin -------------------------------------------------------------------------

  Future<List<DispatchStand>> allStands() async {
    final rows = await _db.from('dispatch_stands').select().order('name');
    final links = await _db.from('dispatch_stand_groups').select('stand_id, group_id');
    final byStand = <String, List<String>>{};
    for (final l in links) {
      byStand.putIfAbsent('${l['stand_id']}', () => []).add('${l['group_id']}');
    }
    return [
      for (final r in rows) DispatchStand.fromJson({...r, 'admin': true, 'group_ids': byStand['${r['id']}'] ?? []}),
    ];
  }

  /// Adds or updates a stand and the groups it sends to.
  Future<String> saveStand(DispatchStand s, {String? id}) async {
    final row = s.toRow();
    final saved = id == null
        ? await _db.from('dispatch_stands').insert(row).select('id').single()
        : await _db.from('dispatch_stands').update(row).eq('id', id).select('id').single();
    final standId = '${saved['id']}';
    await _db.from('dispatch_stand_groups').delete().eq('stand_id', standId);
    if (s.groupIds.isNotEmpty) {
      await _db.from('dispatch_stand_groups').insert([
        for (final g in s.groupIds) {'stand_id': standId, 'group_id': g},
      ]);
    }
    return standId;
  }

  /// The admin's charges for a stand: the fee, who sets it, the platform's fee.
  Future<void> saveStandCharges(String standId, StandFee fee) => _db
      .from('dispatch_stands')
      .update({
        'fee_type': fee.type.name,
        'fee_value': fee.value,
        'fee_bearer': fee.payer.name,
        'fee_set_by': fee.setByStand ? 'stand' : 'admin',
        'platform_fee_type': fee.platformType == FeeType.fixed ? 'fixed' : 'percent',
        'platform_fee_value': fee.platformValue,
      })
      .eq('id', standId);

  /// Everyone who works at the stands (admins read every row).
  Future<List<Map<String, dynamic>>> standPeople() async =>
      List<Map<String, dynamic>>.from(await _db.from('dispatch_stand_people').select().order('created_at'));

  Future<void> setStandPerson(String standId, String userId, Map<String, dynamic> patch) =>
      _db.from('dispatch_stand_people').update(patch).eq('stand_id', standId).eq('user_id', userId);

  Future<List<DispatchGroup>> allGroups() async => [
    for (final r in await _db.from('dispatch_groups').select().order('name')) DispatchGroup.fromJson(r),
  ];

  Future<void> saveGroup(DispatchGroup g, {String? id}) async {
    if (id == null) {
      await _db.from('dispatch_groups').insert(g.toRow());
    } else {
      await _db.from('dispatch_groups').update(g.toRow()).eq('id', id);
    }
  }

  /// The group's drivers and requests, with names (admins and the fleet's owner).
  Future<List<Map<String, dynamic>>> groupPeople(String groupId) async =>
      _list(await _db.rpc('dispatch_group_people', params: {'p_group': groupId}));

  Future<void> decide(String groupId, String driverId, String status) =>
      _db.from('dispatch_group_members').update({'status': status}).eq('group_id', groupId).eq('driver_id', driverId);

  Future<void> removeMember(String groupId, String driverId) =>
      _db.from('dispatch_group_members').delete().eq('group_id', groupId).eq('driver_id', driverId);

  /// An admin adds a driver straight in.
  Future<void> addMember(String groupId, String driverId) => _db.from('dispatch_group_members').upsert({
    'group_id': groupId,
    'driver_id': driverId,
    'status': 'approved',
  }, onConflict: 'group_id,driver_id');

  Future<List<Map<String, dynamic>>> accounts() async => _list(await _db.rpc('dispatch_accounts'));

  /// Turns a stand admin's or fleet owner's ID on or off.
  Future<void> setAccountActive(String kind, String userId, bool active) => kind == 'fleet_owner'
      ? _db.from('dispatch_fleet_owners').update({'active': active}).eq('user_id', userId)
      : _db.from('dispatch_stand_people').update({'active': active}).eq('user_id', userId).eq('role', 'admin');

  // ---- The fleet owner -------------------------------------------------------------------

  Future<Map<String, dynamic>> fleet(String groupId) async =>
      _map(await _db.rpc('dispatch_fleet', params: {'p_group': groupId}));

  Future<void> fleetAdd(String groupId, String phoneOrPlate) =>
      _db.rpc('dispatch_fleet_add', params: {'p_group': groupId, 'p_query': phoneOrPlate.trim()});

  Future<List<Map<String, dynamic>>> fleetVehicles(String groupId) async =>
      _list(await _db.rpc('dispatch_fleet_vehicles', params: {'p_group': groupId}));

  Future<void> linkVehicle(String groupId, String vehicleId) =>
      _db.rpc('dispatch_fleet_link_vehicle', params: {'p_group': groupId, 'p_vehicle': vehicleId});

  Future<void> assignVehicle(String groupId, String vehicleId, String? driverId) =>
      _db.rpc('dispatch_fleet_assign', params: {'p_group': groupId, 'p_vehicle': vehicleId, 'p_driver': driverId});

  // ---- The driver ----------------------------------------------------------------------------

  /// An assigned order goes back to the stand; a broadcast one is noted.
  Future<void> decline(String requestId) async {
    try {
      await _db.rpc('dispatch_decline', params: {'p_request': requestId});
    } catch (_) {}
  }

  /// Completes a metered stand order at the meter's fare (the driver's own).
  Future<void> driverComplete(String requestId, double fare) =>
      _db.rpc('dispatch_driver_complete', params: {'p_request': requestId, 'p_fare': fare});

  /// The groups the driver may ask to join, with where they stand in each.
  Future<List<({DispatchGroup group, JoinState state})>> joinable() async {
    final uid = _db.auth.currentUser?.id;
    final groups = await _db.from('dispatch_groups').select().eq('active', true).order('name');
    final mine = uid == null
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _db.from('dispatch_group_members').select('group_id, status').eq('driver_id', uid),
          );
    final state = {for (final m in mine) '${m['group_id']}': JoinState.parse(m['status'])};
    return [
      for (final g in groups)
        if (g['allow_join'] == true || state.containsKey('${g['id']}'))
          (group: DispatchGroup.fromJson(g), state: state['${g['id']}'] ?? JoinState.none),
    ];
  }

  Future<void> askToJoin(String groupId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('Not signed in');
    await _db.from('dispatch_group_members').insert({'group_id': groupId, 'driver_id': uid});
  }

  Future<void> leave(String groupId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    await _db.from('dispatch_group_members').delete().eq('group_id', groupId).eq('driver_id', uid);
  }
}

final dispatchRepositoryProvider = Provider((ref) => DispatchRepository(ref.watch(supabaseProvider)));

/// The signed-in person's stands and fleets (re-read on sign-in).
final dispatchRolesProvider = FutureProvider<DispatchRoles>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(dispatchRepositoryProvider).myRoles();
});
