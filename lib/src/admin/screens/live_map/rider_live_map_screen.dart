// Admin › Settings › Rider live map (migration 0322): what riders may see on
// the home map. A Default rule and rules per region (country, state, city,
// suburb; the most specific wins and a region sets only what it changes),
// four modes each switched on or off, who sees it, which fields show (some
// never), and every number. The server enforces all of it and logs each
// change in the admin audit log.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/rider_live_map.dart';
import '../../../data/rider_live_map_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../widgets/region_scope_picker.dart';
import '../city_to_city/c2c_widgets.dart' show C2cCardTitle, C2cStepper;

class RiderLiveMapScreen extends ConsumerStatefulWidget {
  const RiderLiveMapScreen({super.key});

  @override
  ConsumerState<RiderLiveMapScreen> createState() => _RiderLiveMapScreenState();
}

class _RiderLiveMapScreenState extends ConsumerState<RiderLiveMapScreen> {
  /// The rule open (by region key; '' is Default's key prefix).
  String? _pick;

  /// Regions added here and not saved yet.
  final _added = <LiveMapRule>[];

  /// Changes not saved yet, by region key.
  final _drafts = <String, Map<String, dynamic>>{};

  Future<void> _addRegion(List<LiveMapRule> rules) async {
    final scope = await pickRegionScope(context, title: 'Region for its own live map rule');
    if (scope == null || scope.isAll || !mounted) return;
    final rule = LiveMapRule(country: scope.country, state: scope.state, city: scope.city, suburb: scope.suburb);
    final have = [...rules, ..._added].where((r) => r.key == rule.key).firstOrNull;
    setState(() {
      if (have == null) _added.add(rule);
      _pick = rule.key;
    });
  }

  Future<void> _save(LiveMapRule rule) async {
    final draft = _drafts[rule.key] ?? const {};
    final next = rule.copyWith({...rule.values, ...draft});
    final ok = await runAdminAction(
      context,
      () => ref.read(riderLiveMapRepositoryProvider).saveRule(next),
      success: 'Saved ${rule.label}',
    );
    if (ok && mounted) {
      setState(() {
        _drafts.remove(rule.key);
        _added.removeWhere((r) => r.key == rule.key);
      });
      ref.invalidate(liveMapRulesProvider);
    }
  }

  Future<void> _delete(LiveMapRule rule) async {
    if (rule.id == null) {
      setState(() {
        _added.removeWhere((r) => r.key == rule.key);
        _drafts.remove(rule.key);
        _pick = null;
      });
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(riderLiveMapRepositoryProvider).deleteRule(rule.id!),
      success: 'Removed ${rule.label}',
    );
    if (ok && mounted) {
      setState(() {
        _drafts.remove(rule.key);
        _pick = null;
      });
      ref.invalidate(liveMapRulesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(riderLiveMapPage)) == AccessLevel.edit;
    final async = ref.watch(liveMapRulesProvider);
    final t = Theme.of(context);
    final stored = async.value ?? const <LiveMapRule>[];
    final all = [
      if (!stored.any((r) => r.isDefault)) const LiveMapRule(),
      ...stored,
      for (final a in _added) if (!stored.any((r) => r.key == a.key)) a,
    ];
    final current = all.where((r) => r.key == _pick).firstOrNull ?? all.first;
    final draft = _drafts[current.key];
    return AdminPage(
      title: 'Rider live map',
      page: riderLiveMapPage,
      actions: [
        if (canEdit)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              key: const ValueKey('rlm-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: draft == null && current.id != null ? null : () => _save(current),
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Save'),
            ),
          ),
      ],
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(liveMapRulesProvider),
        data: (_) {
          final inherited = current.isDefault ? const <String, dynamic>{} : inheritedFor(stored, current);
          final values = {...inherited, ...current.values, ...?draft};
          void set(String key, Object? v) => setState(() {
            _drafts[current.key] = {...?_drafts[current.key], key: v};
          });
          void clear(List<String> keys) => setState(() {
            _drafts[current.key] = {...?_drafts[current.key], for (final k in keys) k: null};
          });
          _ModeCard card(_Mode m) => _ModeCard(
            key: ValueKey('rlm-card-${m.name}-${current.key}'),
            mode: m,
            values: values,
            own: {...current.values, ...?draft},
            regionRule: !current.isDefault,
            canEdit: canEdit,
            onSet: set,
            onFollow: () => clear(m.keys),
          );
          final regions = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('Region', style: t.textTheme.labelLarge),
            for (final r in all)
              ChoiceChip(
                key: ValueKey('rlm-region-${r.key}'),
                label: Text(r.label),
                selected: r.key == current.key,
                onSelected: (_) => setState(() => _pick = r.key),
              ),
            if (canEdit)
              ActionChip(
                key: const ValueKey('rlm-add-region'),
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Add region'),
                onPressed: () => _addRegion(all),
              ),
            if (canEdit && !current.isDefault)
              IconButton(
                key: const ValueKey('rlm-delete-region'),
                tooltip: 'Remove ${current.label}',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(current),
              ),
          ]);
          return LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 900;
            final cars = card(_Mode.cars), busy = card(_Mode.busy), people = card(_Mode.people), team = card(_Mode.team);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Text(
                  'What riders may see on the home map. Each region can have its own; a region not set uses Default.'
                  '${current.isDefault ? ' Every mode starts off.' : ' ${current.label} changes only what it sets.'}',
                  style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)),
                ),
                const SizedBox(height: 10),
                regions,
                const SizedBox(height: 12),
                if (wide)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Column(children: [cars, const SizedBox(height: 12), people])),
                    const SizedBox(width: 12),
                    Expanded(child: Column(children: [busy, const SizedBox(height: 12), team])),
                  ])
                else ...[cars, const SizedBox(height: 12), busy, const SizedBox(height: 12), people, const SizedBox(height: 12), team],
              ],
            );
          });
        },
      ),
    );
  }
}

enum _Mode {
  cars(Icons.directions_car_outlined, 'Cars near me', 'Free cars around the rider, as anonymous dots on the home map.',
      'cars', carsFieldNames, carsNeverShown, carsNumbers, null),
  busy(Icons.local_fire_department_outlined, 'Busy areas',
      'Where bookings are high now, as a honeycomb of coloured hexagons.', 'busy', busyFieldNames, busyNeverShown,
      busyNumbers, busyWho),
  people(Icons.family_restroom, 'My people',
      'Family members on a trip, through Family\'s location rule. They see "Shared with family" and can stop at once.',
      'people', peopleFieldNames, peopleNeverShown, peopleNumbers, peopleWho),
  team(Icons.business_center_outlined, 'Team',
      'Company-paid trips of the business account\'s staff, only while they run. Personal trips never show.', 'team',
      teamFieldNames, teamNeverShown, teamNumbers, teamWho);

  const _Mode(this.icon, this.title, this.about, this.prefix, this.fields, this.never, this.numbers, this.who);
  final IconData icon;
  final String title, about, prefix, never;
  final Map<String, String> fields;
  final List<RuleNumber> numbers;
  final Map<String, String>? who;

  List<String> get keys => [for (final k in ruleKeys) if (k.startsWith('${prefix}_')) k];
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    super.key,
    required this.mode,
    required this.values,
    required this.own,
    required this.regionRule,
    required this.canEdit,
    required this.onSet,
    required this.onFollow,
  });

  final _Mode mode;
  final Map<String, dynamic> values, own;
  final bool regionRule, canEdit;
  final void Function(String key, Object? value) onSet;
  final VoidCallback onFollow;

  bool _on(String k) => values[k] == true;
  int _n(String k, int fallback) => values[k] is num ? (values[k] as num).toInt() : fallback;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final p = mode.prefix;
    final fields = [for (final f in (values['${p}_fields'] is List ? values['${p}_fields'] as List : const [])) '$f'];
    final setHere = mode.keys.any((k) => own[k] != null);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 8), child: C2cCardTitle(mode.icon, mode.title))),
            if (mode != _Mode.cars)
              Switch(
                key: ValueKey('rlm-$p-on'),
                value: _on('${p}_on'),
                onChanged: canEdit ? (v) => onSet('${p}_on', v) : null,
              )
            else
              const SizedBox(height: 48),
          ]),
          Text(mode.about, style: t.textTheme.bodySmall?.copyWith(color: muted)),
          if (regionRule)
            Row(children: [
              Expanded(
                child: Text(
                  setHere ? 'Set for this region' : 'Follows the rule above',
                  style: t.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
              if (canEdit && setHere)
                TextButton(key: ValueKey('rlm-$p-follow'), onPressed: onFollow, child: const Text('Use the rule above')),
            ]),
          if (mode == _Mode.cars) ...[
            SwitchListTile(
              key: const ValueKey('rlm-cars-on'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('On in this region', style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
              subtitle: const Text('Every rider here sees the cars on the home map'),
              value: _on('cars_on'),
              onChanged: canEdit ? (v) => onSet('cars_on', v) : null,
            ),
            SwitchListTile(
              key: const ValueKey('rlm-cars-may-hide'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('Riders may hide it in Settings', style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
              subtitle: const Text('"Show cars near me on the map"'),
              value: _on('cars_may_hide'),
              onChanged: canEdit ? (v) => onSet('cars_may_hide', v) : null,
            ),
          ],
          if (mode.who case final who?) ...[
            const SizedBox(height: 8),
            Text('Who sees it', style: t.textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              key: ValueKey('rlm-$p-who'),
              segments: [for (final e in who.entries) ButtonSegment(value: e.key, label: Text(e.value))],
              selected: {'${values['${p}_who'] ?? who.keys.first}'},
              onSelectionChanged: canEdit ? (v) => onSet('${p}_who', v.first) : null,
            ),
          ],
          const SizedBox(height: 8),
          Text('Shown to them', style: t.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in mode.fields.entries)
              FilterChip(
                key: ValueKey('rlm-$p-field-${e.key}'),
                label: Text(e.value),
                selected: fields.contains(e.key),
                showCheckmark: false,
                onSelected: canEdit
                    ? (v) => onSet('${p}_fields', [
                        for (final k in mode.fields.keys)
                          if (k == e.key ? v : fields.contains(k)) k,
                      ])
                    : null,
              ),
            FilterChip(
              key: ValueKey('rlm-$p-never'),
              avatar: Icon(Icons.lock_outline, size: 16, color: muted),
              label: Text(mode.never),
              selected: false,
              onSelected: null,
            ),
          ]),
          const SizedBox(height: 6),
          for (final n in mode.numbers)
            C2cStepper(
              key: ValueKey('rlm-${n.key}'),
              label: n.label,
              hint: n.hint,
              value: n.show(_n(n.key, n.min)),
              valueKey: ValueKey('rlm-${n.key}-value'),
              onDown: canEdit && _n(n.key, n.min) > n.min ? () => onSet(n.key, n.down(_n(n.key, n.min))) : null,
              onUp: canEdit && _n(n.key, n.min) < n.max ? () => onSet(n.key, n.up(_n(n.key, n.min))) : null,
            ),
          if (mode == _Mode.busy)
            _ColourScaleRow(
              colours: [
                for (final c in (values['busy_colours'] is List ? values['busy_colours'] as List : const [])) ?hexColour('$c'),
              ],
              onChanged: canEdit ? (c) => onSet('busy_colours', [for (final x in c) colourHex(x)]) : null,
            ),
        ]),
      ),
    );
  }
}

class _ColourScaleRow extends StatelessWidget {
  const _ColourScaleRow({required this.colours, this.onChanged});
  final List<Color> colours;
  final ValueChanged<List<Color>>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final ramp = colours.length == 4 ? colours : defaultBusyColours;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Colour scale', style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
            Text('Pale yellow to deep red, see-through', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            key: const ValueKey('rlm-colour-scale'),
            width: 168,
            height: 28,
            child: CustomPaint(painter: _HexRampPainter(ramp)),
          ),
          const SizedBox(height: 2),
          SizedBox(
            width: 168,
            child: Row(children: [
              Text('Low', style: t.textTheme.labelSmall?.copyWith(color: muted)),
              const Spacer(),
              Text('Very high', style: t.textTheme.labelSmall?.copyWith(color: muted)),
            ]),
          ),
        ]),
        const SizedBox(width: 4),
        IconButton(
          key: const ValueKey('rlm-colours-edit'),
          tooltip: 'Change colours',
          onPressed: onChanged == null
              ? null
              : () async {
                  final next = await showAppDialog<List<Color>>(
                    id: 'admin.rider-live-map-colours',
                    context: context,
                    builder: (_) => _ColoursDialog(colours: ramp),
                  );
                  if (next != null) onChanged!(next);
                },
          icon: const Icon(Icons.edit_outlined),
        ),
      ]),
    );
  }
}

/// Six little hexagons along the scale, as the rider sees them.
class _HexRampPainter extends CustomPainter {
  _HexRampPainter(this.ramp);
  final List<Color> ramp;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 6;
    final w = size.width / n;
    final r = math.min(w / math.sqrt(3), size.height / 2) - 0.5;
    for (var i = 0; i < n; i++) {
      final c = Offset(w * (i + 0.5), size.height / 2);
      final path = ui.Path();
      for (var k = 0; k < 6; k++) {
        final a = (60 * k - 30) * math.pi / 180;
        final p = c + Offset(r * math.cos(a), r * math.sin(a));
        k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = rampAt(ramp, i / (n - 1)).withValues(alpha: 0.85));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HexRampPainter old) => old.ramp != ramp;
}

/// The four colours of the scale, low to very high, as #RRGGBB.
class _ColoursDialog extends StatefulWidget {
  const _ColoursDialog({required this.colours});
  final List<Color> colours;

  @override
  State<_ColoursDialog> createState() => _ColoursDialogState();
}

class _ColoursDialogState extends State<_ColoursDialog> {
  late final _fields = [for (final c in widget.colours) TextEditingController(text: colourHex(c))];
  static const _names = ['Low', 'Busy', 'Very busy', 'Very high'];

  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  List<Color>? get _result {
    final out = [for (final f in _fields) hexColour(f.text)];
    return out.any((c) => c == null) ? null : out.cast<Color>();
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return AlertDialog(
      title: const Text('Colour scale'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (i, f) in _fields.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: hexColour(f.text) ?? Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: ValueKey('rlm-colour-$i'),
                    controller: f,
                    decoration: InputDecoration(labelText: _names[i], hintText: '#FFEDA0'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ]),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () => setState(() {
            for (final (i, c) in defaultBusyColours.indexed) {
              _fields[i].text = colourHex(c);
            }
          }),
          child: const Text('Approved scale'),
        ),
        FilledButton(
          key: const ValueKey('rlm-colours-ok'),
          onPressed: r == null ? null : () => Navigator.pop(context, r),
          child: const Text('Use these'),
        ),
      ],
    );
  }
}
