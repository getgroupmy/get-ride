// Freight (migration 0267): the freight sizes from Admin > Vehicle Services,
// the cargo photo (the rider's own folder of the private `ride-cargo`
// bucket, opened through short-lived signed links by the rider, the driver
// who takes the request and admins) and the rider's freight requests, live.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/freight.dart';
import '../core/ride_chat.dart' show RideMessageType, rideChatContentType;
import '../core/support_media.dart' show fileExt;
import '../providers.dart';
import 'live_tables.dart';
import 'models.dart';
import 'realtime_backup.dart';
import 'realtime_hub.dart';
import 'storage_links.dart' show cachedSignedLink;

class FreightRepository {
  FreightRepository(this._db);
  final SupabaseClient _db;

  static const _table = 'ride_requests';

  /// Every Vehicle Services entry, in the admin's order.
  Future<List<({String id, Map<String, dynamic> values})>> catalogue() async {
    final rows = await _db
        .from('settings_entries')
        .select('id, values')
        .eq('category', 'vehicle-services')
        .order('position', ascending: true)
        .order('created_at', ascending: true);
    return [
      for (final r in rows)
        (id: '${r['id']}', values: r['values'] is Map ? Map<String, dynamic>.from(r['values'] as Map) : <String, dynamic>{}),
    ];
  }

  /// Uploads a photo of the cargo into the rider's folder; its path.
  Future<String> uploadCargoPhoto(Uint8List bytes, String name) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('Sign in to add a photo.');
    final ext = fileExt(name);
    final path = rideCargoPhotoPath(uid, const Uuid().v4(), ext);
    await _db.storage
        .from(rideCargoBucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: rideChatContentType(RideMessageType.image, ext)));
    return path;
  }

  /// A short-lived link to a cargo photo; storage signs it only for the
  /// rider, the driver who took the request and admins.
  Future<String> cargoPhotoUrl(String path) => cachedSignedLink(
    '$rideCargoBucket/$path',
    ttl: rideCargoLinkTtl,
    sign: () => _db.storage.from(rideCargoBucket).createSignedUrl(path, rideCargoLinkTtl.inSeconds),
  );

  /// Uploads a proof of delivery (a photo at pickup or drop-off, or the
  /// signature) into the caller's own folder; its path.
  Future<String> uploadProof(Uint8List bytes, String name, String kind) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('Sign in to add a photo.');
    final ext = fileExt(name);
    final path = freightProofPath(uid, kind, const Uuid().v4(), ext);
    await _db.storage
        .from(rideCargoBucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: rideChatContentType(RideMessageType.image, ext)));
    return path;
  }

  /// Stores a proof on the ride: [column] is pickup_proof_path,
  /// dropoff_proof_path (the driver's) or delivery_signature_path (the
  /// sender's); the server checks whose it is.
  Future<void> setProof(String rideId, String column, String path) async {
    if (!const {'pickup_proof_path', 'dropoff_proof_path', 'delivery_signature_path'}.contains(column)) {
      throw ArgumentError.value(column, 'column');
    }
    await _db.from(_table).update({column: path}).eq('id', rideId);
  }

  /// Asks freight-notify to send the recipient's tracking link now (the
  /// server's job asks it again for anything left). Never throws.
  Future<void> notifyRecipient(String rideId) async {
    try {
      await _db.functions.invoke('freight-notify', body: {'rideId': rideId});
    } catch (_) {}
  }

  /// The tracking link notices of a ride (its rider, driver and admins).
  Future<List<Map<String, dynamic>>> notices(String rideId) async {
    final rows = await _db
        .from('freight_recipient_notices')
        .select('channel, status, error, sent_at, created_at')
        .eq('ride_id', rideId)
        .order('created_at', ascending: true);
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  /// The Freight settings (app_settings 'freight').
  Future<FreightConfig> config() async => FreightConfig.fromJson(await _db.rpc('freight_config'));

  Future<FreightConfig> saveConfig(FreightConfig c) async =>
      FreightConfig.fromJson(await _db.rpc('set_freight_config', params: {'p_config': c.toJson()}));

  /// The rider's freight requests (those with a cargo), newest first.
  Future<List<RideRequest>> mine({int limit = 30}) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _db
        .from(_table)
        .select()
        .eq('rider_id', uid)
        .not('cargo_description', 'is', null)
        .order('created_at', ascending: false)
        .limit(limit);
    return rows.map(RideRequest.new).toList();
  }

  /// [mine], again whenever one of the rider's requests changes (a driver's
  /// offer, an accept, the trip moving on).
  Stream<List<RideRequest>> watchMine() {
    final controller = StreamController<List<RideRequest>>();
    RealtimeListen? channel;
    RealtimeBackup? backup;
    Future<void> refresh() async {
      try {
        final list = await mine();
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    controller.onListen = () {
      refresh();
      backup = RealtimeBackup(refresh, every: const Duration(seconds: 15));
      channel = RealtimeHub.of(_db).listen(table: _table, onChange: (_) => refresh(), onStatus: backup!.onStatus);
    };
    controller.onCancel = () async {
      backup?.dispose();
      channel?.cancel();
      await controller.close();
    };
    return controller.stream;
  }
}

final freightRepositoryProvider = Provider((ref) => FreightRepository(ref.watch(supabaseProvider)));

/// The freight sizes a rider can book, live; none when they can't be read
/// (the home Freight box then stays "coming soon").
final freightVehiclesProvider = FutureProvider<List<FreightVehicle>>((ref) async {
  ref.watchLive('settings_entries');
  try {
    return freightVehiclesFrom(await ref.watch(freightRepositoryProvider).catalogue());
  } catch (_) {
    return const [];
  }
});

/// Whether the home Freight box opens the Freight page.
final freightAvailableProvider = Provider<bool>(
  (ref) => freightAvailable(ref.watch(freightVehiclesProvider).value ?? const []),
);

/// Uploads a picked cargo photo (bytes, file name); its storage path.
/// Overridden in tests.
final freightCargoPhotoUploadProvider = Provider<Future<String> Function(Uint8List bytes, String name)>(
  (ref) => ref.watch(freightRepositoryProvider).uploadCargoPhoto,
);

/// The signed link to a cargo photo, renewed before it runs out.
final freightCargoPhotoUrlProvider = FutureProvider.autoDispose.family<String, String>((ref, path) async {
  final url = await ref.watch(freightRepositoryProvider).cargoPhotoUrl(path);
  final keep = ref.keepAlive();
  final timer = Timer(rideCargoLinkTtl - const Duration(minutes: 10), () {
    keep.close();
    ref.invalidateSelf();
  });
  ref.onDispose(timer.cancel);
  return url;
});

/// The Freight settings, live; the defaults when they can't be read.
final freightConfigProvider = FutureProvider<FreightConfig>((ref) async {
  ref.watchLive('app_settings');
  try {
    return await ref.watch(freightRepositoryProvider).config();
  } catch (_) {
    return const FreightConfig();
  }
});

/// Uploads a proof of delivery (bytes, file name, kind); its storage path.
/// Overridden in tests.
final freightProofUploadProvider = Provider<Future<String> Function(Uint8List bytes, String name, String kind)>(
  (ref) => ref.watch(freightRepositoryProvider).uploadProof,
);

/// A ride's tracking link notices.
final freightNoticesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, rideId) => ref.watch(freightRepositoryProvider).notices(rideId),
);

/// The rider's freight requests, live.
final myFreightRequestsProvider = StreamProvider.autoDispose<List<RideRequest>>(
  (ref) => ref.watch(freightRepositoryProvider).watchMine(),
);
