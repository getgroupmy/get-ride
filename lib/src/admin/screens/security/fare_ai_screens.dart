import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/loading_skeleton.dart';
import '../../admin_access.dart';
import '../../widgets/admin_widgets.dart';
import 'api_keys_logic.dart' show maskSecret;
import '../../../core/route_estimate.dart' show FareTrend, FareTrendDirection, argbFromHex;
import '../../../widgets/fare_trend_arrows.dart';
import 'fare_ai_logic.dart';
import 'security_data.dart';
import '../../../data/live_tables.dart';

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
  final _trendUp = TextEditingController();
  final _trendDown = TextEditingController();

  /// The four arrow colour boxes, by settings key.
  final _trendColors = {for (final k in _trendColorKeys) k: TextEditingController()};
  static const _trendColorKeys = ['upColorLight', 'upColorDark', 'downColorLight', 'downColorDark'];

  /// The logged answers' AI and standard minutes, for the trend measure.
  List<Map<String, dynamic>> _trendSample = const [];

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
    _trendUp.dispose();
    _trendDown.dispose();
    for (final c in _trendColors.values) {
      c.dispose();
    }
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
      _loadTrendSample();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadTrendSample() async {
    try {
      final rows = await ref.read(securityRepositoryProvider).fareAiTrendSample();
      if (mounted) setState(() => _trendSample = rows);
    } catch (_) {}
  }

  /// Opens Request & format; on the way back, picks up what was saved there
  /// so a later save here never puts the old request back.
  Future<void> _openRequest() async {
    await context.push('/admin/m/fare-ai-request');
    if (!mounted || _config == null) return;
    try {
      final fresh = await ref.read(securityRepositoryProvider).fareAiConfig();
      if (mounted && _config != null) setState(() => _config = _config!.copyWith(request: fresh.request));
    } catch (_) {}
  }

  /// Clears a key's pause (or every key's, with null).
  Future<void> _resetCooldown([String? keyId]) async {
    await runAdminAction(context, () => ref.read(securityRepositoryProvider).resetFareAiCooldown(keyId),
        success: keyId == null ? 'All keys are back in rotation.' : 'Key is back in rotation.');
    await _refreshStats();
  }

  Future<void> _refreshStats() async {
    final s = await ref.read(securityRepositoryProvider).fareAiKeyStates();
    if (mounted) setState(() => _states = s);
    await _loadTrendSample();
  }

  void _syncFields(FareAiConfig c) {
    _model.text = c.models[c.provider] ?? '';
    _retry.text = '${c.retryAfterValue}';
    String pct(double? v) => v == null ? '' : (v == v.roundToDouble() ? '${v.round()}' : '$v');
    _trendUp.text = pct(c.trend.upPct);
    _trendDown.text = pct(c.trend.downPct);
    for (final e in _trendColors.entries) {
      e.value.text = c.trend.color(e.key) ?? '';
    }
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

  /// Fare trend arrows: the thresholds, what decides when the fare range is
  /// asked for, and how far the AI has actually sat from standard.
  Widget _trendCard(FareAiConfig c, bool canEdit) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final m = measureFareTrend(_trendSample, c.trend);
    String share(double v) => '${(v * 100).round()}%';
    Widget field(String label, TextEditingController ctl, ValueChanged<double?> onChanged, Key key) => TextField(
          key: key,
          controller: ctl,
          readOnly: !canEdit,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (v) => onChanged(FareTrendSettings.parse(v)),
          decoration: InputDecoration(isDense: true, labelText: label, suffixText: '%', hintText: 'Off'),
        );
    return Card(
      key: const ValueKey('fare-trend-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.swap_vert),
            const SizedBox(width: 12),
            Expanded(child: Text('Fare trend arrows', style: t.textTheme.titleMedium)),
          ]),
          const SizedBox(height: 6),
          Text(
            "Red up arrows or green down arrows before the recommended fare, when the AI's drive time is that much "
            "above or below the standard route's. The standard route assumes empty roads, so the AI is usually above "
            'it: set the thresholds from the measure below. A fare the rider raises or lowers shows no arrows.',
            style: muted,
          ),
          if (c.request.includeFareRange) ...[
            const SizedBox(height: 8),
            Text(
              "Fare range is on (Request & format): the AI's own verdict decides — usual time no arrows, lower "
              'time down arrows, heavier traffic up arrows. The thresholds apply only when it gives no verdict.',
              key: const ValueKey('fare-trend-fare-range'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary),
            ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: field('Up arrows when AI time is above by', _trendUp,
                  (v) => _update(c.copyWith(trend: c.trend.withUp(v))), const ValueKey('fare-trend-up')),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: field('Down arrows when AI time is below by', _trendDown,
                  (v) => _update(c.copyWith(trend: c.trend.withDown(v))), const ValueKey('fare-trend-down')),
            ),
          ]),
          const SizedBox(height: 16),
          Text('Colours', style: t.textTheme.titleSmall),
          Text('Hex, e.g. #E02424. Leave blank for the default red (up) and green (down).', style: muted),
          const SizedBox(height: 8),
          for (final up in [true, false])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                for (final dark in [false, true]) ...[
                  if (dark) const SizedBox(width: 12),
                  Expanded(child: _trendColorField(c, canEdit, up: up, dark: dark)),
                ],
              ]),
            ),
          const SizedBox(height: 4),
          Text(
            m == null
                ? 'Not measured yet: from now on every answer is logged with the standard time it is compared with.'
                : 'Last ${m.count} answer${m.count == 1 ? '' : 's'}: the AI is typically ${signedPct(m.median)} against '
                    'standard (middle half ${signedPct(m.p25)} to ${signedPct(m.p75)}). With these settings up arrows '
                    'would show on ${share(m.upShare)} of trips and down arrows on ${share(m.downShare)}.',
            key: const ValueKey('fare-trend-measure'),
            style: muted,
          ),
        ]),
      ),
    );
  }

  /// One colour box: the hex, with the arrows drawn in it on the mode's card.
  Widget _trendColorField(FareAiConfig c, bool canEdit, {required bool up, required bool dark}) {
    final key = '${up ? 'up' : 'down'}Color${dark ? 'Dark' : 'Light'}';
    final ctl = _trendColors[key]!;
    final typed = ctl.text.trim();
    final valid = typed.isEmpty || FareTrendSettings.hex(typed) != null;
    final chosen = argbFromHex(c.trend.color(key));
    final fallback = up
        ? (dark ? FareTrendArrows.upDark : FareTrendArrows.upLight)
        : (dark ? FareTrendArrows.downDark : FareTrendArrows.downLight);
    final preview = Container(
      width: 36,
      height: 36,
      margin: const EdgeInsets.all(6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF262626) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: FareTrendArrows(
        trend: FareTrend(direction: up ? FareTrendDirection.up : FareTrendDirection.down, fromFareRange: true),
        size: 22,
        animate: false,
        color: chosen == null ? fallback : Color(chosen),
      ),
    );
    return TextField(
      key: ValueKey('fare-trend-$key'),
      controller: ctl,
      readOnly: !canEdit,
      onChanged: (v) {
        setState(() {}); // the preview and the error follow the typing
        if (v.trim().isEmpty || FareTrendSettings.hex(v) != null) {
          _update(c.copyWith(trend: c.trend.withColor(key, v)));
        }
      },
      decoration: InputDecoration(
        isDense: true,
        labelText: '${up ? 'Up' : 'Down'} arrows · ${dark ? 'dark' : 'light'} mode',
        hintText: '#${(fallback.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
        errorText: valid ? null : 'Use a hex colour like #E02424',
        suffixIcon: preview,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Another admin's save (or a key's state changing) shows here, unless
    // this form has unsaved edits.
    ref.listenAdminLive(const ['app_settings', 'fare_ai_key_states'], () {
      if (!_dirty && !_saving) unawaited(_load());
    });
    final canEdit = ref.watch(securityLevelProvider(_page)) == AccessLevel.edit;
    final c = _config;
    return AdminPage(
      title: 'Fare AI provider',
      page: _page,
      actions: [
        BusyIconButton(tooltip: 'Refresh usage stats', icon: const Icon(Icons.refresh), onPressed: _refreshStats),
        IconButton(
          tooltip: 'Request & format',
          icon: const Icon(Icons.tune),
          onPressed: _openRequest,
        ),
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
                  action: BusyButton.text(onPressed: _load, child: const Text('Retry')),
                )
              : const LoadingSkeletonPage())
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
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            key: const ValueKey('fare-ai-request-link'),
            leading: const Icon(Icons.tune),
            title: const Text('Request & format'),
            subtitle: Text(c.request.isDefault
                ? 'Default prompt · distance, time, summary and tolls'
                : 'Customised prompt · ${[
                    'distance, time',
                    if (c.request.includeSummary) 'summary',
                    if (c.request.includeTolls) c.request.includeTollCoords ? 'tolls with locations' : 'tolls',
                    if (c.request.includeFareRange) 'fare range',
                    if (c.request.includeTraffic) 'traffic',
                  ].join(', ')}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openRequest,
          ),
        ),
        const SizedBox(height: 16),
        _trendCard(c, canEdit),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: Text('${meta.label} keys', style: t.textTheme.titleMedium)),
          if (canEdit && _states.values.any((st) => isCoolingDown(st.disabledUntil)))
            BusyButton.text(
              key: const ValueKey('reset-all-cooldowns'),
              icon: const Icon(Icons.restart_alt),
              onPressed: () => _resetCooldown(),
              child: const Text('Reset all cooldowns'),
            ),
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
          BusyButton.filled(
            onPressed: _saving || !_dirty ? null : _save,
            icon: const Icon(Icons.save_outlined),
            child: Text(_dirty ? 'Save changes' : 'Saved'),
          )
        else
          const Text('You have read-only access to this setting.'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('View response log'),
          onPressed: () => context.push('/admin/m/fare-ai-logs'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.tune),
          label: const Text('Request & format'),
          onPressed: _openRequest,
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
            Row(children: [
              Expanded(
                child: Text('Cooling down — retries ${formatRelative(st?.disabledUntil)}',
                    style: const TextStyle(color: Colors.red)),
              ),
              if (canEdit)
                BusyButton.text(
                  key: ValueKey('reset-cooldown-${k.id}'),
                  icon: const Icon(Icons.restart_alt),
                  onPressed: () => _resetCooldown(k.id),
                  child: const Text('Reset cooldown'),
                ),
            ])
          else if (st?.lastError != null)
            Text('Last error: ${st!.lastError}', maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.red)),
        ]),
      ),
    );
  }
}

// ---- Response log ------------------------------------------------------------

final _responsesProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('fare_ai_responses');
  return ref.watch(securityRepositoryProvider).fareAiResponses();
});

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
          BusyIconButton(tooltip: 'Clear log', icon: const Icon(Icons.delete_sweep_outlined), onPressed: () => _clear(context, ref)),
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
          for (final line in fareAiTrafficLines(r['extra'] is Map ? r['extra'] as Map : null))
            Text(line, style: Theme.of(context).textTheme.bodySmall),
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
