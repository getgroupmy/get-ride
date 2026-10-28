// Admin › People › Family (migration 0317): the Default rule and per-place
// rules (country, state, city, suburb: the smallest place that sets a value
// wins, a place overrides only what it sets), every value editable, and the
// Modules and Family matrix, which lists every registered booking module,
// a new one switched off until its boxes are turned on.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/booking_modules.dart' show bookingModule;
import '../../../core/family.dart';
import '../../../core/format.dart' show formatMoney;
import '../../../data/family_repository.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';

const _familyListPath = '/admin/m/family-list';

class FamilySettingsScreen extends ConsumerStatefulWidget {
  const FamilySettingsScreen({super.key});

  @override
  ConsumerState<FamilySettingsScreen> createState() => _FamilySettingsScreenState();
}

class _FamilySettingsScreenState extends ConsumerState<FamilySettingsScreen> {
  /// The place being edited ('' Default).
  String _place = '';

  /// Edits not saved yet, by place key.
  final _drafts = <String, Map<String, dynamic>>{};

  Future<void> _addPlace() async {
    final p = await showAppDialog<FamilyPlace>(id: 'admin.family-place', context: context, builder: (_) => const _AddPlaceDialog());
    if (p == null || !mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(familyRepositoryProvider).savePlace(FamilyPlaceRules(place: p)),
      success: 'Added ${p.label}',
    );
    if (ok && mounted) {
      ref.invalidate(familyPlacesProvider);
      setState(() => _place = p.key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(familyAdminPage)) == AccessLevel.edit;
    final places = ref.watch(familyPlacesProvider);
    return AdminPage(
      title: 'Family',
      page: familyAdminPage,
      actions: [
        IconButton(
          key: const ValueKey('family-admin-open-list'),
          tooltip: 'Families, requests and the log',
          icon: const Icon(Icons.groups_outlined),
          onPressed: () => context.push(_familyListPath),
        ),
      ],
      body: AsyncView(
        value: places,
        onRetry: () => ref.invalidate(familyPlacesProvider),
        data: (rows) {
          final all = rows.isEmpty ? [const FamilyPlaceRules(place: FamilyPlace())] : rows;
          final current = all.where((r) => r.place.key == _place).firstOrNull ?? all.first;
          final values = _ValuesCard(
            key: ValueKey('family-values-${current.place.key}'),
            row: current,
            defaults: all.firstWhere((r) => r.place.isDefault, orElse: () => all.first),
            draft: _drafts[current.place.key],
            canEdit: canEdit,
            onDraft: (d) => setState(() => d == null ? _drafts.remove(current.place.key) : _drafts[current.place.key] = d),
          );
          final matrix = _MatrixCard(place: current.place, canEdit: canEdit);
          final placePicker = Row(children: [
            Expanded(
              child: SearchableDropdownFormField<String>(
                key: const ValueKey('family-admin-place'),
                initialValue: current.place.key,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Rule for'),
                items: [for (final r in all) DropdownMenuItem(value: r.place.key, child: Text(r.place.label))],
                onChanged: (v) => setState(() => _place = v ?? ''),
              ),
            ),
            if (canEdit) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                key: const ValueKey('family-admin-add-place'),
                onPressed: _addPlace,
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const Text('Add a place'),
              ),
              if (!current.place.isDefault)
                IconButton(
                  tooltip: 'Remove this place',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final ok = await runAdminAction(
                      context,
                      () => ref.read(familyRepositoryProvider).deletePlace(current.id!),
                      success: 'Removed ${current.place.label}',
                    );
                    if (ok && mounted) {
                      ref.invalidate(familyPlacesProvider);
                      setState(() => _place = '');
                    }
                  },
                ),
            ],
          ]);
          return LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 900;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(
                      'Default rule and per-place rules (the host\'s region). Every value editable; a place sets only '
                      'what it changes.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    placePicker,
                    const SizedBox(height: 8),
                    if (wide)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: Column(children: [values, const _GodViewCard()])),
                        const SizedBox(width: 16),
                        Expanded(child: matrix),
                      ])
                    else ...[values, matrix, const _GodViewCard()],
                  ]),
                ),
              ),
            );
          });
        },
      ),
    );
  }
}

String _fmt(String key, num v) => switch (key) {
  'inviteDays' => '$v days',
  'aloneAge' => '$v years',
  'monthCap' => formatMoney(v),
  _ => '$v',
};

/// The values of one place: steppers, switches, the location rule and the
/// per-trip limit choices. On a place other than Default each value is
/// "Set here" or uses the place above.
class _ValuesCard extends ConsumerWidget {
  const _ValuesCard({
    super.key,
    required this.row,
    required this.defaults,
    required this.draft,
    required this.canEdit,
    required this.onDraft,
  });
  final FamilyPlaceRules row;
  final FamilyPlaceRules defaults;
  final Map<String, dynamic>? draft;
  final bool canEdit;
  final ValueChanged<Map<String, dynamic>?> onDraft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final rules = draft ?? row.rules;
    final shown = {...const FamilySettings().toJson(), ...defaults.rules, ...rules};
    final isDefault = row.place.isDefault;
    void set(String k, Object? v) {
      final next = {...rules};
      v == null ? next.remove(k) : next[k] = v;
      onDraft(next);
    }

    Widget inherit(String k) => isDefault
        ? const SizedBox.shrink()
        : Checkbox(
            key: ValueKey('family-set-$k'),
            value: rules.containsKey(k),
            onChanged: canEdit ? (v) => set(k, v == true ? shown[k] : null) : null,
          );

    final problem = familyRulesProblem(rules);
    final changed = draft != null && draft.toString() != row.rules.toString();
    return Card(
      key: const ValueKey('family-values'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Family · ${row.place.label}', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (!isDefault)
            Text('Ticked: set here. Unticked: as the place above.', style: t.textTheme.bodySmall),
          for (final k in ['enabled', 'children', 'womenDriversForChildren'])
            Row(children: [
              inherit(k),
              Expanded(
                child: SwitchListTile(
                  key: ValueKey('family-switch-$k'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(FamilySettings.labels[k]!),
                  value: shown[k] == true,
                  onChanged: canEdit && (isDefault || rules.containsKey(k)) ? (v) => set(k, v) : null,
                ),
              ),
            ]),
          for (final e in FamilySettings.limits.entries)
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(children: [
                inherit(e.key),
                Expanded(child: Text(FamilySettings.labels[e.key]!, style: t.textTheme.bodyMedium)),
                IconButton(
                  key: ValueKey('family-down-${e.key}'),
                  tooltip: 'Lower',
                  onPressed: canEdit && (isDefault || rules.containsKey(e.key)) && (shown[e.key] as num) - e.value.$3 >= e.value.$1
                      ? () => set(e.key, (shown[e.key] as num) - e.value.$3)
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                SizedBox(
                  width: 96,
                  child: Text(_fmt(e.key, shown[e.key] as num),
                      key: ValueKey('family-value-${e.key}'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  key: ValueKey('family-up-${e.key}'),
                  tooltip: 'Raise',
                  onPressed: canEdit && (isDefault || rules.containsKey(e.key)) && (shown[e.key] as num) + e.value.$3 <= e.value.$2
                      ? () => set(e.key, (shown[e.key] as num) + e.value.$3)
                      : null,
                  icon: const Icon(Icons.add),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          Row(children: [
            inherit('perRideChoices'),
            Expanded(child: Text(FamilySettings.labels['perRideChoices']!, style: t.textTheme.titleSmall)),
          ]),
          _ChoicesEditor(
            values: [for (final v in (shown['perRideChoices'] as List)) (v as num).toDouble()],
            enabled: canEdit && (isDefault || rules.containsKey('perRideChoices')),
            onChanged: (l) => set('perRideChoices', l),
          ),
          const SizedBox(height: 10),
          Row(children: [
            inherit('locationRule'),
            Expanded(child: Text(FamilySettings.labels['locationRule']!, style: t.textTheme.titleSmall)),
          ]),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            key: const ValueKey('family-location-rule'),
            segments: [for (final r in FamilyLocationRule.values) ButtonSegment(value: r.db, label: Text(r.label))],
            selected: {'${shown['locationRule']}'},
            onSelectionChanged: canEdit && (isDefault || rules.containsKey('locationRule'))
                ? (s) => set('locationRule', s.first)
                : null,
          ),
          const SizedBox(height: 4),
          Text(
            'Whatever is chosen, the member is told before joining, sees "Shared with family" while it\'s on, sees who '
            'can see them, and can leave at once. There is no hidden viewing.',
            style: t.textTheme.bodySmall,
          ),
          if (canEdit) ...[
            const SizedBox(height: 10),
            if (problem != null) Text(problem, style: TextStyle(color: t.colorScheme.error)),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (changed) TextButton(onPressed: () => onDraft(null), child: const Text('Undo')),
              Flexible(child: BusyButton.filled(
                key: const ValueKey('family-values-save'),
                onPressed: changed && problem == null
                    ? () async {
                        final ok = await runAdminAction(
                          context,
                          () => ref.read(familyRepositoryProvider).savePlace(
                              FamilyPlaceRules(id: row.id, place: row.place, rules: rules)),
                          success: 'Family values saved for ${row.place.label}',
                        );
                        if (ok) {
                          onDraft(null);
                          ref.invalidate(familyPlacesProvider);
                        }
                      }
                    : null,
                child: const Text('Save'),
              )),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// The per-trip limits a host picks from: chips, with add and remove.
class _ChoicesEditor extends StatefulWidget {
  const _ChoicesEditor({required this.values, required this.enabled, required this.onChanged});
  final List<double> values;
  final bool enabled;
  final ValueChanged<List<double>> onChanged;

  @override
  State<_ChoicesEditor> createState() => _ChoicesEditorState();
}

class _ChoicesEditorState extends State<_ChoicesEditor> {
  final _add = TextEditingController();

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = [...widget.values]..sort();
    return Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final x in v)
        InputChip(
          key: ValueKey('family-choice-${x.toStringAsFixed(0)}'),
          label: Text(formatMoney(x)),
          onDeleted: widget.enabled ? () => widget.onChanged([...v]..remove(x)) : null,
        ),
      if (widget.enabled && v.length < 10)
        SizedBox(
          width: 140,
          child: TextField(
            key: const ValueKey('family-choice-add'),
            controller: _add,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Add RM', isDense: true),
            onSubmitted: (s) {
              final n = double.tryParse(s.trim());
              if (n == null || n < 1 || n > 100000 || v.contains(n)) return;
              _add.clear();
              widget.onChanged([...v, n]..sort());
            },
          ),
        ),
    ]);
  }
}

/// The Modules and Family matrix at a place: every registered module, its
/// four switches. Default: on or off; a place: set here (on or off) or as
/// the place above.
class _MatrixCard extends ConsumerWidget {
  const _MatrixCard({required this.place, required this.canEdit});
  final FamilyPlace place;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final modules = ref.watch(familyRegisteredModulesProvider);
    final rules = ref.watch(familyModuleRulesProvider);
    return Card(
      key: const ValueKey('family-matrix'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Modules and Family', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          Text(
            'Every booking module is listed here, today\'s and any added later. A new module appears automatically, '
            'switched off, until you turn its boxes on.${place.isDefault ? '' : ' A dash: as the place above.'}',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: modules,
            onRetry: () => ref.invalidate(familyRegisteredModulesProvider),
            data: (mods) {
              final rows = rules.value ?? const <FamilyModuleRule>[];
              Widget head(String s) => Expanded(
                child: Text(s, textAlign: TextAlign.center, style: t.textTheme.labelSmall),
              );
              return Column(children: [
                Row(children: [
                  const Expanded(flex: 2, child: Text('Module')),
                  for (final n in FamilyModuleSwitches.names) head(n),
                ]),
                for (final m in mods)
                  Builder(builder: (context) {
                    final own = rows.where((r) => r.moduleKey == m.key && r.place.key == place.key).firstOrNull ??
                        FamilyModuleRule(place: place, moduleKey: m.key);
                    final known = bookingModule(m.key);
                    // GET.Plus (0323): only "Family pays" means something.
                    final payOnly = known?.familyPaysOnly ?? false;
                    return Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.dividerColor))),
                      child: Row(children: [
                        Expanded(
                          flex: 2,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(m.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                            if (known?.note case final note?)
                              Text(note, key: ValueKey('family-matrix-${m.key}-note'), style: t.textTheme.bodySmall),
                          ]),
                        ),
                        for (var i = 0; i < 4; i++)
                          if (payOnly && i > 0)
                            Expanded(
                              child: Text('–', key: ValueKey('family-matrix-${m.key}-$i'), textAlign: TextAlign.center,
                                  semanticsLabel: '${m.name}: ${FamilyModuleSwitches.names[i]} does not apply'),
                            )
                          else
                          Expanded(
                            child: Checkbox(
                              key: ValueKey('family-matrix-${m.key}-$i'),
                              tristate: !place.isDefault,
                              value: place.isDefault ? (own.list[i] ?? false) : own.list[i],
                              semanticLabel: '${m.name}: ${FamilyModuleSwitches.names[i]}',
                              onChanged: canEdit
                                  ? (_) async {
                                      // Default: off, on. A place: as above (null), on, off.
                                      final cur = own.list[i];
                                      final next = place.isDefault
                                          ? !(cur ?? false)
                                          : (cur == null ? true : (cur ? false : null));
                                      final ok = await runAdminAction(
                                        context,
                                        () => ref.read(familyRepositoryProvider).saveModuleRule(own.withSwitch(i, next)),
                                      );
                                      if (ok) ref.invalidate(familyModuleRulesProvider);
                                    }
                                  : null,
                            ),
                          ),
                      ]),
                    );
                  }),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

class _GodViewCard extends StatelessWidget {
  const _GodViewCard();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('family-godview-card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('God View access to family members', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text(
            'Admins open a family only with a reason (report, SOS, legal request). Every look is logged with who, when '
            'and why; the member can read their log.',
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => context.push(_familyListPath),
              child: const Text('Families and the log'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _AddPlaceDialog extends StatefulWidget {
  const _AddPlaceDialog();

  @override
  State<_AddPlaceDialog> createState() => _AddPlaceDialogState();
}

class _AddPlaceDialogState extends State<_AddPlaceDialog> {
  String _level = 'country';
  final _names = {for (final l in ['country', 'state', 'city', 'suburb']) l: TextEditingController()};

  static const _levels = ['country', 'state', 'city', 'suburb'];
  List<String> get _named => _levels.sublist(0, _levels.indexOf(_level) + 1);

  @override
  void dispose() {
    for (final c in _names.values) {
      c.dispose();
    }
    super.dispose();
  }

  FamilyPlace? get _result {
    if (_named.any((l) => _names[l]!.text.trim().isEmpty)) return null;
    String? n(String l) => _named.contains(l) ? _names[l]!.text.trim() : null;
    return FamilyPlace(level: _level, country: n('country'), state: n('state'), city: n('city'), suburb: n('suburb'));
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return AlertDialog(
      title: const Text('Add a place'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SearchableDropdownFormField<String>(
              key: const ValueKey('family-place-level'),
              initialValue: _level,
              decoration: const InputDecoration(labelText: 'Place'),
              items: const [
                DropdownMenuItem(value: 'country', child: Text('Country')),
                DropdownMenuItem(value: 'state', child: Text('State')),
                DropdownMenuItem(value: 'city', child: Text('City')),
                DropdownMenuItem(value: 'suburb', child: Text('Suburb')),
              ],
              onChanged: (v) => setState(() => _level = v ?? _level),
            ),
            for (final l in _named)
              TextField(
                key: ValueKey('family-place-$l'),
                controller: _names[l],
                decoration: InputDecoration(
                  labelText: '${l[0].toUpperCase()}${l.substring(1)}',
                  helperText: l == _named.first ? 'As the Country / States / Cities tables name it' : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('family-place-save'),
          onPressed: r == null ? null : () => Navigator.pop(context, r),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
