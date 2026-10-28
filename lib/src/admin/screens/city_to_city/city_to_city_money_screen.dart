// Admin → Services & catalogue → City to City payments, fees and reminders
// (migration 0309; the approved boards 11, 12 and 14):
//
//   Driver gives up a booked trip   a default rule and a rule per region (the
//                                   pickup's most specific region wins): the
//                                   fee, when, where it goes, a short wallet;
//                                   a live example and the driver's line.
//   In-app payment                  a default rule and a rule per region:
//                                   held at booking or paid after the trip,
//                                   the ways to pay, Top up / Switch to cash.
//   Cancel fees a rider owes        how they are collected (any combination).
//   Trip reminders                  on/off, the list, the channels, and how a
//                                   reminder reads on the phone.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/city_to_city.dart';
import '../../../data/city_to_city_repository.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../geo/geo_data.dart' show regionsProvider;
import '../geo/geo_logic.dart' show RegionEntry;
import 'c2c_widgets.dart';

const cityToCityMoneyPath = '/admin/m/city-to-city-money';

class CityToCityMoneyScreen extends ConsumerWidget {
  const CityToCityMoneyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(c2cPage)) == AccessLevel.edit;
    // Read by Add a region rule: kept loaded while the page is open.
    ref.watch(regionsProvider);
    final settings = ref.watch(c2cSettingsProvider);
    return AdminPage(
      title: 'City to City payments, fees and reminders',
      page: c2cPage,
      body: AsyncView(
        value: settings,
        onRetry: () => ref.invalidate(c2cSettingsProvider),
        data: (s) => ListView(padding: const EdgeInsets.all(16), children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _GiveUpSection(canEdit: canEdit, currency: s.currency),
                const SizedBox(height: 16),
                _PaySection(canEdit: canEdit),
                const SizedBox(height: 16),
                _OwedCard(stored: s, canEdit: canEdit),
                const SizedBox(height: 16),
                _RemindersCard(stored: s, canEdit: canEdit),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A section's heading and what it is for.
class _Heading extends StatelessWidget {
  const _Heading(this.title, this.intro);
  final String title, intro;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(intro, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

/// The list beside the editor on a wide screen, above it on a phone.
class _Split extends StatelessWidget {
  const _Split({required this.list, required this.editor});
  final Widget list, editor;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
    if (c.maxWidth >= 860) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 340, child: list),
        const SizedBox(width: 16),
        Expanded(child: editor),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [list, const SizedBox(height: 12), editor]);
  });
}

/// The rules, the default first, then the regions by name; and Add a
/// region rule.
class _RuleList<T extends C2cRegionRule> extends StatelessWidget {
  const _RuleList({
    required this.rules,
    required this.selected,
    required this.summary,
    required this.onPick,
    required this.keyPrefix,
    this.onAdd,
    this.footer,
  });

  final List<T> rules;
  final T? selected;
  final String Function(T) summary;
  final ValueChanged<T> onPick;
  final VoidCallback? onAdd;
  final String keyPrefix;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text('Rules', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          for (final r in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: identical(r, selected) ? cs.primaryContainer : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: identical(r, selected) ? cs.primary : cs.outlineVariant,
                    width: identical(r, selected) ? 2 : 1,
                  ),
                ),
                child: ListTile(
                  key: ValueKey('$keyPrefix-${r.id ?? 'new'}'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: Icon(r.isDefault ? Icons.public : Icons.location_on_outlined),
                  title: Text(r.name),
                  subtitle: Text(r.active ? summary(r) : 'Off. ${summary(r)}'),
                  textColor: identical(r, selected) ? cs.onPrimaryContainer : null,
                  iconColor: identical(r, selected) ? cs.onPrimaryContainer : null,
                  onTap: () => onPick(r),
                ),
              ),
            ),
          if (onAdd != null) ...[
            OutlinedButton.icon(
              key: ValueKey('$keyPrefix-add'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: onAdd,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('Add a region rule'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text('Pick the region from Country / State / City / Suburb, with search.',
                  style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
          ],
          ?footer,
        ]),
      ),
    );
  }
}

/// The default first, then the regions by name.
List<T> _ordered<T extends C2cRegionRule>(List<T> rules) => [
  ...rules.where((r) => r.isDefault),
  ...rules.where((r) => !r.isDefault).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
];

/// Asks for a region no rule of [taken] has yet.
Future<C2cPlace?> _pickRegion(BuildContext context, WidgetRef ref, Iterable<C2cRegionRule> taken) {
  final regions = ref.read(regionsProvider).value ?? const <RegionEntry>[];
  return pickC2cPlace(
    context,
    title: 'Rule for a region',
    choices: c2cPlaceChoices(regions),
    taken: [for (final r in taken) ?r.place],
  );
}

/// A card's footer: why it can't be saved, or whether it is; Delete and Save.
class _SaveRow extends StatelessWidget {
  const _SaveRow({
    required this.problem,
    required this.changed,
    required this.onSave,
    required this.saveKey,
    this.onDelete,
    this.deleteKey,
  });

  final String? problem;
  final bool changed;
  final VoidCallback onSave;
  final VoidCallback? onDelete;
  final Key saveKey;
  final Key? deleteKey;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(problem ?? (changed ? 'Not saved yet.' : 'Saved.'),
              style: TextStyle(color: problem != null ? cs.error : cs.onSurfaceVariant)),
          if (onDelete != null)
            TextButton.icon(
              key: deleteKey,
              style: TextButton.styleFrom(foregroundColor: cs.error, minimumSize: const Size(0, 44)),
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete rule'),
            ),
          FilledButton.icon(
            key: saveKey,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: changed && problem == null ? onSave : null,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// A grey box with the example's lines.
class _Example extends StatelessWidget {
  const _Example({super.key, required this.title, required this.lines});
  final String title;
  final (String, String) lines;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(lines.$1, style: t.textTheme.titleSmall?.copyWith(color: cs.onSurface)),
        const SizedBox(height: 2),
        Text(lines.$2, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurface)),
      ]),
    );
  }
}

final _seg = SegmentedButton.styleFrom(visualDensity: VisualDensity.compact);

// ---- Driver gives up a booked trip ------------------------------------------------------------------------

class _GiveUpSection extends ConsumerStatefulWidget {
  const _GiveUpSection({required this.canEdit, required this.currency});
  final bool canEdit;
  final String currency;

  @override
  ConsumerState<_GiveUpSection> createState() => _GiveUpSectionState();
}

class _GiveUpSectionState extends ConsumerState<_GiveUpSection> {
  /// The rule picked (its id; 'new' for one not saved yet) and its draft.
  String? _pick;
  C2cGiveUpRule? _draft;
  C2cGiveUpRule? _loaded;

  bool get _changed => _draft != null && (_loaded == null || _draft!.toRow().toString() != _loaded!.toRow().toString());

  void _select(C2cGiveUpRule r) => setState(() {
    _pick = r.id ?? 'new';
    _draft = r;
    _loaded = r.id == null ? null : r;
  });

  Future<void> _add(List<C2cGiveUpRule> rules) async {
    final place = await _pickRegion(context, ref, rules);
    if (place == null || !mounted) return;
    final base = rules.where((r) => r.isDefault).firstOrNull ?? C2cGiveUpRule();
    _select(C2cGiveUpRule(
      place: place,
      charge: base.charge,
      amount: base.amount,
      when: base.when,
      freeHours: base.freeHours,
      dest: base.dest,
      splitFixed: base.splitFixed,
      splitPercent: base.splitPercent,
      splitAmount: base.splitAmount,
      shortMode: base.shortMode,
    ));
  }

  Future<void> _save() async {
    final d = _draft!;
    final ok = await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).saveGiveUpRule(d),
        success: 'Rule saved');
    if (ok && mounted) {
      setState(() {
        _loaded = d;
        if (d.id == null) _pick = null;
      });
      ref.invalidate(c2cGiveUpRulesProvider);
    }
  }

  Future<void> _delete() async {
    final d = _draft!;
    if (d.id == null) {
      setState(() => _pick = _draft = _loaded = null);
      return;
    }
    if (!await confirm(context, 'Delete rule?', 'Pickups in ${d.name} follow the default again.', ok: 'Delete') ||
        !mounted) {
      return;
    }
    if (await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).deleteGiveUpRule(d.id!),
        success: 'Rule deleted')) {
      setState(() => _pick = _draft = _loaded = null);
      ref.invalidate(c2cGiveUpRulesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(c2cGiveUpRulesProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _Heading(
        'Driver gives up a booked trip',
        'A default rule for everywhere, and a rule per region where it should differ. The rule of the pickup\'s '
            'most specific region wins (suburb, city, state, country, then the default).',
      ),
      AsyncView(
        value: async,
        onRetry: () => ref.invalidate(c2cGiveUpRulesProvider),
        data: (stored) {
          final rules = _ordered(stored);
          // The picked rule as stored now, unless it is being changed.
          var draft = _draft;
          if (_pick != 'new') {
            final live = rules.where((r) => r.id == _pick).firstOrNull ?? rules.firstOrNull;
            if (live != null && (draft == null || !_changed || draft.id != live.id)) {
              draft = live;
              _draft = live;
              _loaded = live;
              _pick = live.id;
            }
          }
          final shown = [...rules, if (_pick == 'new' && draft != null) draft];
          return _Split(
            list: _RuleList<C2cGiveUpRule>(
              rules: shown,
              selected: draft,
              summary: (r) => c2cGiveUpSummary(r, widget.currency),
              onPick: _select,
              keyPrefix: 'c2c-give',
              onAdd: widget.canEdit ? () => _add(rules) : null,
            ),
            editor: draft == null
                ? const SizedBox.shrink()
                : _GiveUpEditor(
                    rule: draft,
                    currency: widget.currency,
                    onChanged: widget.canEdit ? (r) => setState(() => _draft = r) : null,
                    footer: widget.canEdit
                        ? _SaveRow(
                            problem: draft.problem,
                            changed: _changed,
                            onSave: _save,
                            saveKey: const ValueKey('c2c-give-save'),
                            onDelete: draft.isDefault ? null : _delete,
                            deleteKey: const ValueKey('c2c-give-delete'),
                          )
                        : null,
                  ),
          );
        },
      ),
    ]);
  }
}

class _GiveUpEditor extends StatelessWidget {
  const _GiveUpEditor({required this.rule, required this.currency, this.onChanged, this.footer});
  final C2cGiveUpRule rule;
  final String currency;
  final ValueChanged<C2cGiveUpRule>? onChanged;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final r = rule;
    final on = onChanged;
    VoidCallback? step(bool ok, C2cGiveUpRule Function() next) => on == null || !ok ? null : () => on(next());
    String money(double v) => c2cMoney(v, currency);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: t.textTheme.titleLarge),
                Text(r.scope, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
            if (!r.isDefault) ...[
              Text('On', style: t.textTheme.bodyMedium),
              Switch(
                key: const ValueKey('c2c-give-active'),
                value: r.active,
                onChanged: on == null ? null : (v) => on(r.copyWith(active: v)),
              ),
            ],
          ]),
          SwitchListTile(
            key: const ValueKey('c2c-give-charge'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Charge the driver'),
            subtitle: const Text('Off: giving up is free'),
            value: r.charge,
            onChanged: on == null ? null : (v) => on(r.copyWith(charge: v)),
          ),
          if (r.charge) ...[
            C2cStepper(
              label: 'Fee',
              hint: "Taken from the driver's GET wallet",
              value: money(r.amount),
              valueKey: const ValueKey('c2c-give-amount'),
              onDown: step(r.amount > 5, () => r.copyWith(amount: r.amount - 5)),
              onUp: step(r.amount < 10000, () => r.copyWith(amount: r.amount + 5)),
            ),
            const SizedBox(height: 8),
            Text('When', style: t.textTheme.titleSmall),
            const SizedBox(height: 6),
            SegmentedButton<C2cGiveUpWhen>(
              key: const ValueKey('c2c-give-when'),
              style: _seg,
              segments: [for (final w in C2cGiveUpWhen.values) ButtonSegment(value: w, label: Text(w.label))],
              selected: {r.when},
              onSelectionChanged: on == null ? null : (v) => on(r.copyWith(when: v.first)),
            ),
            if (r.when == C2cGiveUpWhen.within)
              C2cStepper(
                label: 'Free until',
                hint: 'Hours before the time to leave',
                value: '${r.freeHours} h',
                valueKey: const ValueKey('c2c-give-hours'),
                onDown: step(r.freeHours > 1, () => r.copyWith(freeHours: r.freeHours - (r.freeHours > 12 ? 6 : 1))),
                onUp: step(r.freeHours < 720, () => r.copyWith(freeHours: r.freeHours + (r.freeHours >= 12 ? 6 : 1))),
              ),
            const SizedBox(height: 8),
            Text('Fee goes to', style: t.textTheme.titleSmall),
            const SizedBox(height: 6),
            SegmentedButton<C2cFeeDest>(
              key: const ValueKey('c2c-give-dest'),
              style: _seg,
              segments: [for (final d in C2cFeeDest.values) ButtonSegment(value: d, label: Text(d.label))],
              selected: {r.dest},
              onSelectionChanged: on == null ? null : (v) => on(r.copyWith(dest: v.first)),
            ),
            if (r.dest == C2cFeeDest.split) ...[
              const SizedBox(height: 8),
              Text("Rider's share", style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 4),
              SegmentedButton<bool>(
                key: const ValueKey('c2c-give-split-mode'),
                style: _seg,
                segments: const [
                  ButtonSegment(value: false, label: Text('Percent')),
                  ButtonSegment(value: true, label: Text('Fixed RM')),
                ],
                selected: {r.splitFixed},
                onSelectionChanged: on == null ? null : (v) => on(r.copyWith(splitFixed: v.first)),
              ),
              r.splitFixed
                  ? C2cStepper(
                      label: 'To the rider',
                      hint: 'Up to the fee; the rest to get.ride',
                      value: money(r.splitAmount),
                      valueKey: const ValueKey('c2c-give-share'),
                      onDown: step(r.splitAmount >= 5, () => r.copyWith(splitAmount: r.splitAmount - 5)),
                      onUp: step(r.splitAmount < 10000, () => r.copyWith(splitAmount: r.splitAmount + 5)),
                    )
                  : C2cStepper(
                      label: 'To the rider',
                      hint: 'The rest to get.ride',
                      value: '${r.splitPercent.round()}%',
                      valueKey: const ValueKey('c2c-give-share'),
                      onDown: step(r.splitPercent >= 10, () => r.copyWith(splitPercent: r.splitPercent - 10)),
                      onUp: step(r.splitPercent <= 90, () => r.copyWith(splitPercent: r.splitPercent + 10)),
                    ),
            ],
            const SizedBox(height: 8),
            Text("If the driver's wallet is short", style: t.textTheme.titleSmall),
            const SizedBox(height: 6),
            SegmentedButton<C2cShortMode>(
              key: const ValueKey('c2c-give-short'),
              style: _seg,
              segments: [for (final m in C2cShortMode.values) ButtonSegment(value: m, label: Text(m.label))],
              selected: {r.shortMode},
              onSelectionChanged: on == null ? null : (v) => on(r.copyWith(shortMode: v.first)),
            ),
            const SizedBox(height: 4),
            Text(r.shortMode.note, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
          _Example(
            key: const ValueKey('c2c-give-example'),
            title: 'Example: a driver gives up 3 hours before leaving, with RM 12 in their wallet',
            lines: c2cGiveUpExample(r, currency: currency),
          ),
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: 'Driver sees before Give up trip: ', style: TextStyle(color: cs.onSurfaceVariant)),
                    TextSpan(text: c2cGiveUpLine(r, currency), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                  key: const ValueKey('c2c-give-driver-line'),
                ),
              ),
            ]),
          ),
          ?footer,
        ]),
      ),
    );
  }
}

// ---- In-app payment ---------------------------------------------------------------------------------

class _PaySection extends ConsumerStatefulWidget {
  const _PaySection({required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<_PaySection> createState() => _PaySectionState();
}

class _PaySectionState extends ConsumerState<_PaySection> {
  String? _pick;
  C2cPayRule? _draft;
  C2cPayRule? _loaded;

  bool get _changed => _draft != null && (_loaded == null || _draft!.toRow().toString() != _loaded!.toRow().toString());

  void _select(C2cPayRule r) => setState(() {
    _pick = r.id ?? 'new';
    _draft = r;
    _loaded = r.id == null ? null : r;
  });

  Future<void> _add(List<C2cPayRule> rules) async {
    final place = await _pickRegion(context, ref, rules);
    if (place == null || !mounted) return;
    final base = rules.where((r) => r.isDefault).firstOrNull ?? C2cPayRule();
    _select(C2cPayRule(
      place: place,
      when: base.when,
      wallet: base.wallet,
      coin: base.coin,
      mix: base.mix,
      offerTopup: base.offerTopup,
      offerCash: base.offerCash,
    ));
  }

  Future<void> _save() async {
    final d = _draft!;
    final ok = await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).savePayRule(d),
        success: 'Rule saved');
    if (ok && mounted) {
      setState(() {
        _loaded = d;
        if (d.id == null) _pick = null;
      });
      ref.invalidate(c2cPayRulesProvider);
    }
  }

  Future<void> _delete() async {
    final d = _draft!;
    if (d.id == null) {
      setState(() => _pick = _draft = _loaded = null);
      return;
    }
    if (!await confirm(context, 'Delete rule?', 'Pickups in ${d.name} follow the default again.', ok: 'Delete') ||
        !mounted) {
      return;
    }
    if (await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).deletePayRule(d.id!),
        success: 'Rule deleted')) {
      setState(() => _pick = _draft = _loaded = null);
      ref.invalidate(c2cPayRulesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(c2cPayRulesProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _Heading(
        'In-app payment',
        'How a trip paid "In app" is charged. A default rule, and a rule per region where it should differ (the '
            'pickup\'s most specific region wins). Cash trips are not touched.',
      ),
      AsyncView(
        value: async,
        onRetry: () => ref.invalidate(c2cPayRulesProvider),
        data: (stored) {
          final rules = _ordered(stored);
          var draft = _draft;
          if (_pick != 'new') {
            final live = rules.where((r) => r.id == _pick).firstOrNull ?? rules.firstOrNull;
            if (live != null && (draft == null || !_changed || draft.id != live.id)) {
              draft = live;
              _draft = live;
              _loaded = live;
              _pick = live.id;
            }
          }
          final shown = [...rules, if (_pick == 'new' && draft != null) draft];
          return _Split(
            list: _RuleList<C2cPayRule>(
              rules: shown,
              selected: draft,
              summary: c2cPayRuleSummary,
              onPick: _select,
              keyPrefix: 'c2c-pay',
              onAdd: widget.canEdit ? () => _add(rules) : null,
            ),
            editor: draft == null
                ? const SizedBox.shrink()
                : _PayEditor(
                    rule: draft,
                    onChanged: widget.canEdit ? (r) => setState(() => _draft = r) : null,
                    footer: widget.canEdit
                        ? _SaveRow(
                            problem: draft.problem,
                            changed: _changed,
                            onSave: _save,
                            saveKey: const ValueKey('c2c-pay-save'),
                            onDelete: draft.isDefault ? null : _delete,
                            deleteKey: const ValueKey('c2c-pay-delete'),
                          )
                        : null,
                  ),
          );
        },
      ),
    ]);
  }
}

class _PayEditor extends StatelessWidget {
  const _PayEditor({required this.rule, this.onChanged, this.footer});
  final C2cPayRule rule;
  final ValueChanged<C2cPayRule>? onChanged;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final r = rule;
    final on = onChanged;
    Widget box(Key key, String label, String? note, bool value, C2cPayRule Function(bool) next, {bool enabled = true}) =>
        CheckboxListTile(
          key: key,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(label),
          subtitle: note == null ? null : Text(note),
          value: value,
          onChanged: on == null || !enabled ? null : (v) => on(next(v ?? false)),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: t.textTheme.titleLarge),
                Text(r.scope, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
            if (!r.isDefault) ...[
              Text('On', style: t.textTheme.bodyMedium),
              Switch(
                key: const ValueKey('c2c-pay-active'),
                value: r.active,
                onChanged: on == null ? null : (v) => on(r.copyWith(active: v)),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          Text('When the rider pays', style: t.textTheme.titleSmall),
          const SizedBox(height: 6),
          SegmentedButton<C2cPayWhen>(
            key: const ValueKey('c2c-pay-when'),
            style: _seg,
            segments: [for (final w in C2cPayWhen.values) ButtonSegment(value: w, label: Text(w.label))],
            selected: {r.when},
            onSelectionChanged: on == null ? null : (v) => on(r.copyWith(when: v.first)),
          ),
          const SizedBox(height: 4),
          Text(r.when.note, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          Text('Riders may pay with', style: t.textTheme.titleSmall),
          box(const ValueKey('c2c-pay-wallet'), 'GET.wallet', "The rider's wallet balance", r.wallet,
              (v) => r.copyWith(wallet: v)),
          box(const ValueKey('c2c-pay-coin'), 'GET.coin', 'Coins at the coin rate', r.coin, (v) => r.copyWith(coin: v)),
          box(const ValueKey('c2c-pay-mix'), 'Coins first, the rest from the wallet', 'Needs both ways on', r.mix,
              (v) => r.copyWith(mix: v), enabled: r.wallet && r.coin),
          Text('Keep at least one way on, or turn In app off in Payment methods.',
              style: t.textTheme.bodySmall?.copyWith(
                color: !r.wallet && !r.coin ? cs.error : cs.onSurfaceVariant,
                fontWeight: !r.wallet && !r.coin ? FontWeight.w600 : null,
              )),
          const SizedBox(height: 12),
          Text("If the rider's wallet is short when they accept", style: t.textTheme.titleSmall),
          box(const ValueKey('c2c-pay-topup'), 'Offer "Top up"', null, r.offerTopup, (v) => r.copyWith(offerTopup: v)),
          box(const ValueKey('c2c-pay-cash'), 'Offer "Switch to cash"', null, r.offerCash, (v) => r.copyWith(offerCash: v)),
          _Example(
            key: const ValueKey('c2c-pay-example'),
            title: 'Example: RM 140 trip, rider has RM 100 and 500 coins (100 coins = RM 1)',
            lines: c2cPayExample(r),
          ),
          ?footer,
        ]),
      ),
    );
  }
}

// ---- Cancel fees a rider owes -------------------------------------------------------------------------

class _OwedCard extends ConsumerStatefulWidget {
  const _OwedCard({required this.stored, required this.canEdit});
  final C2cSettings stored;
  final bool canEdit;

  @override
  ConsumerState<_OwedCard> createState() => _OwedCardState();
}

class _OwedCardState extends ConsumerState<_OwedCard> {
  ({bool topup, bool next, bool cash, bool block})? _draft;

  ({bool topup, bool next, bool cash, bool block}) _of(C2cSettings s) =>
      (topup: s.owedFromTopup, next: s.owedNextInApp, cash: s.owedCashCollect, block: s.owedBlock);

  Future<void> _save() async {
    final d = _draft!;
    // The stored settings as they are now, with these four changed.
    final s = widget.stored.copyWith(owedFromTopup: d.topup, owedNextInApp: d.next, owedCashCollect: d.cash, owedBlock: d.block);
    if (await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).saveSettings(s), success: 'Saved')) {
      if (mounted) setState(() => _draft = null);
      ref.invalidate(c2cSettingsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stored = _of(widget.stored);
    final d = _draft ?? stored;
    final on = widget.canEdit;
    void set(({bool topup, bool next, bool cash, bool block}) v) => setState(() => _draft = v);
    Widget box(Key key, String label, bool value, ({bool topup, bool next, bool cash, bool block}) Function(bool) next) =>
        CheckboxListTile(
          key: key,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(label),
          value: value,
          onChanged: on ? (v) => set(next(v ?? false)) : null,
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.receipt_long_outlined, 'Cancel fees a rider owes'),
          Text('When the wallet was short at cancel. Applies everywhere. Tick any.', style: t.textTheme.bodySmall),
          box(const ValueKey('c2c-owed-topup'), 'Take it from the next top-up', d.topup,
              (v) => (topup: v, next: d.next, cash: d.cash, block: d.block)),
          box(const ValueKey('c2c-owed-next'), 'Add it to the next in-app payment', d.next,
              (v) => (topup: d.topup, next: v, cash: d.cash, block: d.block)),
          box(const ValueKey('c2c-owed-cash'), 'Driver collects it on the next cash trip', d.cash,
              (v) => (topup: d.topup, next: d.next, cash: v, block: d.block)),
          box(const ValueKey('c2c-owed-block'), 'No new City to City booking until paid', d.block,
              (v) => (topup: d.topup, next: d.next, cash: d.cash, block: v)),
          Text(
            c2cOwedNote(widget.stored.copyWith(owedBlock: d.block)),
            key: const ValueKey('c2c-owed-note'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          if (on)
            _SaveRow(
              problem: null,
              changed: d != stored,
              onSave: _save,
              saveKey: const ValueKey('c2c-owed-save'),
            ),
        ]),
      ),
    );
  }
}

// ---- Trip reminders ----------------------------------------------------------------------------------

class _RemindersCard extends ConsumerStatefulWidget {
  const _RemindersCard({required this.stored, required this.canEdit});
  final C2cSettings stored;
  final bool canEdit;

  @override
  ConsumerState<_RemindersCard> createState() => _RemindersCardState();
}

class _RemindersCardState extends ConsumerState<_RemindersCard> {
  C2cSettings? _draft;
  int _sel = 0;

  String _key(C2cSettings s) =>
      '${s.remindersOn}|${s.reminderPush}|${s.reminderInbox}|${s.reminderSms}|'
      '${[for (final r in s.reminders) '${r.minutes}:${r.to}'].join(',')}';

  Future<void> _save() async {
    final d = _draft!;
    final s = widget.stored.copyWith(
      remindersOn: d.remindersOn,
      reminderPush: d.reminderPush,
      reminderInbox: d.reminderInbox,
      reminderSms: d.reminderSms,
      reminders: d.reminders,
    );
    if (await runAdminAction(context, () => ref.read(cityToCityRepositoryProvider).saveSettings(s), success: 'Saved')) {
      if (mounted) setState(() => _draft = null);
      ref.invalidate(c2cSettingsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final d = _draft ?? widget.stored;
    final on = widget.canEdit;
    final list = d.reminders;
    final sel = list.isEmpty ? null : list[_sel.clamp(0, list.length - 1)];
    void set(C2cSettings v) => setState(() => _draft = v);
    void setAt(int i, C2cReminder r) => set(d.copyWith(reminders: [for (var j = 0; j < list.length; j++) j == i ? r : list[j]]));
    final problem = c2cRemindersProblem(list);

    final editor = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SwitchListTile(
        key: const ValueKey('c2c-rem-on'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Send trip reminders'),
        subtitle: const Text('Off: no reminders anywhere'),
        value: d.remindersOn,
        onChanged: on ? (v) => set(d.copyWith(remindersOn: v)) : null,
      ),
      if (d.remindersOn) ...[
        for (var i = 0; i < list.length; i++)
          Container(
            key: ValueKey('c2c-rem-$i'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: i == _sel ? cs.primary : cs.outlineVariant, width: i == _sel ? 2 : 1),
            ),
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: [
              IconButton(
                tooltip: 'Show on the phone',
                onPressed: () => setState(() => _sel = i),
                icon: Icon(i == _sel ? Icons.notifications_active : Icons.notifications_outlined),
              ),
              IconButton.outlined(
                tooltip: 'Closer to leaving',
                onPressed: on && c2cReminderStep(list[i].minutes, -1) != list[i].minutes
                    ? () => setAt(i, list[i].copyWith(minutes: c2cReminderStep(list[i].minutes, -1)))
                    : null,
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 64,
                child: Text(c2cReminderWhen(list[i].minutes),
                    key: ValueKey('c2c-rem-$i-when'), textAlign: TextAlign.center, style: t.textTheme.titleSmall),
              ),
              IconButton.outlined(
                tooltip: 'Further ahead',
                onPressed: on && c2cReminderStep(list[i].minutes, 1) != list[i].minutes
                    ? () => setAt(i, list[i].copyWith(minutes: c2cReminderStep(list[i].minutes, 1)))
                    : null,
                icon: const Icon(Icons.add),
              ),
              const Text('before, to'),
              SegmentedButton<String>(
                key: ValueKey('c2c-rem-$i-to'),
                style: _seg,
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'rider', label: Text('Rider')),
                  ButtonSegment(value: 'driver', label: Text('Driver')),
                  ButtonSegment(value: 'both', label: Text('Both')),
                ],
                selected: {list[i].to},
                onSelectionChanged: on ? (v) => setAt(i, list[i].copyWith(to: v.first)) : null,
              ),
              if (on)
                IconButton(
                  tooltip: 'Remove reminder',
                  onPressed: () => setState(() {
                    _draft = d.copyWith(reminders: [for (var j = 0; j < list.length; j++) if (j != i) list[j]]);
                    _sel = 0;
                  }),
                  icon: const Icon(Icons.delete_outline),
                ),
            ]),
          ),
        if (on && list.length < 10)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('c2c-rem-add'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () {
                final free = [60, ...c2cReminderSteps].firstWhere(
                  (m) => !list.any((r) => r.minutes == m),
                  orElse: () => 60,
                );
                setState(() {
                  _draft = d.copyWith(reminders: [...list, C2cReminder(free)]);
                  _sel = list.length;
                });
              },
              icon: const Icon(Icons.add_alert_outlined),
              label: const Text('Add a reminder'),
            ),
          ),
        const SizedBox(height: 12),
        Text("How they're sent", style: t.textTheme.titleSmall),
        for (final (key, label, note, value, next) in [
          ('c2c-rem-push', 'Push notification', 'To the phone', d.reminderPush, (bool v) => d.copyWith(reminderPush: v)),
          ('c2c-rem-inbox', 'Notifications page', 'Kept in the side menu', d.reminderInbox,
              (bool v) => d.copyWith(reminderInbox: v)),
          ('c2c-rem-sms', "SMS if the push isn't delivered", 'Uses the SMS gateway; costs per message. Needs push on.',
              d.reminderSms, (bool v) => d.copyWith(reminderSms: v)),
        ])
          CheckboxListTile(
            key: ValueKey(key),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(label),
            subtitle: Text(note),
            value: value,
            onChanged: on ? (v) => set(next(v ?? false)) : null,
          ),
        Text(
          "A reminder whose time has already passed when the trip is booked is skipped (a trip booked 3 hours ahead "
          "gets only the 2 h and 30 min ones). A trip that's cancelled or given up gets no more reminders.",
          style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
      if (on)
        _SaveRow(
          problem: problem,
          changed: _key(d) != _key(widget.stored),
          onSave: _save,
          saveKey: const ValueKey('c2c-rem-save'),
        ),
    ]);

    final preview = _PhonePreview(settings: d, reminder: sel);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _Heading(
        'Trip reminders',
        "Sent before a booked trip's time to leave, to the rider, the driver or both. Add, remove or change any "
            'reminder, and tap a reminder to see it on the phone.',
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(builder: (context, c) {
            if (c.maxWidth >= 860) {
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: editor),
                const SizedBox(width: 16),
                SizedBox(width: 320, child: preview),
              ]);
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [editor, const SizedBox(height: 12), preview]);
          }),
        ),
      ),
    ]);
  }
}

/// How the picked reminder reads on the phone (the board's example trip).
class _PhonePreview extends StatelessWidget {
  const _PhonePreview({required this.settings, required this.reminder});
  final C2cSettings settings;
  final C2cReminder? reminder;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final r = reminder;
    final off = !settings.remindersOn || r == null;
    final words = r == null
        ? null
        : c2cReminderTexts(
            minutes: r.minutes,
            dropCity: 'Ipoh',
            driverName: 'Hafiz Rahman',
            riderName: 'Farah Tan',
            leaves: DateTime(2026, 10, 31, 8),
            pickup: '12 Jalan Ampang',
            car: 'Toyota Vios, WXY 1234',
            fare: 140,
            payLine: 'cash',
          );
    Widget note(Key key, String title, String body) => Container(
      key: key,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.directions_car, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Text('get.ride · now', style: t.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
        const SizedBox(height: 4),
        Text(title, style: t.textTheme.titleSmall?.copyWith(color: cs.onSurface)),
        Text(body, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurface)),
      ]),
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(28)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Sat 06:00', textAlign: TextAlign.center, style: t.textTheme.titleMedium?.copyWith(color: cs.onSurface)),
        if (off)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Text('Reminders are off.', textAlign: TextAlign.center,
                style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          )
        else ...[
          if (r.toRider) note(const ValueKey('c2c-rem-preview-rider'), words!.riderTitle, words.riderBody),
          if (r.toDriver) note(const ValueKey('c2c-rem-preview-driver'), words!.driverTitle, words.driverBody),
          if (settings.reminderSms && settings.reminderPush)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text("If the push isn't delivered in a few minutes, an SMS goes out with the same text.",
                  textAlign: TextAlign.center, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
        ],
      ]),
    );
  }
}
