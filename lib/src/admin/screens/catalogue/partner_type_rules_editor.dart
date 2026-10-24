import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/partner_type_rules.dart';
import '../../../widgets/common.dart' show showError;
import '../../../widgets/search_select.dart';
import '../../widgets/region_scope_picker.dart';
import 'catalogue_widgets.dart';

/// The Partner Type editor's rules (migration 0245): the vehicle age limit,
/// the permit and street hail — shown only with "Vehicle service" on — and
/// where the type is offered, for every type.
class PartnerTypeRulesEditor extends StatefulWidget {
  const PartnerTypeRulesEditor({
    super.key,
    required this.rules,
    required this.vehicleRequired,
    required this.isTeksi,
    required this.onChanged,
    this.showErrors = false,
  });

  final PartnerTypeRules rules;
  final bool vehicleRequired;

  /// TEKSI keeps street hail when it was never set.
  final bool isTeksi;
  final ValueChanged<PartnerTypeRules> onChanged;

  /// Save was pressed: wrong ages say so under their field.
  final bool showErrors;

  @override
  State<PartnerTypeRulesEditor> createState() => _PartnerTypeRulesEditorState();
}

class _PartnerTypeRulesEditorState extends State<PartnerTypeRulesEditor> {
  late final List<TextEditingController> _ages = [
    for (final r in widget.rules.ageRules) TextEditingController(text: r.maxYears == 0 ? '' : '${r.maxYears}'),
  ];

  PartnerTypeRules get _r => widget.rules;

  @override
  void dispose() {
    for (final c in _ages) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(PartnerTypeRules r) => widget.onChanged(r);

  Future<void> _addAgeRule() async {
    final scope = await pickRegionScope(context, title: 'Age limit applies to', allowAll: true);
    if (scope == null || !mounted) return;
    if (_r.ageRules.any((x) => x.scope.key == scope.key)) {
      showError(context, 'There is already a rule for ${scope.label}.');
      return;
    }
    _ages.add(TextEditingController());
    _set(_r.copyWith(ageRules: [..._r.ageRules, AgeRule(scope: scope, maxYears: 0)]));
  }

  Future<void> _changeAgeScope(int i) async {
    final scope = await pickRegionScope(
      context,
      title: 'Age limit applies to',
      allowAll: true,
      initial: _r.ageRules[i].scope,
    );
    if (scope == null || !mounted) return;
    final list = [..._r.ageRules];
    list[i] = list[i].copyWith(scope: scope);
    _set(_r.copyWith(ageRules: list));
  }

  void _removeAgeRule(int i) {
    _ages.removeAt(i).dispose();
    _set(_r.copyWith(ageRules: [..._r.ageRules]..removeAt(i)));
  }

  void _setAge(int i, String text) {
    final list = [..._r.ageRules];
    list[i] = list[i].copyWith(maxYears: int.tryParse(text.trim()) ?? 0);
    _set(_r.copyWith(ageRules: list));
  }

  Widget _ageRules() {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < _r.ageRules.length; i++)
        Card(
          key: ValueKey('age-rule-$i'),
          margin: const EdgeInsets.only(bottom: 8),
          color: cs.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  TextButton.icon(
                    key: ValueKey('age-rule-region-$i'),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                    onPressed: () => _changeAgeScope(i),
                    icon: const Icon(Icons.place_outlined, size: 18),
                    label: Text(_r.ageRules[i].scope.label, overflow: TextOverflow.ellipsis),
                  ),
                  TextField(
                    key: ValueKey('age-rule-years-$i'),
                    controller: _ages[i],
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                    decoration: InputDecoration(
                      labelText: 'Max vehicle age (years)',
                      helperText: 'From the vehicle\'s year: $minVehicleAgeYears to $maxVehicleAgeYears',
                      errorText: widget.showErrors &&
                              (_r.ageRules[i].maxYears < minVehicleAgeYears || _r.ageRules[i].maxYears > maxVehicleAgeYears)
                          ? 'Enter $minVehicleAgeYears to $maxVehicleAgeYears years'
                          : null,
                    ),
                    onChanged: (t) => _setAge(i, t),
                  ),
                ]),
              ),
              IconButton(
                tooltip: 'Remove rule',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _removeAgeRule(i),
              ),
            ]),
          ),
        ),
      if (_r.ageRules.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('No rules yet. The narrowest rule that matches a region wins.',
              style: TextStyle(color: cs.onSurfaceVariant)),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('age-rule-add'),
          onPressed: _addAgeRule,
          icon: const Icon(Icons.add),
          label: const Text('Add age rule'),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final hailOn = _r.hailAllowed ?? widget.isTeksi;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.vehicleRequired) ...[
        const Divider(height: 24),
        SwitchListTile(
          key: const ValueKey('rule-age-required'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Max vehicle age limit'),
          subtitle: const Text('Required: vehicles older than the limit are refused.'),
          value: _r.ageRequired,
          onChanged: (v) => _set(_r.copyWith(ageRequired: v)),
        ),
        if (_r.ageRequired) _ageRules(),
        SwitchListTile(
          key: const ValueKey('rule-permit-required'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Permit'),
          subtitle: const Text('Required: the permit document is compulsory in these regions.'),
          value: _r.permitRequired,
          onChanged: (v) => _set(_r.copyWith(permitRequired: v)),
        ),
        if (_r.permitRequired)
          RegionListEditor(
            keyPrefix: 'permit',
            value: _r.permitRegions,
            title: 'Permit required in',
            onChanged: (l) => _set(_r.copyWith(permitRegions: l)),
          ),
        SwitchListTile(
          key: const ValueKey('rule-hail-allowed'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow hail service'),
          subtitle: const Text('Street hail on the meter (TEKSI).'),
          value: hailOn,
          onChanged: (v) => _set(_r.copyWith(hailAllowed: v)),
        ),
        if (hailOn)
          RegionListEditor(
            keyPrefix: 'hail',
            value: _r.hailRegions,
            title: 'Street hail allowed in',
            onChanged: (l) => _set(_r.copyWith(hailRegions: l)),
          ),
      ],
      const SectionLabel('Service availability', hint: 'Where this Partner Service type can be chosen and gets jobs.'),
      RegionListEditor(
        keyPrefix: 'availability',
        value: _r.availability,
        title: 'Offered in',
        onChanged: (l) => _set(_r.copyWith(availability: l)),
      ),
    ]);
  }
}

/// "All regions" or a picked list of country / state / city / suburb.
class RegionListEditor extends StatelessWidget {
  const RegionListEditor({
    super.key,
    required this.keyPrefix,
    required this.value,
    required this.title,
    required this.onChanged,
  });

  final String keyPrefix;
  final RegionList value;
  final String title;
  final ValueChanged<RegionList> onChanged;

  Future<void> _add(BuildContext context) async {
    final scope = await pickRegionScope(context, title: title);
    if (scope == null || scope.isAll || !context.mounted) return;
    if (value.regions.any((r) => r.key == scope.key)) return;
    onChanged(value.copyWith(regions: [...value.regions, scope]));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<bool>(
          key: ValueKey('$keyPrefix-scope'),
          segments: const [
            ButtonSegment(value: true, label: Text('All regions'), icon: Icon(Icons.public)),
            ButtonSegment(value: false, label: Text('Selected'), icon: Icon(Icons.place_outlined)),
          ],
          selected: {value.all},
          onSelectionChanged: (s) => onChanged(value.copyWith(all: s.first)),
        ),
        if (!value.all) ...[
          const SizedBox(height: 8),
          ListSearchFilter(
            count: value.regions.length,
            hint: 'Search regions',
            fieldKey: ValueKey('$keyPrefix-search'),
            builder: (_, q) {
              final shown = [
                for (final r in value.regions)
                  if (q.isEmpty || r.label.toLowerCase().contains(q.toLowerCase())) r,
              ];
              return Wrap(spacing: 6, runSpacing: 6, children: [
                for (final r in shown)
                  InputChip(
                    key: ValueKey('$keyPrefix-region-${r.key}'),
                    label: Text(r.label),
                    onDeleted: () => onChanged(value.copyWith(regions: [...value.regions]..remove(r))),
                  ),
                if (value.regions.isEmpty)
                  Text('No regions picked yet.', style: TextStyle(color: cs.error)),
              ]);
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('$keyPrefix-add'),
              onPressed: () => _add(context),
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('Add region'),
            ),
          ),
        ],
      ]),
    );
  }
}
