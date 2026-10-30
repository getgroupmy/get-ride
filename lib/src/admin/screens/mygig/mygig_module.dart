// Admin › Operations › myGiG (migration 0329), page id admin-mygig
// (grantable to sub-admins): the settings (a Default rule and rules per
// country, state, city or suburb, each part set or left to the place above),
// who may use myGiG and what drivers are charged (all, selected, nobody; a
// driver's own access and charge), and the places where myGiG isn't allowed
// (per fenced place of the place fees list). Changes work in the driver
// screens straight away (live tables).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/mygig.dart';
import '../../../core/partner_type_rules.dart' show RegionScope;
import '../../../data/live_tables.dart';
import '../../../data/mygig_repository.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../admin_registry.dart' show AdminScreenEntry;
import '../../widgets/admin_widgets.dart';
import '../../widgets/region_scope_picker.dart' show pickRegionScope;

const mygigSettingsAdminPath = '/admin/m/mygig';
const mygigAccessAdminPath = '/admin/m/mygig-access';
const mygigPlacesAdminPath = '/admin/m/mygig-places';

final mygigAdminRoutes = <RouteBase>[
  GoRoute(path: mygigSettingsAdminPath, builder: (_, _) => const MygigSettingsAdminScreen()),
  GoRoute(path: mygigAccessAdminPath, builder: (_, _) => const MygigAccessAdminScreen()),
  GoRoute(path: mygigPlacesAdminPath, builder: (_, _) => const MygigPlacesAdminScreen()),
];

const mygigAdminEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Operations',
    title: 'myGiG settings',
    subtitle: 'Street hail for drivers who aren\'t TEKSI: fare, luggage, waiting, fees, limits and the price guard by region',
    path: mygigSettingsAdminPath,
    pages: [mygigAdminPage],
    icon: Icons.hail,
  ),
  AdminScreenEntry(
    section: 'Operations',
    title: 'myGiG access',
    subtitle: 'Who may use myGiG, the charge to drivers, and each driver\'s own',
    path: mygigAccessAdminPath,
    pages: [mygigAdminPage],
    icon: Icons.verified_user_outlined,
  ),
  AdminScreenEntry(
    section: 'Operations',
    title: 'Places where myGiG isn\'t allowed',
    subtitle: 'No pickups, no drop-offs or neither, per fenced place',
    path: mygigPlacesAdminPath,
    pages: [mygigAdminPage],
    icon: Icons.block,
  ),
];

final _mygigRulesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  ref.watchLive(mygigRulesTable);
  return ref.watch(mygigRepositoryProvider).rules();
});

/// A rule as the editor holds it.
class _Rule {
  _Rule({this.id, required this.level, required this.scope, required this.settings});
  final String? id;
  final String level;
  final RegionScope scope;
  Map<String, dynamic> settings;

  bool get isDefault => level == 'default';
}

String _levelOf(RegionScope s) => s.suburb.isNotEmpty
    ? 'suburb'
    : s.city.isNotEmpty
        ? 'city'
        : s.state.isNotEmpty
            ? 'state'
            : 'country';

class MygigSettingsAdminScreen extends ConsumerStatefulWidget {
  const MygigSettingsAdminScreen({super.key});

  @override
  ConsumerState<MygigSettingsAdminScreen> createState() => _MygigSettingsAdminScreenState();
}

class _MygigSettingsAdminScreenState extends ConsumerState<MygigSettingsAdminScreen> {
  List<_Rule>? _rules;
  final _removed = <String>{};
  bool _dirty = false;

  void _load(List<Map<String, dynamic>> rows) {
    _rules = [
      for (final r in rows)
        _Rule(
          id: '${r['id']}',
          level: '${r['level']}',
          scope: RegionScope(
            country: '${r['country'] ?? ''}',
            state: '${r['state'] ?? ''}',
            city: '${r['city'] ?? ''}',
            suburb: '${r['suburb'] ?? ''}',
          ),
          settings: r['settings'] is Map ? Map<String, dynamic>.from(r['settings'] as Map) : {},
        ),
    ]..sort((a, b) => a.isDefault ? -1 : b.isDefault ? 1 : a.scope.label.compareTo(b.scope.label));
  }

  Map<String, dynamic> get _default => _rules!.firstWhere((r) => r.isDefault, orElse: () => _rules!.first).settings;

  Future<void> _add() async {
    final scope = await pickRegionScope(context, title: 'Rule for');
    if (scope == null || scope.isAll || !mounted) return;
    if (_rules!.any((r) => !r.isDefault && r.scope.key == scope.key)) {
      showError(context, 'There is already a rule for ${scope.label}.');
      return;
    }
    setState(() {
      _rules!.add(_Rule(level: _levelOf(scope), scope: scope, settings: {}));
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final repo = ref.read(mygigRepositoryProvider);
    for (final r in _rules!) {
      for (final f in mygigFields.where((f) => f.kind == MygigFieldKind.time)) {
        final v = mygigGet(r.settings, f.path);
        if (v != null && !mygigTimeOk(v)) {
          showError(context, '${f.label}: type a time like 06:00.');
          return;
        }
      }
    }
    final ok = await runAdminAction(context, () async {
      for (final id in _removed) {
        await repo.deleteRule(id);
      }
      for (final r in _rules!) {
        await repo.saveRule(
          id: r.id,
          level: r.level,
          country: r.isDefault ? null : r.scope.country,
          state: r.isDefault || r.scope.state.isEmpty ? null : r.scope.state,
          city: r.isDefault || r.scope.city.isEmpty ? null : r.scope.city,
          suburb: r.isDefault || r.scope.suburb.isEmpty ? null : r.scope.suburb,
          settings: r.settings,
        );
      }
    }, success: 'myGiG settings saved');
    if (ok && mounted) {
      setState(() {
        _dirty = false;
        _removed.clear();
        _rules = null;
      });
      ref.invalidate(_mygigRulesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(mygigAdminPage)) == AccessLevel.edit;
    final async = ref.watch(_mygigRulesProvider);
    return AdminPage(
      title: 'myGiG settings',
      page: mygigAdminPage,
      actions: [
        if (canEdit)
          IconButton(key: const ValueKey('mygig-rule-add'), tooltip: 'Add a region rule', icon: const Icon(Icons.add_location_alt_outlined), onPressed: _add),
      ],
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(_mygigRulesProvider),
        data: (rows) {
          if (_rules == null || !_dirty) _load(rows);
          final t = Theme.of(context);
          return ListView(
            key: const ValueKey('mygig-admin-settings'),
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'The Default rule holds everywhere. A region rule sets only the parts switched on in it; the smallest place '
                'that sets a part decides it. Drivers keep their own prices within these limits, and the server charges '
                'exactly this.',
                style: t.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              for (final (i, r) in _rules!.indexed)
                _RuleCard(
                  key: ValueKey('mygig-rule-${r.isDefault ? 'default' : r.scope.key}'),
                  rule: r,
                  base: _default,
                  canEdit: canEdit,
                  onChanged: (s) => setState(() {
                    r.settings = s;
                    _dirty = true;
                  }),
                  onRemove: r.isDefault || !canEdit
                      ? null
                      : () => setState(() {
                          if (r.id != null) _removed.add(r.id!);
                          _rules!.removeAt(i);
                          _dirty = true;
                        }),
                ),
              if (canEdit) ...[
                const SizedBox(height: 12),
                BusyButton.filled(
                  key: const ValueKey('mygig-admin-save'),
                  icon: const Icon(Icons.save_outlined),
                  onPressed: _dirty ? _save : null,
                  child: const Text('Save'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({super.key, required this.rule, required this.base, required this.canEdit, required this.onChanged, this.onRemove});
  final _Rule rule;
  final Map<String, dynamic> base;
  final bool canEdit;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = rule.settings;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        initiallyExpanded: rule.isDefault,
        title: Text(rule.isDefault ? 'Default (everywhere)' : rule.scope.label, style: t.textTheme.titleMedium),
        subtitle: rule.isDefault
            ? null
            : Text('Sets: ${[for (final p in mygigParts) if (mygigPartSet(s, p.$1)) p.$2].join(', ').ifEmpty('nothing yet')}'),
        trailing: onRemove == null
            ? null
            : IconButton(tooltip: 'Remove this rule', icon: const Icon(Icons.delete_outline), onPressed: onRemove),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          for (final (part, label, _) in mygigParts) ...[
            if (rule.isDefault)
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(label, style: t.textTheme.titleSmall),
              )
            else
              SwitchListTile(
                key: ValueKey('mygig-part-${rule.scope.key}-$part'),
                contentPadding: EdgeInsets.zero,
                title: Text(label, style: t.textTheme.titleSmall),
                subtitle: Text(mygigPartSet(s, part) ? 'Set here' : 'As the place above'),
                value: mygigPartSet(s, part),
                onChanged: canEdit ? (on) => onChanged(mygigSetPart(s, part, on: on, from: base)) : null,
              ),
            if (rule.isDefault || mygigPartSet(s, part))
              for (final f in mygigFields.where((f) => f.part == part))
                _FieldRow(
                  key: ValueKey('mygig-field-${rule.isDefault ? 'default' : rule.scope.key}-${f.path}'),
                  field: f,
                  value: mygigGet(s, f.path) ?? mygigGet(base, f.path),
                  enabled: canEdit,
                  onChanged: (v) => onChanged(mygigPut(s, f.path, v)),
                ),
          ],
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({super.key, required this.field, required this.value, required this.enabled, required this.onChanged});
  final MygigField field;
  final Object? value;
  final bool enabled;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final f = field;
    switch (f.kind) {
      case MygigFieldKind.toggle:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          subtitle: f.hint == null ? null : Text(f.hint!),
          value: value == true,
          onChanged: enabled ? onChanged : null,
        );
      case MygigFieldKind.choice:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(f.label),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              segments: [for (final (v, l) in f.choices) ButtonSegment(value: v, label: Text(l))],
              selected: {'${value ?? f.choices.first.$1}'},
              onSelectionChanged: enabled ? (v) => onChanged(v.first) : null,
            ),
          ]),
        );
      case MygigFieldKind.number || MygigFieldKind.whole || MygigFieldKind.time:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _ValueField(
            label: f.label,
            hint: f.hint,
            text: value == null ? '' : '$value',
            kind: f.kind,
            enabled: enabled,
            onChanged: onChanged,
          ),
        );
    }
  }
}

class _ValueField extends StatefulWidget {
  const _ValueField({super.key, required this.label, required this.text, required this.kind, required this.enabled, required this.onChanged, this.hint});
  final String label;
  final String? hint;
  final String text;
  final MygigFieldKind kind;
  final bool enabled;
  final ValueChanged<Object?> onChanged;

  @override
  State<_ValueField> createState() => _ValueFieldState();
}

class _ValueFieldState extends State<_ValueField> {
  late final _c = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final whole = widget.kind == MygigFieldKind.whole;
    final time = widget.kind == MygigFieldKind.time;
    return TextField(
      controller: _c,
      enabled: widget.enabled,
      keyboardType: time ? TextInputType.text : TextInputType.numberWithOptions(decimal: !whole),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(time ? r'[0-9:]' : whole ? r'[0-9]' : r'[0-9.]'))],
      decoration: InputDecoration(labelText: widget.label, helperText: widget.hint, hintText: time ? '06:00' : null),
      onChanged: (v) {
        if (time) {
          widget.onChanged(v.trim());
          return;
        }
        final n = whole ? int.tryParse(v) : double.tryParse(v);
        if (n != null && n >= 0) widget.onChanged(n);
      },
    );
  }
}

// ---- Access ------------------------------------------------------------------------------------------

final _mygigGlobalProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) {
  ref.watchLive('app_settings');
  return ref.watch(mygigRepositoryProvider).global();
});

final _mygigDriversProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, q) => ref.watch(mygigRepositoryProvider).adminDrivers(q),
);

class MygigAccessAdminScreen extends ConsumerStatefulWidget {
  const MygigAccessAdminScreen({super.key});

  @override
  ConsumerState<MygigAccessAdminScreen> createState() => _MygigAccessAdminScreenState();
}

class _MygigAccessAdminScreenState extends ConsumerState<MygigAccessAdminScreen> {
  String? _who;
  MygigFee? _fee;
  String _search = '';

  Future<void> _saveGlobal() async {
    final ok = await runAdminAction(context, () async {
      await ref.read(mygigRepositoryProvider).saveGlobal(who: _who ?? 'all', fee: _fee ?? const MygigFee());
    }, success: 'myGiG access saved');
    if (ok && mounted) ref.invalidate(_mygigGlobalProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(mygigAdminPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    return AdminPage(
      title: 'myGiG access',
      page: mygigAdminPage,
      body: AsyncView(
        value: ref.watch(_mygigGlobalProvider),
        onRetry: () => ref.invalidate(_mygigGlobalProvider),
        data: (g) {
          _who ??= '${g['who'] ?? 'all'}';
          _fee ??= MygigFee.fromJson(g['fee']);
          final fee = _fee!;
          final drivers = ref.watch(_mygigDriversProvider(_search));
          return ListView(
            key: const ValueKey('mygig-admin-access'),
            padding: const EdgeInsets.all(16),
            children: [
              Text('Who can use myGiG', style: t.textTheme.titleMedium),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'all', label: Text('All drivers')),
                  ButtonSegment(value: 'selected', label: Text('Selected drivers only')),
                  ButtonSegment(value: 'none', label: Text('Nobody')),
                ],
                selected: {_who!},
                onSelectionChanged: canEdit ? (v) => setState(() => _who = v.first) : null,
              ),
              const SizedBox(height: 4),
              Text(switch (_who) {
                'all' => 'Every driver whose partner type allows myGiG, except the ones you block below.',
                'selected' => 'Only the drivers you switch on below.',
                _ => 'myGiG is off for every driver.',
              }, style: t.textTheme.bodySmall),
              const SizedBox(height: 16),
              Text('Default charge to drivers', style: t.textTheme.titleMedium),
              _FeeEditor(fee: fee, enabled: canEdit, onChanged: (f) => setState(() => _fee = f), keyPrefix: 'default'),
              Text(
                '${switch (fee.mode) {
                  MygigFeeMode.none => 'Drivers use myGiG free.',
                  MygigFeeMode.trip => 'Taken from the driver\'s GET.credit when each myGiG ride ends.',
                  _ => 'Drivers buy a pass from GET.credit or GET.wallet before their first myGiG ride, and it lasts the period.',
                }} A change applies to the next ride or pass; a pass already bought runs to its end.',
                style: t.textTheme.bodySmall,
              ),
              if (canEdit) ...[
                const SizedBox(height: 8),
                BusyButton.filled(key: const ValueKey('mygig-access-save'), onPressed: _saveGlobal, child: const Text('Save')),
              ],
              const Divider(height: 32),
              Text('Drivers', style: t.textTheme.titleMedium),
              const SizedBox(height: 6),
              TextField(
                key: const ValueKey('mygig-driver-search'),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Search by name, phone or plate'),
                onSubmitted: (v) => setState(() => _search = v.trim()),
              ),
              const SizedBox(height: 8),
              AsyncView(
                value: drivers,
                onRetry: () => ref.invalidate(_mygigDriversProvider(_search)),
                data: (list) => list.isEmpty
                    ? const Padding(padding: EdgeInsets.all(16), child: Text('No drivers found.'))
                    : ListSearchFilter(
                        count: list.length,
                        hint: 'Filter these drivers',
                        builder: (_, q) => Column(children: [
                          for (final d in list)
                            if (q.isEmpty || '${d['name']} ${d['phone']} ${d['plate']}'.toLowerCase().contains(q.toLowerCase()))
                              _DriverRow(
                                key: ValueKey('mygig-driver-${d['id']}'),
                                driver: d,
                                who: _who!,
                                defaultFee: fee,
                                canEdit: canEdit,
                                onSaved: () => ref.invalidate(_mygigDriversProvider(_search)),
                              ),
                        ]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FeeEditor extends StatelessWidget {
  const _FeeEditor({required this.fee, required this.enabled, required this.onChanged, required this.keyPrefix});
  final MygigFee fee;
  final bool enabled;
  final ValueChanged<MygigFee> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Wrap(spacing: 6, runSpacing: 6, children: [
      for (final e in mygigFeeModeLabels.entries)
        ChoiceChip(
          key: ValueKey('mygig-fee-$keyPrefix-${e.key.name}'),
          label: Text(e.value),
          selected: fee.mode == e.key,
          onSelected: enabled ? (_) => onChanged(fee.copyWith(mode: e.key)) : null,
        ),
    ]),
    if (fee.mode == MygigFeeMode.trip)
      Wrap(spacing: 6, children: [
        ChoiceChip(label: const Text('RM a trip'), selected: !fee.percent,
            onSelected: enabled ? (_) => onChanged(fee.copyWith(percent: false)) : null),
        ChoiceChip(label: const Text('% of the fare'), selected: fee.percent,
            onSelected: enabled ? (_) => onChanged(fee.copyWith(percent: true)) : null),
      ]),
    if (fee.mode != MygigFeeMode.none)
      SizedBox(
        width: 220,
        child: _ValueField(
          key: ValueKey('mygig-fee-$keyPrefix-amount-${fee.mode.name}'),
          label: 'Amount (${fee.mode == MygigFeeMode.trip && fee.percent ? '%' : 'RM'})',
          text: fee.amount.toStringAsFixed(2),
          kind: MygigFieldKind.number,
          enabled: enabled,
          onChanged: (v) => onChanged(fee.copyWith(amount: (v as num).toDouble())),
        ),
      ),
  ]);
}

class _DriverRow extends ConsumerStatefulWidget {
  const _DriverRow({super.key, required this.driver, required this.who, required this.defaultFee, required this.canEdit, required this.onSaved});
  final Map<String, dynamic> driver;
  final String who;
  final MygigFee defaultFee;
  final bool canEdit;
  final VoidCallback onSaved;

  @override
  ConsumerState<_DriverRow> createState() => _DriverRowState();
}

class _DriverRowState extends ConsumerState<_DriverRow> {
  late bool? _allowed = widget.driver['allowed'] as bool?;
  late String _charge = '${widget.driver['charge'] ?? 'default'}';
  late MygigFee _custom = MygigFee.fromJson(widget.driver['custom']).mode == MygigFeeMode.none &&
          (widget.driver['custom'] is! Map || (widget.driver['custom'] as Map)['mode'] == null)
      ? const MygigFee(mode: MygigFeeMode.trip, amount: 1)
      : MygigFee.fromJson(widget.driver['custom']);

  bool get _on => widget.who == 'selected' ? (_allowed ?? false) : (_allowed ?? true);

  Future<void> _save() async {
    await runAdminAction(context, () async {
      await ref.read(mygigRepositoryProvider).adminDriverSet('${widget.driver['id']}',
          allowed: _allowed, charge: _charge, custom: _charge == 'custom' ? _custom : null);
    }, success: 'Saved');
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.driver;
    final t = Theme.of(context);
    final status = widget.who == 'none' ? 'Off for everyone' : _on ? 'Allowed' : widget.who == 'selected' ? 'Not selected' : 'Blocked';
    final charge = _charge == 'none' ? 'No charge' : _charge == 'custom' ? 'Own charge: ${_custom.text}' : 'Default: ${widget.defaultFee.text}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${d['name']}'),
            subtitle: Text('${[d['vehicle'], d['plate'], d['phone']].whereType<String>().join(' · ')}'
                '\n$status · $charge · today ${d['today'] ?? 0}'),
            isThreeLine: true,
            value: _on,
            onChanged: widget.canEdit && widget.who != 'none' ? (v) => setState(() => _allowed = v) : null,
          ),
          Wrap(spacing: 6, children: [
            for (final (k, l) in const [('default', 'Default'), ('none', 'No charge'), ('custom', 'Own charge')])
              ChoiceChip(
                label: Text(l),
                selected: _charge == k,
                onSelected: widget.canEdit ? (_) => setState(() => _charge = k) : null,
              ),
          ]),
          if (_charge == 'custom')
            _FeeEditor(fee: _custom, enabled: widget.canEdit, onChanged: (f) => setState(() => _custom = f),
                keyPrefix: '${d['id']}'),
          if (widget.canEdit)
            Align(
              alignment: Alignment.centerRight,
              child: BusyButton.text(key: ValueKey('mygig-driver-save-${d['id']}'), onPressed: _save, child: const Text('Save')),
            ),
          if (d['pass'] is Map)
            Text('Pass until ${formatDayDate(DateTime.parse('${(d['pass'] as Map)['endsAt']}').toLocal())}',
                style: t.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

// ---- Places ------------------------------------------------------------------------------------------

final _mygigPlacesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  ref.watchLive('mygig_place_rules');
  ref.watchLive('airport_areas');
  return ref.watch(mygigRepositoryProvider).adminPlaces();
});

class MygigPlacesAdminScreen extends ConsumerWidget {
  const MygigPlacesAdminScreen({super.key});

  static const _rules = [('allowed', 'Allowed'), ('pickup', 'No pickups'), ('drop', 'No drop-offs'), ('both', 'Neither')];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(mygigAdminPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    return AdminPage(
      title: 'Places where myGiG isn\'t allowed',
      page: mygigAdminPage,
      body: AsyncView(
        value: ref.watch(_mygigPlacesProvider),
        onRetry: () => ref.invalidate(_mygigPlacesProvider),
        data: (places) => ListView(
          key: const ValueKey('mygig-admin-places'),
          padding: const EdgeInsets.all(16),
          children: [
            Text('From the fenced places list (the same as place fees). Add a place there and it shows here. The driver '
                'sees the reason and can\'t send a myGiG.', style: t.textTheme.bodyMedium),
            const SizedBox(height: 12),
            if (places.isEmpty)
              const Text('No fenced places yet.')
            else
              ListSearchFilter(
                count: places.length,
                hint: 'Search places',
                builder: (_, q) => Column(children: [
                  for (final p in places)
                    if (q.isEmpty || '${p['name']}'.toLowerCase().contains(q.toLowerCase()))
                      Card(
                        key: ValueKey('mygig-place-${p['id']}'),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${p['name']}', style: t.textTheme.titleSmall),
                            const SizedBox(height: 6),
                            Wrap(spacing: 6, children: [
                              for (final (k, l) in _rules)
                                ChoiceChip(
                                  label: Text(l),
                                  selected: (p['rule'] ?? 'allowed') == k,
                                  onSelected: canEdit
                                      ? (_) async {
                                          final ok = await runAdminAction(context,
                                              () => ref.read(mygigRepositoryProvider).adminPlaceSet('${p['id']}', k));
                                          if (ok) ref.invalidate(_mygigPlacesProvider);
                                        }
                                      : null,
                                ),
                            ]),
                          ]),
                        ),
                      ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
