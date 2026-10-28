// Admin › Settings › Ride safety (migration 0311): trip report categories and
// the report window, blocking limits and the review flag, the driver request
// filters and their limits, and passenger cover per region with the permit
// line. Grantable to sub-admins (admin-settings-ride-safety).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/city_to_city.dart' show C2cPlace;
import '../../../core/ride_safety.dart';
import '../../../data/ride_safety_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../admin_registry.dart';
import '../../widgets/admin_widgets.dart';
import '../city_to_city/c2c_widgets.dart' show C2cCardTitle, C2cStepper, c2cPlaceChoices, pickC2cPlace;
import '../geo/geo_data.dart' show regionsProvider;

final rideSafetyRoutes = <RouteBase>[
  GoRoute(path: '/admin/m/ride-safety', builder: (_, _) => const RideSafetyScreen()),
];

const rideSafetyEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Operations',
    title: 'Ride safety',
    subtitle: 'Trip reports, blocked drivers, driver request filters, passenger cover and permits',
    path: rideSafetyPath,
    pages: [rideSafetyPage],
    icon: Icons.health_and_safety_outlined,
  ),
];

class RideSafetyScreen extends ConsumerStatefulWidget {
  const RideSafetyScreen({super.key});

  @override
  ConsumerState<RideSafetyScreen> createState() => _RideSafetyScreenState();
}

class _RideSafetyScreenState extends ConsumerState<RideSafetyScreen> {
  RideSafetySettings? _draft;
  RideSafetySettings? _loaded;

  bool get _changed =>
      _draft != null && _loaded != null && _draft!.toRow().toString() != _loaded!.toRow().toString();

  Future<void> _save() async {
    final d = _draft;
    if (d == null) return;
    final why = d.problem;
    if (why != null) {
      showInfo(context, why);
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(rideSafetyRepositoryProvider).saveSettings(d),
      success: 'Ride safety settings saved',
    );
    if (ok) {
      setState(() => _loaded = d);
      ref.invalidate(rideSafetySettingsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(rideSafetyPage)) == AccessLevel.edit;
    return AdminPage(
      title: 'Ride safety',
      page: rideSafetyPage,
      body: AsyncView(
        value: ref.watch(rideSafetySettingsProvider),
        onRetry: () => ref.invalidate(rideSafetySettingsProvider),
        data: (stored) {
          if (_loaded == null || (!_changed && _loaded!.toRow().toString() != stored.toRow().toString())) {
            _loaded = stored;
            _draft = stored;
          }
          final s = _draft!;
          void set(RideSafetySettings v) => setState(() => _draft = v);
          final on = canEdit ? set : null;
          final left = [
            _ReportsCard(s: s, onChanged: on, canEdit: canEdit),
            _BlockingCard(s: s, onChanged: on),
          ];
          final right = [
            _FiltersCard(s: s, onChanged: on),
            _CoverCard(s: s, onChanged: on, canEdit: canEdit),
          ];
          final t = Theme.of(context);
          final save = canEdit
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        s.problem ?? (_changed ? 'Not saved yet.' : 'Saved.'),
                        key: const ValueKey('ride-safety-state'),
                        style: TextStyle(color: s.problem != null ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('ride-safety-save'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                      onPressed: _changed && s.problem == null ? _save : null,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                  ]),
                )
              : const SizedBox.shrink();
          return LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 900;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Reports, blocks, request filters and cover', style: t.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    if (wide)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: Column(children: left)),
                        const SizedBox(width: 16),
                        Expanded(child: Column(children: right)),
                      ])
                    else ...[...left, ...right],
                    save,
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

// ---- Trip reports ------------------------------------------------------------------------------------

class _ReportsCard extends ConsumerWidget {
  const _ReportsCard({required this.s, required this.onChanged, required this.canEdit});
  final RideSafetySettings s;
  final ValueChanged<RideSafetySettings>? onChanged;
  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, List<TripReportCategory> all, [TripReportCategory? c]) async {
    final label = await showAppDialog<String>(
      id: 'ride-safety.category',
      context: context,
      builder: (_) => _CategoryNameDialog(initial: c?.label ?? '', others: [for (final x in all) if (x.id != c?.id) x]),
    );
    if (label == null || !context.mounted) return;
    final next = c == null
        ? TripReportCategory(label: label, position: all.where((x) => x.active).length)
        : c.copyWith(label: label);
    if (await runAdminAction(context, () => ref.read(rideSafetyRepositoryProvider).saveCategory(next))) {
      ref.invalidate(tripReportCategoriesProvider);
    }
  }

  Future<void> _save(BuildContext context, WidgetRef ref, TripReportCategory c) async {
    if (await runAdminAction(context, () => ref.read(rideSafetyRepositoryProvider).saveCategory(c))) {
      ref.invalidate(tripReportCategoriesProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final on = onChanged;
    final days = s.reportWindowDays;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.flag_outlined, 'Trip reports'),
          Text(
            'Categories riders pick; each opens a support ticket with the trip attached.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: ref.watch(tripReportCategoriesProvider),
            onRetry: () => ref.invalidate(tripReportCategoriesProvider),
            data: (all) {
              final active = [for (final c in all) if (c.active) c];
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                ListSearchFilter(
                  count: active.length,
                  hint: 'Search categories',
                  fieldKey: const ValueKey('ride-safety-categories-search'),
                  builder: (context, q) => Column(children: [
                    for (final c in active)
                      if (q.isEmpty || c.label.toLowerCase().contains(q.toLowerCase()))
                        Padding(
                          key: ValueKey('category-${c.label}'),
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(c.label, style: t.textTheme.bodyLarge),
                                if (c.sosReminder)
                                  Text('Shows the SOS reminder', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                              ]),
                            ),
                            _PriorityChip(
                              key: ValueKey('category-priority-${c.label}'),
                              urgent: c.urgent,
                              onTap: canEdit ? () => _save(context, ref, c.copyWith(urgent: !c.urgent)) : null,
                            ),
                            if (canEdit)
                              PopupMenuButton<String>(
                                key: ValueKey('category-menu-${c.label}'),
                                tooltip: 'More for ${c.label}',
                                onSelected: (v) => switch (v) {
                                  'rename' => _edit(context, ref, all, c),
                                  'sos' => _save(context, ref, c.copyWith(sosReminder: !c.sosReminder)),
                                  _ => _save(context, ref, c.copyWith(active: false)),
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                                  CheckedPopupMenuItem(value: 'sos', checked: c.sosReminder, child: const Text('Show the SOS reminder')),
                                  const PopupMenuItem(value: 'remove', child: Text('Remove')),
                                ],
                              ),
                          ]),
                        ),
                  ]),
                ),
                if (canEdit)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('category-add'),
                      onPressed: () => _edit(context, ref, all),
                      icon: const Icon(Icons.add),
                      label: const Text('Add a category'),
                    ),
                  ),
              ]);
            },
          ),
          const Divider(height: 20),
          C2cStepper(
            label: 'Riders can report up to',
            hint: 'Days after the trip ends',
            value: '$days ${days == 1 ? 'day' : 'days'}',
            valueKey: const ValueKey('ride-safety-days'),
            onDown: on == null || days <= 1 ? null : () => on(s.copyWith(reportWindowDays: days - 1)),
            onUp: on == null || days >= 365 ? null : () => on(s.copyWith(reportWindowDays: days + 1)),
          ),
          Text(
            'Urgent categories go to the top of the support queue and alert the on-duty team (the SOS on-call '
            'list); the driver\'s report count shows on the Partners list.',
            style: t.textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

class _PriorityChip extends StatelessWidget {
  const _PriorityChip({super.key, required this.urgent, this.onTap});
  final bool urgent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return ActionChip(
      label: Text(urgent ? 'Urgent' : 'Normal',
          style: TextStyle(fontWeight: FontWeight.w600, color: urgent ? c.onErrorContainer : c.onSurface)),
      backgroundColor: urgent ? c.errorContainer : null,
      side: BorderSide(color: urgent ? c.error : c.outline),
      tooltip: urgent ? 'Make it normal' : 'Make it urgent',
      onPressed: onTap,
    );
  }
}

class _CategoryNameDialog extends StatefulWidget {
  const _CategoryNameDialog({required this.initial, required this.others});
  final String initial;
  final List<TripReportCategory> others;

  @override
  State<_CategoryNameDialog> createState() => _CategoryNameDialogState();
}

class _CategoryNameDialogState extends State<_CategoryNameDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final why = categoryLabelProblem(_text.text, widget.others);
    return AlertDialog(
      title: Text(widget.initial.isEmpty ? 'Add a category' : 'Rename category'),
      content: TextField(
        key: const ValueKey('category-name'),
        controller: _text,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(labelText: 'Name', errorText: _text.text.trim().isEmpty ? null : why),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('category-save'),
          onPressed: why == null ? () => Navigator.pop(context, _text.text.trim()) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---- Blocking ----------------------------------------------------------------------------------------

class _BlockingCard extends StatelessWidget {
  const _BlockingCard({required this.s, required this.onChanged});
  final RideSafetySettings s;
  final ValueChanged<RideSafetySettings>? onChanged;

  @override
  Widget build(BuildContext context) {
    final on = onChanged;
    final blk = s.maxBlocksPerRider, flag = s.blockFlagRiders;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.block, 'Blocking'),
          C2cStepper(
            label: 'A rider can block up to',
            value: '$blk ${blk == 1 ? 'driver' : 'drivers'}',
            valueKey: const ValueKey('ride-safety-blocks'),
            onDown: on == null || blk <= 1 ? null : () => on(s.copyWith(maxBlocksPerRider: blk - 1)),
            onUp: on == null || blk >= 500 ? null : () => on(s.copyWith(maxBlocksPerRider: blk + 1)),
          ),
          C2cStepper(
            label: 'Flag a driver for review when blocked by',
            value: '$flag ${flag == 1 ? 'rider' : 'riders'}',
            valueKey: const ValueKey('ride-safety-flag'),
            onDown: on == null || flag <= 1 ? null : () => on(s.copyWith(blockFlagRiders: flag - 1)),
            onUp: on == null || flag >= 100 ? null : () => on(s.copyWith(blockFlagRiders: flag + 1)),
          ),
          Text(
            'Blocks are enforced by the server: a blocked driver doesn\'t see the rider\'s requests (city, scheduled, '
            'City to City), can\'t offer, and My Ride or GET.now direct booking to him is refused. Admins see who '
            'blocked whom on the driver\'s Partners page.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

// ---- Driver request filters ----------------------------------------------------------------------------

class _FiltersCard extends StatelessWidget {
  const _FiltersCard({required this.s, required this.onChanged});
  final RideSafetySettings s;
  final ValueChanged<RideSafetySettings>? onChanged;

  String _km(double v) => v == v.roundToDouble() ? '${v.round()} km' : '${v.toStringAsFixed(1)} km';

  @override
  Widget build(BuildContext context) {
    final on = onChanged;
    Widget tick(String key, String label, bool v, RideSafetySettings Function(bool) next) => CheckboxListTile(
          key: ValueKey(key),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(label),
          value: v,
          onChanged: on == null ? null : (x) => on(next(x ?? false)),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.tune, 'Driver request filters'),
          tick('filter-on-min-fare', 'Drivers may set a minimum fare', s.minFareOn, (v) => s.copyWith(minFareOn: v)),
          tick('filter-on-distance', 'Drivers may set a max pickup distance', s.distanceOn, (v) => s.copyWith(distanceOn: v)),
          tick('filter-on-sort', 'Drivers may sort by price or distance', s.sortOn, (v) => s.copyWith(sortOn: v)),
          if (s.minFareOn)
            C2cStepper(
              label: 'Minimum fare filter up to',
              value: '${s.currency} ${s.minFareCap.round()}',
              valueKey: const ValueKey('ride-safety-fare-cap'),
              onDown: on == null || s.minFareCap <= 5 ? null : () => on(s.copyWith(minFareCap: s.minFareCap - 5)),
              onUp: on == null || s.minFareCap >= 10000 ? null : () => on(s.copyWith(minFareCap: s.minFareCap + 5)),
            ),
          if (s.distanceOn) ...[
            C2cStepper(
              label: 'Shortest pickup distance',
              value: _km(s.distanceMinKm),
              valueKey: const ValueKey('ride-safety-km-min'),
              onDown: on == null || s.distanceMinKm <= 0.5
                  ? null
                  : () => on(s.copyWith(distanceMinKm: s.distanceMinKm <= 1 ? 0.5 : s.distanceMinKm - 1)),
              onUp: on == null || s.distanceMinKm + 1 > s.distanceMaxKm
                  ? null
                  : () => on(s.copyWith(distanceMinKm: s.distanceMinKm < 1 ? 1 : s.distanceMinKm + 1)),
            ),
            C2cStepper(
              label: 'Longest pickup distance',
              value: _km(s.distanceMaxKm),
              valueKey: const ValueKey('ride-safety-km-max'),
              onDown: on == null || s.distanceMaxKm - 1 < s.distanceMinKm
                  ? null
                  : () => on(s.copyWith(distanceMaxKm: s.distanceMaxKm - 1)),
              onUp: on == null || s.distanceMaxKm >= 200 ? null : () => on(s.copyWith(distanceMaxKm: s.distanceMaxKm + 1)),
            ),
          ],
          const SizedBox(height: 4),
          Text(s.limitsLine, key: const ValueKey('ride-safety-limits'), style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            'Filters only hide requests in the driver\'s own list. There is no acceptance rate per driver, so a '
            'hidden request counts against nobody.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
      ),
    );
  }
}

// ---- Passenger cover and permits --------------------------------------------------------------------------

class _CoverCard extends ConsumerWidget {
  const _CoverCard({required this.s, required this.onChanged, required this.canEdit});
  final RideSafetySettings s;
  final ValueChanged<RideSafetySettings>? onChanged;
  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, CoverRule rule) async {
    final next = await showAppDialog<CoverRule>(
      id: 'ride-safety.cover-rule',
      context: context,
      builder: (_) => CoverRuleDialog(rule: rule),
    );
    if (next == null || !context.mounted) return;
    if (await runAdminAction(context, () => ref.read(rideSafetyRepositoryProvider).saveCoverRule(next))) {
      ref.invalidate(coverRulesProvider);
    }
  }

  Future<void> _add(BuildContext context, WidgetRef ref, List<CoverRule> have) async {
    final regions = ref.read(regionsProvider).value ?? const [];
    final taken = {for (final r in have) r.placeLabel};
    final place = await pickC2cPlace(
      context,
      title: 'Cover for a place',
      choices: [
        for (final p in c2cPlaceChoices(regions))
          if (p.level != 'suburb' && !taken.contains(_rule(p).placeLabel)) p,
      ],
    );
    if (place == null || !context.mounted) return;
    await _edit(context, ref, _rule(place));
  }

  static CoverRule _rule(C2cPlace p) => CoverRule(
        country: p.country,
        state: p.level == 'country' ? null : p.state,
        city: p.level == 'city' ? p.city : null,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final on = onChanged;
    ref.watch(regionsProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.verified_user_outlined, 'Passenger cover and permits'),
          Text(
            'Per region: the default, then a country, state or city; the most specific wins, even one that is off. '
            'Shown on receipts and the Safety page only when it is on with an insurer, a policy number and an amount.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          AsyncView(
            value: ref.watch(coverRulesProvider),
            onRetry: () => ref.invalidate(coverRulesProvider),
            data: (rules) {
              final sorted = [...rules]..sort((a, b) {
                  final c = a.rank.compareTo(b.rank);
                  return c != 0 ? c : a.placeLabel.compareTo(b.placeLabel);
                });
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                ListSearchFilter(
                  count: sorted.length,
                  hint: 'Search places',
                  fieldKey: const ValueKey('ride-safety-cover-search'),
                  builder: (context, q) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final r in sorted)
                      if (q.isEmpty || r.placeLabel.toLowerCase().contains(q.toLowerCase()))
                        Container(
                          key: ValueKey('cover-rule-${r.placeLabel}'),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: t.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ListTile(
                            title: Text(r.placeLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(r.summary),
                            trailing: !canEdit
                                ? null
                                : Row(mainAxisSize: MainAxisSize.min, children: [
                                    IconButton(
                                      tooltip: 'Edit ${r.placeLabel}',
                                      icon: const Icon(Icons.edit_outlined),
                                      onPressed: () => _edit(context, ref, r),
                                    ),
                                    if (!r.isDefault && r.id != null)
                                      IconButton(
                                        tooltip: 'Remove ${r.placeLabel}',
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () async {
                                          if (await runAdminAction(
                                              context, () => ref.read(rideSafetyRepositoryProvider).removeCoverRule(r.id!))) {
                                            ref.invalidate(coverRulesProvider);
                                          }
                                        },
                                      ),
                                  ]),
                          ),
                        ),
                  ]),
                ),
                if (canEdit)
                  Wrap(spacing: 8, children: [
                    if (!rules.any((r) => r.isDefault))
                      TextButton.icon(
                        key: const ValueKey('cover-add-default'),
                        onPressed: () => _edit(context, ref, const CoverRule(enabled: false)),
                        icon: const Icon(Icons.add),
                        label: const Text('Add the default'),
                      ),
                    TextButton.icon(
                      key: const ValueKey('cover-add'),
                      onPressed: () => _add(context, ref, rules),
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Add a place'),
                    ),
                  ]),
              ]);
            },
          ),
          const Divider(height: 20),
          CheckboxListTile(
            key: const ValueKey('ride-safety-permit'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Show the driver\'s permit and expiry on receipts'),
            subtitle: const Text('From the driver\'s approved permit shown to passengers (People › Vehicle permits)'),
            value: s.showDriverPermit,
            onChanged: on == null ? null : (v) => on(s.copyWith(showDriverPermit: v ?? false)),
          ),
        ]),
      ),
    );
  }
}

/// One region's cover: on or off, insurer, policy, amount, claim days,
/// hotline and the terms link. Pops the changed rule.
class CoverRuleDialog extends StatefulWidget {
  const CoverRuleDialog({super.key, required this.rule});
  final CoverRule rule;

  @override
  State<CoverRuleDialog> createState() => _CoverRuleDialogState();
}

class _CoverRuleDialogState extends State<CoverRuleDialog> {
  late bool _on = widget.rule.enabled;
  late final _insurer = TextEditingController(text: widget.rule.insurer);
  late final _policy = TextEditingController(text: widget.rule.policyNo);
  late final _amount = TextEditingController(text: widget.rule.coverAmount?.round().toString() ?? '');
  late final _days = TextEditingController(text: widget.rule.claimDays?.toString() ?? '');
  late final _hotline = TextEditingController(text: widget.rule.hotline);
  late final _terms = TextEditingController(text: widget.rule.termsUrl);

  @override
  void dispose() {
    for (final c in [_insurer, _policy, _amount, _days, _hotline, _terms]) {
      c.dispose();
    }
    super.dispose();
  }

  CoverRule get _rule {
    final amount = double.tryParse(_amount.text.trim());
    final days = int.tryParse(_days.text.trim());
    return widget.rule.copyWith(
      enabled: _on,
      insurer: _insurer.text,
      policyNo: _policy.text,
      coverAmount: amount,
      clearAmount: amount == null,
      claimDays: days,
      clearDays: days == null,
      hotline: _hotline.text,
      termsUrl: _terms.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _rule;
    final why = r.problem;
    Widget field(String key, String label, TextEditingController c, {bool digits = false, int max = 120}) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            key: ValueKey(key),
            controller: c,
            maxLength: max,
            keyboardType: digits ? TextInputType.number : null,
            inputFormatters: digits ? [FilteringTextInputFormatter.digitsOnly] : null,
            decoration: InputDecoration(labelText: label, counterText: ''),
            onChanged: (_) => setState(() {}),
          ),
        );
    return AlertDialog(
      title: Text(widget.rule.placeLabel),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SwitchListTile(
              key: const ValueKey('cover-on'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Show cover here'),
              subtitle: const Text('Off: no cover shown in this place'),
              value: _on,
              onChanged: (v) => setState(() => _on = v),
            ),
            field('cover-insurer', 'Insurer', _insurer),
            field('cover-policy', 'Policy number', _policy, max: 80),
            field('cover-amount', 'Cover amount (${widget.rule.currency})', _amount, digits: true, max: 9),
            field('cover-days', 'Claim within (days)', _days, digits: true, max: 4),
            field('cover-hotline', 'Hotline', _hotline, max: 40),
            field('cover-terms', 'Terms link (https://)', _terms, max: 500),
            if (_on && !r.hasDetails)
              Text(
                'Riders see nothing until it has an insurer, a policy number and an amount.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            if (why != null) Text(why, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('cover-save'),
          onPressed: why == null ? () => Navigator.pop(context, r) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
