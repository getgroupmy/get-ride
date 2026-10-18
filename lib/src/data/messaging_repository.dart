import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/messaging.dart';
import '../core/session_access.dart';
import '../core/sms_fallback.dart';
import '../core/sms_limits.dart';
import '../providers.dart';

/// SMS / WhatsApp routing (migration 0120): devices, routes and the SMS
/// queue.
class MessagingRepository {
  MessagingRepository(this._db);
  final SupabaseClient _db;

  /// Says this device is here; returns its row id.
  Future<String?> heartbeat({
    required String deviceId,
    String? label,
    String? platform,
    String kind = 'app',
    List<String> capabilities = const [],
    String? appVersion,
  }) async {
    final row = await _db.rpc(
      'messaging_heartbeat',
      params: {
        'p_device_id': deviceId,
        'p_label': label,
        'p_platform': platform,
        'p_kind': kind,
        'p_capabilities': capabilities,
        'p_app_version': appVersion,
      },
    );
    return row is Map ? '${row['id']}' : null;
  }

  Future<List<MessagingDevice>> devices() async => [
    for (final r in await _db.from('messaging_devices').select().order('last_seen_at', ascending: false))
      MessagingDevice.fromRow(r),
  ];

  Future<void> renameDevice(String id, String label) =>
      _db.from('messaging_devices').update({'label': label.trim().isEmpty ? null : label.trim()}).eq('id', id);

  Future<void> removeDevice(String id) => _db.from('messaging_devices').delete().eq('id', id);

  Future<List<MessagingRoute>> routes() async => [
    for (final r in await _db.from('messaging_routes').select()) ?MessagingRoute.fromRow(r),
  ];

  Future<void> saveRoute(MessagingRoute r) => _db.from('messaging_routes').upsert({
    ...r.toRow(),
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  }, onConflict: 'channel,direction');

  /// Queues an SMS on [channel]; the gateway routed to it sends it.
  Future<void> queueSms({required MessagingChannel channel, required String to, required String body}) =>
      _db.from('sms_outbox').insert({'channel': channel.id, 'to_phone': to, 'body': body});

  /// The newest queued SMS. A sign-in code's text is masked on the queue row
  /// (migration 0183); a full admin gets the real text back from
  /// sms_otp_secret (0187), a sub-admin gets nothing and keeps the mask.
  Future<List<Map<String, dynamic>>> recentOutbox({int limit = 20}) async {
    final rows = List<Map<String, dynamic>>.from(
      await _db.from('sms_outbox').select().order('created_at', ascending: false).limit(limit),
    );
    final otpIds = [
      for (final r in rows)
        if (r['channel'] == 'otp') '${r['id']}',
    ];
    if (otpIds.isEmpty) return rows;
    try {
      final secrets = {
        for (final s in await _db.from('sms_otp_secret').select('outbox_id, body').inFilter('outbox_id', otpIds))
          '${s['outbox_id']}': s['body'],
      };
      return [
        for (final r in rows) secrets.containsKey('${r['id']}') ? {...r, 'body': secrets['${r['id']}']} : r,
      ];
    } catch (_) {
      return rows;
    }
  }

  Future<List<Map<String, dynamic>>> recentInbox({int limit = 20}) async => List<Map<String, dynamic>>.from(
    await _db.from('sms_inbox').select().order('created_at', ascending: false).limit(limit),
  );

  // ---- Sign-in SMS limits (migration 0149) --------------------------------

  Future<SmsLimits> smsLimits() async {
    final row = await _db.from('sms_settings').select().eq('id', 1).maybeSingle();
    return row == null ? const SmsLimits() : SmsLimits.fromRow(row);
  }

  Future<void> saveSmsLimits(SmsLimits s) => _db.from('sms_settings').update(s.toPatch()).eq('id', 1);

  /// The newest sign-in SMS attempts, optionally only one [status].
  Future<List<SmsLogEntry>> smsLog({String? status, int limit = 50}) async {
    var q = _db.from('sms_log').select('id, phone, status, reason, created_at');
    if (status != null) q = q.eq('status', status);
    return [for (final r in await q.order('created_at', ascending: false).limit(limit)) SmsLogEntry.fromRow(r)];
  }

  /// Queued, blocked and failed attempts in the last [hours].
  Future<SmsActivity> smsActivity({int hours = 1}) async =>
      smsActivityFrom(await _db.rpc('sms_activity_summary', params: {'p_hours': hours}));

  /// SMS fallback for trips (migration 0150).
  Future<SmsFallbackSettings> smsFallback() async {
    final row = await _db.from('sms_fallback_settings').select().eq('id', 1).maybeSingle();
    return row == null ? const SmsFallbackSettings() : SmsFallbackSettings.fromRow(row);
  }

  Future<void> saveSmsFallback(SmsFallbackSettings s) =>
      _db.from('sms_fallback_settings').update(s.toPatch()).eq('id', 1);

  // ---- Session access (migration 0226) ---------------------------------------

  /// Every session key, newest first (never the key itself).
  Future<List<SessionKey>> sessionKeys() async {
    final rows = await _db.rpc('admin_session_keys');
    return [
      if (rows is List)
        for (final r in rows)
          if (r is Map) ?SessionKey.fromRow(Map<String, dynamic>.from(r)),
    ];
  }

  /// Adds a key (full admin only); answers the key, shown once, and when it
  /// ends.
  Future<({String key, DateTime? expiresAt})> createSessionKey({
    required String label,
    required String testPhone,
    required Set<SessionScope> scopes,
    required int hours,
    String? proxyDevice,
  }) async {
    final r = await _db.rpc(
      'admin_session_key_create',
      params: {
        'p_label': label,
        'p_test_phone': testPhone,
        'p_scopes': [for (final s in scopes) s.id],
        'p_hours': hours,
        'p_proxy_device': proxyDevice,
      },
    );
    final m = r is Map ? r : const {};
    final key = '${m['key'] ?? ''}';
    if (key.isEmpty) throw StateError('The server did not answer with a key.');
    return (key: key, expiresAt: DateTime.tryParse('${m['expires_at'] ?? ''}'));
  }

  Future<void> revokeSessionKey(String id) => _db.rpc('admin_session_key_revoke', params: {'p_id': id});

  /// Alerts, confirmed by the app, and texted, over the last [hours].
  Future<SmsFallbackSummary> smsFallbackSummary({int hours = 24}) async =>
      smsFallbackSummaryFrom(await _db.rpc('sms_fallback_summary', params: {'p_hours': hours}));
}

final messagingRepositoryProvider = Provider((ref) => MessagingRepository(ref.watch(supabaseProvider)));

/// Keeps an admin's app install in the device list (so it can be picked to
/// take support calls) with a heartbeat while the app is open. Nothing for
/// anyone else, and nothing when the database has no messaging tables yet.
class MessagingPresence {
  MessagingPresence({required this.repo, required this.deviceId, required this.label, required this.platform});

  final MessagingRepository repo;
  final String deviceId;
  final String label;
  final String platform;
  Timer? _timer;

  void start() {
    stop();
    unawaited(_beat());
    _timer = Timer.periodic(messagingHeartbeatEvery, (_) => unawaited(_beat()));
  }

  Future<void> _beat() async {
    try {
      await repo.heartbeat(deviceId: deviceId, label: label, platform: platform, capabilities: const ['voip']);
    } catch (e) {
      // No table yet (before 0120), or offline: try again next time.
      if (kDebugMode) debugPrint('messaging heartbeat: $e');
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
