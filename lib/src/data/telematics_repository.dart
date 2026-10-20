// Telematics (migration 0255): the reports' reads. Who may see what is the
// server's (telematics_access); this only asks.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/telematics.dart';
import '../providers.dart';

/// Whose telematics a page reads: the driver's own, everyone's (an admin),
/// a fleet's vehicles, or a stand's orders.
class TelematicsScope {
  const TelematicsScope._(this.kind, this.id, this.name);

  /// The signed-in driver's own.
  static const self = TelematicsScope._('self', null, null);

  /// Everyone (an admin with the Telematics page).
  static const admin = TelematicsScope._('admin', null, null);

  /// A fleet owner's fleet ([id] the fleet group).
  const TelematicsScope.fleet(String id, String name) : this._('fleet', id, name);

  /// A stand's orders ([id] the stand).
  const TelematicsScope.stand(String id, String name) : this._('stand', id, name);

  final String kind;
  final String? id;
  final String? name;

  String? get fleetId => kind == 'fleet' ? id : null;
  String? get standId => kind == 'stand' ? id : null;

  /// No online km for a stand: only its orders are its business.
  bool get hasOnlineKm => kind != 'stand';

  @override
  bool operator ==(Object other) => other is TelematicsScope && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// One report: [scope], narrowed to a driver and / or a vehicle (neither:
/// the whole scope), over [range].
typedef TelematicsQuery = ({TelematicsScope scope, TelematicsRange range, String? driverId, String? vehicleId});

/// One period list.
typedef TelematicsListQuery = ({TelematicsScope scope, TelematicsRange range, TelematicsGroup group});

class TelematicsRepository {
  TelematicsRepository(this._db);
  final SupabaseClient? _db;

  Future<TelematicsSummary> summary(TelematicsQuery q) async {
    final res = await _db!.rpc(
      'telematics_summary',
      params: {
        'p_from': q.range.from.toUtc().toIso8601String(),
        'p_to': q.range.to.toUtc().toIso8601String(),
        'p_bucket': q.range.bucket.db,
        'p_driver': q.driverId,
        'p_vehicle': q.vehicleId,
        'p_fleet': q.scope.fleetId,
        'p_stand': q.scope.standId,
      },
    );
    return TelematicsSummary.fromJson(res is Map ? Map<String, dynamic>.from(res) : const {});
  }

  Future<List<TelematicsListRow>> list(TelematicsListQuery q) async {
    final res = await _db!.rpc(
      'telematics_list',
      params: {
        'p_from': q.range.from.toUtc().toIso8601String(),
        'p_to': q.range.to.toUtc().toIso8601String(),
        'p_group': q.group.db,
        'p_fleet': q.scope.fleetId,
        'p_stand': q.scope.standId,
      },
    );
    return [
      if (res is List)
        for (final r in res)
          if (r is Map) TelematicsListRow.fromJson(Map<String, dynamic>.from(r)),
    ];
  }
}

final telematicsRepositoryProvider = Provider<TelematicsRepository>(
  (ref) => TelematicsRepository(ref.watch(supabaseProvider)),
);

final telematicsSummaryProvider = FutureProvider.autoDispose.family<TelematicsSummary, TelematicsQuery>(
  (ref, q) => ref.watch(telematicsRepositoryProvider).summary(q),
);

final telematicsListProvider = FutureProvider.autoDispose.family<List<TelematicsListRow>, TelematicsListQuery>(
  (ref, q) => ref.watch(telematicsRepositoryProvider).list(q),
);

/// The telematics pages' clock (for tests).
final telematicsClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
