// The values of a business rule or an account's overrides (migration 0313),
// each with its stepper: on the Default every value is set; on a region
// rule or an account each value is switched on to set it there, else it
// follows the rule above ([base]).
import 'package:flutter/material.dart';

import '../../../core/business_accounts.dart';
import '../../../features/business/business_widgets.dart';

/// What a value starts at when it is switched on with nothing above it.
Object _start(BusinessField f) => switch (f) {
  BusinessField.terms => BusinessTerms.invoice,
  BusinessField.services => {...BusinessService.values},
  BusinessField.dueDays || BusinessField.overdueDays => f.min.toInt(),
  _ => f.min.toDouble(),
};

class BusinessValuesEditor extends StatelessWidget {
  const BusinessValuesEditor({
    super.key,
    required this.values,
    required this.base,
    required this.onChanged,
    this.all = false,
    this.followsLabel = 'Follows the rule above',
  });

  /// What is set here.
  final BusinessValues values;

  /// What applies where a value isn't set here.
  final BusinessValues base;

  /// Null: read-only.
  final ValueChanged<BusinessValues>? onChanged;

  /// The Default: every value is set, nothing to switch.
  final bool all;
  final String followsLabel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rows = <Widget>[];
    for (final f in BusinessField.values) {
      final own = values.valueOf(f);
      final inherited = base.valueOf(f);
      final on = all || own != null;
      final shown = own ?? inherited;
      void set(Object? v) => onChanged?.call(values.copyWithField(f, v));
      final toggle = all
          ? null
          : Switch(
              key: ValueKey('biz-set-${f.name}'),
              value: on,
              onChanged: onChanged == null
                  ? null
                  : (v) => set(v ? (inherited ?? _start(f)) : null),
            );
      Widget body;
      if (f.isNumber) {
        final cur = (shown ?? f.min) as num;
        body = BusinessStepper(
          label: f.label,
          hint: on ? null : '$followsLabel: ${f.show(inherited)}',
          value: f.show(shown),
          valueKey: ValueKey('biz-value-${f.name}'),
          leading: toggle,
          onDown: !on || onChanged == null || cur <= f.min ? null : () => set(f.stepped(shown, -1)),
          onUp: !on || onChanged == null || cur >= f.max ? null : () => set(f.stepped(shown, 1)),
        );
      } else if (f == BusinessField.terms) {
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ?toggle,
            Expanded(child: Text(f.label, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500))),
          ]),
          if (!on)
            Text('$followsLabel: ${f.show(inherited)}', style: t.textTheme.bodySmall)
          else
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SegmentedButton<BusinessTerms>(
                key: const ValueKey('biz-terms'),
                segments: [for (final x in BusinessTerms.values) ButtonSegment(value: x, label: Text(x.label))],
                selected: {(shown as BusinessTerms?) ?? BusinessTerms.invoice},
                onSelectionChanged: onChanged == null ? null : (s) => set(s.first),
              ),
            ),
        ]);
      } else {
        final picked = (shown as Set<BusinessService>?) ?? const <BusinessService>{};
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ?toggle,
            Expanded(child: Text(f.label, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500))),
          ]),
          if (!on)
            Text('$followsLabel: ${f.show(inherited)}', style: t.textTheme.bodySmall)
          else
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final s in BusinessService.values)
                FilterChip(
                  key: ValueKey('biz-service-${s.name}'),
                  label: Text(s.label),
                  selected: picked.contains(s),
                  onSelected: onChanged == null
                      ? null
                      : (v) => set(v ? {...picked, s} : ({...picked}..remove(s))),
                ),
            ]),
        ]);
      }
      rows.add(Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: body));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}
