// The Rules section of Admin → Country / States / Cities → add / edit: a
// region's scheduled rules (service hours, bidding, taxes, surcharges) for
// some services at some times. See core/region_rules.dart for what they mean.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/region_rules.dart';
import 'geo_data.dart';
import 'geo_logic.dart';

IconData ruleKindIcon(RuleKind k) => switch (k) {
  RuleKind.availability => Icons.schedule,
  RuleKind.bidding => Icons.gavel_outlined,
  RuleKind.tax => Icons.receipt_long_outlined,
  RuleKind.surcharge => Icons.add_card_outlined,
};

/// "Car, Premium" from the ids a rule names; "All services" for none.
String ruleTargetLabel(RuleTarget t, Map<String, String> names) {
  if (t.isEverything) return 'All services';
  return [
    for (final id in t.categories) names[id] ?? 'Removed type',
    for (final id in t.vehicleTypes) names[id] ?? 'Removed vehicle',
  ].join(', ');
}

/// What the rule does, as the list shows it: "Bidding off", "SST 8%".
String ruleHeadline(RegionRule r) => switch (r.kind) {
  RuleKind.availability => r.on ? 'Service on' : 'Service off',
  RuleKind.bidding => r.on ? 'Bidding on' : 'Bidding off',
  RuleKind.tax || RuleKind.surcharge => r.chargeLabel(),
};

class RegionRulesSection extends ConsumerWidget {
  const RegionRulesSection({super.key, required this.rules, required this.onChanged});

  final List<RegionRule> rules;
  final ValueChanged<List<RegionRule>> onChanged;

  Future<void> _edit(BuildContext context, WidgetRef ref, {RuleKind? kind, RegionRule? rule}) async {
    final result = await showDialog<RegionRule>(
      context: context,
      builder: (_) => RegionRuleDialog(
        rule: rule ?? RegionRule(id: const Uuid().v4(), kind: kind!),
      ),
    );
    if (result == null) return;
    onChanged([
      for (final r in rules) r.id == result.id ? result : r,
      if (!rules.any((r) => r.id == result.id)) result,
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final names = {
      for (final s in ref.watch(regionServicesProvider).value ?? const <ServiceOption>[]) s.id: s.name,
      for (final s in ref.watch(regionVehicleTypesProvider).value ?? const <ServiceOption>[]) s.id: s.name,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.rule, size: 16, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: Text('Rules', style: t.textTheme.titleSmall)),
            PopupMenuButton<RuleKind>(
              key: const ValueKey('region-rule-add'),
              tooltip: 'Add a rule',
              onSelected: (k) => _edit(context, ref, kind: k),
              itemBuilder: (_) => [
                for (final k in RuleKind.values)
                  PopupMenuItem(
                    value: k,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(ruleKindIcon(k)),
                      title: Text(k.label),
                    ),
                  ),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Icon(Icons.add, size: 18), SizedBox(width: 4), Text('Add rule')],
                ),
              ),
            ),
          ],
        ),
        Text(
          'For some services, at some times: service hours, bidding on or off, taxes and surcharges. While a rule '
          'holds it overrides the switches above; the most specific region with a rule decides.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        if (rules.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('No rules.', style: t.textTheme.bodySmall),
          ),
        for (final r in rules)
          ListTile(
            key: ValueKey('region-rule-${r.id}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(ruleKindIcon(r.kind), color: r.enabled ? t.colorScheme.primary : t.colorScheme.outline),
            title: Text(
              '${r.kind.label}: ${ruleHeadline(r)}',
              style: r.enabled ? null : TextStyle(color: t.colorScheme.outline),
            ),
            subtitle: Text('${ruleTargetLabel(r.target, names)} · ${r.schedule.label}${r.enabled ? '' : ' · paused'}'),
            onTap: () => _edit(context, ref, rule: r),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: r.enabled,
                  onChanged: (v) => onChanged([for (final x in rules) x.id == r.id ? x.copyWith(enabled: v) : x]),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => onChanged([
                    for (final x in rules)
                      if (x.id != r.id) x,
                  ]),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Add / edit one rule.
class RegionRuleDialog extends ConsumerStatefulWidget {
  const RegionRuleDialog({super.key, required this.rule});

  final RegionRule rule;

  @override
  ConsumerState<RegionRuleDialog> createState() => _RegionRuleDialogState();
}

class _RegionRuleDialogState extends ConsumerState<RegionRuleDialog> {
  late RegionRule _r = widget.rule;
  late final _name = TextEditingController(text: widget.rule.name);
  late final _amount = TextEditingController(
    text: widget.rule.kind.isCharge && widget.rule.amount > 0 ? _fmt(widget.rule.amount) : '',
  );
  String? _error;

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _schedule(RuleSchedule s) => setState(() => _r = _r.copyWith(schedule: s));

  RuleSchedule _with({
    ScheduleMode? mode,
    Set<int>? days,
    DateTime? Function()? from,
    DateTime? Function()? to,
    bool? allDay,
    int? start,
    int? end,
  }) {
    final s = _r.schedule;
    return RuleSchedule(
      mode: mode ?? s.mode,
      days: days ?? s.days,
      from: from == null ? s.from : from(),
      to: to == null ? s.to : to(),
      allDay: allDay ?? s.allDay,
      start: start ?? s.start,
      end: end ?? s.end,
    );
  }

  Future<void> _pickDate(bool isFrom) async {
    final s = _r.schedule;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? s.from : s.to) ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    _schedule(isFrom ? _with(from: () => picked) : _with(to: () => picked));
  }

  Future<void> _pickTime(bool isStart) async {
    final s = _r.schedule;
    final m = isStart ? s.start : s.end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
    );
    if (picked == null) return;
    final v = picked.hour * 60 + picked.minute;
    _schedule(isStart ? _with(start: v) : _with(end: v));
  }

  void _save() {
    var r = _r;
    if (r.kind.isCharge) {
      r = r.copyWith(name: _name.text.trim(), amount: double.tryParse(_amount.text.trim()) ?? 0);
    }
    final problem = regionRuleProblem(r);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, r);
  }

  String _date(DateTime? d) =>
      d == null ? 'Any' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  String _hm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = _r;
    final s = r.schedule;
    final types = ref.watch(regionServicesProvider).value ?? const <ServiceOption>[];
    final vehicles = ref.watch(regionVehicleTypesProvider).value ?? const <ServiceOption>[];
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(text, style: t.textTheme.titleSmall),
    );

    return AlertDialog(
      title: Text(r.kind.label),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!r.kind.isCharge)
                SegmentedButton<bool>(
                  key: const ValueKey('rule-on'),
                  segments: [
                    ButtonSegment(value: true, label: Text(r.kind == RuleKind.bidding ? 'Bidding on' : 'Service on')),
                    ButtonSegment(
                      value: false,
                      label: Text(r.kind == RuleKind.bidding ? 'Bidding off' : 'Service off'),
                    ),
                  ],
                  selected: {r.on},
                  onSelectionChanged: (v) => setState(() => _r = _r.copyWith(on: v.first)),
                )
              else ...[
                TextField(
                  key: const ValueKey('rule-name'),
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    hintText: r.kind == RuleKind.tax ? 'e.g. SST' : 'e.g. Midnight surcharge',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SegmentedButton<ChargeKind>(
                      key: const ValueKey('rule-charge'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: ChargeKind.percent, label: Text('%')),
                        ButtonSegment(value: ChargeKind.fixed, label: Text('Fixed')),
                      ],
                      selected: {r.charge},
                      onSelectionChanged: (v) => setState(() => _r = _r.copyWith(charge: v.first)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('rule-amount'),
                        controller: _amount,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: r.charge == ChargeKind.percent ? 'Percent of the fare' : 'Amount',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              label('Services'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilterChip(
                    key: const ValueKey('rule-target-all'),
                    label: const Text('All services'),
                    selected: r.target.isEverything,
                    onSelected: (_) => setState(() => _r = _r.copyWith(target: RuleTarget.everything)),
                  ),
                  for (final c in types)
                    FilterChip(
                      key: ValueKey('rule-type-${c.id}'),
                      avatar: const Icon(Icons.category_outlined, size: 16),
                      label: Text(c.name),
                      selected: r.target.categories.contains(c.id),
                      onSelected: (on) => setState(() {
                        final t = _r.target;
                        _r = _r.copyWith(
                          target: RuleTarget(
                            categories: on ? {...t.categories, c.id} : ({...t.categories}..remove(c.id)),
                            vehicleTypes: t.vehicleTypes,
                          ),
                        );
                      }),
                    ),
                  for (final v in vehicles)
                    FilterChip(
                      key: ValueKey('rule-vehicle-${v.id}'),
                      avatar: const Icon(Icons.directions_car_outlined, size: 16),
                      label: Text(v.name),
                      selected: r.target.vehicleTypes.contains(v.id),
                      onSelected: (on) => setState(() {
                        final t = _r.target;
                        _r = _r.copyWith(
                          target: RuleTarget(
                            categories: t.categories,
                            vehicleTypes: on ? {...t.vehicleTypes, v.id} : ({...t.vehicleTypes}..remove(v.id)),
                          ),
                        );
                      }),
                    ),
                ],
              ),
              Text(
                'A service type (Car, Bike, …) covers every vehicle in it; a vehicle (Ride, Premium, …) just that one.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              label('When'),
              SegmentedButton<ScheduleMode>(
                key: const ValueKey('rule-mode'),
                showSelectedIcon: false,
                segments: [for (final m in ScheduleMode.values) ButtonSegment(value: m, label: Text(m.label))],
                selected: {s.mode},
                onSelectionChanged: (v) => _schedule(_with(mode: v.first)),
              ),
              if (s.mode == ScheduleMode.days) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        key: ValueKey('rule-day-$d'),
                        label: Text(_days[d - 1]),
                        selected: s.days.contains(d),
                        onSelected: (on) {
                          final days = _r.schedule.days;
                          _schedule(_with(days: on ? {...days, d} : ({...days}..remove(d))));
                        },
                      ),
                  ],
                ),
              ],
              if (s.mode == ScheduleMode.dates) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('rule-from'),
                        icon: const Icon(Icons.event, size: 18),
                        label: Text('From ${_date(s.from)}'),
                        onPressed: () => _pickDate(true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('rule-to'),
                        icon: const Icon(Icons.event, size: 18),
                        label: Text('To ${_date(s.to)}'),
                        onPressed: () => _pickDate(false),
                      ),
                    ),
                  ],
                ),
              ],
              SwitchListTile(
                key: const ValueKey('rule-all-day'),
                contentPadding: EdgeInsets.zero,
                title: const Text('All day'),
                subtitle: s.allDay ? null : const Text('A range past midnight (22:00–06:00) runs into the next day.'),
                value: s.allDay,
                onChanged: (v) => _schedule(_with(allDay: v, start: v ? 0 : 9 * 60, end: v ? 0 : 17 * 60)),
              ),
              if (!s.allDay)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('rule-start'),
                        icon: const Icon(Icons.schedule, size: 18),
                        label: Text('From ${_hm(s.start)}'),
                        onPressed: () => _pickTime(true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('rule-end'),
                        icon: const Icon(Icons.schedule, size: 18),
                        label: Text('To ${_hm(s.end)}'),
                        onPressed: () => _pickTime(false),
                      ),
                    ),
                  ],
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    key: const ValueKey('rule-error'),
                    style: TextStyle(color: t.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('rule-save'), onPressed: _save, child: const Text('Done')),
      ],
    );
  }
}
