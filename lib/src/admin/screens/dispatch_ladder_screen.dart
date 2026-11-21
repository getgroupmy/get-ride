// Admin → Dispatch ladder (migration 0417): per service type AND region
// (Country / State / City / Suburb, plus one master), the staged rings a new
// open request is pushed through — e.g. 2 km, then 5 km after a 5 s hold, then
// 10 km, then everybody. Scoped and resolved like the commission rate; with no
// ladder here the dispatch falls back to the service's min/max/widen config.
// The ladder drives BOTH the push notifications and when the offer appears on
// the driver's screen.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dispatch_ladder.dart';
import '../../data/app_display_repository.dart' show rideServicesProvider;
import '../../data/live_tables.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import 'geo/geo_data.dart' show regionsProvider;
import 'geo/geo_logic.dart' show RegionEntry, RegionLevel, regionNamesAt;

final dispatchLadderAdminProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('dispatch_ladder_rules');
  return ref.watch(adminRepositoryProvider).dispatchLadderRules();
});

const dispatchLadderLevels = ['master', 'country', 'state', 'city', 'suburb'];

const _allServices = '__all__';

String dispatchLadderLevelLabel(Object? level) => switch ('$level') {
      '' || 'null' => 'Unknown',
      final l => '${l[0].toUpperCase()}${l.substring(1)}',
    };

class AdminDispatchLadderScreen extends ConsumerWidget {
  const AdminDispatchLadderScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Map<String, dynamic>? row]) async {
    final result = await showAppDialog<Map<String, dynamic>>(
      id: 'dispatch-ladder.edit',
      context: context,
      builder: (_) => _LadderDialog(row: row),
    );
    if (result == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveDispatchLadderRule(result),
      success: 'Dispatch ladder saved',
    );
    if (ok) ref.invalidate(dispatchLadderAdminProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(moduleAccessProvider('dispatch-ladder')) == AccessLevel.edit;
    return AdminPage(
      title: 'Dispatch ladder',
      module: 'dispatch-ladder',
      body: AsyncView(
        value: ref.watch(dispatchLadderAdminProvider),
        onRetry: () => ref.invalidate(dispatchLadderAdminProvider),
        data: (rows) {
          final sorted = [...rows]
            ..sort((a, b) => dispatchLadderLevels
                .indexOf('${a['level']}')
                .compareTo(dispatchLadderLevels.indexOf('${b['level']}')));
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              clipBehavior: Clip.antiAlias,
              child: Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: const ExpansionTile(
                  key: ValueKey('dispatch-ladder-how'),
                  leading: Icon(Icons.info_outline),
                  title: Text('How the dispatch ladder works'),
                  childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'A new open ride request is offered to drivers in widening rings. Ring 1 goes out at once; '
                      'each ring then holds for its seconds before the next, larger ring is pushed. Turn on '
                      '"Then everybody" to reach every online driver after the last ring. For the pickup region '
                      'and service, the most specific active ladder wins: a service-specific row beats an '
                      'all-service one, and suburb > city > state > country > master (everywhere). With no '
                      'ladder here, dispatch uses the service\'s search-radius settings. The ladder drives both '
                      'the push notification and when the offer appears on the driver\'s screen. Changes apply '
                      'to new requests.',
                      key: ValueKey('dispatch-ladder-how-text'),
                    ),
                  ],
                ),
              ),
            ),
            if (canEdit)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('dispatch-ladder-add'),
                    onPressed: () => _edit(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Add ladder'),
                  ),
                ),
              ),
            if (sorted.isEmpty)
              const EmptyState(icon: Icons.wifi_tethering_outlined, title: 'No dispatch ladders yet'),
            for (final r in sorted)
              Card(
                child: BusyListTile(
                  leading: CircleAvatar(child: Text('${r['level']}'.substring(0, 1).toUpperCase())),
                  title: Text(
                    '${dispatchLadderServiceLabel(r)} · ${dispatchLadderRingsLabel(r)}',
                    key: ValueKey('dispatch-ladder-rings-${r['id']}'),
                    maxLines: 1,
                  ),
                  subtitle: Text([
                    dispatchLadderLevelLabel(r['level']),
                    dispatchLadderScopeLabel(r),
                    if (((r['priority'] as num?) ?? 0) != 0) 'Priority ${r['priority']}',
                    if ('${r['note'] ?? ''}'.trim().isNotEmpty) '${r['note']}'.trim(),
                  ].where((s) => s.trim().isNotEmpty).join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    _ActiveSwitch(key: ValueKey('dispatch-ladder-active-${r['id']}'), row: r, canEdit: canEdit),
                    if (canEdit)
                      BusyIconButton(
                        tooltip: 'Delete ladder',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (!await confirm(context, 'Delete ladder?', dispatchLadderScopeLabel(r), ok: 'Delete')) {
                            return;
                          }
                          if (!context.mounted) return;
                          if (await runAdminAction(context,
                              () => ref.read(adminRepositoryProvider).deleteDispatchLadderRule(r['id'] as String))) {
                            ref.invalidate(dispatchLadderAdminProvider);
                          }
                        },
                      ),
                  ]),
                  onTap: canEdit ? () => _edit(context, ref, r) : null,
                ),
              ),
          ]);
        },
      ),
    );
  }
}

/// The on/off switch on a ladder's row: saves the moment it moves and goes back
/// if the database refuses.
class _ActiveSwitch extends ConsumerStatefulWidget {
  const _ActiveSwitch({super.key, required this.row, required this.canEdit});
  final Map<String, dynamic> row;
  final bool canEdit;

  @override
  ConsumerState<_ActiveSwitch> createState() => _ActiveSwitchState();
}

class _ActiveSwitchState extends ConsumerState<_ActiveSwitch> {
  bool? _pending;

  Future<void> _set(bool v) async {
    setState(() => _pending = v);
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).setDispatchLadderRuleActive(widget.row['id'] as String, v),
      success: v ? 'Ladder turned on' : 'Ladder turned off',
    );
    if (ok) ref.invalidate(dispatchLadderAdminProvider);
    if (mounted) setState(() => _pending = null);
  }

  @override
  void didUpdateWidget(_ActiveSwitch old) {
    super.didUpdateWidget(old);
    if (old.row['active'] != widget.row['active']) _pending = null;
  }

  @override
  Widget build(BuildContext context) {
    final active = _pending ?? widget.row['active'] != false;
    return Tooltip(
      message: active ? 'Active' : 'Inactive',
      child: Switch(
        value: active,
        onChanged: widget.canEdit && _pending == null && widget.row['id'] != null ? _set : null,
      ),
    );
  }
}

class _LadderDialog extends ConsumerStatefulWidget {
  const _LadderDialog({this.row});
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_LadderDialog> createState() => _LadderDialogState();
}

class _RingField {
  _RingField(double radiusKm, int holdSec)
      : radius = TextEditingController(text: _plain(radiusKm)),
        hold = TextEditingController(text: holdSec.toString());
  final TextEditingController radius;
  final TextEditingController hold;
  void dispose() {
    radius.dispose();
    hold.dispose();
  }

  static String _plain(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

class _LadderDialogState extends ConsumerState<_LadderDialog> {
  late String _level = (widget.row?['level'] as String?) ?? 'country';
  late String _service = (widget.row?['service'] as String?)?.trim().isNotEmpty == true
      ? (widget.row!['service'] as String).trim()
      : _allServices;
  late bool _active = widget.row?['active'] != false;
  late bool _everyone = widget.row?['offer_everyone'] != false;
  late final _priority = TextEditingController(text: '${widget.row?['priority'] ?? 0}');
  late final _note = TextEditingController(text: widget.row?['note'] as String?);
  late final _fields = {
    for (final k in ['country', 'state', 'city', 'suburb'])
      k: TextEditingController(text: widget.row?[k] as String?),
  };
  late final List<_RingField> _rings = _initRings();
  String? _error;

  List<_RingField> _initRings() {
    final stored = parseLadderSteps(widget.row?['steps']);
    if (stored.isEmpty) return [_RingField(2, 5), _RingField(5, 5), _RingField(10, 0)];
    return [for (final s in stored) _RingField(s.radiusKm, s.holdSec)];
  }

  @override
  void dispose() {
    _priority.dispose();
    _note.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    for (final r in _rings) {
      r.dispose();
    }
    super.dispose();
  }

  void _addRing() {
    final last = _rings.isEmpty ? 5.0 : (double.tryParse(_rings.last.radius.text.trim()) ?? 5) * 2;
    setState(() => _rings.add(_RingField(last.clamp(0.5, 200).toDouble(), 5)));
  }

  void _removeRing(int i) {
    final r = _rings.removeAt(i);
    r.dispose();
    setState(() {});
  }

  void _save() {
    final steps = <LadderStep>[];
    for (final r in _rings) {
      final radius = double.tryParse(r.radius.text.trim());
      final hold = int.tryParse(r.hold.text.trim().isEmpty ? '0' : r.hold.text.trim());
      if (radius == null || radius <= 0 || radius > 200) {
        setState(() => _error = 'Each ring radius must be between 0.5 and 200 km.');
        return;
      }
      if (hold == null || hold < 0 || hold > 3600) {
        setState(() => _error = 'Each hold must be a whole number of seconds, 0–3600.');
        return;
      }
      steps.add((radiusKm: radius, holdSec: hold));
    }
    if (steps.isEmpty) {
      setState(() => _error = 'Add at least one ring.');
      return;
    }
    for (final k in dispatchLadderRequiredScope(_level)) {
      if (_fields[k]!.text.trim().isEmpty) {
        setState(() => _error = 'Enter the $k.');
        return;
      }
    }
    final priority = int.tryParse(_priority.text.trim());
    if (priority == null) {
      setState(() => _error = 'Priority must be a whole number (0 when unsure).');
      return;
    }
    final needed = dispatchLadderRequiredScope(_level).toSet();
    Navigator.pop(context, {
      'id': widget.row?['id'],
      'level': _level,
      'service': _service == _allServices ? null : _service,
      'steps': ladderStepsToJson(steps),
      'offer_everyone': _everyone,
      'active': _active,
      'priority': priority,
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      for (final k in ['country', 'state', 'city', 'suburb'])
        k: needed.contains(k) ? _fields[k]!.text.trim() : null,
    });
  }

  Widget _place(String k, List<RegionEntry> regions) {
    const levels = {
      'country': RegionLevel.country,
      'state': RegionLevel.state,
      'city': RegionLevel.city,
      'suburb': RegionLevel.suburb,
    };
    final title = k[0].toUpperCase() + k.substring(1);
    final options = regionNamesAt(
      regions,
      levels[k]!,
      country: _fields['country']!.text,
      state: _fields['state']!.text,
      city: _fields['city']!.text,
    );
    final value = _fields[k]!.text.trim();
    if (options.isEmpty) {
      return TextField(
        key: ValueKey('dispatch-ladder-$k'),
        controller: _fields[k],
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: title,
          helperText: 'Not on Country / States / Cities yet',
          helperMaxLines: 2,
        ),
      );
    }
    final all = [...options, if (value.isNotEmpty && !options.any((o) => o.toLowerCase() == value.toLowerCase())) value];
    final selected = all.where((o) => o.toLowerCase() == value.toLowerCase()).firstOrNull;
    return SearchableDropdownFormField<String>(
      key: ValueKey('dispatch-ladder-$k-${_fields['country']!.text}/${_fields['state']!.text}/${_fields['city']!.text}'),
      isExpanded: true,
      initialValue: selected,
      decoration: InputDecoration(labelText: title),
      hint: Text('Choose a $k'),
      items: [for (final o in all) DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis))],
      onChanged: (v) => setState(() {
        _fields[k]!.text = v ?? '';
        const order = ['country', 'state', 'city', 'suburb'];
        for (final below in order.skip(order.indexOf(k) + 1)) {
          _fields[below]!.clear();
        }
      }),
    );
  }

  Widget _ringRow(int i) {
    final r = _rings[i];
    return Padding(
      key: ValueKey('dispatch-ladder-ring-$i'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(width: 28, child: Text('${i + 1}', style: Theme.of(context).textTheme.bodySmall)),
        Expanded(
          child: TextField(
            controller: r.radius,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Radius', suffixText: 'km', isDense: true),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: r.hold,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: i == _rings.length - 1 ? 'Then wait' : 'Hold',
              suffixText: 's',
              isDense: true,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Remove ring',
          icon: const Icon(Icons.close),
          onPressed: _rings.length > 1 ? () => _removeRing(i) : null,
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final needed = dispatchLadderRequiredScope(_level);
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final services = ref.watch(rideServicesProvider).value ?? const [];
    final serviceNames = {for (final s in services) s.name}.toList()..sort();
    if (_service != _allServices && !serviceNames.contains(_service)) serviceNames.add(_service);
    return AlertDialog(
      title: Text(widget.row == null ? 'Add dispatch ladder' : 'Edit dispatch ladder'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            SearchableDropdownFormField<String>(
              key: const ValueKey('dispatch-ladder-service'),
              isExpanded: true,
              initialValue: _service,
              decoration: const InputDecoration(labelText: 'Service'),
              items: [
                const DropdownMenuItem(value: _allServices, child: Text('All services')),
                for (final s in serviceNames) DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _service = v ?? _allServices),
            ),
            const SizedBox(height: 12),
            SearchableDropdownFormField<String>(
              key: const ValueKey('dispatch-ladder-level'),
              isExpanded: true,
              initialValue: _level,
              decoration: const InputDecoration(labelText: 'Region level'),
              items: [
                for (final l in dispatchLadderLevels)
                  DropdownMenuItem(value: l, child: Text(l == 'master' ? 'Everywhere' : dispatchLadderLevelLabel(l)))
              ],
              onChanged: (v) => setState(() => _level = v ?? _level),
            ),
            for (final k in needed) ...[
              const SizedBox(height: 12),
              _place(k, regions),
            ],
            const SizedBox(height: 16),
            Text('Rings', style: Theme.of(context).textTheme.titleSmall),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Ring 1 is pushed at once. Each hold is how long to wait before the next, wider ring.',
                key: ValueKey('dispatch-ladder-rings-help'),
              ),
            ),
            for (var i = 0; i < _rings.length; i++) _ringRow(i),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('dispatch-ladder-add-ring'),
                onPressed: _rings.length < 8 ? _addRing : null,
                icon: const Icon(Icons.add),
                label: const Text('Add ring'),
              ),
            ),
            SwitchListTile(
              key: const ValueKey('dispatch-ladder-everyone'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Then everybody'),
              subtitle: const Text('After the last ring, offer to every online driver'),
              value: _everyone,
              onChanged: (v) => setState(() => _everyone = v),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('dispatch-ladder-priority'),
              textInputAction: TextInputAction.next,
              controller: _priority,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(
                labelText: 'Priority',
                helperText: 'Higher wins between ladders at the same level',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('dispatch-ladder-note'),
              controller: _note,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('dispatch-ladder-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
