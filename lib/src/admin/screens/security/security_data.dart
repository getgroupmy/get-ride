// Data access for the Security & integrations screens. Every call runs with
// the signed-in admin's session; RLS (`caller_is_admin()`, the restrictive
// `elife_api_connection` policy and `app_settings_secret_access()` for
// `fare_ai_provider`) is the real gate. Secret values read here are never
// logged.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../providers.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import 'api_keys_logic.dart';
import 'elife_logic.dart';
import 'fare_ai_logic.dart';
import 'fraud_detection.dart';
import 'ip_access_logic.dart';
import 'session_logic.dart';

/// Access across several Expo page keys (comma-separated), plus the
/// Settings hub grant — e.g. the API key sub-screens are gated on
/// `admin-settings-api-keys` in Expo.
final securityLevelProvider = Provider.family<AccessLevel, String>((ref, pagesCsv) {
  final access = ref.watch(adminAccessProvider).value ?? AdminAccess.none;
  return access.levelFor([...pagesCsv.split(','), 'admin-settings']);
});

final securityRepositoryProvider = Provider((ref) => SecurityRepository(ref.watch(supabaseProvider)));

class SecurityRepository {
  SecurityRepository(this._db);
  final SupabaseClient _db;

  String get _now => DateTime.now().toUtc().toIso8601String();

  // ---- Sessions ------------------------------------------------------------

  Future<({List<Map<String, dynamic>> sessions, List<Map<String, dynamic>> pings})> sessionsOverview() async {
    final results = await Future.wait([
      _db.from('user_sessions').select().order('captured_at', ascending: false).limit(1000),
      _db
          .from('user_location_history')
          .select()
          .order('captured_at', ascending: false)
          .limit(5000)
          .then<List<Map<String, dynamic>>>((v) => v, onError: (_) => <Map<String, dynamic>>[]),
    ]);
    return (sessions: List<Map<String, dynamic>>.from(results[0]), pings: List<Map<String, dynamic>>.from(results[1]));
  }

  PostgrestFilterBuilder<List<Map<String, dynamic>>> _forAccount(String table, UserSummary u) {
    final q = _db.from(table).select();
    return u.userId != null ? q.eq('user_id', u.userId!) : q.eq('phone', u.phone ?? '');
  }

  Future<({List<Map<String, dynamic>> sessions, List<Map<String, dynamic>> locations})> accountDetail(UserSummary u) async {
    if (u.userId == null && u.phone == null) return (sessions: <Map<String, dynamic>>[], locations: <Map<String, dynamic>>[]);
    final r = await Future.wait([
      _forAccount('user_sessions', u).order('captured_at', ascending: false).limit(500),
      _forAccount('user_location_history', u).order('captured_at', ascending: false).limit(2000),
    ]);
    return (sessions: List<Map<String, dynamic>>.from(r[0]), locations: List<Map<String, dynamic>>.from(r[1]));
  }

  Future<List<Map<String, dynamic>>> trail(UserSummary u, DateTime start, DateTime end) async =>
      List<Map<String, dynamic>>.from(await _forAccount('user_location_history', u)
          .gte('captured_at', start.toUtc().toIso8601String())
          .lte('captured_at', end.toUtc().toIso8601String())
          .order('captured_at', ascending: false)
          .limit(5000));

  /// Probes the `ip-lookup` edge function with a well-known public IP; false
  /// when it is missing or broken (public IP / ISP columns then stay null).
  Future<bool> ipLookupHealthy() async {
    try {
      final res = await _db.functions.invoke('ip-lookup', body: {'ip': '8.8.8.8'});
      final data = res.data;
      return data is Map && data['ip_country'] != null && '${data['ip_country']}'.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<DeviceGuardConfig> deviceGuardConfig() async {
    try {
      return DeviceGuardConfig.fromRpc(await _db.rpc('device_guard_config'));
    } catch (_) {
      return DeviceGuardConfig.fallback;
    }
  }

  Future<void> setDeviceGuardConfig(DeviceGuardConfig c) async {
    try {
      await _db.rpc('device_guard_set_config', params: c.toRpcParams());
    } on PostgrestException catch (e) {
      if (e.message.contains('not_authorized')) {
        throw StateError("You don't have permission to change this setting.");
      }
      rethrow;
    }
  }

  // ---- Fraud ---------------------------------------------------------------

  Future<List<FraudFinding>> fraudScan() async {
    Future<List<Map<String, dynamic>>> safe(Future<List<Map<String, dynamic>>> f) =>
        f.then((v) => v, onError: (_) => <Map<String, dynamic>>[]);
    final r = await Future.wait([
      safe(_db
          .from('user_sessions')
          .select('user_id, phone, device_id, public_ip, captured_at, os_name, device_model_name')
          .order('captured_at', ascending: false)
          .limit(3000)),
      safe(_db
          .from('ride_requests')
          .select('id, rider_id, rider_phone, partner_id, partner_phone, status, distance_km, duration_min, fare, '
              'pickup_lat, pickup_lng, drop_lat, drop_lng, partner_arrive_lat, partner_arrive_lng, partner_drop_lat, '
              'partner_drop_lng, user_drop_lat, user_drop_lng, cancel_reason, cancel_requested_by, created_at, '
              'completed_at, cancelled_at')
          .order('created_at', ascending: false)
          .limit(3000)),
      safe(_db
          .from('wallet_transactions')
          .select('id, user_id, wallet_type, kind, amount, created_at')
          .order('created_at', ascending: false)
          .limit(3000)),
      safe(_db
          .from('wallet_transfer_requests')
          .select('id, from_user_id, to_user_id, coins, status, created_at')
          .order('created_at', ascending: false)
          .limit(2000)),
    ]);
    return runFraudScan(
      sessions: r[0].map(SessionSignal.fromRow).toList(),
      rides: r[1].map(RideSignal.fromRow).toList(),
      walletTx: r[2].map(WalletTxSignal.fromRow).toList(),
      transfers: r[3].map(TransferSignal.fromRow).toList(),
    );
  }

  /// Names/phones for the ids and phones a scan implicated (profiles first,
  /// then partners, first match wins — as in Expo).
  Future<Map<String, SuspectInfo>> suspectDirectory(List<FraudFinding> findings) async {
    final c = suspectCandidates(findings);
    final ids = c.ids.toList();
    final phones = c.phones.toList();
    final dir = <String, SuspectInfo>{};
    if (ids.isEmpty && phones.isEmpty) return dir;
    Future<List<Map<String, dynamic>>> q(String table, String cols, String col, List<String> values) => values.isEmpty
        ? Future.value(<Map<String, dynamic>>[])
        : _db
            .from(table)
            .select(cols)
            .inFilter(col, values)
            .then((v) => v, onError: (_) => <Map<String, dynamic>>[]);
    final r = await Future.wait([
      q('profiles', 'id, name, phone', 'id', ids),
      q('profiles', 'id, name, phone', 'phone', phones),
      q('partners', 'id, auth_user_id, name, phone', 'id', ids),
      q('partners', 'id, auth_user_id, name, phone', 'auth_user_id', ids),
      q('partners', 'id, auth_user_id, name, phone', 'phone', phones),
    ]);
    SuspectInfo info(Map<String, dynamic> p) => SuspectInfo(name: p['name'] as String?, phone: p['phone'] as String?);
    for (final p in r[0]) {
      dir['${p['id']}'] = info(p);
      if (p['phone'] != null) dir['${p['phone']}'] = info(p);
    }
    for (final p in [...r[1], ...r[2], ...r[3], ...r[4]]) {
      for (final k in [p['id'], p['auth_user_id'], p['phone']]) {
        if (k != null) dir.putIfAbsent('$k', () => info(p));
      }
    }
    return dir;
  }

  // ---- IP access -----------------------------------------------------------

  static const _ipCols = 'id, ip_address, list_type, label, created_at, updated_at';

  Future<List<IpAccessRule>> ipRules() async {
    final rows = await _db.from('ip_access_rules').select(_ipCols).order('created_at', ascending: false);
    return rows.map(IpAccessRule.fromRow).toList();
  }

  Future<void> addIpRule(Map<String, dynamic> row) =>
      _db.from('ip_access_rules').upsert(row, onConflict: 'ip_address,list_type').select(_ipCols).single();

  Future<void> updateIpRule(String id, Map<String, dynamic> row) =>
      _db.from('ip_access_rules').update({...row, 'updated_at': _now}).eq('id', id).select(_ipCols).single();

  Future<void> deleteIpRule(String id) => _db.from('ip_access_rules').delete().eq('id', id);

  /// Rule type for an IP (blacklist wins); null when unknown/unmatched or the
  /// query fails — fail open, as in Expo.
  Future<IpListType?> evaluateIp(String? ip) async {
    if (ip == null || ip.isEmpty) return null;
    try {
      final rows = await _db.from('ip_access_rules').select('list_type').eq('ip_address', ip);
      return classifyIp(rows.map((r) => r['list_type']));
    } catch (_) {
      return null;
    }
  }

  // ---- app_settings rows ---------------------------------------------------

  Future<Object?> _appSetting(String key) async =>
      (await _db.from('app_settings').select('value').eq('key', key).maybeSingle())?['value'];

  Future<void> _saveAppSetting(String key, Object value) =>
      _db.from('app_settings').upsert({'key': key, 'value': value, 'updated_at': _now}, onConflict: 'key');

  /// Providers merged with the default catalogue (in memory only; the merge
  /// is persisted with the next edit).
  Future<List<ApiProviderDef>> apiProviders() async =>
      mergeDefaultProviders(parseProviders(await _appSetting(apiKeysRemoteKey))).list;

  /// Read-modify-write against the freshest row, like every Expo mutation.
  Future<List<ApiProviderDef>> mutateApiProviders(List<ApiProviderDef> Function(List<ApiProviderDef>) change) async {
    final next = change(await apiProviders());
    await _saveAppSetting(apiKeysRemoteKey, providersToJson(next));
    return next;
  }

  Future<Map<String, dynamic>> elifeConfig() async => normalizeElife(await _appSetting(elifeRemoteKey));

  Future<void> saveElifeConfig(Map<String, dynamic> config) => _saveAppSetting(elifeRemoteKey, config);

  /// OAuth client-credentials request to the configured token URL. Only the
  /// status code is kept; the body (an access token on success) is dropped.
  Future<ElifeTestResult> testElifeToken(Map<String, dynamic> config) async {
    final pre = elifePreflight(config);
    if (pre != null) return pre;
    try {
      final res = await http
          .post(
            Uri.parse('${config['tokenUrl']}'.trim()),
            headers: {'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json'},
            body: {
              'grant_type': 'client_credentials',
              'client_id': '${config['clientId']}'.trim(),
              'client_secret': '${config['clientSecret']}'.trim(),
            },
          )
          .timeout(const Duration(seconds: 15));
      return elifeResultForStatus(res.statusCode);
    } catch (e) {
      return ElifeTestResult(ok: false, status: 0, message: 'Could not reach Elife: ${e.runtimeType}');
    }
  }

  Future<FareAiConfig> fareAiConfig() async => normalizeFareAi(await _appSetting(fareAiRemoteKey));

  Future<void> saveFareAiConfig(FareAiConfig c) => _saveAppSetting(fareAiRemoteKey, normalizeFareAi(c.toJson()).toJson());

  Future<Map<String, FareAiKeyState>> fareAiKeyStates() async {
    try {
      final rows = await _db.from('fare_ai_key_states').select(
          'key_id, provider, usage_count, pass_count, fail_count, last_used_at, last_success_at, last_failed_at, '
          'disabled_until, last_error');
      return {for (final r in rows) '${r['key_id']}': FareAiKeyState.fromRow(r)};
    } catch (_) {
      return {};
    }
  }

  static const _responseColumns =
      'id, created_at, provider, key_id, key_label, model, origin_lat, origin_lng, dest_lat, dest_lng, '
      'success, http_status, distance_km, duration_min, summary, toll_count, toll_total, tolls, error, '
      'latency_ms, raw_response';

  /// The log, with the fare-range / traffic answers (`extra`, migration 0114)
  /// where the database has them; an older one is read without.
  Future<List<Map<String, dynamic>>> fareAiResponses({int limit = 150}) async {
    Future<List<Map<String, dynamic>>> read(String cols) async => List<Map<String, dynamic>>.from(
          await _db.from('fare_ai_responses').select(cols).order('created_at', ascending: false).limit(limit),
        );
    try {
      return await read('$_responseColumns, extra');
    } on PostgrestException catch (e) {
      if (!e.message.contains('extra')) rethrow;
      return read(_responseColumns);
    }
  }

  /// The latest answers with the standard route they were compared with
  /// (migration 0115), for the fare trend measure; empty on an older
  /// database.
  Future<List<Map<String, dynamic>>> fareAiTrendSample({int limit = 300}) async {
    try {
      return List<Map<String, dynamic>>.from(await _db
          .from('fare_ai_responses')
          .select('duration_min, standard_duration_min')
          .eq('success', true)
          .not('standard_duration_min', 'is', null)
          .order('created_at', ascending: false)
          .limit(limit));
    } on PostgrestException catch (e) {
      if (e.message.contains('standard_duration_min')) return const [];
      rethrow;
    }
  }

  /// Puts a cooling-down key (or, with null, every key) straight back into
  /// rotation (migration 0113, admins only). Returns how many were paused.
  Future<int> resetFareAiCooldown([String? keyId]) async {
    final n = await _db.rpc('fare_ai_reset_cooldown', params: {'p_key_id': keyId});
    return n is num ? n.toInt() : 0;
  }

  /// Runs [draft] once through `ai-route-proxy` (admins only): the prompt sent,
  /// the raw reply and the parsed estimate. Nothing is logged or counted.
  Future<Map<String, dynamic>> testFareAiRequest(
    FareAiRequest draft, {
    required ({double lat, double lng}) origin,
    required ({double lat, double lng}) destination,
  }) async {
    final res = await _db.functions.invoke('ai-route-proxy', body: {
      'test': true,
      'origin': {'latitude': origin.lat, 'longitude': origin.lng},
      'destination': {'latitude': destination.lat, 'longitude': destination.lng},
      'request': draft.toJson(),
    });
    final data = res.data;
    if (data is! Map) throw Exception('Unexpected reply from ai-route-proxy');
    if (data['ok'] != true) throw Exception('${data['error'] ?? 'Test failed'}');
    return Map<String, dynamic>.from(data['test'] as Map);
  }

  /// Same filter as Expo (a `delete` needs one).
  Future<void> clearFareAiResponses() =>
      _db.from('fare_ai_responses').delete().neq('id', '00000000-0000-0000-0000-000000000000');

  // ---- Backend diagnostics -------------------------------------------------

  Future<({bool ok, String message})> pingAuthClient() async {
    try {
      await _db.auth.getUser();
      return (ok: true, message: 'Active client responded successfully.');
    } catch (e) {
      return (ok: false, message: errorText(e));
    }
  }

  Future<int> profileCount() async => (await _db.from('profiles').select('id').count(CountOption.exact)).count;
}

/// First public-IP provider that answers (5 s each).
Future<String?> lookupPublicIp() async {
  for (final url in publicIpProviders) {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      final ip = parsePublicIp(res.body);
      if (ip != null) return ip;
    } catch (_) {}
  }
  return null;
}

/// Saves a CSV through the platform save dialog (a download on web); falls
/// back to the clipboard where saving isn't supported.
Future<void> exportCsv(BuildContext context, String filename, String csv) async {
  try {
    final uri = await FilePicker.saveFile(
      fileName: filename,
      bytes: Uint8List.fromList(utf8.encode(csv)),
      mimeType: 'text/csv',
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (uri != null && context.mounted) showInfo(context, 'Saved $filename');
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: csv));
    if (context.mounted) showInfo(context, 'Saving isn\'t available here — CSV copied to the clipboard.');
  }
}
