// Admin > Display Settings > Ride Options > Add-ons, cover and cash on
// delivery (migration 0312, the Admin board): a Default rule and a rule per
// region (country, state, city, suburb; the pickup's most specific region
// wins). A region rule only lists what differs; anything not set follows the
// rule above. Each add-on has a switch per rule, its values on steppers, and
// the two lists (excluded items, temperature levels) edited in their cards.
// Parcel cover claims are decided on their own page.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config.dart' show AppConfig;
import '../../../core/delivery_addons.dart';
import '../../../core/format.dart' show formatDateTime, formatMoney;
import '../../../core/partner_type_rules.dart' show RegionScope;
import '../../../core/ride_option_places.dart' show OptionPlaceScope;
import '../../../data/delivery_addons_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../../features/ride/delivery_addons_parts.dart' show AddonStepButton;
import '../geo/geo_data.dart' show regionsProvider;
import '../geo/geo_logic.dart' show RegionEntry, regionCurrency;
import 'display_screen.dart' show displayPage;

/// "State, Malaysia" for a region rule; Default's own words.
String addonRuleScopeText(RegionScope s) {
  if (s.isAll) return 'Everywhere without its own rule';
  final level = s.level;
  final above = s.parent?.path.reversed.join(', ') ?? '';
  final kind = '${level[0].toUpperCase()}${level.substring(1)}';
  return above.isEmpty ? kind : '$kind, $above';
}

/// The rules to list: Default, then every region rule (and any picked but
/// not yet saved), by name.
List<RegionScope> addonRuleScopes(AddonRules rules, Iterable<RegionScope> extra) {
  final out = <String, RegionScope>{'': RegionScope.all};
  for (final r in rules.rows) {
    out.putIfAbsent(r.scope.key, () => r.scope);
  }
  for (final s in extra) {
    out.putIfAbsent(s.key, () => s);
  }
  final list = out.values.where((s) => !s.isAll).toList()
    ..sort((a, b) => a.path.join('\u0000').toLowerCase().compareTo(b.path.join('\u0000').toLowerCase()));
  return [RegionScope.all, ...list];
}

const _icons = <DeliveryAddon, IconData>{
  DeliveryAddon.cover: Icons.verified_user_outlined,
  DeliveryAddon.roundTrip: Icons.sync_alt,
  DeliveryAddon.stairs: Icons.stairs_outlined,
  DeliveryAddon.cold: Icons.ac_unit,
  DeliveryAddon.cod: Icons.payments_outlined,
};

class DeliveryAddonsScreen extends ConsumerStatefulWidget {
  const DeliveryAddonsScreen({super.key});

  @override
  ConsumerState<DeliveryAddonsScreen> createState() => _DeliveryAddonsScreenState();
}

class _DeliveryAddonsScreenState extends ConsumerState<DeliveryAddonsScreen> {
  RegionScope _sel = RegionScope.all;
  final _picked = <RegionScope>[];
  final _item = TextEditingController();

  @override
  void dispose() {
    _item.dispose();
    super.dispose();
  }

  Future<void> _edit(AddonRules rules, AddonRule Function(AddonRule) f) async {
    final next = f(rules.at(_sel));
    await runAdminAction(context, () => ref.read(deliveryAddonsRepositoryProvider).save(next));
    ref.invalidate(deliveryAddonRulesProvider);
  }

  Future<void> _addRule(AddonRules rules, List<RegionEntry> regions) async {
    final taken = addonRuleScopes(rules, _picked).map((s) => s.key).toSet();
    final choices = <SearchChoice<RegionScope>>[];
    final seen = <String>{};
    for (final r in regions) {
      final s = RegionScope(country: r.country, state: r.state, city: r.city, suburb: r.suburb);
      if (s.isAll || taken.contains(s.key) || !seen.add(s.key)) continue;
      choices.add((value: s, label: s.placeName, subtitle: addonRuleScopeText(s), leading: null));
    }
    if (choices.isEmpty) return showInfo(context, 'Every region already has a rule. Add regions under Geo first.');
    final picked = await showSearchPicker<RegionScope>(context, title: 'Add a region rule', choices: choices);
    if (picked == null || !mounted) return;
    setState(() {
      _picked.add(picked);
      _sel = picked;
    });
  }

  Future<String?> _askName({String initial = '', required String title}) async {
    final v = await showAppDialog<String>(
      id: 'display.addon-level-name',
      context: context,
      builder: (_) => _NameDialog(title: title, initial: initial),
    );
    return v == null || v.trim().isEmpty ? null : v.trim();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add-ons, cover and cash on delivery'),
        actions: [
          TextButton.icon(
            key: const ValueKey('addons-claims'),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Cover claims'),
            onPressed: () => Navigator.of(context).push(
              AppPageRoute(id: 'display.cover-claims', builder: (_) => const CoverClaimsScreen()),
            ),
          ),
        ],
      ),
      body: AsyncView(
        value: ref.watch(deliveryAddonRulesProvider),
        onRetry: () => ref.invalidate(deliveryAddonRulesProvider),
        data: (rules) => _body(context, rules, canEdit),
      ),
    );
  }

  Widget _body(BuildContext context, AddonRules rules, bool canEdit) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final scopes = addonRuleScopes(rules, _picked);
    final sel = scopes.any((s) => s.key == _sel.key) ? _sel : RegionScope.all;
    final currency = sel.isAll ? AppConfig.currency : (regionCurrency(regions, sel.country) ?? AppConfig.currency);
    String money(double v) => formatMoney(v, currency, v == v.roundToDouble() ? 0 : 2);

    final list = Card(
      key: const ValueKey('addons-rules'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text('Rules', style: t.textTheme.titleMedium),
          ),
          for (final s in scopes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _RuleTile(
                key: ValueKey('addons-rule-${s.isAll ? 'default' : s.key}'),
                scope: s,
                selected: s.key == sel.key,
                onTap: () => setState(() => _sel = s),
              ),
            ),
          OutlinedButton.icon(
            key: const ValueKey('addons-add-rule'),
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('Add a region rule'),
            onPressed: canEdit ? () => _addRule(rules, regions) : null,
          ),
          const SizedBox(height: 8),
          Text(
            'A region rule only lists what differs; anything not set follows the default.',
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ]),
      ),
    );

    final here = rules.here(sel);
    final rule = rules.at(sel);
    final cards = [
      for (final a in DeliveryAddon.values)
        _AddonCard(
          key: ValueKey('addons-card-${a.key}'),
          addon: a,
          icon: _icons[a]!,
          here: here,
          rule: rule,
          rules: rules,
          money: money,
          canEdit: canEdit,
          onSet: (field, value) => _edit(rules, (r) => r.withField(a, field, value)),
          onClear: () => _edit(rules, (r) => r.cleared(a)),
          extra: switch (a) {
            DeliveryAddon.cover => _excludedEditor(rules, here, canEdit),
            DeliveryAddon.cold => _levelsEditor(rules, here, canEdit, money),
            _ => null,
          },
        ),
    ];

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900;
      final grid = wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(children: [for (var i = 0; i < cards.length; i += 2) cards[i]])),
              const SizedBox(width: 14),
              Expanded(child: Column(children: [for (var i = 1; i < cards.length; i += 2) cards[i]])),
            ])
          : Column(children: cards);
      return ListView(padding: const EdgeInsets.all(16), children: [
        Text(
          'A default rule and a rule per region (country, state, city, suburb; the pickup\'s most specific region '
          'wins). Every value is editable.',
          style: t.textTheme.bodyMedium?.copyWith(color: muted),
        ),
        const SizedBox(height: 12),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 260, child: list),
            const SizedBox(width: 18),
            Expanded(child: grid),
          ])
        else ...[
          list,
          const SizedBox(height: 12),
          grid,
        ],
      ]);
    });
  }

  Widget _excludedEditor(AddonRules rules, DeliveryAddons here, bool canEdit) {
    final items = here.excluded;
    final t = Theme.of(context);
    void save(List<String> next) => _edit(rules, (r) => r.withField(DeliveryAddon.cover, 'excluded', next));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 4),
      Text('Excluded items', style: t.textTheme.labelLarge),
      const SizedBox(height: 4),
      ListSearchFilter(
        count: items.length,
        hint: 'Search excluded items',
        builder: (context, q) => Wrap(spacing: 6, runSpacing: 6, children: [
          for (final i in items)
            if (q.isEmpty || searchSelectMatches(i, q))
              InputChip(
                key: ValueKey('addons-excluded-$i'),
                label: Text(i),
                onDeleted: canEdit ? () => save([for (final x in items) if (x != i) x]) : null,
              ),
        ]),
      ),
      Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('addons-excluded-new'),
            controller: _item,
            enabled: canEdit,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'Add an excluded item', counterText: '', isDense: true),
            onSubmitted: (v) {
              save(withExcludedItem(items, v));
              _item.clear();
            },
          ),
        ),
        IconButton(
          key: const ValueKey('addons-excluded-add'),
          tooltip: 'Add',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: canEdit
              ? () {
                  save(withExcludedItem(items, _item.text));
                  _item.clear();
                }
              : null,
        ),
      ]),
    ]);
  }

  Widget _levelsEditor(AddonRules rules, DeliveryAddons here, bool canEdit, String Function(double) money) {
    final levels = here.coldLevels;
    final t = Theme.of(context);
    void save(List<ColdLevel> next) =>
        _edit(rules, (r) => r.withField(DeliveryAddon.cold, 'levels', [for (final l in next) l.toJson()]));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 4),
      Text('Temperature levels', style: t.textTheme.labelLarge),
      for (final l in levels)
        Row(key: ValueKey('addons-level-${l.id}'), children: [
          Expanded(
            child: InkWell(
              onTap: !canEdit
                  ? null
                  : () async {
                      final name = await _askName(initial: l.name, title: 'Rename the level');
                      if (name == null) return;
                      save([for (final x in levels) x.id == l.id ? ColdLevel(id: x.id, name: name, charge: x.charge) : x]);
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(l.name, style: t.textTheme.bodyMedium),
              ),
            ),
          ),
          AddonStepButton(
            key: ValueKey('addons-level-${l.id}-down'),
            add: false,
            size: 36,
            tooltip: 'Lower',
            onPressed: canEdit && l.charge >= 5
                ? () => save([for (final x in levels) x.id == l.id ? ColdLevel(id: x.id, name: x.name, charge: x.charge - 5) : x])
                : null,
          ),
          SizedBox(width: 74, child: Text(money(l.charge), textAlign: TextAlign.center)),
          AddonStepButton(
            key: ValueKey('addons-level-${l.id}-up'),
            add: true,
            size: 36,
            tooltip: 'Raise',
            onPressed: canEdit && l.charge + 5 <= 100000
                ? () => save([for (final x in levels) x.id == l.id ? ColdLevel(id: x.id, name: x.name, charge: x.charge + 5) : x])
                : null,
          ),
          IconButton(
            key: ValueKey('addons-level-${l.id}-remove'),
            tooltip: 'Remove the level',
            icon: const Icon(Icons.delete_outline),
            onPressed: canEdit ? () => save([for (final x in levels) if (x.id != l.id) x]) : null,
          ),
        ]),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('addons-level-add'),
          icon: const Icon(Icons.add),
          label: const Text('Add a level'),
          onPressed: canEdit && levels.length < 20
              ? () async {
                  final name = await _askName(title: 'New temperature level');
                  if (name == null) return;
                  save([...levels, ColdLevel(id: coldLevelId(name, levels.map((l) => l.id)), name: name, charge: 0)]);
                }
              : null,
        ),
      ),
    ]);
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({super.key, required this.scope, required this.selected, required this.onTap});
  final RegionScope scope;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Material(
      color: selected ? c.primaryContainer : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? c.primary : c.outlineVariant, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Icon(scope.isAll ? Icons.public : Icons.location_on_outlined,
                color: selected ? c.onPrimaryContainer : c.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(scope.isAll ? 'Default' : scope.placeName,
                    style: t.textTheme.titleSmall?.copyWith(color: selected ? c.onPrimaryContainer : null)),
                Text(addonRuleScopeText(scope),
                    style: t.textTheme.bodySmall?.copyWith(color: selected ? c.onPrimaryContainer : c.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _AddonCard extends StatelessWidget {
  const _AddonCard({
    super.key,
    required this.addon,
    required this.icon,
    required this.here,
    required this.rule,
    required this.rules,
    required this.money,
    required this.canEdit,
    required this.onSet,
    required this.onClear,
    this.extra,
  });

  final DeliveryAddon addon;
  final IconData icon;
  final DeliveryAddons here;
  final AddonRule rule;
  final AddonRules rules;
  final String Function(double) money;
  final bool canEdit;
  final void Function(String field, Object? value) onSet;
  final VoidCallback onClear;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final on = here.on(addon);
    final region = !rule.scope.isAll;
    String follows(String field) {
      if (!region || rule.sets(addon, field)) return '';
      final from = rules.fromWhere(rule.scope, addon, field);
      return from == null || from.isAll ? 'Default' : from.placeName;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, color: t.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(addon.title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
            Switch(
              key: ValueKey('addons-switch-${addon.key}'),
              value: on,
              onChanged: canEdit ? (v) => onSet('on', v) : null,
            ),
          ]),
          if (region && follows('on').isNotEmpty)
            Text('On or off as ${follows('on')}', style: t.textTheme.bodySmall?.copyWith(color: muted)),
          if (on) ...[
            for (final f in addonFields[addon]!)
              Padding(
                key: ValueKey('addons-${addon.key}-${f.key}'),
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(f.label, style: t.textTheme.bodyMedium),
                      if (follows(f.key).isNotEmpty)
                        Text('As ${follows(f.key)}', style: t.textTheme.bodySmall?.copyWith(color: muted)),
                    ]),
                  ),
                  AddonStepButton(
                    key: ValueKey('addons-${addon.key}-${f.key}-down'),
                    add: false,
                    size: 36,
                    tooltip: 'Lower',
                    onPressed: canEdit && f.stepped(here.num(addon, f.key), up: false) != null
                        ? () => onSet(f.key, f.stepped(here.num(addon, f.key), up: false))
                        : null,
                  ),
                  SizedBox(
                    width: 84,
                    child: Text(
                      f.format(here.num(addon, f.key), money),
                      key: ValueKey('addons-${addon.key}-${f.key}-value'),
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  AddonStepButton(
                    key: ValueKey('addons-${addon.key}-${f.key}-up'),
                    add: true,
                    size: 36,
                    tooltip: 'Raise',
                    onPressed: canEdit && f.stepped(here.num(addon, f.key), up: true) != null
                        ? () => onSet(f.key, f.stepped(here.num(addon, f.key), up: true))
                        : null,
                  ),
                ]),
              ),
            ?extra,
          ],
          if (region && rule.setsAny(addon))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: ValueKey('addons-clear-${addon.key}'),
                onPressed: canEdit ? onClear : null,
                child: Text('Follow ${rule.scope.parent == null || rule.scope.parent!.isAll ? 'the default' : rule.scope.parent!.placeName} again'),
              ),
            ),
        ]),
      ),
    );
  }
}

/// An admin's decision on a claim: the amount paid (approving) and a note.
typedef ClaimDecision = ({double? amount, String note});

/// Admin > ... > Add-ons > Cover claims: open claims first; approve (paid to
/// the sender's GET.wallet) or reject.
class CoverClaimsScreen extends ConsumerWidget {
  const CoverClaimsScreen({super.key});

  Future<void> _decide(BuildContext context, WidgetRef ref, CoverClaim c, {required bool approve}) async {
    final res = await showAppDialog<ClaimDecision>(
      id: 'display.cover-claim-decide',
      context: context,
      builder: (_) => _DecideDialog(claim: c, approve: approve),
    );
    if (res == null || !context.mounted) return;
    await runAdminAction(
      context,
      () => ref.read(deliveryAddonsRepositoryProvider).decideClaim(c.id, approve: approve, amount: res.amount, note: res.note),
      success: approve ? 'Approved and paid' : 'Rejected',
    );
    ref.invalidate(coverClaimsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Parcel cover claims')),
      body: AsyncView(
        value: ref.watch(coverClaimsProvider),
        onRetry: () => ref.invalidate(coverClaimsProvider),
        data: (claims) => claims.isEmpty
            ? const Center(child: Text('No claims yet.', key: ValueKey('cover-claims-empty')))
            : ListSearchFilter(
                count: claims.length,
                hint: 'Search claims',
                builder: (context, q) => ListView(padding: const EdgeInsets.all(16), children: [
                  for (final c in claims)
                    if (q.isEmpty || searchSelectMatches('${c.service ?? ''} ${c.reason} ${c.statusLabel}', q))
                      Card(
                        key: ValueKey('cover-claim-${c.id}'),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Row(children: [
                              Expanded(
                                child: Text(
                                  '${formatMoney(c.amount, c.currency)} claimed · declared '
                                  '${formatMoney(c.declaredValue, c.currency)}',
                                  style: t.textTheme.titleSmall,
                                ),
                              ),
                              Text(c.statusLabel, style: t.textTheme.labelMedium),
                            ]),
                            Text(
                              [?c.service, if (c.createdAt != null) formatDateTime(c.createdAt)].join(' · '),
                              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 4),
                            Text(c.reason),
                            if (c.paidAmount != null) Text('Paid ${formatMoney(c.paidAmount, c.currency)}'),
                            if (c.adminNote != null) Text(c.adminNote!, style: t.textTheme.bodySmall),
                            if (c.open && canEdit)
                              Wrap(spacing: 8, children: [
                                FilledButton(
                                  key: ValueKey('cover-claim-approve-${c.id}'),
                                  onPressed: () => _decide(context, ref, c, approve: true),
                                  child: const Text('Approve'),
                                ),
                                OutlinedButton(
                                  key: ValueKey('cover-claim-reject-${c.id}'),
                                  onPressed: () => _decide(context, ref, c, approve: false),
                                  child: const Text('Reject'),
                                ),
                              ]),
                          ]),
                        ),
                      ),
                ]),
              ),
      ),
    );
  }
}

/// Names a temperature level.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});
  final String title, initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('addon-level-name'),
      controller: _c,
      autofocus: true,
      maxLength: 60,
      decoration: const InputDecoration(labelText: 'Name', hintText: 'Chilled 0 to 8 °C'),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        key: const ValueKey('addon-level-name-save'),
        onPressed: () => Navigator.pop(context, _c.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}

/// Approves (with the amount paid) or rejects a claim, with a note.
class _DecideDialog extends StatefulWidget {
  const _DecideDialog({required this.claim, required this.approve});
  final CoverClaim claim;
  final bool approve;

  @override
  State<_DecideDialog> createState() => _DecideDialogState();
}

class _DecideDialogState extends State<_DecideDialog> {
  late final _amount = TextEditingController(text: widget.approve ? widget.claim.amount.toStringAsFixed(2) : '');
  final _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.claim;
    return AlertDialog(
      title: Text(widget.approve ? 'Approve the claim' : 'Reject the claim'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.approve)
            TextField(
              key: const ValueKey('cover-claim-decide-amount'),
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Pay to the sender\'s GET.wallet',
                helperText: 'Up to the declared ${formatMoney(c.declaredValue, c.currency)}',
              ),
            ),
          TextField(
            key: const ValueKey('cover-claim-decide-note'),
            controller: _note,
            maxLength: 1000,
            decoration: const InputDecoration(labelText: 'Note to the sender (optional)'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('cover-claim-decide-confirm'),
          onPressed: () => Navigator.pop(context, (amount: double.tryParse(_amount.text.trim()), note: _note.text)),
          child: Text(widget.approve ? 'Approve and pay' : 'Reject'),
        ),
      ],
    );
  }
}
