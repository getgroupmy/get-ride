import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/partner_type_rules.dart';
import '../../../core/permits.dart' show PermitType;
import '../../../widgets/common.dart' show showNotice;
import '../../../widgets/search_select.dart';
import '../../widgets/region_scope_picker.dart';
import '../people/vehicle_permits_screen.dart' show adminPermitTypesProvider;
import 'catalogue_widgets.dart';
import 'partner_type_rules_editor.dart' show RegionListEditor;

/// The Partner Service type editor's registration settings: where only
/// citizens may join, where a registered business is required, the driver
/// permit, and, for a vehicle service, the vehicle permit (uploaded by
/// GET.ride, never the driver), which other types' vehicles also need it, and
/// whose age limits this type's limit covers.
class PartnerServiceSettingsEditor extends StatelessWidget {
  const PartnerServiceSettingsEditor({
    super.key,
    required this.settings,
    required this.vehicleRequired,
    required this.ageRequired,
    required this.otherTypes,
    required this.onChanged,
  });

  final PartnerServiceSettings settings;
  final bool vehicleRequired;

  /// The max vehicle age limit is on: the age cover shows.
  final bool ageRequired;

  /// The other Partner Service types' names, in their order.
  final List<String> otherTypes;
  final ValueChanged<PartnerServiceSettings> onChanged;

  PartnerServiceSettings get _s => settings;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('Partner registration', hint: 'What registration asks of partners of this type, by region.'),
      SwitchListTile(
        key: const ValueKey('pst-citizens-required'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Citizens only'),
        subtitle: const Text('Only citizens may join in these regions. Registration shows a notice and the admin checks '
            'the nationality on the ID.'),
        value: _s.citizensOnly.required,
        onChanged: (v) => onChanged(_s.copyWith(citizensOnly: _s.citizensOnly.copyWith(required: v))),
      ),
      if (_s.citizensOnly.required)
        RegionListEditor(
          keyPrefix: 'citizens',
          value: _s.citizensOnly.where,
          title: 'Citizens only in',
          onChanged: (l) => onChanged(_s.copyWith(citizensOnly: _s.citizensOnly.copyWith(where: l))),
        ),
      SwitchListTile(
        key: const ValueKey('pst-business-required'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Business registration'),
        subtitle: const Text('A registered business (company) is required in these regions. Registration asks for '
            'the company registration and fills in the company details from it.'),
        value: _s.businessRegistration.required,
        onChanged: (v) =>
            onChanged(_s.copyWith(businessRegistration: _s.businessRegistration.copyWith(required: v))),
      ),
      if (_s.businessRegistration.required)
        RegionListEditor(
          keyPrefix: 'business',
          value: _s.businessRegistration.where,
          title: 'Business registration required in',
          onChanged: (l) =>
              onChanged(_s.copyWith(businessRegistration: _s.businessRegistration.copyWith(where: l))),
        ),
      SwitchListTile(
        key: const ValueKey('pst-driver-permit-required'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Driver permit'),
        subtitle: const Text('The driver uploads this permit during registration (for example Kad Pemandu, issued by '
            'APAD, in Malaysia).'),
        value: _s.driverPermit.required,
        onChanged: (v) => onChanged(_s.copyWith(driverPermit: _s.driverPermit.copyWith(required: v))),
      ),
      if (_s.driverPermit.required)
        PermitRulesEditor(
          keyPrefix: 'driver-permit',
          value: _s.driverPermit,
          forDriver: true,
          onChanged: (p) => onChanged(_s.copyWith(driverPermit: p)),
        ),
      if (vehicleRequired) ...[
        SwitchListTile(
          key: const ValueKey('pst-vehicle-permit-required'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Vehicle permit'),
          subtitle: const Text('Each vehicle needs this permit in these regions. GET.ride or the admin uploads it in '
              'Vehicle permits, never the driver; the service stays off for that vehicle until it is uploaded.'),
          value: _s.vehiclePermit.required,
          onChanged: (v) => onChanged(_s.copyWith(vehiclePermit: _s.vehiclePermit.copyWith(required: v))),
        ),
        if (_s.vehiclePermit.required) ...[
          PermitRulesEditor(
            keyPrefix: 'vehicle-permit',
            value: _s.vehiclePermit,
            forDriver: false,
            onChanged: (p) => onChanged(_s.copyWith(vehiclePermit: p)),
          ),
          _TypeChips(
            keyPrefix: 'vehicle-permit-also',
            title: 'Also needed by',
            hint: "Vehicles registered for these types need this permit too when they do this service (a taxi "
                "doing eHailing). Others don't (a motorbike).",
            options: otherTypes,
            selected: _s.vehiclePermitAlsoFor,
            onChanged: (l) => onChanged(_s.copyWith(vehiclePermitAlsoFor: l)),
          ),
        ],
        if (ageRequired)
          _AgeCoverEditor(
            rules: _s.ageLimitCovers,
            otherTypes: otherTypes,
            onChanged: (l) => onChanged(_s.copyWith(ageLimitCovers: l)),
          ),
      ],
    ]);
  }
}

/// A permit's regions, each with its name and issuer, typed or filled from
/// Admin → Vehicle permits → Permit types.
class PermitRulesEditor extends ConsumerStatefulWidget {
  const PermitRulesEditor({
    super.key,
    required this.keyPrefix,
    required this.value,
    required this.forDriver,
    required this.onChanged,
  });

  final String keyPrefix;
  final PermitRequirement value;
  final bool forDriver;
  final ValueChanged<PermitRequirement> onChanged;

  @override
  ConsumerState<PermitRulesEditor> createState() => _PermitRulesEditorState();
}

class _PermitRulesEditorState extends ConsumerState<PermitRulesEditor> {
  late final List<(TextEditingController, TextEditingController)> _fields = [
    for (final r in widget.value.rules) _controllers(r),
  ];

  (TextEditingController, TextEditingController) _controllers(PermitRule r) =>
      (TextEditingController(text: r.name), TextEditingController(text: r.issuer));

  List<PermitRule> get _rules => widget.value.rules;

  String get _what => widget.forDriver ? 'Driver permit' : 'Vehicle permit';

  @override
  void dispose() {
    for (final (a, b) in _fields) {
      a.dispose();
      b.dispose();
    }
    super.dispose();
  }

  void _set(List<PermitRule> rules) => widget.onChanged(widget.value.copyWith(rules: rules));

  void _replace(int i, PermitRule r) => _set([..._rules]..[i] = r);

  Future<void> _add() async {
    final scope = await pickRegionScope(context, title: '$_what required in', allowAll: true);
    if (scope == null || !mounted) return;
    if (_rules.any((x) => x.scope.key == scope.key)) {
      await showNotice(context, message: 'There is already a rule for ${scope.label}.');
      return;
    }
    _fields.add(_controllers(const PermitRule()));
    _set([..._rules, PermitRule(scope: scope)]);
  }

  Future<void> _changeScope(int i) async {
    final scope = await pickRegionScope(
      context,
      title: '$_what required in',
      allowAll: true,
      initial: _rules[i].scope,
    );
    if (scope == null || !mounted) return;
    _replace(i, _rules[i].copyWith(scope: scope));
  }

  void _remove(int i) {
    final (a, b) = _fields.removeAt(i);
    a.dispose();
    b.dispose();
    _set([..._rules]..removeAt(i));
  }

  /// Fills the name and issuer from one of the country's permit types.
  Future<void> _fromPermitTypes(int i) async {
    List<PermitType> all;
    try {
      all = await ref.read(adminPermitTypesProvider.future);
    } catch (_) {
      all = const [];
    }
    if (!mounted) return;
    final country = _rules[i].scope.country.toLowerCase();
    final options = [
      for (final t in all)
        if (t.active && t.forDriver == widget.forDriver && (country.isEmpty || t.country.toLowerCase() == country)) t,
    ];
    if (options.isEmpty) {
      await showNotice(
        context,
        title: 'No permit types',
        message: 'There are no ${widget.forDriver ? 'driver' : 'vehicle'} permit types'
            '${country.isEmpty ? '' : ' for ${_rules[i].scope.country}'} yet. Add them in Vehicle permits, '
            'or type the name here.',
      );
      return;
    }
    final picked = await showSearchPicker<PermitType>(
      context,
      title: 'Permit type',
      choices: [
        for (final t in options)
          (
            value: t,
            label: t.name,
            subtitle: [if (t.issuer.isNotEmpty) t.issuer, if (country.isEmpty) t.country].join(' · '),
            leading: null,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    _fields[i].$1.text = picked.name;
    _fields[i].$2.text = picked.issuer;
    _replace(i, _rules[i].copyWith(name: picked.name, issuer: picked.issuer, permitType: picked.key));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = widget.keyPrefix;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < _rules.length; i++)
          Card(
            key: ValueKey('$p-rule-$i'),
            margin: const EdgeInsets.only(bottom: 8),
            color: cs.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TextButton.icon(
                      key: ValueKey('$p-region-$i'),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                      onPressed: () => _changeScope(i),
                      icon: const Icon(Icons.place_outlined, size: 18),
                      label: Text(_rules[i].scope.label, overflow: TextOverflow.ellipsis),
                    ),
                    TextField(
                      key: ValueKey('$p-name-$i'),
                      controller: _fields[i].$1,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Permit name',
                        hintText: widget.forDriver ? 'Kad Pemandu' : 'EVP',
                      ),
                      // Typed by hand: no longer the permit type picked.
                      onChanged: (t) => _replace(i, _rules[i].copyWith(name: t, permitType: '')),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: ValueKey('$p-issuer-$i'),
                      controller: _fields[i].$2,
                      decoration: const InputDecoration(labelText: 'Issued by (optional)', hintText: 'APAD'),
                      onChanged: (t) => _replace(i, _rules[i].copyWith(issuer: t)),
                    ),
                    TextButton.icon(
                      key: ValueKey('$p-from-types-$i'),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: () => _fromPermitTypes(i),
                      icon: const Icon(Icons.badge_outlined, size: 18),
                      label: Text(_rules[i].permitType.isEmpty ? 'Choose from permit types' : 'From permit types'),
                    ),
                  ]),
                ),
                IconButton(
                  tooltip: 'Remove rule',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _remove(i),
                ),
              ]),
            ),
          ),
        if (_rules.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('No regions yet. The narrowest rule that matches a region wins.',
                style: TextStyle(color: cs.error)),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('$p-add'),
            onPressed: _add,
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('Add region'),
          ),
        ),
      ]),
    );
  }
}

/// Per region, the other types whose max vehicle age this type's limit
/// replaces for a vehicle registered for this type.
class _AgeCoverEditor extends StatelessWidget {
  const _AgeCoverEditor({required this.rules, required this.otherTypes, required this.onChanged});

  final List<AgeCoverRule> rules;
  final List<String> otherTypes;
  final ValueChanged<List<AgeCoverRule>> onChanged;

  Future<void> _add(BuildContext context) async {
    final scope = await pickRegionScope(context, title: 'The age limit covers others in', allowAll: true);
    if (scope == null || !context.mounted) return;
    if (rules.any((r) => r.scope.key == scope.key)) {
      await showNotice(context, message: 'There is already a rule for ${scope.label}.');
      return;
    }
    onChanged([...rules, AgeCoverRule(scope: scope)]);
  }

  Future<void> _changeScope(BuildContext context, int i) async {
    final scope = await pickRegionScope(
      context,
      title: 'The age limit covers others in',
      allowAll: true,
      initial: rules[i].scope,
    );
    if (scope == null || !context.mounted) return;
    onChanged([...rules]..[i] = rules[i].copyWith(scope: scope));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel(
        "This type's age limit also covers",
        hint: "For a vehicle registered for this type, its max vehicle age replaces the limit of these types "
            "(a taxi's 20 years also covers eHailing's 15).",
      ),
      for (var i = 0; i < rules.length; i++)
        Card(
          key: ValueKey('age-cover-rule-$i'),
          margin: const EdgeInsets.only(bottom: 8),
          color: cs.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: ValueKey('age-cover-region-$i'),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: () => _changeScope(context, i),
                      icon: const Icon(Icons.place_outlined, size: 18),
                      label: Text(rules[i].scope.label, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  _TypeChips(
                    keyPrefix: 'age-cover-$i',
                    options: otherTypes,
                    selected: rules[i].types,
                    onChanged: (l) => onChanged([...rules]..[i] = rules[i].copyWith(types: l)),
                  ),
                ]),
              ),
              IconButton(
                tooltip: 'Remove rule',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => onChanged([...rules]..removeAt(i)),
              ),
            ]),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('age-cover-add'),
          onPressed: () => _add(context),
          icon: const Icon(Icons.add),
          label: const Text('Add region'),
        ),
      ),
    ]);
  }
}

/// Tick chips of Partner Service type names, searchable when long.
class _TypeChips extends StatelessWidget {
  const _TypeChips({
    required this.keyPrefix,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.title,
    this.hint,
  });

  final String keyPrefix;
  final List<String> options;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final String? title;
  final String? hint;

  bool _on(String o) => selected.any((s) => partnerTypeNameKey(s) == partnerTypeNameKey(o));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // A stored name no longer among the types still shows, to be unticked.
    final all = [
      ...options,
      for (final s in selected)
        if (!options.any((o) => partnerTypeNameKey(o) == partnerTypeNameKey(s))) s,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null) SectionLabel(title!, hint: hint),
        if (all.isEmpty)
          Text('No other Partner Service types yet.', style: TextStyle(color: cs.onSurfaceVariant))
        else
          ListSearchFilter(
            count: all.length,
            hint: 'Search Partner Service types',
            fieldKey: ValueKey('$keyPrefix-search'),
            builder: (_, q) => Wrap(spacing: 6, runSpacing: 6, children: [
              for (final o in all)
                if (q.isEmpty || o.toLowerCase().contains(q.toLowerCase()))
                  FilterChip(
                    key: ValueKey('$keyPrefix-${partnerTypeNameKey(o)}'),
                    label: Text(o),
                    selected: _on(o),
                    onSelected: (v) => onChanged(v
                        ? [...selected, o]
                        : [for (final s in selected) if (partnerTypeNameKey(s) != partnerTypeNameKey(o)) s]),
                  ),
            ]),
          ),
      ]),
    );
  }
}
