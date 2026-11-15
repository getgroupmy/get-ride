// Admin → Ride display: region switches (migration 0411). Per Country / State
// / City / Suburb (and one master default), an admin turns off the AI fare
// (its pricing and badge) and/or the "12 km · 24 min" distance·time line on the
// ride home. Scoped and resolved exactly like the commission rate.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ride_display_rules.dart';
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

final rideDisplayRulesAdminProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('ride_display_rules');
  return ref.watch(adminRepositoryProvider).rideDisplayRules();
});

const rideDisplayLevels = ['master', 'country', 'state', 'city', 'suburb'];

String rideDisplayLevelLabel(Object? level) => switch ('$level') {
      '' || 'null' => 'Unknown',
      final l => '${l[0].toUpperCase()}${l.substring(1)}',
    };

/// What a rule turns off, in words: "AI fare + Distance & time", "AI fare",
/// "Distance & time", or "Nothing (shows all)".
String rideDisplayEffectLabel(Map<String, dynamic> r) {
  final parts = [
    if (r['ai_fare_off'] == true) 'AI fare',
    if (r['distance_time_off'] == true) 'Distance & time',
  ];
  return parts.isEmpty ? 'Nothing off (shows all)' : '${parts.join(' + ')} off';
}

class AdminRideDisplayScreen extends ConsumerWidget {
  const AdminRideDisplayScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Map<String, dynamic>? row]) async {
    final result = await showAppDialog<Map<String, dynamic>>(
      id: 'ride-display.edit',
      context: context,
      builder: (_) => _RuleDialog(row: row),
    );
    if (result == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(adminRepositoryProvider).saveRideDisplayRule(result),
      success: 'Rule saved',
    );
    if (ok) ref.invalidate(rideDisplayRulesAdminProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(moduleAccessProvider('ride-display')) == AccessLevel.edit;
    return AdminPage(
      title: 'Ride display',
      module: 'ride-display',
      body: AsyncView(
        value: ref.watch(rideDisplayRulesAdminProvider),
        onRetry: () => ref.invalidate(rideDisplayRulesAdminProvider),
        data: (rows) {
          final sorted = [...rows]
            ..sort((a, b) =>
                rideDisplayLevels.indexOf('${a['level']}').compareTo(rideDisplayLevels.indexOf('${b['level']}')));
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              clipBehavior: Clip.antiAlias,
              child: Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: const ExpansionTile(
                  key: ValueKey('ride-display-how'),
                  leading: Icon(Icons.info_outline),
                  title: Text('How these switches work'),
                  childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'For the pickup region, the most specific active rule wins: suburb > city > state > '
                      'country > master. Turn off the AI fare to price rides on the plain route and hide the '
                      '"AI" estimate badge; turn off distance & time to hide the "12 km · 24 min" line. '
                      'With no rule, both show, as before. Changes apply live on riders\' phones.',
                      key: ValueKey('ride-display-how-text'),
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
                    key: const ValueKey('ride-display-add'),
                    onPressed: () => _edit(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Add rule'),
                  ),
                ),
              ),
            if (sorted.isEmpty) const EmptyState(icon: Icons.visibility_off_outlined, title: 'No region rules yet'),
            for (final r in sorted)
              Card(
                child: BusyListTile(
                  leading: CircleAvatar(child: Text('${r['level']}'.substring(0, 1).toUpperCase())),
                  title: Text(rideDisplayEffectLabel(r),
                      key: ValueKey('ride-display-effect-${r['id']}'), maxLines: 1),
                  subtitle: Text([
                    rideDisplayLevelLabel(r['level']),
                    rideDisplayScopeLabel(r),
                    if (((r['priority'] as num?) ?? 0) != 0) 'Priority ${r['priority']}',
                    if ('${r['note'] ?? ''}'.trim().isNotEmpty) '${r['note']}'.trim(),
                  ].where((s) => s.trim().isNotEmpty).join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    _ActiveSwitch(key: ValueKey('ride-display-active-${r['id']}'), row: r, canEdit: canEdit),
                    if (canEdit)
                      BusyIconButton(
                        tooltip: 'Delete rule',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (!await confirm(context, 'Delete rule?', rideDisplayScopeLabel(r), ok: 'Delete')) return;
                          if (!context.mounted) return;
                          if (await runAdminAction(
                              context, () => ref.read(adminRepositoryProvider).deleteRideDisplayRule(r['id'] as String))) {
                            ref.invalidate(rideDisplayRulesAdminProvider);
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

/// The on/off switch on a rule's row: saves the moment it moves and goes back
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
      () => ref.read(adminRepositoryProvider).setRideDisplayRuleActive(widget.row['id'] as String, v),
      success: v ? 'Rule turned on' : 'Rule turned off',
    );
    if (ok) ref.invalidate(rideDisplayRulesAdminProvider);
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

class _RuleDialog extends ConsumerStatefulWidget {
  const _RuleDialog({this.row});
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends ConsumerState<_RuleDialog> {
  late String _level = (widget.row?['level'] as String?) ?? 'country';
  late bool _active = widget.row?['active'] != false;
  late bool _aiOff = widget.row?['ai_fare_off'] == true;
  late bool _distOff = widget.row?['distance_time_off'] == true;
  late final _priority = TextEditingController(text: '${widget.row?['priority'] ?? 0}');
  late final _note = TextEditingController(text: widget.row?['note'] as String?);
  late final _fields = {
    for (final k in ['country', 'state', 'city', 'suburb'])
      k: TextEditingController(text: widget.row?[k] as String?),
  };
  String? _error;

  @override
  void dispose() {
    _priority.dispose();
    _note.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_aiOff && !_distOff) {
      setState(() => _error = 'Turn off at least one of AI fare or distance & time.');
      return;
    }
    for (final k in rideDisplayRequiredScope(_level)) {
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
    final needed = rideDisplayRequiredScope(_level).toSet();
    Navigator.pop(context, {
      'id': widget.row?['id'],
      'level': _level,
      'ai_fare_off': _aiOff,
      'distance_time_off': _distOff,
      'active': _active,
      'priority': priority,
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      for (final k in ['country', 'state', 'city', 'suburb'])
        k: needed.contains(k) ? _fields[k]!.text.trim() : null,
    });
  }

  /// A place field: picked from Admin → Country / States / Cities, typed where
  /// that level has none (mirrors the commission dialog's `_place`).
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
        key: ValueKey('ride-display-$k'),
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
      key: ValueKey('ride-display-$k-${_fields['country']!.text}/${_fields['state']!.text}/${_fields['city']!.text}'),
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

  @override
  Widget build(BuildContext context) {
    final needed = rideDisplayRequiredScope(_level);
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    return AlertDialog(
      title: Text(widget.row == null ? 'Add region rule' : 'Edit region rule'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SearchableDropdownFormField<String>(
              key: const ValueKey('ride-display-level'),
              isExpanded: true,
              initialValue: _level,
              decoration: const InputDecoration(labelText: 'Level'),
              items: [
                for (final l in rideDisplayLevels) DropdownMenuItem(value: l, child: Text(rideDisplayLevelLabel(l)))
              ],
              onChanged: (v) => setState(() => _level = v ?? _level),
            ),
            for (final k in needed) ...[
              const SizedBox(height: 12),
              _place(k, regions),
            ],
            const SizedBox(height: 4),
            SwitchListTile(
              key: const ValueKey('ride-display-ai-off'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Turn off AI fare'),
              subtitle: const Text('Price on the plain route and hide the AI badge'),
              value: _aiOff,
              onChanged: (v) => setState(() => _aiOff = v),
            ),
            SwitchListTile(
              key: const ValueKey('ride-display-distance-off'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Turn off distance & time'),
              subtitle: const Text('Hide the "12 km · 24 min" line'),
              value: _distOff,
              onChanged: (v) => setState(() => _distOff = v),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('ride-display-priority'),
              textInputAction: TextInputAction.next,
              controller: _priority,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(
                labelText: 'Priority',
                helperText: 'Higher wins between rules at the same level',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('ride-display-note'),
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
          key: const ValueKey('ride-display-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
