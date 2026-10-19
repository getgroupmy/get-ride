// The server's side of the gateway: the RPCs of migrations 0120 / 0121, and
// since 0190 the paired phone's own (a device key instead of a sign-in).
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core.dart';
import 'settings.dart';

abstract class GatewayBackend {
  /// Says this phone is here and can send SMS; returns its device row id and
  /// the longest quiet wait between asks the admin set (migration 0236).
  Future<GatewayHeartbeat> heartbeat({required String deviceId, String? label, String? simNumber, String? appVersion});

  /// The next jobs routed to this gateway, marked as sending.
  Future<List<SmsJob>> claim(String device, {int limit = 10});

  Future<void> report(String device, String jobId, {required bool ok, String? error});

  /// Hands the server an SMS this phone received.
  Future<void> receive(String device, IncomingSms sms);
}

/// The paired phone's calls (migration 0190): each carries the device key,
/// so no account session is needed and none can lapse. [key] is read on
/// every call, so pairing again takes effect at once.
class SupabaseGatewayBackend implements GatewayBackend {
  SupabaseGatewayBackend(this._db, {required this.key});
  final SupabaseClient _db;

  /// The device key, read on each call.
  final String? Function() key;

  String get _k {
    final k = key();
    if (k == null) throw StateError('GATEWAY_KEY_INVALID');
    return k;
  }

  @override
  Future<GatewayHeartbeat> heartbeat({
    required String deviceId,
    String? label,
    String? simNumber,
    String? appVersion,
  }) async {
    final row = await _db.rpc(
      'gateway_key_heartbeat',
      params: {'p_key': _k, 'p_label': label, 'p_sim_number': simNumber, 'p_app_version': appVersion},
    );
    final hb = GatewayHeartbeat.fromRow(row);
    if (hb.device.isEmpty) throw StateError('NOT_A_GATEWAY');
    return hb;
  }

  @override
  Future<List<SmsJob>> claim(String device, {int limit = 10}) async {
    final rows = await _db.rpc('gateway_key_claim', params: {'p_key': _k, 'p_limit': limit});
    return [
      if (rows is List)
        for (final r in rows)
          if (r is Map) ?SmsJob.fromRow(Map<String, dynamic>.from(r)),
    ];
  }

  @override
  Future<void> report(String device, String jobId, {required bool ok, String? error}) =>
      _db.rpc('gateway_key_report', params: {'p_key': _k, 'p_id': jobId, 'p_ok': ok, 'p_error': error});

  @override
  Future<void> receive(String device, IncomingSms sms) => _db.rpc(
    'gateway_key_receive',
    params: {'p_key': _k, 'p_from': sms.from, 'p_body': sms.body, 'p_received_at': sms.at.toUtc().toIso8601String()},
  );
}

/// Pairs this phone with a code from Admin → SMS / WhatsApp; null when
/// paired (the key is kept in [settings]), else what to show.
Future<String?> pairGateway(SupabaseClient db, GatewaySettings settings, String code, {String? appVersion}) async {
  try {
    final res = await db.rpc(
      'gateway_pair',
      params: {
        'p_code': normalizePairCode(code),
        'p_device_id': settings.deviceId,
        'p_label': settings.label,
        'p_sim_number': settings.simNumber,
        'p_app_version': appVersion,
      },
    );
    final r = pairResult(res);
    if (r.key == null) return r.error;
    settings.gatewayKey = r.key;
    return null;
  } on PostgrestException catch (e) {
    return e.hint?.isNotEmpty == true ? e.hint : "Couldn't pair. Check this phone's connection and try again.";
  } catch (_) {
    return "Couldn't reach GET.ride. Check this phone's connection and try again.";
  }
}
