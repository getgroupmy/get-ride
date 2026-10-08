import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/loading_skeleton.dart';
import '../../admin_access.dart';
import '../../widgets/admin_widgets.dart';
import 'fare_ai_logic.dart';
import 'security_data.dart';

const _page = 'admin-settings-fare-ai';

/// A sample trip for the preview and the test (KLCC → KL Sentral).
const _sampleOrigin = (lat: 3.158, lng: 101.712);
const _sampleDest = (lat: 3.134, lng: 101.686);

/// Admin → Fare AI → Request & format: the wording the fare AI is sent, which
/// optional fields it is asked for, and a test run before saving. The answer's
/// JSON shape stays fixed (distance_km and duration_min always), since fares
/// are priced on it.
class AdminFareAiRequestScreen extends ConsumerStatefulWidget {
  const AdminFareAiRequestScreen({super.key});

  @override
  ConsumerState<AdminFareAiRequestScreen> createState() => _RequestState();
}

class _RequestState extends ConsumerState<AdminFareAiRequestScreen> {
  FareAiRequest? _draft;
  FareAiRequest? _saved;
  String _provider = '';
  Object? _error;

  final _system = TextEditingController();
  final _template = TextEditingController();
  final _maxTokens = TextEditingController();
  final _origin = TextEditingController(text: '${_sampleOrigin.lat},${_sampleOrigin.lng}');
  final _dest = TextEditingController(text: '${_sampleDest.lat},${_sampleDest.lng}');

  Map<String, dynamic>? _test;
  Object? _testError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_system, _template, _maxTokens, _origin, _dest]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = await ref.read(securityRepositoryProvider).fareAiConfig();
      if (!mounted) return;
      setState(() {
        _saved = c.request;
        _provider = c.provider;
        _error = null;
      });
      _fill(c.request);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _fill(FareAiRequest r) {
    _draft = r;
    _system.text = r.systemInstruction;
    _template.text = r.promptTemplate;
    _maxTokens.text = '${r.maxTokens}';
  }

  void _set(FareAiRequest r) => setState(() => _draft = r);

  String? get _problem => fareAiTemplateProblem(_template.text);

  bool get _dirty {
    final d = _draft, s = _saved;
    if (d == null || s == null) return false;
    return _system.text.trim() != s.systemInstruction ||
        _template.text.trim() != s.promptTemplate ||
        d.includeSummary != s.includeSummary ||
        d.includeTolls != s.includeTolls ||
        (d.includeTolls && d.includeTollCoords) != (s.includeTolls && s.includeTollCoords) ||
        d.temperature != s.temperature ||
        d.maxTokens != s.maxTokens;
  }

  /// The draft with the text boxes applied.
  FareAiRequest get _current => _draft!.copyWith(
    systemInstruction: _system.text.trim().isEmpty ? fareAiDefaultSystem : _system.text.trim(),
    promptTemplate: _template.text.trim(),
  );

  void _insert(String placeholder) {
    final sel = _template.selection;
    final text = _template.text;
    final at = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _template.value = TextEditingValue(
      text: text.replaceRange(at, end, placeholder),
      selection: TextSelection.collapsed(offset: at + placeholder.length),
    );
    setState(() {});
  }

  Future<void> _save() async {
    final next = _current;
    final ok = await runAdminAction(context, () async {
      // Re-read so keys or a provider changed elsewhere are never overwritten.
      final repo = ref.read(securityRepositoryProvider);
      final c = await repo.fareAiConfig();
      await repo.saveFareAiConfig(c.copyWith(request: next));
    }, success: 'The fare AI now uses this request.');
    if (ok && mounted) setState(() => _saved = FareAiRequest.fromJson(next.toJson()));
  }

  void _resetToDefault() {
    _fill(FareAiRequest.defaults);
    setState(() {});
  }

  ({double lat, double lng})? _point(String s) {
    final parts = s.split(',').map((p) => double.tryParse(p.trim())).toList();
    if (parts.length != 2 || parts.any((p) => p == null)) return null;
    final lat = parts[0]!, lng = parts[1]!;
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    return (lat: lat, lng: lng);
  }

  Future<void> _runTest() async {
    final o = _point(_origin.text), d = _point(_dest.text);
    if (o == null || d == null) {
      setState(() {
        _test = null;
        _testError = 'Enter both points as "latitude,longitude".';
      });
      return;
    }
    setState(() {
      _test = null;
      _testError = null;
    });
    try {
      final r = await ref.read(securityRepositoryProvider).testFareAiRequest(_current, origin: o, destination: d);
      if (mounted) setState(() => _test = r);
    } catch (e) {
      if (mounted) setState(() => _testError = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(securityLevelProvider(_page)) == AccessLevel.edit;
    return AdminPage(
      title: 'Fare AI · Request & format',
      page: _page,
      body: _draft == null
          ? (_error != null
                ? EmptyState(
                    icon: Icons.lock_outline,
                    title: 'Could not load the fare AI settings',
                    message: errorText(_error!),
                    action: BusyButton.text(onPressed: _load, child: const Text('Retry')),
                  )
                : const LoadingSkeletonPage())
          : _body(canEdit),
    );
  }

  Widget _body(bool canEdit) {
    final t = Theme.of(context);
    final d = _draft!;
    final problem = _problem;
    final preview = problem == null ? fareAiPrompt(_current, _sampleOrigin, _sampleDest) : null;
    return ResponsiveCenter(
      maxWidth: 760,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text(
                'What every fare AI request says. The wording and the optional fields are yours; the answer '
                'always includes distance_km and duration_min, because fares are priced on them.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('System instruction', style: t.textTheme.titleMedium),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('fare-ai-system'),
            controller: _system,
            readOnly: !canEdit,
            minLines: 2,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          Text('Prompt', style: t.textTheme.titleMedium),
          Text('Placeholders are filled with the trip. Tap one to insert it.', style: t.textTheme.bodySmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in fareAiPlaceholders.entries)
                Tooltip(
                  message: e.value,
                  child: ActionChip(
                    key: ValueKey('placeholder-${e.key}'),
                    label: Text(e.key, style: const TextStyle(fontFamily: 'monospace')),
                    onPressed: canEdit ? () => _insert(e.key) : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('fare-ai-template'),
            controller: _template,
            readOnly: !canEdit,
            minLines: 4,
            maxLines: 12,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(border: const OutlineInputBorder(), errorText: problem, errorMaxLines: 3),
          ),
          const SizedBox(height: 16),
          Text('Ask the AI for', style: t.textTheme.titleMedium),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('Distance and drive time'),
                  subtitle: Text('distance_km and duration_min — always asked for'),
                ),
                SwitchListTile(
                  key: const ValueKey('ask-summary'),
                  secondary: const Icon(Icons.short_text),
                  title: const Text('Route summary'),
                  subtitle: const Text('summary: a short description of the route'),
                  value: d.includeSummary,
                  onChanged: canEdit ? (v) => _set(d.copyWith(includeSummary: v)) : null,
                ),
                SwitchListTile(
                  key: const ValueKey('ask-tolls'),
                  secondary: const Icon(Icons.toll_outlined),
                  title: const Text('Tolls'),
                  subtitle: const Text('toll_count, toll_total and each booth with its charge'),
                  value: d.includeTolls,
                  onChanged: canEdit ? (v) => _set(d.copyWith(includeTolls: v)) : null,
                ),
                SwitchListTile(
                  key: const ValueKey('ask-toll-coords'),
                  secondary: const Icon(Icons.place_outlined),
                  title: const Text('Toll booth locations'),
                  subtitle: const Text('lat and lng of each booth, for the map'),
                  value: d.includeTolls && d.includeTollCoords,
                  onChanged: canEdit && d.includeTolls ? (v) => _set(d.copyWith(includeTollCoords: v)) : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('Temperature: ${d.temperature.toStringAsFixed(1)}', style: t.textTheme.titleMedium),
          Text('0 gives the same answer for the same trip; higher varies it.', style: t.textTheme.bodySmall),
          Slider(
            key: const ValueKey('fare-ai-temperature'),
            value: d.temperature,
            divisions: 10,
            label: d.temperature.toStringAsFixed(1),
            onChanged: canEdit ? (v) => _set(d.copyWith(temperature: (v * 10).round() / 10)) : null,
          ),
          TextField(
            key: const ValueKey('fare-ai-max-tokens'),
            controller: _maxTokens,
            readOnly: !canEdit,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Max output tokens',
              helperText: 'Used where the provider needs a cap (Claude). 128–4096.',
            ),
            onChanged: (v) {
              final n = int.tryParse(v.trim());
              if (n != null) _set(d.copyWith(maxTokens: n.clamp(128, 4096)));
            },
          ),
          const SizedBox(height: 16),
          ExpansionTile(
            key: const ValueKey('fare-ai-preview'),
            tilePadding: EdgeInsets.zero,
            title: const Text('Preview: what the AI receives'),
            subtitle: const Text('For a sample trip, KLCC → KL Sentral'),
            children: [
              _mono('System', _current.systemInstruction),
              if (preview != null)
                _mono('Prompt', preview)
              else
                Text(problem!, style: TextStyle(color: t.colorScheme.error)),
            ],
          ),
          const SizedBox(height: 16),
          Text('Test', style: t.textTheme.titleMedium),
          Text(
            'Sends this draft once to ${fareAiProviderLabel(_provider)} with your first active key. '
            'Nothing is logged, and no key is counted or paused.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _origin,
                  decoration: const InputDecoration(labelText: 'From (lat,lng)', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _dest,
                  decoration: const InputDecoration(labelText: 'To (lat,lng)', isDense: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          BusyButton.outlined(
            key: const ValueKey('fare-ai-run-test'),
            icon: const Icon(Icons.play_arrow),
            onPressed: problem != null ? null : _runTest,
            child: const Text('Run test'),
          ),
          if (_testError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(errorText(_testError!), style: TextStyle(color: t.colorScheme.error)),
            ),
          if (_test != null) _testResult(_test!),
          const SizedBox(height: 20),
          if (canEdit) ...[
            BusyButton.filled(
              key: const ValueKey('fare-ai-request-save'),
              icon: const Icon(Icons.save_outlined),
              onPressed: problem != null || !_dirty ? null : _save,
              child: Text(_dirty ? 'Save changes' : 'Saved'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('fare-ai-request-reset'),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset to default'),
              onPressed: _current.isDefault ? null : _resetToDefault,
            ),
          ] else
            const Text('You have read-only access to this setting.'),
        ],
      ),
    );
  }

  Widget _mono(String label, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label.isNotEmpty) ...[
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
        ],
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ],
    ),
  );

  Widget _testResult(Map<String, dynamic> r) {
    final t = Theme.of(context);
    final est = r['estimate'] is Map ? r['estimate'] as Map : null;
    return Card(
      key: const ValueKey('fare-ai-test-result'),
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  est != null ? Icons.check_circle : Icons.error_outline,
                  color: est != null ? Colors.green : t.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    est != null
                        ? '${est['distance_km']} km · ${est['duration_min']} min'
                        : '${r['error'] ?? 'No estimate'}',
                    style: t.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                fareAiProviderLabel('${r['provider'] ?? ''}'),
                if (r['model'] != null) '${r['model']}',
                if (r['key_label'] != null) 'key "${r['key_label']}"',
                if (r['latency_ms'] != null) '${r['latency_ms']} ms',
                if (r['http_status'] != null) 'HTTP ${r['http_status']}',
              ].join(' · '),
              style: t.textTheme.bodySmall,
            ),
            if (est?['summary'] != null) Text('${est!['summary']}'),
            if (est != null && est['tolls'] is List && (est['tolls'] as List).isNotEmpty)
              for (final toll in est['tolls'] as List)
                if (toll is Map) Text('• ${toll['name'] ?? 'Toll booth'} — ${toll['charge']}'),
            if (r['raw'] != null)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Raw reply'),
                children: [_mono('', '${r['raw']}')],
              ),
          ],
        ),
      ),
    );
  }
}
