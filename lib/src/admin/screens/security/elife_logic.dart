/// Pure half of `expo/utils/elifeApiStore.ts`. The config is one JSON object in
/// `app_settings` (key = `elife_api_connection`), readable by admins only
/// (restrictive RLS policy "app_settings elife admin only select").
library;

import 'dart:math';

const elifeRemoteKey = 'elife_api_connection';
const elifeDocsUrl = 'https://app.theneo.io/elifetransfer/suppliers/fleet-ride-management-api';
const elifeActivityCap = 25;

/// The stored defaults (Expo `DEFAULT_ELIFE_CONFIG`).
const defaultElifeConfig = <String, dynamic>{
  'enabled': false,
  'environment': 'sandbox',
  'baseUrl': 'https://api.elifetransfer.com',
  'tokenUrl': 'https://api.elifetransfer.com/oauth/token',
  'clientId': '',
  'clientSecret': '',
  'webhookUrl': '',
  'status': 'unknown',
  'activity': <Object>[],
};

/// Defaults overlaid with the stored object, activity capped. Works on the
/// raw JSON map so fields this client doesn't know are preserved.
Map<String, dynamic> normalizeElife(Object? raw) {
  final m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  final activity = m['activity'] is List ? (m['activity'] as List).take(elifeActivityCap).toList() : <Object>[];
  return {...defaultElifeConfig, ...m, 'activity': activity};
}

class ElifeEvent {
  const ElifeEvent({required this.id, required this.at, required this.kind, required this.ok, required this.status, required this.message});

  factory ElifeEvent.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return ElifeEvent(
      id: '${m['id'] ?? ''}',
      at: m['at'] is num ? (m['at'] as num).toInt() : 0,
      kind: '${m['kind'] ?? ''}',
      ok: m['ok'] == true,
      status: m['status'] is num ? (m['status'] as num).toInt() : 0,
      message: '${m['message'] ?? ''}',
    );
  }

  final String id;
  final int at;
  final String kind;
  final bool ok;
  final int status;
  final String message;
}

List<ElifeEvent> elifeActivity(Map<String, dynamic> config) =>
    [for (final e in (config['activity'] as List?) ?? const []) ElifeEvent.fromJson(e)];

String _genId(String prefix, DateTime now) {
  final r = Random();
  return '${prefix}_${now.millisecondsSinceEpoch.toRadixString(36)}_'
      '${List.generate(5, (_) => r.nextInt(36).toRadixString(36)).join()}';
}

List<Object?> _append(Map<String, dynamic> config, DateTime now,
    {required String kind, required bool ok, required int status, required String message}) {
  final entry = {
    'id': _genId('evt', now),
    'at': now.millisecondsSinceEpoch,
    'kind': kind,
    'ok': ok,
    'status': status,
    'message': message,
  };
  return [entry, ...((config['activity'] as List?) ?? const [])].take(elifeActivityCap).toList();
}

/// Saves form fields; [logMessage] also records a "config" event.
Map<String, dynamic> applyElifePatch(Map<String, dynamic> current, Map<String, dynamic> patch,
    {String? logMessage, DateTime? now}) {
  final merged = {...current, ...patch};
  if (logMessage == null) return merged;
  return {
    ...merged,
    'activity': _append(current, now ?? DateTime.now(), kind: 'config', ok: true, status: 0, message: logMessage),
  };
}

/// Turning off also sets status "disabled"; both log an event.
Map<String, dynamic> setElifeEnabled(Map<String, dynamic> current, bool enabled, {DateTime? now}) => {
      ...current,
      'enabled': enabled,
      'status': enabled ? current['status'] : 'disabled',
      'activity': _append(current, now ?? DateTime.now(),
          kind: enabled ? 'enable' : 'disable',
          ok: true,
          status: 0,
          message: enabled ? 'Integration enabled' : 'Integration disabled'),
    };

Map<String, dynamic> clearElifeActivity(Map<String, dynamic> current) => {...current, 'activity': <Object>[]};

class ElifeTestResult {
  const ElifeTestResult({required this.ok, required this.status, required this.message});
  final bool ok;
  final int status;
  final String message;
}

/// Pre-flight check before the token request; null when it can be sent.
ElifeTestResult? elifePreflight(Map<String, dynamic> config) {
  if ('${config['clientId'] ?? ''}'.trim().isEmpty || '${config['clientSecret'] ?? ''}'.trim().isEmpty) {
    return const ElifeTestResult(ok: false, status: 0, message: 'Client ID and Client Secret are required.');
  }
  if ('${config['tokenUrl'] ?? ''}'.trim().isEmpty) {
    return const ElifeTestResult(ok: false, status: 0, message: 'Token URL is not configured.');
  }
  return null;
}

/// Maps the token endpoint's HTTP status to a result. The response body is
/// deliberately not kept: on success it holds an access token.
ElifeTestResult elifeResultForStatus(int status) => status >= 200 && status < 300
    ? ElifeTestResult(ok: true, status: status, message: 'Access token obtained successfully.')
    : ElifeTestResult(ok: false, status: status, message: 'Token request failed (HTTP $status).');

/// Records a test outcome: status, lastCheckedAt, lastError and an event.
Map<String, dynamic> applyElifeTest(Map<String, dynamic> current, ElifeTestResult result, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final next = {
    ...current,
    'status': result.ok ? 'connected' : 'error',
    'lastCheckedAt': at.millisecondsSinceEpoch,
    'lastError': result.message,
    'activity': _append(current, at, kind: 'test', ok: result.ok, status: result.status, message: result.message),
  };
  if (result.ok) next.remove('lastError');
  return next;
}

/// "connected" / "error" / "disabled" / "unknown" as shown (a disabled
/// integration always reads disabled).
String elifeDisplayStatus(Map<String, dynamic> config) =>
    config['enabled'] == true ? '${config['status'] ?? 'unknown'}' : 'disabled';

String elifeStatusLabel(String status) => switch (status) {
      'connected' => 'Connected',
      'error' => 'Connection error',
      'disabled' => 'Disabled',
      _ => 'Not tested',
    };

String timeAgo(int epochMs, {DateTime? now}) {
  final s = (((now ?? DateTime.now()).millisecondsSinceEpoch - epochMs) / 1000).floor();
  if (s < 60) return '${s}s ago';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ago';
  final h = m ~/ 60;
  if (h < 24) return '${h}h ago';
  return '${h ~/ 24}d ago';
}
