// Admin › Services & catalogue › Premium and GET.Plus (migration 0316): the
// Premium service rules and the GET.Plus rider membership, a Default rule
// and a rule per region (the most specific wins; a region rule only
// overrides what it sets), every value editable; the members and the
// revenue. Its own page and keys, beside City ride extras (0314).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/city_to_city.dart' show C2cPlace;
import '../../../core/commission.dart' show Geo;
import '../../../core/format.dart' show formatMoney;
import '../../../core/premium_plus.dart';
import '../../../data/premium_plus_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../city_to_city/c2c_widgets.dart';
import '../geo/geo_data.dart' show regionsProvider;

const premiumPlusPath = '/admin/m/premium-plus';

enum _View {
  rules('Rules'),
  members('Members'),
  revenue('Revenue');

  const _View(this.label);
  final String label;
}

class PremiumPlusScreen extends ConsumerStatefulWidget {
  const PremiumPlusScreen({super.key});

  @override
  ConsumerState<PremiumPlusScreen> createState() => _PremiumPlusScreenState();
}

class _PremiumPlusScreenState extends ConsumerState<PremiumPlusScreen> {
  _View _view = _View.rules;

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(premiumPlusPage)) == AccessLevel.edit;
    return AdminPage(
      title: 'Premium and GET.Plus',
      page: premiumPlusPage,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SegmentedButton<_View>(
            key: const ValueKey('pp-views'),
            showSelectedIcon: false,
            segments: [
              for (final v in _View.values)
                ButtonSegment(value: v, label: Text(v.label, key: ValueKey('pp-view-${v.name}'))),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
        ),
        Expanded(
          child: switch (_view) {
            _View.rules => _RulesView(canEdit: canEdit),
            _View.members => const _MembersView(),
            _View.revenue => const _RevenueView(),
          },
        ),
      ]),
    );
  }
}

// ---- Rules --------------------------------------------------------------------------------------------

class _RulesView extends ConsumerStatefulWidget {
  const _RulesView({required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<_RulesView> createState() => _RulesViewState();
}

class _RulesViewState extends ConsumerState<_RulesView> {
  /// The place shown, by key ('' is Default).
  String _selected = '';

  /// Edits not saved yet, by place key.
  final _drafts = <String, Map<String, dynamic>>{};

  /// Region rules added here and not saved yet.
  final _added = <PremiumPlusPlace>[];

  List<PremiumPlusPlace> _places(List<PremiumPlusPlace> stored) {
    final all = [
      ...stored,
      for (final a in _added)
        if (!stored.any((s) => s.key == a.key)) a,
    ];
    if (!all.any((p) => p.isDefault)) all.insert(0, const PremiumPlusPlace(level: 'default'));
    return [for (final p in all) _drafts.containsKey(p.key) ? p.withRules(_drafts[p.key]!) : p];
  }

  Geo _geo(PremiumPlusPlace p) => Geo(country: p.country, state: p.state, city: p.city, suburb: p.suburb);

  void _set(PremiumPlusPlace p, String key, Object? value) {
    final next = {...p.rules};
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    setState(() => _drafts[p.key] = next);
  }

  bool _changed(PremiumPlusPlace shown, List<PremiumPlusPlace> stored) {
    final was = stored.where((s) => s.key == shown.key).firstOrNull;
    if (was == null) return true;
    return !_sameRules(was.rules, shown.rules);
  }

  static bool _sameRules(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a.length == b.length && a.entries.every((e) => b.containsKey(e.key) && '${b[e.key]}' == '${e.value}');

  Future<void> _save(PremiumPlusPlace p) async {
    final why = premiumPlusRulesProblem(p.rules);
    if (why != null) {
      showError(context, why);
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(premiumPlusRepositoryProvider).savePlace(p),
      success: '${p.label} saved',
    );
    if (!ok || !mounted) return;
    setState(() {
      _drafts.remove(p.key);
      _added.removeWhere((a) => a.key == p.key);
    });
    ref.invalidate(premiumPlusPlacesProvider);
  }

  Future<void> _delete(PremiumPlusPlace p) async {
    if (p.id == null) {
      setState(() {
        _added.removeWhere((a) => a.key == p.key);
        _drafts.remove(p.key);
        _selected = '';
      });
      return;
    }
    final sure = await showAppDialog<bool>(
      id: 'admin.premium-plus-remove',
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        content: const Text('Its rides then follow the place above it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('pp-remove-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(premiumPlusRepositoryProvider).deletePlace(p.id!),
      success: 'Removed ${p.name}',
    );
    if (!ok || !mounted) return;
    setState(() {
      _drafts.remove(p.key);
      _selected = '';
    });
    ref.invalidate(premiumPlusPlacesProvider);
  }

  Future<void> _add(List<PremiumPlusPlace> places) async {
    List<C2cPlace> choices;
    try {
      choices = c2cPlaceChoices(await ref.read(regionsProvider.future));
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final taken = {for (final p in places) p.key};
    final picked = await pickC2cPlace(
      context,
      title: 'Add a region rule',
      choices: [for (final c in choices) if (!taken.contains(_fromC2c(c).key)) c],
    );
    if (picked == null || !mounted) return;
    final p = _fromC2c(picked);
    setState(() {
      _added.add(p);
      _selected = p.key;
    });
  }

  static PremiumPlusPlace _fromC2c(C2cPlace c) =>
      PremiumPlusPlace(level: c.level, country: c.country, state: c.state, city: c.city, suburb: c.suburb);

  Future<void> _addModel(PremiumPlusPlace p, List<String> current) async {
    final name = await showAppDialog<String>(
      id: 'admin.premium-model',
      context: context,
      builder: (_) => const _ModelDialog(),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final t = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (current.any((m) => premiumNameKey(m) == premiumNameKey(t))) return;
    _set(p, 'premiumModels', [...current, t]);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(premiumPlusPlacesProvider);
    return AsyncView(
      value: async,
      onRetry: () => ref.invalidate(premiumPlusPlacesProvider),
      data: (stored) {
        final places = _places(stored);
        final p = places.where((x) => x.key == _selected).firstOrNull ?? places.first;
        final here = premiumPlusRulesAt(places, _geo(p));
        final edit = widget.canEdit;
        final problem = premiumPlusRulesProblem(p.rules);
        final changed = _changed(p, stored);

        final list = _PlaceList(
          places: places,
          selected: p.key,
          onPick: (k) => setState(() => _selected = k),
          onAdd: edit ? () => _add(places) : null,
        );
        final cards = [
          _PremiumCard(
            place: p,
            here: here,
            onSet: edit ? (k, v) => _set(p, k, v) : null,
            onAddModel: edit ? () => _addModel(p, here.models) : null,
          ),
          _PlusCard(place: p, here: here, onSet: edit ? (k, v) => _set(p, k, v) : null),
        ];
        final save = !edit
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(
                    problem ?? (changed ? '${p.label}: not saved yet.' : '${p.label}: saved.'),
                    key: const ValueKey('pp-state'),
                    style: TextStyle(
                      color: problem != null
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (!p.isDefault)
                    OutlinedButton.icon(
                      key: const ValueKey('pp-remove'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                      onPressed: () => _delete(p),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove this rule'),
                    ),
                  FilledButton.icon(
                    key: const ValueKey('pp-save'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: changed && problem == null ? () => _save(p) : null,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                  ),
                ]),
              );
        final intro = Text(
          'A Default rule and a rule per region: the most specific place wins, and a region rule only '
          'overrides what it sets. Which services are Premium: Vehicle Services › Premium.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        );
        return LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 900;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  intro,
                  const SizedBox(height: 12),
                  if (wide)
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 260, child: list),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(child: cards[0]),
                            const SizedBox(width: 12),
                            Expanded(child: cards[1]),
                          ]),
                          save,
                        ]),
                      ),
                    ])
                  else ...[list, const SizedBox(height: 12), ...cards, save],
                ]),
              ),
            ),
          );
        });
      },
    );
  }
}

class _PlaceList extends StatelessWidget {
  const _PlaceList({required this.places, required this.selected, required this.onPick, this.onAdd});
  final List<PremiumPlusPlace> places;
  final String selected;
  final ValueChanged<String> onPick;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('pp-places'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final p in places)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ListTile(
                key: ValueKey('pp-place-${p.isDefault ? 'default' : p.key}'),
                minTileHeight: 48,
                selected: p.key == selected,
                selectedTileColor: s.secondaryContainer,
                selectedColor: s.onSecondaryContainer,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                leading: Icon(p.isDefault ? Icons.public : Icons.location_on_outlined),
                title: Text(p.isDefault ? 'Default' : p.name),
                subtitle: p.isDefault ? null : Text(p.within.isEmpty ? p.level : '${p.level} · ${p.within}'),
                onTap: () => onPick(p.key),
              ),
            ),
          if (onAdd != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton.icon(
                key: const ValueKey('pp-add-region'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: onAdd,
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const Text('Add a region rule'),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A card's switch with, on a region, whether it is set here and a reset.
class _CardSwitch extends StatelessWidget {
  const _CardSwitch({
    required this.keyName,
    required this.place,
    required this.value,
    required this.title,
    this.subtitle,
    this.onSet,
  });
  final String keyName;
  final PremiumPlusPlace place;
  final bool value;
  final String title;
  final String? subtitle;
  final void Function(String key, Object? value)? onSet;

  @override
  Widget build(BuildContext context) {
    final setHere = place.isDefault || place.rules.containsKey(keyName);
    final on = onSet;
    return Row(children: [
      Expanded(
        child: SwitchListTile(
          key: ValueKey('pp-$keyName'),
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text([?subtitle, if (!setHere) 'As the place above'].join('. ')),
          value: value,
          onChanged: on == null ? null : (v) => on(keyName, v),
        ),
      ),
      if (!setHere || on == null)
        const SizedBox.shrink()
      else if (!place.isDefault)
        IconButton(
          key: ValueKey('pp-reset-$keyName'),
          tooltip: 'Use the place above',
          icon: const Icon(Icons.undo),
          onPressed: () => on(keyName, null),
        ),
    ]);
  }
}

/// The numbers of one card as steppers, each set here or as above.
List<Widget> _steppers(
  BuildContext context,
  List<PremiumPlusField> fields,
  PremiumPlusPlace place,
  PremiumPlusRules here,
  void Function(String key, Object? value)? onSet,
) {
  final out = <Widget>[];
  for (final f in fields) {
    final v = here.number(f.key);
    final setHere = place.isDefault || place.rules.containsKey(f.key);
    num clamp(double x) {
      final c = x < f.min ? f.min : (x > f.max ? f.max : x);
      final r = (c * 100).round() / 100;
      return f.whole ? r.round() : r;
    }

    out.add(Row(children: [
      Expanded(
        child: C2cStepper(
          label: f.label,
          hint: setHere ? null : 'As the place above',
          value: f.show(v),
          valueKey: ValueKey('pp-value-${f.key}'),
          onDown: onSet == null || v <= f.min ? null : () => onSet(f.key, clamp(v - f.step)),
          onUp: onSet == null || v >= f.max ? null : () => onSet(f.key, clamp(v + f.step)),
        ),
      ),
      if (setHere && !place.isDefault && onSet != null)
        IconButton(
          key: ValueKey('pp-reset-${f.key}'),
          tooltip: 'Use the place above',
          icon: const Icon(Icons.undo),
          onPressed: () => onSet(f.key, null),
        ),
    ]));
  }
  return out;
}

class _PremiumCard extends StatelessWidget {
  const _PremiumCard({required this.place, required this.here, this.onSet, this.onAddModel});
  final PremiumPlusPlace place;
  final PremiumPlusRules here;
  final void Function(String key, Object? value)? onSet;
  final VoidCallback? onAddModel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final modelsHere = place.isDefault || place.rules.containsKey('premiumModels');
    final on = onSet;
    return Card(
      key: const ValueKey('pp-premium-card'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.diamond_outlined, 'Premium service'),
          _CardSwitch(
            keyName: 'premiumOn',
            place: place,
            value: here.premiumOn,
            title: 'Premium rules',
            subtitle: 'Off: any driver who takes the service',
            onSet: on,
          ),
          if (here.premiumOn) ...[
            ..._steppers(context, premiumFields, place, here, on),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text('Allowed car models', style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500))),
              if (modelsHere && !place.isDefault && on != null)
                IconButton(
                  key: const ValueKey('pp-reset-premiumModels'),
                  tooltip: 'Use the place above',
                  icon: const Icon(Icons.undo),
                  onPressed: () => on('premiumModels', null),
                ),
            ]),
            Text(
              [
                'A make alone allows its every model. None listed: any car.',
                if (!modelsHere) 'As the place above.',
              ].join(' '),
              style: muted,
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final m in here.models)
                on == null
                    ? Chip(key: ValueKey('pp-model-$m'), label: Text(m), visualDensity: VisualDensity.compact)
                    : InputChip(
                        key: ValueKey('pp-model-$m'),
                        label: Text(m),
                        deleteButtonTooltipMessage: 'Remove $m',
                        onDeleted: () => on('premiumModels', [for (final x in here.models) if (x != m) x]),
                      ),
              if (here.models.isEmpty) Text('Any car', key: const ValueKey('pp-models-any'), style: muted),
              if (onAddModel != null)
                ActionChip(
                  key: const ValueKey('pp-model-add'),
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Add a model'),
                  onPressed: onAddModel,
                ),
            ]),
          ],
          const SizedBox(height: 10),
          Text(
            'Checked on the server when a driver offers on or takes a Premium request; drivers who don\'t '
            'qualify don\'t see those requests, and their Services page says why.',
            style: muted,
          ),
        ]),
      ),
    );
  }
}

class _PlusCard extends StatelessWidget {
  const _PlusCard({required this.place, required this.here, this.onSet});
  final PremiumPlusPlace place;
  final PremiumPlusRules here;
  final void Function(String key, Object? value)? onSet;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Card(
      key: const ValueKey('pp-plus-card'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const C2cCardTitle(Icons.workspace_premium_outlined, 'GET.Plus rider membership'),
          _CardSwitch(
            keyName: 'plusOn',
            place: place,
            value: here.plusOn,
            title: 'Sell GET.Plus here',
            subtitle: 'Off: no joining and no member benefits for pickups here',
            onSet: onSet,
          ),
          if (here.plusOn) ...[
            ..._steppers(context, plusFields, place, here, onSet),
            _CardSwitch(
              keyName: 'plusPriority',
              place: place,
              value: here.priority,
              title: 'Priority matching',
              subtitle: 'Members\' requests first in drivers\' lists',
              onSet: onSet,
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'Paid monthly from GET.wallet and renewed by itself; members cancel any time and keep it to the '
            'month\'s end. The driver still gets the full fare: get.ride credits them the member\'s discount '
            'out of its commission. A free cancel pays the driver what the fee would have.',
            style: muted,
          ),
        ]),
      ),
    );
  }
}

class _ModelDialog extends StatefulWidget {
  const _ModelDialog();

  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _c.text.trim();
    final ok = t.isNotEmpty && t.length <= 80;
    return AlertDialog(
      title: const Text('Add a car model'),
      content: SizedBox(
        width: 380,
        child: TextField(
          key: const ValueKey('pp-model-name'),
          controller: _c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Make, or make and model',
            helperText: 'Toyota allows every Toyota; Toyota Camry only the Camry',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: ok ? (_) => Navigator.pop(context, t) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('pp-model-save'),
          onPressed: ok ? () => Navigator.pop(context, t) : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

// ---- Members ------------------------------------------------------------------------------------------

typedef _MembersQuery = ({String? status, String search, int limit});

final _membersProvider = FutureProvider.autoDispose.family<PlusMembersPage, _MembersQuery>(
  (ref, q) => ref
      .watch(premiumPlusRepositoryProvider)
      .members(status: q.status, search: q.search.isEmpty ? null : q.search, limit: q.limit),
);

class _MembersView extends ConsumerStatefulWidget {
  const _MembersView();

  @override
  ConsumerState<_MembersView> createState() => _MembersViewState();
}

class _MembersViewState extends ConsumerState<_MembersView> {
  final _search = TextEditingController();
  String? _status;
  String _query = '';
  int _limit = 50;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = (status: _status, search: _query, limit: _limit);
    final value = ref.watch(_membersProvider(q));
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 320,
          child: TextField(
            key: const ValueKey('pp-members-search'),
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              labelText: 'Search by name or phone',
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) => setState(() {
              _query = v.trim();
              _limit = 50;
            }),
          ),
        ),
        Wrap(spacing: 6, children: [
          for (final s in [null, ...PlusStatus.values])
            ChoiceChip(
              key: ValueKey('pp-members-${s?.name ?? 'all'}'),
              label: Text(s?.label ?? 'All'),
              selected: _status == s?.name,
              onSelected: (_) => setState(() {
                _status = s?.name;
                _limit = 50;
              }),
            ),
        ]),
      ]),
      const SizedBox(height: 12),
      AsyncView(
        value: value,
        onRetry: () => ref.invalidate(_membersProvider(q)),
        data: (page) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${page.total} ${page.total == 1 ? 'member' : 'members'}', key: const ValueKey('pp-members-total'),
              style: t.textTheme.titleSmall),
          const SizedBox(height: 6),
          if (page.rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('No members here yet.', style: t.textTheme.bodyMedium),
            )
          else
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (final (i, m) in page.rows.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  _MemberTile(m: m),
                ],
              ]),
            ),
          if (page.rows.length < page.total)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: OutlinedButton(
                  key: const ValueKey('pp-members-more'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => setState(() => _limit += 50),
                  child: const Text('Show more'),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }
}

String _day(DateTime? d) => d == null ? '' : '${d.day} ${_months[d.month - 1]} ${d.year}';
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.m});
  final PlusMemberRow m;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final status = switch (m.status) {
      PlusStatus.active when !m.autoRenew => 'Cancelling, ends ${_day(m.periodEnd)}',
      PlusStatus.active => 'Active, renews ${_day(m.periodEnd)}',
      PlusStatus.grace => 'Payment due by ${_day(m.graceUntil)}',
      PlusStatus.ended => 'Ended',
      PlusStatus.expired => 'Expired: wallet short',
    };
    return ListTile(
      key: ValueKey('pp-member-${m.riderId}'),
      leading: Icon(m.live ? Icons.workspace_premium : Icons.workspace_premium_outlined,
          color: m.live ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
      title: Text(m.name ?? m.phone ?? m.riderId),
      subtitle: Text([
        status,
        if (m.phone != null && m.name != null) m.phone!,
        if (m.place != null) m.place!,
        'Paid ${formatMoney(m.paid)} · saved ${formatMoney(m.saved)}',
        if (m.freeCancelsUsed > 0) '${m.freeCancelsUsed} free ${m.freeCancelsUsed == 1 ? 'cancel' : 'cancels'} used',
      ].join(' · ')),
      trailing: Text(formatMoney(m.price), style: t.textTheme.titleSmall),
    );
  }
}

// ---- Revenue ------------------------------------------------------------------------------------------

final _revenueProvider = FutureProvider.autoDispose.family<PlusRevenue, int>(
  (ref, days) => ref.watch(premiumPlusRepositoryProvider).revenue(days: days),
);

class _RevenueView extends ConsumerStatefulWidget {
  const _RevenueView();

  @override
  ConsumerState<_RevenueView> createState() => _RevenueViewState();
}

class _RevenueViewState extends ConsumerState<_RevenueView> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final value = ref.watch(_revenueProvider(_days));
    return ListView(padding: const EdgeInsets.all(16), children: [
      Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<int>(
          key: const ValueKey('pp-revenue-days'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 7, label: Text('7 days')),
            ButtonSegment(value: 30, label: Text('30 days')),
            ButtonSegment(value: 90, label: Text('90 days')),
          ],
          selected: {_days},
          onSelectionChanged: (s) => setState(() => _days = s.first),
        ),
      ),
      const SizedBox(height: 12),
      AsyncView(
        value: value,
        onRetry: () => ref.invalidate(_revenueProvider(_days)),
        data: (r) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 12, runSpacing: 12, children: [
            _Tile('Members now', '${r.active}', note: '${r.cancelling} cancelling, ${r.grace} payment due', k: 'active'),
            _Tile('Fees collected', formatMoney(r.fees), note: '${r.joins} joins, ${r.renewals} renewals', k: 'fees'),
            _Tile('Discounts funded', formatMoney(r.discounts), note: '${r.discountedRides} rides', k: 'discounts'),
            _Tile('Free cancels paid', formatMoney(r.waivedPaid), note: '${r.freeCancels} cancels', k: 'waived'),
            _Tile('GET.Plus net', formatMoney(r.net), note: 'Fees less discounts and free cancels', k: 'net'),
            _Tile('Commission on members\' rides', formatMoney(r.commissionOnMemberRides),
                note: '${r.failed} renewals failed', k: 'commission'),
          ]),
          const SizedBox(height: 12),
          Text(
            'Drivers are paid the full fare: the discount and the free cancels come out of get.ride\'s commission. '
            'Fees are what members paid from GET.wallet in the period.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {required this.note, required this.k});
  final String label, value, note, k;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      width: 250,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(value, key: ValueKey('pp-revenue-$k'), style: t.textTheme.headlineSmall),
            const SizedBox(height: 2),
            Text(note, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}
