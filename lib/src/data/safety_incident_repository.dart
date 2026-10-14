// SOS to GET.ride's safety team (migration 0193): the person in trouble
// raises an incident and keeps its location up to date; admins see the open
// ones, acknowledge and resolve them, and set who is alerted.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';
import 'live_tables.dart';

/// Admin → App Settings → SOS alerts.
@immutable
class SosOpsConfig {
  const SosOpsConfig({
    this.onCall = const [],
    this.smsNumbers = const [],
    this.smsEnabled = true,
    this.realertMinutes = 2,
    this.locationMinutes = 30,
  });

  /// The admins alerted first (profile ids).
  final List<String> onCall;

  /// Ops phone numbers texted through the gateway's "Ops alert" channel.
  final List<String> smsNumbers;
  final bool smsEnabled;

  /// Unacknowledged: sent again this often, to every full admin too.
  final int realertMinutes;

  /// How long the reporter's phone keeps sending its location.
  final int locationMinutes;

  static const standard = SosOpsConfig();

  factory SosOpsConfig.fromJson(Object? json) {
    if (json is! Map) return standard;
    List<String> list(String k) => [for (final v in (json[k] is List ? json[k] as List : const [])) '$v'];
    int n(String k, int d) => json[k] is num ? (json[k] as num).round() : d;
    return SosOpsConfig(
      onCall: list('onCall'),
      smsNumbers: list('smsNumbers'),
      smsEnabled: json['smsEnabled'] != false,
      realertMinutes: n('realertMinutes', 2),
      locationMinutes: n('locationMinutes', 30),
    );
  }

  Map<String, dynamic> toJson() => {
    'onCall': onCall,
    'smsNumbers': smsNumbers,
    'smsEnabled': smsEnabled,
    'realertMinutes': realertMinutes,
    'locationMinutes': locationMinutes,
  };

  @override
  bool operator ==(Object other) =>
      other is SosOpsConfig &&
      listEquals(other.onCall, onCall) &&
      listEquals(other.smsNumbers, smsNumbers) &&
      other.smsEnabled == smsEnabled &&
      other.realertMinutes == realertMinutes &&
      other.locationMinutes == locationMinutes;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(onCall), Object.hashAll(smsNumbers), smsEnabled, realertMinutes, locationMinutes);
}

/// The ops numbers as typed: split on commas, spaces or new lines, each a
/// plausible number. Pure.
List<String> parseOpsNumbers(String text) => [
  for (final part in text.split(RegExp(r'[,;\n]')))
    if (RegExp(r'^\+?[0-9]{6,20}$').hasMatch(part.replaceAll(RegExp(r'[\s()-]'), '')))
      part.replaceAll(RegExp(r'[\s()-]'), ''),
];

/// One SOS, as an admin sees it.
@immutable
class SafetyIncident {
  const SafetyIncident(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id']}';
  String get status => (raw['status'] as String?) ?? 'open';
  bool get open => status == 'open';
  bool get resolved => status == 'resolved';
  String get reporterRole => (raw['reporter_role'] as String?) ?? 'user';
  String get reporterName => (raw['reporter_name'] as String?) ?? 'Someone';
  String? get reporterPhone => raw['reporter_phone'] as String?;
  String? get partnerName => raw['partner_name'] as String?;
  String? get plate => raw['plate'] as String?;
  String? get vehicle => raw['vehicle'] as String?;
  String? get pickupName => raw['pickup_name'] as String?;
  String? get dropName => raw['drop_name'] as String?;
  String? get rideId => raw['ride_id'] as String?;
  String? get note => raw['note'] as String?;
  double? get lat => (raw['lat'] as num?)?.toDouble();
  double? get lng => (raw['lng'] as num?)?.toDouble();
  DateTime? get createdAt => DateTime.tryParse('${raw['created_at']}')?.toLocal();
  DateTime? get locationAt => DateTime.tryParse('${raw['location_at'] ?? ''}')?.toLocal();
  int get alertRound => (raw['alert_round'] as num?)?.toInt() ?? 0;

  /// "Passenger", "Driver" or "User".
  String get roleLabel => switch (reporterRole) {
    'rider' => 'Passenger',
    'partner' => 'Driver',
    _ => 'User',
  };

  /// Where they are, on a map.
  Uri? get mapUri => lat == null || lng == null ? null : Uri.parse('https://maps.google.com/?q=$lat,$lng');
}

class SafetyIncidentRepository {
  SafetyIncidentRepository(this._db);
  final SupabaseClient _db;

  Future<String> raise({String? rideId, double? lat, double? lng}) async {
    final id = await _db.rpc('sos_raise', params: {'p_ride': rideId, 'p_lat': lat, 'p_lng': lng});
    return '$id';
  }

  Future<bool> shareLocation(String incidentId, double lat, double lng) async =>
      await _db.rpc('sos_location', params: {'p_incident': incidentId, 'p_lat': lat, 'p_lng': lng}) == true;

  Future<List<SafetyIncident>> list({bool openOnly = false}) async {
    var q = _db.from('safety_incidents').select();
    if (openOnly) q = q.inFilter('status', ['open', 'acknowledged']);
    return [for (final r in await q.order('created_at', ascending: false).limit(100)) SafetyIncident(r)];
  }

  Future<void> acknowledge(String id) => _db.rpc('sos_acknowledge', params: {'p_incident': id});

  Future<void> resolve(String id, {String? note}) => _db.rpc('sos_resolve', params: {'p_incident': id, 'p_note': note});

  Future<SosOpsConfig> config() async => SosOpsConfig.fromJson(await _db.rpc('admin_sos_ops_config'));

  Future<SosOpsConfig> saveConfig(SosOpsConfig c) async =>
      SosOpsConfig.fromJson(await _db.rpc('set_sos_ops_config', params: {'p_config': c.toJson()}));

  /// Admins who can be put on call: id → name (or phone).
  Future<Map<String, String>> admins() async {
    final ids = {for (final r in await _db.from('admin_access').select('profile_id')) '${r['profile_id']}'};
    if (ids.isEmpty) return const {};
    return {
      for (final p in await _db.from('profiles').select('id, name, phone').inFilter('id', ids.toList()))
        '${p['id']}': ((p['name'] as String?)?.trim().isNotEmpty ?? false)
            ? p['name'] as String
            : (p['phone'] as String?) ?? 'Admin',
    };
  }
}

final safetyIncidentRepositoryProvider = Provider((ref) => SafetyIncidentRepository(ref.watch(supabaseProvider)));

/// Open and acknowledged incidents, newest first, kept live for admins.
final activeIncidentsProvider = FutureProvider.autoDispose<List<SafetyIncident>>((ref) async {
  ref.watchAdminLive('safety_incidents');
  try {
    return await ref.watch(safetyIncidentRepositoryProvider).list(openOnly: true);
  } catch (_) {
    return const [];
  }
});

/// Every incident (the admin's history), newest first.
final allIncidentsProvider = FutureProvider.autoDispose<List<SafetyIncident>>((ref) async {
  ref.watchAdminLive('safety_incidents');
  return ref.watch(safetyIncidentRepositoryProvider).list();
});

/// After an SOS, the reporter's phone sends its position every
/// [every] until the server stops taking it (the admin's minutes) or the
/// app is closed.
class SosLocationSharer {
  SosLocationSharer(this._repo, {this.every = const Duration(seconds: 20), Future<Position?> Function()? position})
    : _position = position ?? _currentPosition;

  final SafetyIncidentRepository _repo;
  final Duration every;
  final Future<Position?> Function() _position;
  Timer? _timer;
  String? _incident;

  bool get running => _timer != null;

  static Future<Position?> _currentPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(timeLimit: Duration(seconds: 8)),
      );
    } catch (_) {
      try {
        return kIsWeb ? null : await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }

  /// Where the phone is now, for raising the SOS (null: unknown).
  Future<Position?> position() => _position();

  void start(String incidentId) {
    if (_incident == incidentId && running) return;
    stop();
    _incident = incidentId;
    _timer = Timer.periodic(every, (_) => unawaited(_send()));
  }

  Future<void> _send() async {
    final id = _incident;
    if (id == null) return;
    final p = await _position();
    if (p == null) return;
    try {
      // False once the window is over or the incident is resolved.
      if (!await _repo.shareLocation(id, p.latitude, p.longitude)) stop();
    } catch (_) {}
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _incident = null;
  }
}

final sosLocationSharerProvider = Provider((ref) {
  final s = SosLocationSharer(ref.watch(safetyIncidentRepositoryProvider));
  ref.onDispose(s.stop);
  return s;
});
