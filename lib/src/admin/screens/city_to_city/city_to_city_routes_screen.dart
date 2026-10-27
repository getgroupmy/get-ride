// Admin → City to City → Route rules and fares (migration 0306): the rules
// (From and To each several places at any level; the most specific match
// wins), the default for trips no rule matches, and an editor with a live
// example worked out the way the server quotes (core/city_to_city.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/city_to_city.dart';
import '../../../core/commission.dart' show Geo;
import '../../../core/fare_tariff.dart';
import '../../../data/city_to_city_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../geo/geo_data.dart' show regionsProvider;
import '../geo/geo_logic.dart' show RegionEntry;
import 'c2c_widgets.dart';

/// The example trip the editor prices: 205 km, 2 h 40 min.
const c2cExampleKm = 205.0;
const c2cExampleMin = 160.0;

/// What the editor hands back: a rule to save, or one to delete.
typedef _Edit = ({C2cRule rule, bool delete});

class CityToCityRoutesScreen extends ConsumerStatefulWidget {
  const CityToCityRoutesScreen({super.key});

  @override
  ConsumerState<CityToCityRoutesScreen> createState() => _CityToCityRoutesScreenState();
}

class _CityToCityRoutesScreenState extends ConsumerState<CityToCityRoutesScreen> {
  Future<void> _edit(C2cRule? rule, C2cSettings s, {bool isDefault = false, int nextPosition = 0}) async {
    final canEdit = ref.read(pageAccessProvider(c2cPage)) == AccessLevel.edit;
    final regions = ref.read(regionsProvider).value ?? const <RegionEntry>[];
    final start = isDefault
        ? s.defaultRule
        : rule ??
            C2cRule(
              position: nextPosition,
              bookAheadDays: s.defaultBookAheadDays,
            );
    final out = await showAdminSheet<_Edit>(
      context,
      title: isDefault
          ? 'Default when no rule matches'
          : rule == null
              ? 'New rule'
              : 'Edit rule',
      builder: (_) => C2cRuleEditor(
        rule: start,
        settings: s,
        isDefault: isDefault,
        canEdit: canEdit,
        canDelete: rule?.id != null,
        places: c2cPlaceChoices(regions),
      ),
    );
    if (out == null || !mounted) return;
    final repo = ref.read(cityToCityRepositoryProvider);
    if (out.delete) {
      if (!await confirm(context, 'Delete rule?', _routeText(out.rule), ok: 'Delete') || !mounted) return;
      if (await runAdminAction(context, () => repo.deleteRule(out.rule.id!), success: 'Rule deleted')) {
        ref.invalidate(c2cRulesProvider);
      }
      return;
    }
    final ok = await runAdminAction(
      context,
      () => isDefault ? repo.saveSettings(s.copyWith(defaultRule: out.rule)) : repo.saveRule(out.rule),
      success: isDefault ? 'Default saved' : 'Rule saved',
    );
    if (ok) {
      ref.invalidate(isDefault ? c2cSettingsProvider : c2cRulesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(c2cPage)) == AccessLevel.edit;
    // Read when a rule is edited: kept loaded while the page is open.
    ref.watch(regionsProvider);
    ref.watch(c2cFareContextProvider);
    final settings = ref.watch(c2cSettingsProvider);
    final rules = ref.watch(c2cRulesProvider);
    final t = Theme.of(context);
    return AdminPage(
      title: 'Route rules and fares',
      page: c2cPage,
      addAction: PageAddAction(
        key: const ValueKey('c2c-rule-add'),
        onPressed: settings.value == null
            ? null
            : () => _edit(null, settings.value!,
                nextPosition: (rules.value ?? const <C2cRule>[]).fold<int>(0, (m, r) => r.position > m ? r.position : m) + 1),
        label: const Text('Add rule'),
      ),
      body: AsyncView(
        value: settings,
        onRetry: () => ref.invalidate(c2cSettingsProvider),
        data: (s) => AsyncView(
          value: rules,
          onRetry: () => ref.invalidate(c2cRulesProvider),
          data: (list) => ListView(padding: const EdgeInsets.all(16), children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Card(
                    child: ListTile(
                      key: const ValueKey('c2c-default'),
                      leading: const Icon(Icons.rule_outlined),
                      title: const Text('Default when no rule matches'),
                      subtitle: Text(
                        '${c2cFareText(s.defaultRule, currency: s.currency, isDefault: true)}, '
                        'range ${c2cRangeText(s.defaultRule, currency: s.currency)}, '
                        'book up to ${s.defaultBookAheadDays} days ahead',
                        key: const ValueKey('c2c-default-text'),
                      ),
                      trailing: TextButton(
                        key: const ValueKey('c2c-default-edit'),
                        onPressed: () => _edit(null, s, isDefault: true),
                        child: Text(canEdit ? 'Edit' : 'View'),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'From and To can each hold several places, at any level: country, state, city or suburb. The '
                      'most specific match wins: suburb, then city, then state, then country, counting both ends; '
                      'when two rules tie, the one more specific at the pickup, then the one higher in this list. '
                      'Fare card: the Fare tariffs card for the pickup and the service (base, per km, per minute). '
                      'Min years "Default" follows City to City settings.',
                      style: t.textTheme.bodySmall,
                    ),
                  ),
                  if (list.isEmpty)
                    const EmptyState(
                      icon: Icons.route_outlined,
                      title: 'No route rules yet',
                      message: 'Every trip uses the default until you add one.',
                    ),
                  ListSearchFilter(
                    count: list.length,
                    hint: 'Search rules by place',
                    fieldKey: const ValueKey('c2c-rules-search'),
                    builder: (context, q) {
                      final query = q.toLowerCase();
                      final shown = [
                        for (final r in list)
                          if (query.isEmpty ||
                              [...r.from, ...r.to].any((p) => p.label.toLowerCase().contains(query)))
                            r,
                      ];
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final r in shown)
                          _RuleCard(
                            rule: r,
                            settings: s,
                            canEdit: canEdit,
                            onEdit: () => _edit(r, s),
                            onActive: (on) async {
                              if (await runAdminAction(
                                  context, () => ref.read(cityToCityRepositoryProvider).setRuleActive(r.id!, on))) {
                                ref.invalidate(c2cRulesProvider);
                              }
                            },
                          ),
                      ]);
                    },
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

String _routeText(C2cRule r) => '${r.from.map((p) => p.name).join(', ')} to ${r.to.map((p) => p.name).join(', ')}';

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.settings,
    required this.canEdit,
    required this.onEdit,
    required this.onActive,
  });

  final C2cRule rule;
  final C2cSettings settings;
  final bool canEdit;
  final VoidCallback onEdit;
  final ValueChanged<bool> onActive;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = rule.active ? null : t.colorScheme.onSurfaceVariant;
    Widget fact(String label, String value, String key) => Padding(
      padding: const EdgeInsets.only(right: 16, top: 4),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '$label ', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          TextSpan(text: value, style: TextStyle(color: muted)),
        ]),
        key: ValueKey('c2c-rule-$key-${rule.id}'),
      ),
    );
    return Card(
      key: ValueKey('c2c-rule-${rule.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('From', style: t.textTheme.labelMedium),
              const SizedBox(height: 4),
              C2cPlaceChips(places: rule.from, keyPrefix: 'c2c-from-${rule.id}-'),
              const SizedBox(height: 8),
              Text('To', style: t.textTheme.labelMedium),
              const SizedBox(height: 4),
              C2cPlaceChips(places: rule.to, from: false, keyPrefix: 'c2c-to-${rule.id}-'),
              const SizedBox(height: 4),
              Wrap(children: [
                fact('Fare', c2cFareText(rule, currency: settings.currency), 'fare'),
                fact('Range', c2cRangeText(rule, currency: settings.currency), 'range'),
                fact('Book ahead', '${rule.bookAheadDays} days', 'ahead'),
                fact('Min years', c2cYearsText(rule, settings), 'years'),
              ]),
            ]),
          ),
          Column(children: [
            Switch(
              key: ValueKey('c2c-rule-active-${rule.id}'),
              value: rule.active,
              onChanged: canEdit && rule.id != null ? onActive : null,
            ),
            TextButton(
              key: ValueKey('c2c-rule-edit-${rule.id}'),
              onPressed: onEdit,
              child: Text(canEdit ? 'Edit' : 'View'),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// The rule (or the default) being edited, with the live example.
class C2cRuleEditor extends ConsumerStatefulWidget {
  const C2cRuleEditor({
    super.key,
    required this.rule,
    required this.settings,
    required this.places,
    this.isDefault = false,
    this.canEdit = true,
    this.canDelete = false,
  });

  final C2cRule rule;
  final C2cSettings settings;
  final List<C2cPlace> places;
  final bool isDefault, canEdit, canDelete;

  @override
  ConsumerState<C2cRuleEditor> createState() => _C2cRuleEditorState();
}

class _C2cRuleEditorState extends ConsumerState<C2cRuleEditor> {
  late C2cRule _r = widget.rule;

  void _set(C2cRule r) => setState(() => _r = r);

  /// The place the example starts from: the rule's first From place.
  Geo get _exampleFrom {
    final p = _r.from.firstOrNull;
    if (p == null) return const Geo();
    return Geo(
      country: p.country,
      state: p.rank >= 2 ? p.state : null,
      city: p.rank >= 3 ? p.city : null,
      suburb: p.rank >= 4 ? p.suburb : null,
    );
  }

  Future<void> _addPlace(bool from) async {
    final list = from ? _r.from : _r.to;
    final p = await pickC2cPlace(
      context,
      title: from ? 'Add to From' : 'Add to To',
      choices: widget.places,
      taken: list,
    );
    if (p == null) return;
    _set(from ? _r.copyWith(from: [..._r.from, p]) : _r.copyWith(to: [..._r.to, p]));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = widget.settings;
    final edit = widget.canEdit;
    final cur = s.currency;
    final ctx = ref.watch(c2cFareContextProvider).value;
    final card = c2cFareCard(
      ctx?.cards ?? const <FareTariff>[],
      _exampleFrom,
      c2cExampleKm,
      c2cExampleMin,
      vehicleService: ctx?.service.id,
      serviceTypes: ctx?.service.types ?? const {},
      rates: ctx?.service.rates,
      currency: cur,
    );
    final q = c2cQuoteFor(widget.isDefault ? null : _r, widget.isDefault ? s.copyWith(defaultRule: _r) : s,
        fareCard: card.fare, currency: card.currency);
    final problem = c2cRuleProblem(_r, isDefault: widget.isDefault) ??
        (q.inRange ? null : 'The suggested fare should sit inside the range (low at or below high).');
    final fixed = !widget.isDefault && _r.fareMode == C2cFareMode.fixed;
    VoidCallback? step(bool ok, C2cRule Function() next) => edit && ok ? () => _set(next()) : null;
    String money(double v) => c2cMoney(v, cur);
    String pct(double v) => '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}%';
    final fromName = _r.from.firstOrNull?.name;
    final lo = q.low ?? 0, hi = q.high ?? 0;

    final segStyle = SegmentedButton.styleFrom(visualDensity: VisualDensity.compact);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!widget.isDefault) ...[
        Text('From (one or more places)', style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        C2cPlaceChips(
          places: _r.from,
          keyPrefix: 'c2c-edit-from-',
          onRemove: edit ? (p) => _set(_r.copyWith(from: [..._r.from]..remove(p))) : null,
          onAdd: edit ? () => _addPlace(true) : null,
        ),
        const SizedBox(height: 12),
        Text('To (one or more places)', style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        C2cPlaceChips(
          places: _r.to,
          from: false,
          keyPrefix: 'c2c-edit-to-',
          onRemove: edit ? (p) => _set(_r.copyWith(to: [..._r.to]..remove(p))) : null,
          onAdd: edit ? () => _addPlace(false) : null,
        ),
        const Divider(height: 28),
      ] else
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Applies to any City to City trip that no rule matches. The fare is always the fare card plus this '
            'add-on (0 by default).',
            style: t.textTheme.bodyMedium,
          ),
        ),
      Text('How the fare is worked out', style: t.textTheme.titleSmall),
      const SizedBox(height: 6),
      SegmentedButton<C2cFareMode>(
        key: const ValueKey('c2c-edit-fare-mode'),
        style: segStyle,
        segments: [
          for (final m in C2cFareMode.values)
            ButtonSegment(value: m, label: Text(m.label), enabled: !(widget.isDefault && m == C2cFareMode.fixed)),
        ],
        selected: {fixed ? C2cFareMode.fixed : C2cFareMode.card},
        onSelectionChanged: edit
            ? (v) => _set(_r.copyWith(
                fareMode: v.first,
                fixedFare: v.first == C2cFareMode.fixed && _r.fixedFare == null ? c2cRound0(q.suggested) : null))
            : null,
      ),
      if (!fixed) ...[
        C2cStepper(
          label: 'Add-on, fixed',
          hint: '0 for none',
          value: money(_r.addOnAmount),
          valueKey: const ValueKey('c2c-edit-add-rm'),
          onDown: step(_r.addOnAmount >= 5, () => _r.copyWith(addOnAmount: _r.addOnAmount - 5)),
          onUp: step(_r.addOnAmount < 10000, () => _r.copyWith(addOnAmount: _r.addOnAmount + 5)),
        ),
        C2cStepper(
          label: 'Add-on, percent',
          hint: 'Of the fare card, 0 for none',
          value: pct(_r.addOnPercent),
          valueKey: const ValueKey('c2c-edit-add-pct'),
          onDown: step(_r.addOnPercent >= 1, () => _r.copyWith(addOnPercent: _r.addOnPercent - 1)),
          onUp: step(_r.addOnPercent < 500, () => _r.copyWith(addOnPercent: _r.addOnPercent + 1)),
        ),
      ] else
        C2cStepper(
          label: 'Fare per car',
          hint: 'Whole car',
          value: money(_r.fixedFare ?? 0),
          valueKey: const ValueKey('c2c-edit-fixed'),
          onDown: step((_r.fixedFare ?? 0) > 20, () => _r.copyWith(fixedFare: (_r.fixedFare ?? 0) - 5)),
          onUp: step(true, () => _r.copyWith(fixedFare: (_r.fixedFare ?? 0) + 5)),
        ),
      const Divider(height: 28),
      Text('Suggested range', style: t.textTheme.titleSmall),
      const SizedBox(height: 6),
      SegmentedButton<C2cRangeMode>(
        key: const ValueKey('c2c-edit-range-mode'),
        style: segStyle,
        segments: [for (final m in C2cRangeMode.values) ButtonSegment(value: m, label: Text(m.label))],
        selected: {_r.rangeMode},
        onSelectionChanged: edit
            ? (v) => _set(v.first == C2cRangeMode.set
                ? _r.copyWith(rangeMode: v.first, rangeLow: _r.rangeLow ?? lo, rangeHigh: _r.rangeHigh ?? hi)
                : _r.copyWith(rangeMode: v.first))
            : null,
      ),
      if (_r.rangeMode == C2cRangeMode.auto)
        C2cStepper(
          label: 'Plus or minus',
          hint: 'Around the suggestion, default 8',
          value: pct(_r.rangePercent),
          valueKey: const ValueKey('c2c-edit-range-pct'),
          onDown: step(_r.rangePercent > 1, () => _r.copyWith(rangePercent: _r.rangePercent - 1)),
          onUp: step(_r.rangePercent < 90, () => _r.copyWith(rangePercent: _r.rangePercent + 1)),
        )
      else ...[
        C2cStepper(
          label: 'Range low',
          hint: 'Most drivers accept from',
          value: money(_r.rangeLow ?? 0),
          valueKey: const ValueKey('c2c-edit-low'),
          onDown: step((_r.rangeLow ?? 0) > 5, () => _r.copyWith(rangeLow: (_r.rangeLow ?? 0) - 5)),
          onUp: step(true, () => _r.copyWith(rangeLow: (_r.rangeLow ?? 0) + 5)),
        ),
        C2cStepper(
          label: 'Range high',
          hint: 'Most drivers accept up to',
          value: money(_r.rangeHigh ?? 0),
          valueKey: const ValueKey('c2c-edit-high'),
          onDown: step((_r.rangeHigh ?? 0) > 5, () => _r.copyWith(rangeHigh: (_r.rangeHigh ?? 0) - 5)),
          onUp: step(true, () => _r.copyWith(rangeHigh: (_r.rangeHigh ?? 0) + 5)),
        ),
      ],
      const Divider(height: 28),
      Text('Riders can book up to', style: t.textTheme.titleSmall),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final d in {7, 14, 30, 60, _r.bookAheadDays}.toList()..sort())
          ChoiceChip(
            key: ValueKey('c2c-edit-ahead-$d'),
            label: Text('$d days'),
            selected: _r.bookAheadDays == d,
            onSelected: edit ? (_) => _set(_r.copyWith(bookAheadDays: d)) : null,
          ),
      ]),
      if (!widget.isDefault) ...[
        const Divider(height: 28),
        Text('Minimum years driving', style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        SegmentedButton<C2cYearsMode>(
          key: const ValueKey('c2c-edit-years-mode'),
          style: segStyle,
          segments: [for (final m in C2cYearsMode.values) ButtonSegment(value: m, label: Text(m.label))],
          selected: {_r.yearsMode},
          onSelectionChanged: edit
              ? (v) => _set(_r.copyWith(yearsMode: v.first, minYears: _r.minYears ?? s.minYears))
              : null,
        ),
        if (_r.yearsMode == C2cYearsMode.set)
          C2cStepper(
            label: 'Years',
            value: '${_r.minYears ?? s.minYears}',
            valueKey: const ValueKey('c2c-edit-years'),
            onDown: step((_r.minYears ?? s.minYears) > 1, () => _r.copyWith(minYears: (_r.minYears ?? s.minYears) - 1)),
            onUp: step((_r.minYears ?? s.minYears) < 60, () => _r.copyWith(minYears: (_r.minYears ?? s.minYears) + 1)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            switch (_r.yearsMode) {
              C2cYearsMode.byDefault => s.minYearsOn
                  ? 'Follows City to City settings: ${s.minYears} years.'
                  : 'Follows City to City settings: no minimum now.',
              C2cYearsMode.off => 'Any driver can take these trips.',
              C2cYearsMode.set => 'Only for this rule.',
            },
            style: t.textTheme.bodySmall,
          ),
        ),
      ],
      const SizedBox(height: 16),
      Container(
        key: const ValueKey('c2c-edit-example'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: t.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Suggested ${money(q.suggested)}, range ${money(lo)} to ${money(hi)}',
            key: const ValueKey('c2c-edit-example-head'),
            style: t.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            fixed
                ? 'Riders start at ${money(q.suggested)} and see "most drivers accept ${money(lo)} to ${money(hi)}". '
                    'The fare card is not used.'
                : 'Example: ${c2cExampleKm.toStringAsFixed(0)} km, 2 h 40 min'
                    '${fromName == null ? '' : ' from $fromName'}: fare card ${money(card.fare)}'
                    '${_r.addOnAmount > 0 ? ' + ${money(_r.addOnAmount)}' : ''}'
                    '${_r.addOnPercent > 0 ? ' + ${pct(_r.addOnPercent)}' : ''} = ${money(q.suggested)}. '
                    'Riders see "most drivers accept ${money(lo)} to ${money(hi)}".',
            key: const ValueKey('c2c-edit-example-text'),
            style: t.textTheme.bodySmall,
          ),
          if (!fixed)
            Text(
              card.card == null
                  ? 'No fare tariff covers this pickup: the service\'s own rates price it.'
                  : 'Fare card: ${describeFareTariff(card.card!)} (${card.card!.scope}).',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
        ]),
      ),
      if (problem != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            problem,
            key: const ValueKey('c2c-edit-problem'),
            style: TextStyle(color: t.colorScheme.error, fontWeight: FontWeight.w500),
          ),
        ),
      const SizedBox(height: 16),
      Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
        if (edit && widget.canDelete)
          TextButton.icon(
            key: const ValueKey('c2c-edit-delete'),
            onPressed: () => Navigator.pop<_Edit>(context, (rule: _r, delete: true)),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(edit ? 'Cancel' : 'Close')),
        if (edit) ...[
          FilledButton(
            key: const ValueKey('c2c-edit-save'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: problem == null ? () => Navigator.pop<_Edit>(context, (rule: _r, delete: false)) : null,
            child: const Text('Save'),
          ),
        ],
      ]),
    ]);
  }
}
