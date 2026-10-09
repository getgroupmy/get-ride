// The server's side of the gateway: the RPCs of migrations 0120 / 0121.
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core.dart';

abstract class GatewayBackend {
  /// Says this phone is here and can send SMS; returns its device row id.
  Future<String> heartbeat({required String deviceId, String? label, String? simNumber, String? appVersion});

  /// The next jobs routed to this gateway, marked as sending.
  Future<List<SmsJob>> claim(String device, {int limit = 10});

  Future<void> report(String device, String jobId, {required bool ok, String? error});

  /// Hands the server an SMS this phone received.
  Future<void> receive(String device, IncomingSms sms);
}

class SupabaseGatewayBackend implements GatewayBackend {
  SupabaseGatewayBackend(this._db);
  final SupabaseClient _db;

  @override
  Future<String> heartbeat({required String deviceId, String? label, String? simNumber, String? appVersion}) async {
    final row = await _db.rpc(
      'messaging_heartbeat',
      params: {
        'p_device_id': deviceId,
        'p_label': label,
        'p_platform': 'android',
        'p_kind': 'gateway',
        'p_capabilities': ['sms'],
        'p_sim_number': simNumber,
        'p_app_version': appVersion,
      },
    );
    final id = row is Map ? '${row['id'] ?? ''}' : '';
    if (id.isEmpty) throw StateError('NOT_A_GATEWAY');
    return id;
  }

  @override
  Future<List<SmsJob>> claim(String device, {int limit = 10}) async {
    final rows = await _db.rpc('gateway_claim_sms', params: {'p_device': device, 'p_limit': limit});
    return [
      if (rows is List)
        for (final r in rows)
          if (r is Map) ?SmsJob.fromRow(Map<String, dynamic>.from(r)),
    ];
  }

  @override
  Future<void> report(String device, String jobId, {required bool ok, String? error}) =>
      _db.rpc('gateway_report_sms', params: {'p_device': device, 'p_id': jobId, 'p_ok': ok, 'p_error': error});

  @override
  Future<void> receive(String device, IncomingSms sms) => _db.rpc(
    'gateway_receive_sms',
    params: {
      'p_device': device,
      'p_from': sms.from,
      'p_body': sms.body,
      'p_received_at': sms.at.toUtc().toIso8601String(),
    },
  );
}
