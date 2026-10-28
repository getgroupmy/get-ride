// Admin > Services & catalogue > City ride extras (migration 0314): a
// Default rule and a rule per region (country, state, city or suburb; the
// most specific wins, and a region rule only overrides the cards it sets),
// each card switchable on or off, every value with − and +. The cards are
// [cityRideExtrasCards]: tips, waiting charge and luggage now; rider audio,
// Premium and GET.Plus join the same list later.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/city_ride_extras.dart';
import '../../core/city_to_city.dart' show C2cPlace;
import '../../core/partner_type_rules.dart' show RegionScope;
import '../../core/ride_option_places.dart' show OptionPlaceScope;
import '../../data/city_ride_extras_repository.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../admin_registry.dart' show AdminScreenEntry;
import '../widgets/admin_widgets.dart';
import 'city_to_city/c2c_widgets.dart';
import 'geo/geo_data.dart' show regionsProvider;
import 'geo/geo_logic.dart' show RegionEntry;

const cityRideExtrasPath = '/admin/m/city-ride-extras';

final cityRideExtrasRoutes = <RouteBase>[
  GoRoute(path: cityRideExtrasPath, builder: (_, _) => const CityRideExtrasScreen()),
];

const cityRideExtrasEntries = <AdminScreenEntry>[
  AdminScreenEntry(
    section: 'Services & catalogue',
    title: 'City ride extras',
    subtitle: 'Tips, the waiting charge and luggage, by region',
    path: cityRideExtrasPath,
    pages: [cityRideExtrasPage],
    icon: Icons.volunteer_activism_outlined,
  ),
];

/// Each card's icon; a card without one shows a generic icon.
const cityRideExtrasIcons = <String, IconData>{
  'tips': Icons.volunteer_activism_outlined,
  'waiting': Icons.hourglass_top,
  'luggage': Icons.luggage_outlined,
};

class CityRideExtrasScreen extends ConsumerStatefulWidget {
  const CityRideExtrasScreen({super.key});

  @override
  ConsumerState<CityRideExtrasScreen> createState() => _CityRideExtrasScreenState();
}

class _CityRideExtrasScreenState extends ConsumerState<CityRideExtrasScreen> {
  /// The place shown (its scope key; '' is Default).
  String _selected = '';

  /// Edits not saved yet, by place key; a new place lives only here.
  final Map<String, ExtrasPlace> _drafts = {};

  List<ExtrasPlace> _merged(List<ExtrasPlace> stored) {
    final out = [for (final p in stored) _drafts[p.scope.key] ?? p];
    for (final d in _drafts.values) {
      if (!stored.any((p) => p.scope.key == d.scope.key)) out.add(d);
    }
    if (!out.any((p) => p.isDefault)) out.insert(0, const ExtrasPlace());
    out.sort((a, b) {
      final r = a.scope.rank.compareTo(b.scope.rank);
      return r != 0 ? r : a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return out;
  }

  bool _changed(ExtrasPlace p, List<ExtrasPlace> stored) {
    final d = _drafts[p.scope.key];
    if (d == null) return false;
    final s = stored.where((x) => x.scope.key == p.scope.key).firstOrNull;
    return s == null || '${s.rules}' != '${d.rules}';
  }

  Future<void> _addPlace(List<ExtrasPlace> all) async {
    final regions = ref.read(regionsProvider).value ?? const <RegionEntry>[];
    final picked = await pickC2cPlace(
      context,
      title: 'Add a region rule',
      choices: c2cPlaceChoices(regions),
      taken: [
        for (final p in all)
          if (!p.isDefault) _c2cOf(p.scope),
      ],
    );
    if (picked == null || !mounted) return;
    final scope = RegionScope(
      country: picked.country,
      state: picked.state ?? '',
      city: picked.city ?? '',
      suburb: picked.suburb ?? '',
    );
    setState(() {
      _drafts[scope.key] = ExtrasPlace(scope: scope);
      _selected = scope.key;
    });
  }

  C2cPlace _c2cOf(RegionScope s) => C2cPlace(
    level: s.level,
    country: s.country,
    state: s.state.isEmpty ? null : s.state,
    city: s.city.isEmpty ? null : s.city,
    suburb: s.suburb.isEmpty ? null : s.suburb,
  );

  Future<void> _save(ExtrasPlace p) async {
    for (final e in p.rules.entries) {
      final why = extrasSectionProblem(e.key, e.value);
      if (why != null) return showError(context, why);
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(cityRideExtrasRepositoryProvider).savePlace(p),
      success: '${p.label}: saved',
    );
    if (!ok || !mounted) return;
    setState(() => _drafts.remove(p.scope.key));
    ref.invalidate(adminCityRideExtraPlacesProvider);
    ref.invalidate(cityRideExtraPlacesProvider);
  }

  Future<void> _remove(ExtrasPlace p) async {
    final id = p.id;
    if (id == null) {
      setState(() {
        _drafts.remove(p.scope.key);
        _selected = '';
      });
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(cityRideExtrasRepositoryProvider).deletePlace(id),
      success: 'Removed ${p.label}',
    );
    if (!ok || !mounted) return;
    setState(() {
      _drafts.remove(p.scope.key);
      _selected = '';
    });
    ref.invalidate(adminCityRideExtraPlacesProvider);
    ref.invalidate(cityRideExtraPlacesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(cityRideExtrasPage)) == AccessLevel.edit;
    ref.watch(regionsProvider);
    return AdminPage(
      title: 'City ride extras',
      page: cityRideExtrasPage,
      body: AsyncView(
        value: ref.watch(adminCityRideExtraPlacesProvider),
        onRetry: () => ref.invalidate(adminCityRideExtraPlacesProvider),
        data: (stored) {
          final all = _merged(stored);
          final place = all.where((p) => p.scope.key == _selected).firstOrNull ?? all.first;
          final rules = _RulesList(
            places: all,
            selected: place.scope.key,
            changed: {for (final p in all) if (_changed(p, stored)) p.scope.key},
            onPick: (k) => setState(() => _selected = k),
            onAdd: canEdit ? () => _addPlace(all) : null,
          );
          final cards = _PlaceCards(
            key: ValueKey('extras-place-${place.scope.key}'),
            place: place,
            all: all,
            canEdit: canEdit,
            changed: _changed(place, stored),
            onChanged: (p) => setState(() => _drafts[p.scope.key] = p),
            onSave: () => _save(place),
            onRemove: place.isDefault ? null : () => _remove(place),
          );
          return LayoutBuilder(builder: (context, c) {
            final t = Theme.of(context);
            final intro = Text(
              'A default rule and a rule per region: the most specific region wins, and a region rule only '
              'overrides the cards it sets. Every value is editable; the server works out every charge.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            );
            if (c.maxWidth >= 900) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  intro,
                  const SizedBox(height: 16),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 260, child: rules),
                    const SizedBox(width: 18),
                    Expanded(child: cards),
                  ]),
                ]),
              );
            }
            return ListView(padding: const EdgeInsets.all(16), children: [
              intro,
              const SizedBox(height: 12),
              rules,
              const SizedBox(height: 12),
              cards,
            ]);
          });
        },
      ),
    );
  }
}

/// Default and the region rules, one picked.
class _RulesList extends StatelessWidget {
  const _RulesList({required this.places, required this.selected, required this.changed, required this.onPick, this.onAdd});

  final List<ExtrasPlace> places;
  final String selected;
  final Set<String> changed;
  final ValueChanged<String> onPick;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('extras-rules'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final p in places)
            ListTile(
              key: ValueKey('extras-rule-${p.isDefault ? 'default' : p.scope.key}'),
              selected: p.scope.key == selected,
              selectedTileColor: t.colorScheme.secondaryContainer,
              selectedColor: t.colorScheme.onSecondaryContainer,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              leading: Icon(p.isDefault ? Icons.public : Icons.location_on_outlined),
              title: Text(p.isDefault ? 'Default' : p.label),
              subtitle: p.isDefault
                  ? const Text('Everywhere')
                  : Text(p.rules.isEmpty ? 'Sets nothing yet' : 'Sets ${p.rules.keys.map(_cardTitle).join(', ')}'),
              trailing: changed.contains(p.scope.key) ? const Icon(Icons.edit_note, semanticLabel: 'Not saved') : null,
              onTap: () => onPick(p.scope.key),
            ),
          if (onAdd != null) ...[
            const SizedBox(height: 4),
            OutlinedButton.icon(
              key: const ValueKey('extras-add-rule'),
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add a region rule'),
            ),
          ],
        ]),
      ),
    );
  }
}

String _cardTitle(String section) =>
    cityRideExtrasCards.where((c) => c.section == section).firstOrNull?.title.toLowerCase() ?? section;

/// One place's cards.
class _PlaceCards extends StatelessWidget {
  const _PlaceCards({
    super.key,
    required this.place,
    required this.all,
    required this.canEdit,
    required this.changed,
    required this.onChanged,
    required this.onSave,
    this.onRemove,
  });

  final ExtrasPlace place;
  final List<ExtrasPlace> all;
  final bool canEdit, changed;
  final ValueChanged<ExtrasPlace> onChanged;
  final VoidCallback onSave;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final parent = place.scope.parent;
    // What this place would get from the places above it.
    final above = parent == null ? null : CityRideExtras.resolve(all, parent);
    final here = CityRideExtras.resolve(all, place.scope);
    final cards = [
      for (final card in cityRideExtrasCards)
        _ExtrasCardView(
          card: card,
          values: here.section(card.section),
          own: place.isDefault || place.sets(card.section),
          inheritedFrom: parent == null ? null : _setterOf(card.section, parent),
          canEdit: canEdit,
          onSetHere: place.isDefault
              ? null
              : (on) => onChanged(place.withSection(card.section, on ? Map.of(above!.section(card.section)) : null)),
          onValue: (k, v) {
            final cur = Map<String, Object?>.of(place.rules[card.section] ?? const {});
            if (!place.isDefault && cur.isEmpty) cur.addAll(above!.section(card.section));
            cur[k] = v;
            onChanged(place.withSection(card.section, cur));
          },
        ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(place.isDefault ? 'Default (everywhere)' : place.scope.label, style: t.textTheme.titleLarge),
        ),
        if (canEdit && onRemove != null)
          TextButton.icon(
            key: const ValueKey('extras-remove-rule'),
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Remove rule'),
          ),
      ]),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, c) {
        final two = c.maxWidth >= 640;
        if (!two) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final w in cards) Padding(padding: const EdgeInsets.only(bottom: 12), child: w),
          ]);
        }
        final w = (c.maxWidth - 14) / 2;
        return Wrap(spacing: 14, runSpacing: 14, children: [for (final card in cards) SizedBox(width: w, child: card)]);
      }),
      if (canEdit) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const ValueKey('extras-save'),
            onPressed: changed ? onSave : null,
            icon: const Icon(Icons.save_outlined),
            label: Text('Save ${place.isDefault ? 'Default' : place.label}'),
          ),
        ),
      ],
    ]);
  }

  /// The nearest place at or above [from] that sets [section], for "From …".
  String _setterOf(String section, RegionScope from) {
    final byKey = {for (final p in all) p.scope.key: p};
    for (final s in from.chain) {
      final p = byKey[s.key];
      if (p != null && p.sets(section)) return p.isDefault ? 'Default' : p.label;
    }
    return 'the built-in values';
  }
}

class _ExtrasCardView extends StatelessWidget {
  const _ExtrasCardView({
    required this.card,
    required this.values,
    required this.own,
    required this.canEdit,
    required this.onValue,
    this.inheritedFrom,
    this.onSetHere,
  });

  final ExtrasCard card;
  final Map<String, Object?> values;

  /// This place sets the card (Default always does).
  final bool own;
  final bool canEdit;
  final String? inheritedFrom;
  final ValueChanged<bool>? onSetHere;
  final void Function(String key, Object value) onValue;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final on = values['on'] != false;
    final editable = canEdit && own;
    double val(String k, double f) => values[k] is num ? (values[k] as num).toDouble() : f;
    return Card(
      key: ValueKey('extras-card-${card.section}'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: t.colorScheme.outlineVariant),
      ),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(cityRideExtrasIcons[card.section] ?? Icons.tune, color: t.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(card.title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
            Switch(
              key: ValueKey('extras-on-${card.section}'),
              value: on,
              onChanged: editable ? (v) => onValue('on', v) : null,
            ),
          ]),
          if (onSetHere != null)
            CheckboxListTile(
              key: ValueKey('extras-set-here-${card.section}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: own,
              onChanged: canEdit ? (v) => onSetHere!(v ?? false) : null,
              title: const Text('Set for this region'),
              subtitle: own ? null : Text('Uses ${inheritedFrom ?? 'the place above'}'),
            ),
          if (on)
            for (final f in card.fields)
              C2cStepper(
                key: ValueKey('extras-${card.section}-${f.key}'),
                label: f.label,
                value: f.show(val(f.key, f.min), extrasMoney),
                valueKey: ValueKey('extras-${card.section}-${f.key}-value'),
                onDown: editable && f.stepped(val(f.key, f.min), -1) != null
                    ? () => onValue(f.key, f.stepped(val(f.key, f.min), -1)!)
                    : null,
                onUp: editable && f.stepped(val(f.key, f.min), 1) != null
                    ? () => onValue(f.key, f.stepped(val(f.key, f.min), 1)!)
                    : null,
              )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('Off here.', style: t.textTheme.bodyMedium),
            ),
          const SizedBox(height: 4),
          Text(card.note, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
