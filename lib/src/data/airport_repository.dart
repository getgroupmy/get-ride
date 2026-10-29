// Airports (migration 0249): each airport's settings, its waiting zones and
// fare zones, its doors (the gates the Multi-Gate page edits too), the guide
// photos, the driver's queue state and the server's fare quote.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/airport_areas.dart';
import '../core/airport_queue.dart';
import '../providers.dart';
import 'live_tables.dart';
import 'place_gates_repository.dart';

/// The private bucket the pickup guides' photos are kept in.
const airportGuidesBucket = 'airport-guides';

/// A drawn zone: a waiting zone or a fixed-fare zone. [shape] is the stored
/// BoundaryShape object (`{coords, polygons?, bbox, source}`).
class AirportZone {
  const AirportZone({
    required this.id,
    required this.airportId,
    required this.name,
    required this.shape,
    this.position = 0,
    this.toAmount = 0,
    this.fromAmount = 0,
  });

  final String id;
  final String airportId;
  final String name;
  final Map<String, dynamic> shape;
  final int position;

  /// Fare zones only: the fixed fare to / from the airport.
  final double toAmount, fromAmount;

  /// Where the outline came from: drawn, osm, `region:<level>`, ….
  String get source => '${shape['source'] ?? 'manual'}';

  static AirportZone fromRow(Map<String, dynamic> r) {
    double n(Object? v) =>
        v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
    return AirportZone(
      id: '${r['id']}',
      airportId: '${r['airport_id']}',
      name: '${r['name'] ?? ''}',
      shape: Map<String, dynamic>.from((r['shape'] as Map?) ?? const {}),
      position: (r['position'] as num?)?.toInt() ?? 0,
      toAmount: n(r['to_amount']),
      fromAmount: n(r['from_amount']),
    );
  }
}

/// A short label for a zone's [source] chip.
String zoneSourceLabel(String source) {
  if (source.startsWith('region:')) return 'Saved ${source.substring(7)}';
  return switch (source) {
    'osm' => 'OpenStreetMap',
    'bbox' => 'Box',
    'google' || 'geonames' => source,
    _ => 'Drawn',
  };
}

class AirportRepository {
  AirportRepository(this._db);
  final SupabaseClient _db;
  static const _uuid = Uuid();

  Future<List<AirportSettings>> settings() async {
    final rows = await _db.from('airport_settings').select();
    return [for (final r in rows) AirportSettings.fromRow(r)];
  }

  Future<void> saveSettings(AirportSettings s) =>
      _db.from('airport_settings').upsert(s.toRow(), onConflict: 'airport_id');

  Future<List<AirportZone>> waitingZones() async {
    final rows = await _db
        .from('airport_waiting_zones')
        .select()
        .order('position', ascending: true).order('created_at', ascending: true);
    return [for (final r in rows) AirportZone.fromRow(r)];
  }

  Future<List<AirportZone>> fareZones() async {
    final rows = await _db
        .from('airport_fare_zones')
        .select()
        .order('position', ascending: true).order('created_at', ascending: true);
    return [for (final r in rows) AirportZone.fromRow(r)];
  }

  Future<void> saveZone(
    String table, {
    String? id,
    required String airportId,
    required String name,
    required Map<String, dynamic> shape,
    int position = 0,
    double? toAmount,
    double? fromAmount,
  }) => _db.from(table).upsert({
    'id': id ?? _uuid.v4(),
    'airport_id': airportId,
    'name': name.trim().isEmpty ? 'Zone' : name.trim(),
    'shape': shape,
    'position': position,
    'to_amount': ?toAmount,
    'from_amount': ?fromAmount,
  }, onConflict: 'id');

  Future<void> deleteZone(String table, String id) =>
      _db.from(table).delete().eq('id', id);

  /// Uploads a guide photo and answers its stored link (the public form; the
  /// app signs it to show it).
  Future<String> uploadGuidePhoto(
    String airportId,
    Uint8List bytes,
    String fileName,
  ) async {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : 'jpg';
    final path = '$airportId/${_uuid.v4()}.${ext.length > 5 ? 'jpg' : ext}';
    final bucket = _db.storage.from(airportGuidesBucket);
    await bucket.uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(
        upsert: true,
        contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
      ),
    );
    return bucket.getPublicUrl(path);
  }

  /// The vehicle services from lowest to highest (`vehicle_service_order`).
  /// postgrest-dart's `order` sorts descending unless asked otherwise; a bare
  /// `.order('rank')` listed the services highest first, so the admin's
  /// screen showed (and then saved) the table reversed.
  Future<List<String>> serviceOrder() async {
    final rows = await _db
        .from('vehicle_service_order')
        .select('service_id, rank')
        .order('rank', ascending: true)
        .order('service_id', ascending: true);
    return [for (final r in rows) '${r['service_id']}'];
  }

  /// Saves [ids] as the order, lowest first: every service listed is ranked
  /// 1, 2, 3 …; one no longer listed is taken off.
  Future<void> saveServiceOrder(List<String> ids) async {
    final current = await serviceOrder();
    final gone = [
      for (final id in current)
        if (!ids.contains(id)) id,
    ];
    if (gone.isNotEmpty) {
      await _db
          .from('vehicle_service_order')
          .delete()
          .inFilter('service_id', gone);
    }
    if (ids.isEmpty) return;
    await _db.from('vehicle_service_order').upsert([
      for (var i = 0; i < ids.length; i++)
        {'service_id': ids[i], 'rank': i + 1},
    ], onConflict: 'service_id');
  }

  Future<DriverAirportState> driverState() async {
    final res = await _db.rpc('airport_driver_state');
    return DriverAirportState.fromJson(res);
  }

  Future<void> declineOffer(String rideId) =>
      _db.rpc('airport_decline_offer', params: {'p_ride': rideId});

  /// The fare the server will book a ride at (null when neither end is at an
  /// airport, or it can't be reached).
  Future<AirportQuote?> quote({
    required LatLng pickup,
    required LatLng drop,
    required String service,
    required double km,
    required double normalFare,
    String? country,
    String? state,
    String? city,
    String? suburb,
    List<Map<String, Object>> optionCharges = const [],
    List<LatLng> stops = const [],
    DateTime? at,
  }) async {
    final res = await _db.rpc(
      'airport_fare_quote',
      params: {
        'p_pickup_lat': pickup.latitude,
        'p_pickup_lng': pickup.longitude,
        'p_drop_lat': drop.latitude,
        'p_drop_lng': drop.longitude,
        'p_service': service,
        'p_km': double.parse(km.toStringAsFixed(2)),
        'p_normal': normalFare,
        'p_country': country,
        'p_state': state,
        'p_city': city,
        'p_suburb': suburb,
        // The fare has these in it (0248); the server takes them out for the
        // airport fare and adds them back after the minimum.
        'p_option_charges': optionCharges.isEmpty ? null : optionCharges,
        // The trip's stops and its pickup time, for its place fees (0324).
        if (stops.isNotEmpty) 'p_stops': [for (final s in stops) {'lat': s.latitude, 'lng': s.longitude}],
        'p_at': ?at?.toUtc().toIso8601String(),
      },
    );
    return AirportQuote.fromJson(res);
  }
}

final airportRepositoryProvider = Provider(
  (ref) => AirportRepository(ref.watch(supabaseProvider)),
);

/// Every airport's settings by airport id; empty when unreadable.
final airportSettingsProvider = FutureProvider<Map<String, AirportSettings>>((
  ref,
) async {
  ref.watchLive('airport_settings');
  try {
    final list = await ref.watch(airportRepositoryProvider).settings();
    return {for (final s in list) s.airportId: s};
  } catch (_) {
    return const {};
  }
});

final airportWaitingZonesProvider = FutureProvider<List<AirportZone>>((
  ref,
) async {
  ref.watchLive('airport_waiting_zones');
  try {
    return await ref.watch(airportRepositoryProvider).waitingZones();
  } catch (_) {
    return const [];
  }
});

final airportFareZonesProvider = FutureProvider<List<AirportZone>>((ref) async {
  ref.watchLive('airport_fare_zones');
  try {
    return await ref.watch(airportRepositoryProvider).fareZones();
  } catch (_) {
    return const [];
  }
});

/// Every area's doors: an airport's (multi_gate gates under
/// `airport-areas`) and a multi-gate place's (its gates, 0258). A door's
/// airportId is its airport or place, which is its area's id.
final airportDoorsProvider = FutureProvider<List<AirportDoor>>((ref) async {
  final catalogue = await ref.watch(placeGatesProvider.future);
  return [
    for (final g in catalogue.gates)
      if (const {'airport-areas', 'multi-gate-places'}.contains(
        '${g.values['parentKey'] ?? ''}'.isEmpty ? 'multi-gate-places' : '${g.values['parentKey']}',
      ))
        AirportDoor.fromGate(g.id, g.values),
  ];
});

/// The airport whose drawn area holds [p] (no buffer), or null.
AirportArea? airportAt(List<AirportArea> areas, LatLng p) {
  for (final a in areas) {
    if (a.contains(p, bufferM: 0)) return a;
  }
  return null;
}

/// The vehicle services' order, lowest first; empty when unreadable.
final vehicleServiceOrderProvider = FutureProvider<List<String>>((ref) async {
  ref.watchLive('vehicle_service_order');
  try {
    return await ref.watch(airportRepositoryProvider).serviceOrder();
  } catch (_) {
    return const [];
  }
});
