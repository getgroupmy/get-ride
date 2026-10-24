// Admin > Services & catalogue > Partner type services (migrations 0257,
// 0259): which ride services each partner type sees in open requests. A
// partner with several types sees what any of them allows; a type without
// a rule sees every service. The list of types on one side, the editor on
// the other (stacked on a phone), and "Who sees this request?" under them,
// worked out here with the database's rule (core/partner_type_services.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart' show formatDateTime;
import '../../../core/partner_type_services.dart';
import '../../../data/live_tables.dart';
import '../../../providers.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../geo/geo_data.dart' show regionVehicleTypesProvider;
import '../geo/geo_logic.dart' show ServiceOption;

const partnerTypeServicesPath = '/admin/m/partner-type-services';

/// The page key that grants this page (Partner Type's grant edits it too,
/// as `admin_table_pages` says).
const partnerTypeServicesPage = 'admin-settings-partner-type-services';
const _partnerTypePage = 'admin-settings-partner-type';

// ---- Data ------------------------------------------------------------------------

/// Every rule, by name.
final partnerTypeServicesProvider = FutureProvider.autoDispose<List<PartnerTypeServiceRule>>((ref) async {
  ref.watchAdminLive('partner_type_services');
  final rows = await ref
      .watch(supabaseProvider)
      .from('partner_type_services')
      .select('type_key, type_name, all_services, services, note, updated_at, updated_by')
      .order('type_name', ascending: true);
  return [for (final r in rows) PartnerTypeServiceRule.fromRow(Map<String, dynamic>.from(r))];
});

/// The partner types Admin > Partner Type defines, by name.
final partnerTypeNamesForServicesProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  ref.watchLive('settings_entries');
  final rows = await ref
      .watch(supabaseProvider)
      .from('settings_entries')
      .select('values')
      .eq('category', 'partner-type')
      .order('position', ascending: true);
  return [
    for (final r in rows)
      if ('${(r['values'] as Map?)?['name'] ?? ''}'.trim().isNotEmpty) '${(r['values'] as Map?)!['name']}'.trim(),
  ];
});

Future<void> _saveRule(WidgetRef ref, PartnerTypeServiceRule r) =>
    ref.read(supabaseProvider).from('partner_type_services').upsert(r.toRow(), onConflict: 'type_key');

Future<void> _removeRule(WidgetRef ref, String key) =>
    ref.read(supabaseProvider).from('partner_type_services').delete().eq('type_key', key);

// ---- The page ----------------------------------------------------------------------

class PartnerTypeServicesScreen extends ConsumerStatefulWidget {
  const PartnerTypeServicesScreen({super.key});

  @override
  ConsumerState<PartnerTypeServicesScreen> createState() => _PartnerTypeServicesScreenState();
}

class _PartnerTypeServicesScreenState extends ConsumerState<PartnerTypeServicesScreen> {
  /// The type being edited, and the draft of its rule.
  String? _sel;
  DateTime? _loadedAt;
  bool _dirty = false;
  final _name = TextEditingController();
  final _note = TextEditingController();
  bool _all = true;
  List<String> _services = [];
  bool _confirmRemove = false;
  String? _testService;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // A change saved here or elsewhere shows at once; what is being typed
    // is kept until it is saved.
    ref.listenManual(partnerTypeServicesProvider, (_, next) {
      final rules = next.value;
      if (rules == null) return;
      final current = rules.where((r) => r.typeKey == _sel).firstOrNull;
      if (current == null) {
        _select(rules.firstOrNull);
      } else if (!_dirty && current.updatedAt != _loadedAt) {
        _select(current);
      }
    }, fireImmediately: true);
    _ready = true;
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  void _select(PartnerTypeServiceRule? r) {
    void load() {
      _sel = r?.typeKey;
      _loadedAt = r?.updatedAt;
      _dirty = false;
      _confirmRemove = false;
      _name.text = r?.typeName ?? '';
      _note.text = r?.note ?? '';
      _all = r?.allServices ?? true;
      _services = [...?r?.services];
    }

    if (mounted && _ready) {
      setState(load);
    } else {
      load();
    }
  }

  void _edit(void Function() change) => setState(() {
        change();
        _dirty = true;
      });

  bool _canEdit() =>
      ref.watch(pageAccessProvider(partnerTypeServicesPage)) == AccessLevel.edit ||
      ref.watch(pageAccessProvider(_partnerTypePage)) == AccessLevel.edit;

  PartnerTypeServiceRule? get _draft => _sel == null
      ? null
      : PartnerTypeServiceRule(
          typeKey: _sel!,
          typeName: _name.text.trim().isEmpty ? _sel! : _name.text.trim(),
          allServices: _all,
          services: _services,
          note: _note.text,
        );

  Future<void> _save(List<String> choices) async {
    final d = _draft;
    if (d == null) return;
    if (_name.text.trim().isEmpty) {
      showError(context, 'Enter a name for this Partner Service type.');
      return;
    }
    // Ticked services in the list's order.
    final keys = {for (final s in _services) partnerServiceKey(s)};
    final ordered = [for (final s in choices) if (keys.contains(partnerServiceKey(s))) s];
    final row = PartnerTypeServiceRule(
      typeKey: d.typeKey,
      typeName: d.typeName,
      allServices: d.allServices,
      services: ordered,
      note: d.note,
    );
    if (await runAdminAction(context, () => _saveRule(ref, row),
        success: 'Saved. Partners see the change straight away.')) {
      _dirty = false;
      ref.invalidate(partnerTypeServicesProvider);
    }
  }

  Future<void> _remove() async {
    final key = _sel;
    if (key == null) return;
    if (await runAdminAction(context, () => _removeRule(ref, key),
        success: 'Rule removed. This type now sees every service.')) {
      _dirty = false;
      _sel = null;
      ref.invalidate(partnerTypeServicesProvider);
    }
  }

  Future<void> _add(List<PartnerTypeServiceRule> rules) async {
    List<String> names;
    try {
      names = await ref.read(partnerTypeNamesForServicesProvider.future);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final free = typesWithoutRule(names, rules);
    if (free.isEmpty) {
      showInfo(context, 'Every Partner Service type already has a rule.');
      return;
    }
    final picked = await showSearchPicker<String>(
      context,
      title: 'Add a Partner Service type',
      choices: [for (final n in free) (value: n, label: n, subtitle: null, leading: null)],
    );
    if (picked == null || !mounted) return;
    final rule = PartnerTypeServiceRule(typeKey: partnerServiceKey(picked), typeName: picked);
    if (await runAdminAction(context, () => _saveRule(ref, rule),
        success: 'Added $picked. It sees every service until you choose some.')) {
      _dirty = false;
      _sel = rule.typeKey;
      _loadedAt = null;
      ref.invalidate(partnerTypeServicesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _canEdit();
    final value = ref.watch(partnerTypeServicesProvider);
    final catalogue = [
      for (final o in ref.watch(regionVehicleTypesProvider).value ?? const <ServiceOption>[]) o.name,
    ];
    final typeNames = ref.watch(partnerTypeNamesForServicesProvider).value ?? const <String>[];
    return AdminPage(
      title: 'Partner Service type services',
      page: partnerTypeServicesPage,
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(partnerTypeServicesProvider),
        data: (saved) {
          final choices = serviceChoices(catalogue, saved);
          final draft = _draft;
          // What the tester works out: the saved rules, with the one being
          // edited as it is now.
          final rules = [for (final r in saved) r.typeKey == draft?.typeKey ? draft! : r];
          final selected = saved.where((r) => r.typeKey == _sel).firstOrNull;
          final wide = MediaQuery.sizeOf(context).width >= 900;
          final list = _TypeList(
            rules: rules,
            total: choices.length,
            selected: _sel,
            canEdit: canEdit,
            onSelect: _select,
            onAdd: () => _add(saved),
          );
          final editor = selected == null
              ? const _Panel(
                  key: ValueKey('pts-editor'),
                  child: Text('Pick a Partner Service type, or add one.'),
                )
              : _editor(context, selected, choices, canEdit);
          final tester = _Tester(
            rules: rules,
            unruled: typesWithoutRule(typeNames, saved),
            services: choices,
            service: _testService ?? choices.firstOrNull,
            onService: (s) => setState(() => _testService = s),
          );
          final t = Theme.of(context);
          return ResponsiveCenter(
            maxWidth: 1100,
            child: ListView(
              key: const ValueKey('partner-type-services'),
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                Text(
                  'Choose which ride services each Partner Service type sees in open requests. A partner with several '
                  "types sees everything any of their types allows. A type that isn't listed here sees every service.",
                  style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)),
                ),
                const SizedBox(height: 16),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 100, child: list),
                      const SizedBox(width: 16),
                      Expanded(flex: 115, child: editor),
                    ],
                  )
                else ...[
                  list,
                  const SizedBox(height: 16),
                  editor,
                ],
                const SizedBox(height: 16),
                tester,
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _editor(BuildContext context, PartnerTypeServiceRule saved, List<String> choices, bool canEdit) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t));
    final ticked = {for (final s in _services) partnerServiceKey(s)};
    return _Panel(
      key: const ValueKey('pts-editor'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_name.text.trim().isEmpty ? saved.typeName : _name.text.trim(), style: t.textTheme.titleMedium),
          if (saved.updatedAt != null)
            Text('Updated ${formatDateTime(saved.updatedAt)}', key: const ValueKey('pts-updated'), style: muted),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('pts-name'),
            controller: _name,
            enabled: canEdit,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder(), isDense: true, counterText: ''),
            onChanged: (_) => _edit(() {}),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            color: t.colorScheme.surfaceContainerHighest,
            elevation: 0,
            child: SwitchListTile(
              key: const ValueKey('pts-all'),
              title: const Text('All services'),
              subtitle: const Text('Sees every service, including new ones added later'),
              value: _all,
              onChanged: canEdit ? (v) => _edit(() => _all = v) : null,
            ),
          ),
          const SizedBox(height: 12),
          Text('Allowed services', style: t.textTheme.titleSmall),
          if (_all) Text('All services is on, so every service is seen.', style: muted),
          ListSearchFilter(
            count: choices.length,
            hint: 'Search services',
            fieldKey: const ValueKey('pts-service-search'),
            builder: (context, q) {
              final shown = [for (final s in choices) if (q.isEmpty || s.toLowerCase().contains(q.toLowerCase())) s];
              if (shown.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(choices.isEmpty ? 'No vehicle services yet (Vehicle Services).' : 'No service matches.', style: muted),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in shown)
                      FilterChip(
                        key: ValueKey('pts-service-$s'),
                        label: Text(s),
                        selected: !_all && ticked.contains(partnerServiceKey(s)),
                        onSelected: canEdit && !_all
                            ? (on) => _edit(() {
                                  final k = partnerServiceKey(s);
                                  _services = [
                                    for (final x in _services) if (partnerServiceKey(x) != k) x,
                                    if (on) s,
                                  ];
                                })
                            : null,
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('pts-note'),
            controller: _note,
            enabled: canEdit,
            maxLength: 500,
            decoration: const InputDecoration(labelText: 'Note for admins', border: OutlineInputBorder(), isDense: true, counterText: ''),
            onChanged: (_) => _edit(() {}),
          ),
          if (canEdit) ...[
            const SizedBox(height: 12),
            if (_confirmRemove)
              Container(
                key: const ValueKey('pts-remove-confirm'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Remove the rule for ${saved.typeName}? Its partners will see every service.',
                      style: TextStyle(color: t.colorScheme.onErrorContainer),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      children: [
                        TextButton(
                          key: const ValueKey('pts-remove-cancel'),
                          onPressed: () => setState(() => _confirmRemove = false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          key: const ValueKey('pts-remove-yes'),
                          style: FilledButton.styleFrom(
                            backgroundColor: t.colorScheme.error,
                            foregroundColor: t.colorScheme.onError,
                          ),
                          onPressed: _remove,
                          child: const Text('Remove rule'),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    key: const ValueKey('pts-save'),
                    onPressed: () => _save(choices),
                    child: const Text('Save'),
                  ),
                  OutlinedButton(
                    key: const ValueKey('pts-remove'),
                    onPressed: () => setState(() => _confirmRemove = true),
                    child: const Text('Remove rule'),
                  ),
                ],
              ),
            const SizedBox(height: 6),
            Text('Removing the rule lets this type see every service.', style: muted),
          ],
        ],
      ),
    );
  }
}

/// A card section of the page.
class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      );
}

/// The partner types with a rule, searchable.
class _TypeList extends StatelessWidget {
  const _TypeList({
    required this.rules,
    required this.total,
    required this.selected,
    required this.canEdit,
    required this.onSelect,
    required this.onAdd,
  });

  final List<PartnerTypeServiceRule> rules;
  final int total;
  final String? selected;
  final bool canEdit;
  final ValueChanged<PartnerTypeServiceRule> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return _Panel(
      key: const ValueKey('pts-types'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Partner Service types', style: t.textTheme.titleMedium)),
              if (canEdit)
                OutlinedButton.icon(
                  key: const ValueKey('pts-add'),
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add type'),
                ),
            ],
          ),
          ListSearchFilter(
            count: rules.length,
            from: 1,
            hint: 'Search Partner Service types',
            fieldKey: const ValueKey('pts-type-search'),
            builder: (context, q) {
              final shown = [for (final r in rules) if (ruleMatches(r, q)) r];
              if (shown.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    rules.isEmpty ? 'No rules yet: every Partner Service type sees every service.' : 'No Partner Service type matches.',
                    style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
                  ),
                );
              }
              return Column(
                children: [
                  for (final r in shown)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _TypeTile(rule: r, total: total, selected: r.typeKey == selected, onTap: () => onSelect(r)),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TypeTile extends StatelessWidget {
  const _TypeTile({required this.rule, required this.total, required this.selected, required this.onTap});
  final PartnerTypeServiceRule rule;
  final int total;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Material(
      color: selected ? cs.primaryContainer : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? cs.primary : cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('pts-type-${rule.typeKey}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      rule.typeName,
                      style: t.textTheme.titleSmall?.copyWith(color: selected ? cs.onPrimaryContainer : null),
                    ),
                  ),
                  StatusChip(rule.allServices ? 'verified' : 'pending', label: ruleCountLabel(rule, total)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                ruleSummary(rule),
                style: t.textTheme.bodySmall?.copyWith(
                  color: selected ? cs.onPrimaryContainer : mutedTextColor(t),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Who sees this request?": pick a service, see which types get it.
class _Tester extends StatelessWidget {
  const _Tester({
    required this.rules,
    required this.unruled,
    required this.services,
    required this.service,
    required this.onService,
  });

  final List<PartnerTypeServiceRule> rules;

  /// Partner types without a rule (they see every service).
  final List<String> unruled;
  final List<String> services;
  final String? service;
  final ValueChanged<String> onService;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final byKey = rulesByKey(rules);
    final s = service;
    final types = [
      for (final r in rules) (name: r.typeName, key: r.typeKey),
      for (final n in unruled) (name: n, key: partnerServiceKey(n)),
    ];
    return _Panel(
      key: const ValueKey('pts-tester'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Who sees this request?', style: t.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Pick a service to see which Partner Service types get the open request.',
            style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
          ),
          ListSearchFilter(
            count: services.length,
            hint: 'Search services',
            fieldKey: const ValueKey('pts-test-search'),
            builder: (context, q) => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final x in services)
                    if (q.isEmpty || x.toLowerCase().contains(q.toLowerCase()))
                      ChoiceChip(
                        key: ValueKey('pts-test-$x'),
                        label: Text(x),
                        selected: x == s,
                        onSelected: (_) => onService(x),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (s == null)
            Text('No vehicle services yet.', style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)))
          else
            Wrap(
              key: const ValueKey('pts-test-result'),
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final ty in types)
                  () {
                    final sees = partnerTypeAllowsService(byKey, ty.key, s);
                    return Container(
                      key: ValueKey('pts-sees-${ty.key}-${sees ? 'yes' : 'no'}'),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: sees ? Colors.green.withValues(alpha: 0.14) : cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        ty.name,
                        semanticsLabel: '${ty.name}: ${sees ? 'sees it' : 'does not see it'}',
                        style: t.textTheme.bodySmall?.copyWith(
                          color: sees ? (t.brightness == Brightness.dark ? Colors.green.shade300 : Colors.green.shade800) : mutedTextColor(t),
                          decoration: sees ? null : TextDecoration.lineThrough,
                          fontWeight: sees ? FontWeight.w600 : null,
                        ),
                      ),
                    );
                  }(),
              ],
            ),
        ],
      ),
    );
  }
}
