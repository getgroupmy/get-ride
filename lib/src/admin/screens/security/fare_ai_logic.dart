/// Pure half of `expo/utils/fareProviderStore.ts` and `expo/utils/fareAiStats.ts`.
/// The config is one JSON object in `app_settings` (key = `fare_ai_provider`),
/// readable only by admins / the service role (`app_settings_secret_access()`).
library;

import 'package:uuid/uuid.dart';

const fareAiRemoteKey = 'fare_ai_provider';

class FareAiProviderMeta {
  const FareAiProviderMeta(this.id, this.label, this.description, this.keyHint, this.defaultModel);
  final String id;
  final String label;
  final String description;
  final String keyHint;
  final String defaultModel;
}

/// Same order, ids, labels and default models as Expo.
const fareAiProviders = [
  FareAiProviderMeta('gemini', 'Gemini (Google)', 'Google Generative Language API',
      "AIza... key. Leave list empty to use the app's built-in key", 'gemini-2.5-flash'),
  FareAiProviderMeta('grok', 'Grok (xAI)', 'xAI Grok chat completions', 'xai-... API key from console.x.ai', 'grok-3'),
  FareAiProviderMeta('chatgpt', 'ChatGPT (OpenAI)', 'OpenAI chat completions', 'sk-... API key from platform.openai.com',
      'gpt-4o-mini'),
  FareAiProviderMeta('groq', 'Groq', 'Groq fast LPU chat completions', 'gsk_... API key from console.groq.com',
      'llama-3.3-70b-versatile'),
  FareAiProviderMeta('claude', 'Claude (Anthropic)', 'Anthropic Claude messages API',
      'sk-ant-... API key from console.anthropic.com', 'claude-3-5-haiku-latest'),
  FareAiProviderMeta('perplexity', 'Perplexity', 'Perplexity Sonar chat completions', 'pplx-... API key from perplexity.ai',
      'sonar'),
  FareAiProviderMeta('mistral', 'Mistral AI', 'Mistral chat completions', 'API key from console.mistral.ai',
      'mistral-small-latest'),
  FareAiProviderMeta('deepseek', 'DeepSeek', 'DeepSeek chat completions', 'sk-... API key from platform.deepseek.com',
      'deepseek-chat'),
  FareAiProviderMeta('cohere', 'Cohere', 'Cohere Command (OpenAI-compatible)', 'API key from dashboard.cohere.com',
      'command-r'),
  FareAiProviderMeta('together', 'Together AI', 'Together AI chat completions', 'API key from api.together.xyz',
      'meta-llama/Llama-3.3-70B-Instruct-Turbo'),
  FareAiProviderMeta('openrouter', 'OpenRouter', 'OpenRouter unified chat completions', 'sk-or-... API key from openrouter.ai',
      'openai/gpt-4o-mini'),
  FareAiProviderMeta('fireworks', 'Fireworks AI', 'Fireworks chat completions', 'fw_... API key from fireworks.ai',
      'accounts/fireworks/models/llama-v3p3-70b-instruct'),
];

final fareAiProviderIds = [for (final p in fareAiProviders) p.id];

FareAiProviderMeta fareAiMeta(String id) => fareAiProviders.firstWhere((p) => p.id == id, orElse: () => fareAiProviders.first);

/// Label for a provider id; unknown ids are shown as-is ("—" when blank).
String fareAiProviderLabel(String id) {
  for (final p in fareAiProviders) {
    if (p.id == id) return p.label;
  }
  return id.isEmpty ? '—' : id;
}

const retryUnits = {'hour': 'Hours', 'day': 'Days', 'month': 'Months'};

class FareAiKey {
  const FareAiKey({required this.id, required this.label, required this.key, required this.enabled});

  factory FareAiKey.create({String? id, String? label, String key = '', bool enabled = true}) =>
      FareAiKey(id: id ?? const Uuid().v4(), label: label ?? 'New key', key: key, enabled: enabled);

  final String id;
  final String label;

  /// The secret; masked in the UI, never logged.
  final String key;
  final bool enabled;

  bool get isActive => enabled && key.trim().isNotEmpty;

  FareAiKey copyWith({String? label, String? key, bool? enabled}) =>
      FareAiKey(id: id, label: label ?? this.label, key: key ?? this.key, enabled: enabled ?? this.enabled);

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'key': key, 'enabled': enabled};
}

class FareAiConfig {
  const FareAiConfig({
    required this.serviceEnabled,
    required this.provider,
    required this.retryAfterValue,
    required this.retryAfterUnit,
    required this.models,
    required this.keys,
  });

  final bool serviceEnabled;
  final String provider;
  final int retryAfterValue;
  final String retryAfterUnit;
  final Map<String, String> models;
  final Map<String, List<FareAiKey>> keys;

  List<FareAiKey> keysFor(String provider) => keys[provider] ?? const [];
  int activeKeyCount(String provider) => keysFor(provider).where((k) => k.isActive).length;

  FareAiConfig copyWith({
    bool? serviceEnabled,
    String? provider,
    int? retryAfterValue,
    String? retryAfterUnit,
    Map<String, String>? models,
    Map<String, List<FareAiKey>>? keys,
  }) =>
      FareAiConfig(
        serviceEnabled: serviceEnabled ?? this.serviceEnabled,
        provider: provider ?? this.provider,
        retryAfterValue: retryAfterValue ?? this.retryAfterValue,
        retryAfterUnit: retryAfterUnit ?? this.retryAfterUnit,
        models: models ?? this.models,
        keys: keys ?? this.keys,
      );

  FareAiConfig withKeys(String provider, List<FareAiKey> list) => copyWith(keys: {...keys, provider: list});

  Map<String, dynamic> toJson() => {
        'serviceEnabled': serviceEnabled,
        'provider': provider,
        'retryAfterValue': retryAfterValue,
        'retryAfterUnit': retryAfterUnit,
        'models': models,
        'keys': {for (final e in keys.entries) e.key: [for (final k in e.value) k.toJson()]},
      };
}

final defaultFareAiConfig = normalizeFareAi(null);

List<FareAiKey> _keyList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map && item['key'] is String)
        FareAiKey.create(
          id: item['id'] is String && (item['id'] as String).isNotEmpty ? item['id'] as String : null,
          label: item['label'] is String ? item['label'] as String : null,
          key: item['key'] as String,
          enabled: item['enabled'] is bool ? item['enabled'] as bool : true,
        ),
  ];
}

String? _nonBlank(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// Expo `normalize`: tolerant parse, including the legacy single-key fields
/// (`geminiKey`, `grokModel`, …).
FareAiConfig normalizeFareAi(Object? raw) {
  final o = raw is Map ? raw : const {};
  final provider = fareAiProviderIds.contains(o['provider']) ? o['provider'] as String : 'gemini';
  final rv = o['retryAfterValue'];
  final retryValue = rv is num && rv > 0 ? rv.floor() : 1;
  final ru = o['retryAfterUnit'];
  final retryUnit = ru == 'day' || ru == 'month' || ru == 'hour' ? ru as String : 'hour';
  final rawModels = o['models'] is Map ? o['models'] as Map : const {};
  final rawKeys = o['keys'] is Map ? o['keys'] as Map : const {};
  const legacy = {'gemini', 'grok', 'chatgpt', 'groq'};
  final models = <String, String>{};
  final keys = <String, List<FareAiKey>>{};
  for (final p in fareAiProviders) {
    models[p.id] = _nonBlank(rawModels[p.id]) ??
        (legacy.contains(p.id) ? _nonBlank(o['${p.id}Model']) : null) ??
        p.defaultModel;
    var list = _keyList(rawKeys[p.id]);
    final legacyKey = legacy.contains(p.id) ? _nonBlank(o['${p.id}Key']) : null;
    if (list.isEmpty && legacyKey != null) {
      list = [FareAiKey.create(label: 'Key 1', key: legacyKey.trim())];
    }
    keys[p.id] = list;
  }
  return FareAiConfig(
    serviceEnabled: o['serviceEnabled'] is bool ? o['serviceEnabled'] as bool : true,
    provider: provider,
    retryAfterValue: retryValue,
    retryAfterUnit: retryUnit,
    models: models,
    keys: keys,
  );
}

/// Retry window in milliseconds (a month is 30 days).
int retryPolicyMs(num value, String unit) {
  final v = value.isFinite && value > 0 ? value : 1;
  const hour = 3600 * 1000;
  return switch (unit) {
    'month' => (v * 30 * 24 * hour).round(),
    'day' => (v * 24 * hour).round(),
    _ => (v * hour).round(),
  };
}

/// Parses the retry box: digits only, anything non-positive becomes 1.
int parseRetryValue(String input) {
  final n = int.tryParse(input.replaceAll(RegExp(r'[^0-9]'), ''));
  return n != null && n > 0 ? n : 1;
}

String retryLabel(FareAiConfig c) => '${c.retryAfterValue} ${(retryUnits[c.retryAfterUnit] ?? 'Hours').toLowerCase()}';

/// A key is cooling down while `disabled_until` is in the future.
bool isCoolingDown(String? disabledUntil, {DateTime? now}) {
  if (disabledUntil == null) return false;
  final until = DateTime.tryParse(disabledUntil);
  return until != null && until.isAfter(now ?? DateTime.now());
}

/// "in 5m" / "3h ago" / "just now" / "—".
String formatRelative(String? iso, {DateTime? now}) {
  if (iso == null) return '—';
  final then = DateTime.tryParse(iso);
  if (then == null) return '—';
  final diff = then.difference(now ?? DateTime.now()).inMilliseconds;
  final abs = diff.abs();
  final m = (abs / 60000).round();
  final h = (abs / 3600000).round();
  final d = (abs / 86400000).round();
  if (m < 1) return 'just now';
  final body = m < 60 ? '${m}m' : (h < 24 ? '${h}h' : '${d}d');
  return diff >= 0 ? 'in $body' : '$body ago';
}

/// Row of `fare_ai_key_states` (no secrets: counters + cooldown only).
class FareAiKeyState {
  const FareAiKeyState({
    required this.keyId,
    this.usageCount = 0,
    this.passCount = 0,
    this.failCount = 0,
    this.lastUsedAt,
    this.disabledUntil,
    this.lastError,
  });

  factory FareAiKeyState.fromRow(Map<String, dynamic> r) => FareAiKeyState(
        keyId: '${r['key_id']}',
        usageCount: (r['usage_count'] as num?)?.toInt() ?? 0,
        passCount: (r['pass_count'] as num?)?.toInt() ?? 0,
        failCount: (r['fail_count'] as num?)?.toInt() ?? 0,
        lastUsedAt: r['last_used_at'] as String?,
        disabledUntil: r['disabled_until'] as String?,
        lastError: r['last_error'] as String?,
      );

  final String keyId;
  final int usageCount;
  final int passCount;
  final int failCount;
  final String? lastUsedAt;
  final String? disabledUntil;
  final String? lastError;
}

({int total, int passed, int failed}) responseSummary(List<Map<String, dynamic>> rows) {
  final passed = rows.where((r) => r['success'] == true).length;
  return (total: rows.length, passed: passed, failed: rows.length - passed);
}

/// Toll line for a log row, or null when the row has no tolls.
String? tollHeadline(Map<String, dynamic> r) {
  final count = (r['toll_count'] as num?)?.toInt();
  final total = r['toll_total'] as num?;
  final tolls = r['tolls'] is List ? r['tolls'] as List : null;
  final has = (count != null && count > 0) || (total != null && total > 0) || (tolls != null && tolls.isNotEmpty);
  if (!has) return null;
  final n = count ?? tolls?.length ?? 0;
  final t = total == null ? '' : ' · ${total == total.roundToDouble() ? total.toInt() : total} total';
  return 'Tolls: $n booth${n == 1 ? '' : 's'}$t';
}
