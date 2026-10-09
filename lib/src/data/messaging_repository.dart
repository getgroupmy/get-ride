import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/messaging.dart';
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

  Future<List<Map<String, dynamic>>> recentOutbox({int limit = 20}) async => List<Map<String, dynamic>>.from(
    await _db.from('sms_outbox').select().order('created_at', ascending: false).limit(limit),
  );

  Future<List<Map<String, dynamic>>> recentInbox({int limit = 20}) async => List<Map<String, dynamic>>.from(
    await _db.from('sms_inbox').select().order('created_at', ascending: false).limit(limit),
  );
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
