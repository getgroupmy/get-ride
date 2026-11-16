import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/fare_timing.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/loading_skeleton.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../widgets/admin_widgets.dart';
import '../../widgets/region_scope_picker.dart' show pickRegionScope;
import '../../test_traffic.dart';
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

/// The server lists that speak GET.route's API: Waze (GET.route), Google Maps
/// (the Traffic Scraper) and Apple Maps (GET.route Apple Maps). [step] is the
/// fare-order step, also the prefix of the widgets' keys.
enum _ServerKind {
  waze('waze', 'Waze servers', 'Waze server', 'https://route1.getride.my'),
  gmap('gmap', 'Google Maps servers', 'Google Maps server', 'https://traffic.getride.my'),
  apple('apple', 'Apple Maps servers', 'Apple Maps server', 'https://apple.getride.my');

  const _ServerKind(this.step, this.title, this.serverLabel, this.urlHint);

  final String step;
  final String title;
  final String serverLabel;
  final String urlHint;

  List<WazeServer> of(FareAiConfig c) => switch (this) {
        waze => c.wazeServers,
        gmap => c.gmapServers,
        apple => c.appleServers,
      };
}

class _FareAiState extends ConsumerState<AdminFareAiScreen> {
  FareAiConfig? _config;
  Map<String, FareAiKeyState> _states = {};
  Map<String, WazeServerHealth> _health = {};

  /// The automatic Waze / Google Maps share right now (null: not read yet).
  FareLiveBalanceState? _balanceState;
  Object? _error;
  bool _dirty = false;
  bool _saving = false;

  /// Per-key text controllers so typing doesn't lose the cursor on rebuild.
  final _controllers = <String, ({TextEditingController label, TextEditingController key})>{};

  /// The same for each Waze and Google Maps server.
  final _serverControllers =
      <String, ({TextEditingController label, TextEditingController url, TextEditingController key})>{};
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
    for (final c in _serverControllers.values) {
      c.label.dispose();
      c.url.dispose();
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
      final results = await Future.wait([repo.fareAiConfig(), repo.fareAiKeyStates(), repo.wazeServerHealth()]);
      if (!mounted) return;
      final c = results[0] as FareAiConfig;
      setState(() {
        _config = c;
        _states = results[1] as Map<String, FareAiKeyState>;
        _health = results[2] as Map<String, WazeServerHealth>;
        _error = null;
        _dirty = false;
      });
      _syncFields(c);
      _loadTrendSample();
      _loadBalanceState();
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
    final repo = ref.read(securityRepositoryProvider);
    final s = await repo.fareAiKeyStates();
    final h = await repo.wazeServerHealth();
    if (mounted) {
      setState(() {
        _states = s;
        _health = h;
      });
    }
    await _loadTrendSample();
    await _loadBalanceState();
  }

  Future<void> _loadBalanceState() async {
    try {
      final b = await ref.read(securityRepositoryProvider).fareLiveBalanceState();
      if (mounted) setState(() => _balanceState = b);
    } catch (_) {
      // An older database without fare_live_balance: the card just doesn't show it.
    }
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

  void _setServers(List<WazeServer> servers, [_ServerKind kind = _ServerKind.waze]) => _update(switch (kind) {
        _ServerKind.waze => _config!.copyWith(wazeServers: servers),
        _ServerKind.gmap => _config!.copyWith(gmapServers: servers),
        _ServerKind.apple => _config!.copyWith(appleServers: servers),
      });

  ({TextEditingController label, TextEditingController url, TextEditingController key}) _serverCtl(WazeServer s) =>
      _serverControllers.putIfAbsent(
          s.id,
          () => (
                label: TextEditingController(text: s.label),
                url: TextEditingController(text: s.url),
                key: TextEditingController(text: s.key),
              ));

  /// One sample trip (KLCC to KL Sentral) through the server as typed, saved or not.
  Future<void> _testServer(WazeServer s, [_ServerKind kind = _ServerKind.waze]) async {
    try {
      final r = await ref.read(securityRepositoryProvider).testWazeServer(s,
          origin: (lat: 3.158, lng: 101.712), destination: (lat: 3.134, lng: 101.686), kind: kind.step);
      if (!mounted) return;
      final e = r['estimate'];
      final ms = r['latency_ms'];
      if (e is Map) {
        final tolls = (e['toll_total'] is num && (e['toll_total'] as num) > 0) ? ' · tolls ${e['toll_total']}' : '';
        showInfo(context,
            '${s.label} answered in ${ms ?? '?'} ms: ${e['distance_km']} km, ${e['duration_min']} min$tolls.\n${e['summary'] ?? ''}');
      } else {
        showError(context, Exception('${s.label} did not answer a route: ${r['error'] ?? 'no answer'}'));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
  Future<void> _save() async {
    final c = _config!;
    setState(() => _saving = true);
    final ok = await runAdminAction(context, () => ref.read(securityRepositoryProvider).saveFareAiConfig(c),
        success: c.chain.isEmpty
            ? 'Fare estimates are off: fares use the routing engine fallback.'
            : 'Fare estimates now come from ${fareChainLabel(c.chain)} for all users.'
                '${c.uses('waze') && c.uses('gmap') ? ' ${c.liveBalance.label}.' : ''}');
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
            title: Text('Choose where trip distance & traffic-aware time for fares come from, and in what order. '
                "Applies globally to all users. Add multiple AI keys or Waze / Google Maps servers — if one fails it's skipped for "
                'the retry window below and the next one is tried automatically.'),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Fare data order', style: t.textTheme.titleMedium),
              const SizedBox(height: 8),
              SearchableDropdownFormField<String>(
                key: ValueKey('fare-chain-${c.chain.join(',')}'),
                isExpanded: true,
                initialValue: c.chain.join(','),
                decoration: const InputDecoration(labelText: 'Ask in this order'),
                items: [
                  for (final ch in {...fareChains.map((x) => x.join(',')), c.chain.join(',')})
                    DropdownMenuItem(
                      value: ch,
                      child: Text(fareChainLabel(ch.isEmpty ? const [] : ch.split(',')), overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: canEdit
                    ? (v) => _update(c.copyWith(chain: v == null || v.isEmpty ? const [] : cleanFareChain(v.split(','))))
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                'Each step is asked only when the one before has no answer. Waze: live traffic, distance and tolls '
                'from the GET.route pool on the office NAS. Google Maps: Google\'s recommended route and live time '
                'from the Traffic Scraper on the office NAS (no toll prices). Each step has its own time (Time limits below). AI: the provider below. OSRM: road distance and '
                'time without traffic, from the office NAS maps (or the OSRM server when the NAS is off). '
                'Apple Maps: Apple\'s route and time from GET.route Apple Maps on the office NAS (Apple\'s official '
                'Maps Server API, 25,000 calls a day, no toll prices); it has its own 1.5 seconds. The Waze / Google '
                'Maps balance only swaps those two; Apple Maps keeps its place.',
                style: t.textTheme.bodySmall,
              ),
            ]),
          ),
        ),
        if (c.uses('waze')) ..._serverSection(c, _ServerKind.waze, canEdit),
        if (c.uses('gmap')) ..._serverSection(c, _ServerKind.gmap, canEdit),
        if (c.uses('apple')) ..._serverSection(c, _ServerKind.apple, canEdit),
        if ((c.uses('waze') && c.uses('gmap')) || appleBalanceApplies(c.chain)) ..._balanceSection(c, canEdit),
        if (c.chain.isNotEmpty) ..._timingSection(c, canEdit),
        const SizedBox(height: 12),
        Text(_aiTitle(c), style: t.textTheme.titleMedium),
        const SizedBox(height: 6),
        Opacity(
          opacity: c.uses('ai') ? 1 : 0.5,
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

  /// Which live-traffic step a fare asks first: Google Maps' share and
  /// Apple Maps' share, each fixed or automatic inside a range; Waze takes
  /// the rest (`_shared/live_balance.ts`).
  List<Widget> _balanceSection(FareAiConfig c, bool canEdit) {
    final t = Theme.of(context);
    final b = c.liveBalance;
    void set(FareLiveBalance next) => _update(c.copyWith(liveBalance: next));
    final live = _balanceState;
    final gmapOn = c.uses('waze') && c.uses('gmap');
    return [
      const SizedBox(height: 16),
      Card(
        key: const ValueKey('live-balance-card'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(liveBalanceTitle(c.chain), style: t.textTheme.titleMedium),
            if (gmapOn) ..._gmapBalance(b, set, live, canEdit),
            if (appleBalanceApplies(c.chain)) ..._appleBalance(c, b, set, live, canEdit),
          ]),
        ),
      ),
    ];
  }

  /// The Google Maps share (as the Waze / Google Maps balance had it).
  List<Widget> _gmapBalance(
      FareLiveBalance b, void Function(FareLiveBalance) set, FareLiveBalanceState? live, bool canEdit) {
    final t = Theme.of(context);
    return [
            const SizedBox(height: 4),
            Text(
              'Which one a fare asks first. The other is that fare\'s backup, in its own time (Time limits). '
              'Waze answers about 368 lookups a minute (GET.route pool); Google Maps about 70 (one NAS).',
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              key: const ValueKey('live-balance-mode'),
              segments: const [
                ButtonSegment(value: false, label: Text('Fixed'), icon: Icon(Icons.tune)),
                ButtonSegment(value: true, label: Text('Automatic'), icon: Icon(Icons.autorenew)),
              ],
              selected: {b.auto},
              onSelectionChanged: canEdit ? (v) => set(b.copyWith(auto: v.first)) : null,
            ),
            const SizedBox(height: 12),
            if (!b.auto) ...[
              Text(b.gmapFirstPct == 0
                  ? 'Waze always first (Google Maps only when Waze has no answer)'
                  : 'Google Maps first for ${b.gmapFirstPct}% of fares, Waze first for ${100 - b.gmapFirstPct}%'),
              Slider(
                key: const ValueKey('live-balance-fixed'),
                value: b.gmapFirstPct.toDouble(),
                max: 100,
                divisions: 20,
                label: '${b.gmapFirstPct}%',
                onChanged: canEdit ? (v) => set(b.copyWith(gmapFirstPct: v.round())) : null,
              ),
            ] else ...[
              Text('Google Maps first for between ${b.minPct}% and ${b.maxPct}% of fares'),
              RangeSlider(
                key: const ValueKey('live-balance-range'),
                values: RangeValues(b.minPct.toDouble(), b.maxPct.toDouble()),
                max: 100,
                divisions: 20,
                labels: RangeLabels('${b.minPct}%', '${b.maxPct}%'),
                onChanged: canEdit ? (v) => set(b.copyWith(minPct: v.start.round(), maxPct: v.end.round())) : null,
              ),
              Text(
                'Every minute the share moves a few points toward whichever answered more of the last 15 minutes\' '
                'fares, down when Google Maps gets too slow for the 3 seconds, and straight to the edge of the range '
                'when one is offline.',
                style: t.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.speed, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    live == null
                        ? 'Now: not set yet (the first check after saving sets it)'
                        : 'Now: Google Maps first for ${live.gmapFirstPct.clamp(b.minPct, b.maxPct)}% · '
                            'updated ${formatRelative(live.updatedAt)}${live.reason != null ? '\n${live.reason}' : ''}',
                    key: const ValueKey('live-balance-now'),
                  ),
                ),
              ]),
            ],
    ];
  }

  /// Apple Maps' share: taken from Waze's part, fixed or automatic.
  List<Widget> _appleBalance(FareAiConfig c, FareLiveBalance b, void Function(FareLiveBalance) set,
      FareLiveBalanceState? live, bool canEdit) {
    final t = Theme.of(context);
    final gmapFixed = c.uses('waze') && c.uses('gmap') && !b.auto ? b.gmapFirstPct : 0;
    final appleFixed = b.appleFirstPct.clamp(0, 100 - gmapFixed);
    return [
      const SizedBox(height: 16),
      Text('Apple Maps', style: t.textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(
        'A share of fares asks Apple Maps first, taken from Waze\'s part; Google Maps\' share stays as set above. '
        'Apple Maps answers through Apple\'s official Maps Server API: 25,000 calls a day for the team, and the '
        'NAS server allows 20 a minute, so keep the share small when traffic is high.',
        style: t.textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      SegmentedButton<bool>(
        key: const ValueKey('apple-balance-mode'),
        segments: const [
          ButtonSegment(value: false, label: Text('Fixed'), icon: Icon(Icons.tune)),
          ButtonSegment(value: true, label: Text('Automatic'), icon: Icon(Icons.autorenew)),
        ],
        selected: {b.appleAuto},
        onSelectionChanged: canEdit ? (v) => set(b.copyWith(appleAuto: v.first)) : null,
      ),
      const SizedBox(height: 12),
      if (!b.appleAuto) ...[
        Text(
          b.appleFirstPct == 0
              ? 'Apple Maps keeps its place in the order'
              : 'Apple Maps first for $appleFixed% of fares'
                  '${gmapFixed > 0 ? ', Google Maps $gmapFixed%, Waze ${100 - gmapFixed - appleFixed}%' : ', Waze first for ${100 - appleFixed}%'}',
          key: const ValueKey('apple-balance-text'),
        ),
        Slider(
          key: const ValueKey('apple-balance-fixed'),
          value: b.appleFirstPct.toDouble(),
          max: 100,
          divisions: 20,
          label: '${b.appleFirstPct}%',
          onChanged: canEdit ? (v) => set(b.copyWith(appleFirstPct: v.round())) : null,
        ),
      ] else ...[
        Text('Apple Maps first for between ${b.appleMinPct}% and ${b.appleMaxPct}% of fares',
            key: const ValueKey('apple-balance-text')),
        RangeSlider(
          key: const ValueKey('apple-balance-range'),
          values: RangeValues(b.appleMinPct.toDouble(), b.appleMaxPct.toDouble()),
          max: 100,
          divisions: 20,
          labels: RangeLabels('${b.appleMinPct}%', '${b.appleMaxPct}%'),
          onChanged:
              canEdit ? (v) => set(b.copyWith(appleMinPct: v.start.round(), appleMaxPct: v.end.round())) : null,
        ),
        Text(
          'Every minute the share moves a few points toward whichever of Waze and Apple Maps answered more of the '
          'last 15 minutes\' fares, down when Apple Maps gets slow, and to the bottom of the range while Apple Maps '
          'is offline or refusing for its quota.',
          style: t.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.speed, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              live == null || live.appleUpdatedAt == null
                  ? 'Now: not set yet (the first check after saving sets it)'
                  : 'Now: Apple Maps first for ${live.appleFirstPct.clamp(b.appleMinPct, b.appleMaxPct)}% · '
                      'updated ${formatRelative(live.appleUpdatedAt)}'
                      '${live.appleReason != null ? '\n${live.appleReason}' : ''}',
              key: const ValueKey('apple-balance-now'),
            ),
          ),
        ]),
      ],
    ];
  }

  /// Time limits (Admin › Fare AI provider): how long each step may take
  /// before the fare goes to the next, and how long the rider app waits in
  /// all (`_shared/fare_timing.ts`, [FareTiming]).
  List<Widget> _timingSection(FareAiConfig c, bool canEdit) {
    final t = Theme.of(context);
    final f = c.timing;
    void set(FareTiming next) => _update(c.copyWith(timing: next));
    String secs(double v) => '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} s';
    Widget row(String key, String label, String help, double value, ValueChanged<double> onChanged) {
      final (lo, hi) = FareTiming.bounds[key]!;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text(label, style: t.textTheme.bodyLarge)),
          Text(secs(value), key: ValueKey('timing-$key-value'), style: t.textTheme.titleSmall),
        ]),
        Text(help, style: t.textTheme.bodySmall),
        Slider(
          key: ValueKey('timing-$key'),
          value: value.clamp(lo, hi),
          min: lo,
          max: hi,
          divisions: ((hi - lo) * 2).round(),
          label: secs(value),
          onChanged: canEdit ? (v) => onChanged((v * 2).round() / 2) : null,
        ),
      ]);
    }

    // The longest the live-traffic steps can take before the AI and OSRM:
    // Waze, then Google Maps, then Apple Maps on the server or the phone.
    final before = (c.uses('waze') ? f.wazeSeconds : 0) + (c.uses('gmap') ? f.gmapSeconds : 0) +
        [if (c.uses('apple')) f.appleSeconds, if (f.deviceApple) f.deviceAppleSeconds, 0.0].reduce((a, b) => a > b ? a : b);
    final tooLong = (c.uses('ai') || c.uses('osrm')) && before >= f.appWaitSeconds;
    return [
      const SizedBox(height: 16),
      Card(
        key: const ValueKey('fare-timing-card'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Time limits', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'How long each step may take before the fare goes to the next one. A step that fails is skipped on the '
              'next fares for ${retryLabel(c)}.',
              style: t.textTheme.bodySmall,
            ),
            if (c.uses('waze'))
              row('wazeSeconds', 'Waze', 'Every Waze server tried, together.', f.wazeSeconds,
                  (v) => set(f.copyWith(wazeSeconds: v))),
            if (c.uses('gmap'))
              row('gmapSeconds', 'Google Maps', 'Every Google Maps server tried, together.', f.gmapSeconds,
                  (v) => set(f.copyWith(gmapSeconds: v))),
            if (c.uses('apple'))
              row('appleSeconds', 'Apple Maps server', 'GET.route Apple Maps on the office NAS.', f.appleSeconds,
                  (v) => set(f.copyWith(appleSeconds: v))),
            if (c.uses('ai'))
              row('aiSeconds', 'AI, each key', 'Each AI key tried, one after another.', f.aiSeconds, (v) => set(f.copyWith(aiSeconds: v))),
            if (c.uses('osrm'))
              row('osrmSeconds', 'OSRM (office NAS)', 'Else the public OSRM server\'s answer is used.', f.osrmSeconds,
                  (v) => set(f.copyWith(osrmSeconds: v))),
            row('appWaitSeconds', 'Rider app waits in all',
                '"Calculating fare". Past it the app prices the plain route on the phone.', f.appWaitSeconds,
                (v) => set(f.copyWith(appWaitSeconds: v))),
            const Divider(height: 24),
            SwitchListTile(
              key: const ValueKey('timing-deviceApple'),
              contentPadding: EdgeInsets.zero,
              title: const Text('iPhones ask Apple Maps themselves'),
              subtitle: const Text(
                'In Apple Maps\' place in the order, or right after Waze and Google Maps when it isn\'t in it. On the '
                'phone (MapKit): no server and no quota. Shown and logged as "Apple Maps (iPhone)".',
              ),
              value: f.deviceApple,
              onChanged: canEdit ? (v) => set(f.copyWith(deviceApple: v)) : null,
            ),
            if (f.deviceApple)
              row('deviceAppleSeconds', 'Apple Maps on the iPhone', 'How long the phone waits for Apple Maps.',
                  f.deviceAppleSeconds, (v) => set(f.copyWith(deviceAppleSeconds: v))),
            if (tooLong) ...[
              const SizedBox(height: 8),
              Row(key: const ValueKey('timing-too-long'), children: [
                Icon(Icons.warning_amber_rounded, color: t.colorScheme.error, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Waze, Google Maps and Apple Maps together can take ${secs(before)}, as long as the '
                    'app waits (${secs(f.appWaitSeconds)}): when they all miss, the AI and OSRM answer too late.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ),
    ];
  }

  /// "AI provider (after Waze and Google Maps)": the steps asked before it.
  String _aiTitle(FareAiConfig c) {
    final i = c.chain.indexOf('ai');
    final before = [for (final s in i > 0 ? c.chain.sublist(0, i) : const <String>[]) fareSteps[s] ?? s];
    return before.isEmpty ? 'AI provider' : 'AI provider (after ${before.join(' and ')})';
  }

  /// One kind's servers (Waze: GET.route; Google Maps: the Traffic Scraper):
  /// one per container on the office NAS, each for an area or for any trip,
  /// asked most specific area first.
  List<Widget> _serverSection(FareAiConfig c, _ServerKind kind, bool canEdit) {
    final t = Theme.of(context);
    final servers = kind.of(c);
    final what = switch (kind) {
      _ServerKind.gmap => 'Each Traffic Scraper container on the office NAS (getgroupmy/get.route.backup) is one '
          'server. It reads Google Maps\' recommended route and live time; it is asked with the time Waze leaves.',
      _ServerKind.apple => 'Each GET.route Apple Maps container on the office NAS (getgroupmy/get.route.apple) is '
          'one server. It asks Apple\'s official Maps Server API (25,000 calls a day for the team); when the day\'s '
          'calls are used up the server rests until Apple\'s quota resets.',
      _ServerKind.waze => 'Each GET.route container on the office NAS is one server.',
    };
    return [
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: Text(kind.title, style: t.textTheme.titleMedium)),
        if (canEdit)
          TextButton.icon(
            key: ValueKey('add-${kind.step}-server'),
            icon: const Icon(Icons.add),
            label: const Text('Add server'),
            onPressed: () => _setServers(
                [...servers, WazeServer.create(label: '${kind.serverLabel} ${servers.length + 1}')], kind),
          ),
      ]),
      Text(
        '$what Give a server a country, state, city or '
        'suburb to split the load: a trip asks the server for its pickup\'s smallest matching area first, then '
        'servers for all regions, then the others as a backup. A server that fails rests for ${retryLabel(c)}. '
        'Every minute each server is checked; admins with Fare AI access get a push when one has been offline '
        'for 5 minutes, and again when it is back.',
        style: t.textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      if (servers.isEmpty)
        Card(
          child: ListTile(
            title: Text('No servers yet. ${canEdit ? 'Tap "Add server" and paste the tunnel address and key.' : ''}'),
          ),
        ),
      for (final (i, s) in servers.indexed) _serverCard(c, kind, s, i, canEdit),
    ];
  }

  Widget _serverCard(FareAiConfig c, _ServerKind kind, WazeServer s, int i, bool canEdit) {
    final st = _states[s.id];
    final cooling = isCoolingDown(st?.disabledUntil);
    final ctl = _serverCtl(s);
    final servers = kind.of(c);
    void setServers(List<WazeServer> list) => _setServers(list, kind);
    List<WazeServer> patch(WazeServer Function(WazeServer) f) => [for (final x in servers) x.id == s.id ? f(x) : x];
    void move(int by) {
      final list = [...servers]..removeAt(i);
      list.insert(i + by, s);
      setServers(list);
    }

    final problem = s.urlProblem;
    return Card(
      key: ValueKey('${kind.step}-server-${s.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: ctl.label,
                readOnly: !canEdit,
                decoration: InputDecoration(isDense: true, hintText: '${kind.serverLabel} ${i + 1}', labelText: 'Name'),
                onChanged: (v) => setServers(patch((x) => x.copyWith(label: v))),
              ),
            ),
            Switch(value: s.enabled, onChanged: canEdit ? (v) => setServers(patch((x) => x.copyWith(enabled: v))) : null),
            if (canEdit) ...[
              IconButton(
                tooltip: 'Ask earlier',
                icon: const Icon(Icons.arrow_upward),
                onPressed: i == 0 ? null : () => move(-1),
              ),
              IconButton(
                tooltip: 'Remove server',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (await confirm(context, 'Remove server', 'Remove "${s.label}"? Save to apply.', ok: 'Remove')) {
                    setServers(servers.where((x) => x.id != s.id).toList());
                  }
                },
              ),
            ],
          ]),
          TextField(
            controller: ctl.url,
            readOnly: !canEdit,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Server URL',
              hintText: kind.urlHint,
              errorText: s.url.isEmpty ? null : problem,
            ),
            onChanged: (v) => setServers(patch((x) => x.copyWith(url: v))),
          ),
          if (canEdit)
            TextField(
              controller: ctl.key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Key', hintText: 'ROUTE_API_KEY from the server\'s .env'),
              onChanged: (v) => setServers(patch((x) => x.copyWith(key: v))),
            ),
          if (_health[s.id] case final h?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Icon(h.state == 'online' ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                    size: 18, color: h.state == 'online' ? Colors.green : Colors.red),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(h.label(), maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: h.state == 'online' ? null : Colors.red)),
                ),
              ]),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined),
            title: Text(s.area.label),
            subtitle: const Text('Area this server serves first'),
            trailing: canEdit
                ? TextButton(
                    onPressed: () async {
                      final area = await pickRegionScope(context,
                          title: 'Area for ${s.label}', initial: s.area, allowAll: true);
                      if (area != null) setServers(patch((x) => x.copyWith(area: area)));
                    },
                    child: const Text('Change'),
                  )
                : null,
          ),
          Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${st?.usageCount ?? 0} used'),
            Text('${st?.passCount ?? 0} passed', style: const TextStyle(color: Colors.green)),
            Text('${st?.failCount ?? 0} failed', style: const TextStyle(color: Colors.red)),
            Text('last used ${formatRelative(st?.lastUsedAt)}', style: Theme.of(context).textTheme.bodySmall),
          ]),
          if (cooling)
            Row(children: [
              Expanded(
                child: Text('Resting after a failure — back ${formatRelative(st?.disabledUntil)}',
                    style: const TextStyle(color: Colors.red)),
              ),
              if (canEdit)
                BusyButton.text(
                  key: ValueKey('reset-cooldown-${s.id}'),
                  icon: const Icon(Icons.restart_alt),
                  onPressed: () => _resetCooldown(s.id),
                  child: const Text('Reset'),
                ),
            ])
          else if (st?.lastError != null)
            Text('Last error: ${st!.lastError}', maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.red)),
          if (canEdit)
            Align(
              alignment: Alignment.centerLeft,
              child: BusyButton.text(
                key: ValueKey('test-${kind.step}-server-${s.id}'),
                icon: const Icon(Icons.play_arrow_outlined),
                onPressed: problem != null || s.key.trim().isEmpty ? null : () => _testServer(s, kind),
                child: const Text('Test (KLCC to KL Sentral)'),
              ),
            ),
        ]),
      ),
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
  return ref.watch(securityRepositoryProvider).fareAiResponses(includeTest: ref.watch(fareAiLogIncludeTestProvider));
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
                IncludeTestTrafficSwitch(provider: fareAiLogIncludeTestProvider),
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
            Text('${c(r['origin_lat'])},${c(r['origin_lng'])} to ${c(r['dest_lat'])},${c(r['dest_lng'])}',
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
