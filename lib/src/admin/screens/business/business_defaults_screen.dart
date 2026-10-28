// Admin › People › Business accounts › Defaults (migration 0313): a Default
// and a rule per region (the company's registered country, state or city;
// the narrowest matching rule wins and sets only what it sets). Every value
// is editable: starting credit limit, invoice due days, the overdue pause,
// the business discount, the commission on business trips, the default
// member monthly limit, the payment terms and the services allowed. Each
// account can still override any value on its own page.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/business_accounts.dart';
import '../../../data/business_repository.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../widgets/region_scope_picker.dart';
import 'business_values_editor.dart';

class BusinessDefaultsScreen extends ConsumerStatefulWidget {
  const BusinessDefaultsScreen({super.key});

  @override
  ConsumerState<BusinessDefaultsScreen> createState() => _BusinessDefaultsScreenState();
}

class _BusinessDefaultsScreenState extends ConsumerState<BusinessDefaultsScreen> {
  /// The rule open in the editor (by id; null id: a new one).
  int _pick = 0;
  BusinessRegionRule? _draft;
  BusinessRegionRule? _new;

  List<BusinessRegionRule> _ordered(List<BusinessRegionRule> rules) => [
    ...rules.where((r) => r.isDefault),
    ...(rules.where((r) => !r.isDefault).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()))),
    ?_new,
  ];

  Future<void> _add() async {
    final scope = await pickRegionScope(context, title: 'Region of the company\'s registered address');
    if (scope == null || scope.isAll || !mounted) return;
    final rules = ref.read(businessRegionRulesProvider).value ?? const [];
    final exists = rules.indexWhere((r) =>
        regionNameNorm(r.country) == regionNameNorm(scope.country) &&
        regionNameNorm(r.state) == regionNameNorm(scope.state) &&
        regionNameNorm(r.city) == regionNameNorm(scope.city));
    if (exists >= 0) {
      setState(() {
        _pick = _ordered(rules).indexOf(rules[exists]);
        _draft = null;
      });
      return;
    }
    setState(() {
      _new = BusinessRegionRule(country: scope.country, state: scope.state, city: scope.city);
      _draft = _new;
      _pick = _ordered(rules).length - 1;
    });
  }

  Future<void> _save(BusinessRegionRule r) async {
    if (r.isDefault && !r.values.isComplete) return showInfo(context, 'The Default sets every value.');
    final ok = await runAdminAction(context, () => ref.read(businessRepositoryProvider).saveRegionRule(r), success: 'Saved');
    if (ok) {
      setState(() {
        _draft = null;
        _new = null;
      });
      ref.invalidate(businessRegionRulesProvider);
    }
  }

  Future<void> _delete(BusinessRegionRule r) async {
    if (r.id == null) {
      setState(() {
        _new = null;
        _draft = null;
        _pick = 0;
      });
      return;
    }
    if (!await confirm(context, 'Remove the ${r.name} rule?', 'Companies there follow the rules above it again.', ok: 'Remove')) {
      return;
    }
    if (!mounted) return;
    final ok = await runAdminAction(context, () => ref.read(businessRepositoryProvider).deleteRegionRule(r.id!));
    if (ok) {
      setState(() {
        _pick = 0;
        _draft = null;
      });
      ref.invalidate(businessRegionRulesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(businessAccountsPage)) == AccessLevel.edit;
    final async = ref.watch(businessRegionRulesProvider);
    return AdminPage(
      title: 'Business account defaults',
      page: businessAccountsPage,
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(businessRegionRulesProvider),
        data: (rules) {
          final t = Theme.of(context);
          final list = _ordered(rules);
          final pick = _pick.clamp(0, list.isEmpty ? 0 : list.length - 1);
          final stored = list.isEmpty ? const BusinessRegionRule() : list[pick];
          final r = (_draft != null && _draft!.id == stored.id && _draft!.name == stored.name) ? _draft! : stored;
          final base = businessValuesAbove(rules, r);
          final regions = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, x) in list.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: i == pick ? t.colorScheme.primaryContainer : t.colorScheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: i == pick ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: i == pick ? 2 : 1),
                  ),
                  child: ListTile(
                    key: ValueKey('biz-region-${x.name}'),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    title: Text(x.name),
                    subtitle: x.isDefault
                        ? const Text('Every company not under a rule')
                        : Text(x.active ? (x.id == null ? 'Not saved yet' : 'Rule') : 'Off'),
                    onTap: () => setState(() {
                      _pick = i;
                      _draft = null;
                    }),
                  ),
                ),
              ),
            if (canEdit)
              OutlinedButton.icon(
                key: const ValueKey('biz-region-add'),
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Add a region rule'),
              ),
          ]);
          final editor = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(r.name, style: t.textTheme.titleLarge)),
                  if (!r.isDefault)
                    Switch(
                      key: const ValueKey('biz-region-active'),
                      value: r.active,
                      onChanged: canEdit ? (v) => setState(() => _draft = r.copyWith(active: v)) : null,
                    ),
                ]),
                Text(
                  r.isDefault
                      ? 'Used for every company no region rule covers.'
                      : 'Companies registered in ${r.name}. Switch a value on to set it here; off, it follows the rule above.',
                  style: t.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                BusinessValuesEditor(
                  values: r.values,
                  base: base,
                  all: r.isDefault,
                  onChanged: canEdit ? (v) => setState(() => _draft = r.copyWith(values: v)) : null,
                ),
                if (canEdit) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    if (!r.isDefault)
                      TextButton(
                        key: const ValueKey('biz-region-delete'),
                        style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
                        onPressed: () => _delete(r),
                        child: const Text('Remove'),
                      ),
                    const Spacer(),
                    FilledButton.icon(
                      key: const ValueKey('biz-region-save'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                      onPressed: identical(r, stored) && r.id != null ? null : () => _save(r),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                  ]),
                ],
              ]),
            ),
          );
          final intro = Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'A Default and a rule per region (the company\'s registered state). Each account can override any value '
              'on its own page. Payment terms and the services allowed are set the same way.',
              style: t.textTheme.bodyMedium,
            ),
          );
          return LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 900;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    intro,
                    if (wide)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: 300, child: regions),
                        const SizedBox(width: 16),
                        Expanded(child: editor),
                      ])
                    else ...[regions, const SizedBox(height: 12), editor],
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
