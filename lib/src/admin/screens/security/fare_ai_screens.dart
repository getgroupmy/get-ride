import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../widgets/admin_widgets.dart';
import 'api_keys_logic.dart' show maskSecret;
import 'fare_ai_logic.dart';
import 'security_data.dart';

const _page = 'admin-settings-fare-ai';
const _logsPage = 'admin-settings-fare-ai-logs';

class AdminFareAiScreen extends ConsumerStatefulWidget {
  const AdminFareAiScreen({super.key});

  @override
  ConsumerState<AdminFareAiScreen> createState() => _FareAiState();
}

class _FareAiState extends ConsumerState<AdminFareAiScreen> {
  FareAiConfig? _config;
  Map<String, FareAiKeyState> _states = {};
  Object? _error;
  bool _dirty = false;
  bool _saving = false;

  /// Per-key text controllers so typing doesn't lose the cursor on rebuild.
  final _controllers = <String, ({TextEditingController label, TextEditingController key})>{};
  final _model = TextEditingController();
  final _retry = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.label.dispose();
      c.key.dispose();
    }
    _model.dispose();
    _retry.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(securityRepositoryProvider);
    try {
      final results = await Future.wait([repo.fareAiConfig(), repo.fareAiKeyStates()]);
      if (!mounted) return;
      final c = results[0] as FareAiConfig;
      setState(() {
        _config = c;
        _states = results[1] as Map<String, FareAiKeyState>;
        _error = null;
        _dirty = false;
      });
      _syncFields(c);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _refreshStats() async {
    final s = await ref.read(securityRepositoryProvider).fareAiKeyStates();
    if (mounted) setState(() => _states = s);
  }

  void _syncFields(FareAiConfig c) {
    _model.text = c.models[c.provider] ?? '';
    _retry.text = '${c.retryAfterValue}';
  }

  ({TextEditingController label, TextEditingController key}) _ctl(FareAiKey k) =>
      _controllers.putIfAbsent(k.id, () => (label: TextEditingController(text: k.label), key: TextEditingController(text: k.key)));

  void _update(FareAiConfig next) => setState(() {
        _config = next;
        _dirty = true;
      });

  void _setKeys(List<FareAiKey> keys) => _update(_config!.withKeys(_config!.provider, keys));

  Future<void> _save() async {
    final c = _config!;
    setState(() => _saving = true);
    final ok = await runAdminAction(context, () => ref.read(securityRepositoryProvider).saveFareAiConfig(c),
        success: 'Fare calculation now uses ${fareAiProviderLabel(c.provider)} for all users.');
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok && identical(_config, c)) _dirty = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(securityLevelProvider(_page)) == AccessLevel.edit;
    final c = _config;
    return AdminPage(
      title: 'Fare AI provider',
      page: _page,
      actions: [
        IconButton(tooltip: 'Refresh usage stats', icon: const Icon(Icons.refresh), onPressed: _refreshStats),
        IconButton(
          tooltip: 'Response log',
          icon: const Icon(Icons.fact_check_outlined),
          onPressed: () => context.push('/admin/m/fare-ai-logs'),
        ),
      ],
      body: c == null
          ? (_error != null
              ? EmptyState(
                  icon: Icons.lock_outline,
                  title: 'Could not load the fare AI settings',
                  message: errorText(_error!),
                  action: TextButton(onPressed: _load, child: const Text('Retry')),
                )
              : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(onRefresh: _refreshStats, child: _body(c, canEdit)),
    );
  }

  Widget _body(FareAiConfig c, bool canEdit) {
    final t = Theme.of(context);
    final meta = fareAiMeta(c.provider);
    final keys = c.keysFor(c.provider);
    return ResponsiveCenter(
      maxWidth: 760,
      child: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Choose which AI estimates trip distance & traffic-aware time for fare calculation. Applies '
                "globally to all users. Add multiple keys per provider — if one fails it's skipped for the retry "
                'window below and the next key is tried automatically.'),
          ),
        ),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.power_settings_new),
            title: const Text('AI fare service'),
            subtitle: Text(c.serviceEnabled
                ? 'AI estimates trip distance & time for fares'
                : 'Turned off — fares use the routing engine fallback'),
            value: c.serviceEnabled,
            onChanged: canEdit ? (v) => _update(c.copyWith(serviceEnabled: v)) : null,
          ),
        ),
        const SizedBox(height: 12),
        Text('Provider', style: t.textTheme.titleMedium),
        const SizedBox(height: 6),
        Opacity(
          opacity: c.serviceEnabled ? 1 : 0.5,
          child: RadioGroup<String>(
            groupValue: c.provider,
            onChanged: (v) {
              if (!canEdit || v == null) return;
              final next = c.copyWith(provider: v);
              _update(next);
              _syncFields(next);
            },
            child: Card(
              child: Column(children: [
                for (final p in fareAiProviders)
                  RadioListTile<String>(
                    value: p.id,
                    enabled: canEdit,
                    title: Text(p.label),
                    subtitle: Text('${c.activeKeyCount(p.id)} active key${c.activeKeyCount(p.id) == 1 ? '' : 's'}'),
                  ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Retry failed keys after', style: t.textTheme.titleMedium),
        Text('A key that fails is paused for ${retryLabel(c)}, then automatically retried.', style: t.textTheme.bodySmall),
        const SizedBox(height: 8),
        Row(children: [
          SizedBox(
            width: 90,
            child: TextField(
              controller: _retry,
              readOnly: !canEdit,
              keyboardType: TextInputType.number,
              onChanged: (v) => _update(c.copyWith(retryAfterValue: parseRetryValue(v))),
              decoration: const InputDecoration(isDense: true),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SegmentedButton<String>(
              segments: [for (final e in retryUnits.entries) ButtonSegment(value: e.key, label: Text(e.value))],
              selected: {c.retryAfterUnit},
              onSelectionChanged: canEdit ? (s) => _update(c.copyWith(retryAfterUnit: s.first)) : null,
            ),
          ),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: Text('${meta.label} keys', style: t.textTheme.titleMedium)),
          if (canEdit)
            TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add key'),
              onPressed: () => _setKeys([...keys, FareAiKey.create(label: 'Key ${keys.length + 1}')]),
            ),
        ]),
        TextField(
          controller: _model,
          readOnly: !canEdit,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Model', hintText: 'model id'),
          onChanged: (v) => _update(c.copyWith(models: {...c.models, c.provider: v})),
        ),
        const SizedBox(height: 12),
        if (keys.isEmpty)
          Card(
            child: ListTile(
              title: Text('No keys yet. '
                  '${c.provider == 'gemini' ? "The app's built-in Gemini key will be used as a fallback. " : ''}'
                  '${canEdit ? 'Tap "Add key" to add one.' : ''}'),
            ),
          ),
        for (final (i, k) in keys.indexed) _keyCard(c, k, i, canEdit, meta),
        const SizedBox(height: 16),
        if (canEdit)
          FilledButton.icon(
            onPressed: _saving || !_dirty ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: Text(_dirty ? 'Save changes' : 'Saved'),
          )
        else
          const Text('You have read-only access to this setting.'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('View response log'),
          onPressed: () => context.push('/admin/m/fare-ai-logs'),
        ),
      ]),
    );
  }

  Widget _keyCard(FareAiConfig c, FareAiKey k, int i, bool canEdit, FareAiProviderMeta meta) {
    final st = _states[k.id];
    final cooling = isCoolingDown(st?.disabledUntil);
    final ctl = _ctl(k);
    final keys = c.keysFor(c.provider);
    List<FareAiKey> patch(FareAiKey Function(FareAiKey) f) => [for (final x in keys) x.id == k.id ? f(x) : x];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: ctl.label,
                readOnly: !canEdit,
                decoration: InputDecoration(isDense: true, hintText: 'Key ${i + 1}', labelText: 'Label'),
                onChanged: (v) => _setKeys(patch((x) => x.copyWith(label: v))),
              ),
            ),
            Switch(
              value: k.enabled,
              onChanged: canEdit ? (v) => _setKeys(patch((x) => x.copyWith(enabled: v))) : null,
            ),
            if (canEdit)
              IconButton(
                tooltip: 'Remove key',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (await confirm(context, 'Remove key', 'Remove "${k.label}" from ${meta.label}? Save to apply.',
                      ok: 'Remove')) {
                    _setKeys(keys.where((x) => x.id != k.id).toList());
                  }
                },
              ),
          ]),
          if (canEdit)
            TextField(
              controller: ctl.key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: 'API key', hintText: meta.keyHint),
              onChanged: (v) => _setKeys(patch((x) => x.copyWith(key: v))),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 12, children: [
            Text('${st?.usageCount ?? 0} used'),
            Text('${st?.passCount ?? 0} passed', style: const TextStyle(color: Colors.green)),
            Text('${st?.failCount ?? 0} failed', style: const TextStyle(color: Colors.red)),
          ]),
          Text('${maskSecret(k.key)} · last used ${formatRelative(st?.lastUsedAt)}',
              style: Theme.of(context).textTheme.bodySmall),
          if (cooling)
            Text('Cooling down — retries ${formatRelative(st?.disabledUntil)}', style: const TextStyle(color: Colors.red))
          else if (st?.lastError != null)
            Text('Last error: ${st!.lastError}', maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.red)),
        ]),
      ),
    );
  }
}

// ---- Response log ------------------------------------------------------------

final _responsesProvider = FutureProvider.autoDispose((ref) => ref.watch(securityRepositoryProvider).fareAiResponses());

class AdminFareAiLogsScreen extends ConsumerWidget {
  const AdminFareAiLogsScreen({super.key});

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    if (!await confirm(context, 'Clear response log?', 'This permanently deletes all recorded responses.', ok: 'Clear')) {
      return;
    }
    if (!context.mounted) return;
    final ok = await runAdminAction(context, () => ref.read(securityRepositoryProvider).clearFareAiResponses(),
        success: 'Response log cleared');
    if (ok) ref.invalidate(_responsesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(securityLevelProvider('$_page,$_logsPage')) == AccessLevel.edit;
    final rows = ref.watch(_responsesProvider);
    return AdminPage(
      title: 'Fare AI response log',
      page: _page,
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(_responsesProvider)),
        if (canEdit)
          IconButton(tooltip: 'Clear log', icon: const Icon(Icons.delete_sweep_outlined), onPressed: () => _clear(context, ref)),
      ],
      body: AsyncView(
        value: rows,
        onRetry: () => ref.invalidate(_responsesProvider),
        data: (list) {
          final sum = responseSummary(list);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(_responsesProvider),
            child: ResponsiveCenter(
              maxWidth: 820,
              child: ListView(padding: const EdgeInsets.symmetric(vertical: 12), children: [
                Text('${sum.total} records · ${sum.passed} passed · ${sum.failed} failed',
                    style: Theme.of(context).textTheme.bodySmall),
                if (list.isEmpty)
                  const EmptyState(
                    icon: Icons.fact_check_outlined,
                    title: 'No responses yet',
                    message: 'AI fare estimates will appear here as soon as rides are calculated.',
                  ),
                for (final r in list) _LogCard(r),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard(this.r);
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final ok = r['success'] == true;
    final tolls = r['tolls'] is List ? r['tolls'] as List : const [];
    final headline = tollHeadline(r);
    String c(Object? v) => v is num ? v.toStringAsFixed(4) : '?';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(ok ? Icons.check_circle_outline : Icons.highlight_off, color: ok ? Colors.green : Colors.red, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${fareAiProviderLabel('${r['provider'] ?? ''}')}${r['key_label'] != null ? ' · ${r['key_label']}' : ''}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Text(dateText(r['created_at']), style: Theme.of(context).textTheme.bodySmall),
          ]),
          const SizedBox(height: 4),
          if (ok)
            Text('${r['distance_km'] ?? '?'} km · ${r['duration_min'] ?? '?'} min'
                '${r['summary'] != null ? ' — ${r['summary']}' : ''}')
          else
            Text('${r['error'] ?? 'Failed'}', maxLines: 3, style: const TextStyle(color: Colors.red)),
          Wrap(spacing: 10, children: [
            if (r['model'] != null) Text('${r['model']}', style: Theme.of(context).textTheme.bodySmall),
            if (r['http_status'] != null) Text('HTTP ${r['http_status']}', style: Theme.of(context).textTheme.bodySmall),
            if (r['latency_ms'] != null) Text('${r['latency_ms']}ms', style: Theme.of(context).textTheme.bodySmall),
          ]),
          if (headline != null) ...[
            const SizedBox(height: 4),
            Text(headline),
            for (final toll in tolls)
              if (toll is Map) Text('• ${toll['name'] ?? 'Toll booth'} — ${toll['charge']}'),
          ],
          if (r['origin_lat'] != null && r['dest_lat'] != null)
            Text('${c(r['origin_lat'])},${c(r['origin_lng'])} → ${c(r['dest_lat'])},${c(r['dest_lng'])}',
                style: Theme.of(context).textTheme.bodySmall),
          if (r['raw_response'] != null)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Raw response'),
              children: [SelectableText('${r['raw_response']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12))],
            ),
        ]),
      ),
    );
  }
}
