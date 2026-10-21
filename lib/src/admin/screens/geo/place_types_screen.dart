// Admin > Geography > Place types (migration 0264): the types a Multi-Gate
// place can have, each a Google Places type (shopping_mall, airport, ...)
// with a friendly name, a Material icon and a chip colour for light and dark
// (Google Maps' category colours to start), shown next to the place to
// riders and drivers. New types are picked from the Google type list. The list (icon, name, how many
// places use it) on one side, the editor on the other (stacked on a phone).
// A type in use is removed by moving its places to another type first
// (place_type_remove; Other by default).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/place_types.dart';
import '../../../data/live_tables.dart';
import '../../../providers.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/place_type_badge.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'geo_data.dart' show multiGatePlacesProvider;

const placeTypesPath = '/admin/m/place-types';

/// The page key that grants this page (Multi-Gate Places' grant edits the
/// types too, as `admin_table_pages` says).
const placeTypesPage = 'admin-settings-place-types';
const _placesPage = 'admin-settings-multi-gate-places';

// ---- Data ------------------------------------------------------------------------

/// Every type as stored, in the admin's order (errors show on the page).
final adminPlaceTypesProvider = FutureProvider.autoDispose<List<PlaceType>>((ref) async {
  ref.watchLive('place_types');
  final rows = await ref
      .watch(supabaseProvider)
      .from('place_types')
      .select('key, name, icon, color, color_dark, sort_order, active')
      .order('sort_order', ascending: true)
      .order('name', ascending: true);
  return sortPlaceTypes([for (final r in rows) PlaceType.fromRow(Map<String, dynamic>.from(r))]);
});

Future<void> _saveType(WidgetRef ref, PlaceType t) =>
    ref.read(supabaseProvider).from('place_types').upsert(t.toRow(), onConflict: 'key');

Future<void> _removeType(WidgetRef ref, String key, String moveTo) =>
    ref.read(supabaseProvider).rpc('place_type_remove', params: {'p_key': key, 'p_move_to': moveTo});

/// Colours offered: Google Maps' category colours first, then a few deeper
/// ones (a dark screen may want those).
const placeTypeColorPresets = <String>[
  placeColorShopping, placeColorTransport, placeColorHealth, placeColorLodging, placeColorCivic, placeColorPark,
  placeColorAttraction, placeColorFood, '#1a73e8', '#0b8043', '#c5221f', '#e37400', '#8430ce', '#5f6368',
];

/// "local_mall" as "Local mall".
String placeTypeIconLabel(String name) {
  final s = name.replaceAll('_', ' ');
  return s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

/// Asks for one of the curated icons, searchable; null when cancelled.
Future<String?> pickPlaceTypeIcon(BuildContext context, String? current) => showSearchPicker<String>(
      context,
      title: 'Choose an icon',
      selected: current,
      choices: [
        for (final e in placeTypeIcons.entries)
          (value: e.key, label: placeTypeIconLabel(e.key), subtitle: null, leading: Icon(e.value)),
      ],
    );

/// Asks for a colour (`#rrggbb`) from [presets] or typed; null when
/// cancelled.
Future<String?> pickPlaceTypeColor(BuildContext context, String current, String title, List<String> presets) {
  final hex = TextEditingController(text: current);
  return showAppDialog<String>(
    id: 'admin-place-types.colour',
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        final preview = parsePlaceTypeColor(hex.text);
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in presets)
                      InkWell(
                        key: ValueKey('place-type-colour-$p'),
                        customBorder: const CircleBorder(),
                        onTap: () => set(() => hex.text = p),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: parsePlaceTypeColor(p),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(c).colorScheme.outline,
                              width: hex.text.toLowerCase() == p ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('place-type-colour-hex'),
                  controller: hex,
                  decoration: InputDecoration(
                    labelText: 'Colour (#RRGGBB)',
                    suffixIcon: Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircleAvatar(radius: 10, backgroundColor: preview ?? Colors.transparent),
                    ),
                  ),
                  onChanged: (_) => set(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('place-type-colour-ok'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: preview == null ? null : () => Navigator.pop(c, placeTypeHex(preview)),
              child: const Text('OK'),
            ),
          ],
        );
      },
    ),
  );
}

// ---- The page ----------------------------------------------------------------------

class PlaceTypesScreen extends ConsumerStatefulWidget {
  const PlaceTypesScreen({super.key});

  @override
  ConsumerState<PlaceTypesScreen> createState() => _PlaceTypesScreenState();
}

class _PlaceTypesScreenState extends ConsumerState<PlaceTypesScreen> {
  /// The type being edited (null: none; [_adding]: a new one), its draft.
  String? _sel;
  bool _adding = false;
  PlaceType? _draft;
  bool _dirty = false;
  bool _confirmRemove = false;
  String _moveTo = otherPlaceTypeKey;
  final _name = TextEditingController();
  final _order = TextEditingController();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // A change saved here or elsewhere shows at once; what is being typed
    // is kept until it is saved.
    ref.listenManual(adminPlaceTypesProvider, (_, next) {
      final types = next.value;
      if (types == null || _adding) return;
      final current = types.where((t) => t.key == _sel).firstOrNull;
      if (current == null) {
        _select(types.firstOrNull);
      } else if (!_dirty && current != _draft) {
        _select(current);
      }
    }, fireImmediately: true);
    _ready = true;
  }

  @override
  void dispose() {
    _name.dispose();
    _order.dispose();
    super.dispose();
  }

  void _select(PlaceType? t, {bool adding = false}) {
    void load() {
      _sel = t?.key;
      _adding = adding;
      _draft = t;
      _dirty = adding;
      _confirmRemove = false;
      _moveTo = otherPlaceTypeKey;
      _name.text = t?.name ?? '';
      _order.text = t == null ? '' : '${t.sortOrder}';
    }

    if (mounted && _ready) {
      setState(load);
    } else {
      load();
    }
  }

  void _edit(PlaceType Function(PlaceType d) change) => setState(() {
        if (_draft case final d?) _draft = change(d);
        _dirty = true;
      });

  bool _canEdit() =>
      ref.watch(pageAccessProvider(placeTypesPage)) == AccessLevel.edit ||
      ref.watch(pageAccessProvider(_placesPage)) == AccessLevel.edit;

  /// A new type: one of Google's place types not on the list yet, picked
  /// in a searchable list; it starts with its friendly name, icon and colour.
  Future<void> _add(List<PlaceType> types) async {
    final taken = {for (final t in types) t.key};
    final free = [for (final g in googlePlaceTypes) if (!taken.contains(g.key)) g];
    if (free.isEmpty) {
      showInfo(context, 'Every Google place type is on the list already.');
      return;
    }
    final picked = await showSearchPicker<String>(
      context,
      title: 'Add a Google place type',
      choices: [
        for (final g in free)
          (
            value: g.key,
            label: g.name,
            subtitle: g.key,
            leading: PlaceTypeIcon(type: PlaceType(key: g.key, name: g.name, icon: g.icon, color: g.color, colorDark: g.color), size: 28),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    final g = googlePlaceType(picked)!;
    final last = types.where((t) => t.key != otherPlaceTypeKey).fold<int>(0, (m, t) => t.sortOrder > m ? t.sortOrder : m);
    _select(
      PlaceType(key: g.key, name: g.name, icon: g.icon, color: g.color, colorDark: g.color, sortOrder: last + 10),
      adding: true,
    );
  }

  Future<void> _save(List<PlaceType> types) async {
    final d = _draft;
    if (d == null) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      showError(context, 'Enter a name for this type.');
      return;
    }
    final order = int.tryParse(_order.text.trim()) ?? d.sortOrder;
    final key = d.key;
    final row = PlaceType(
      key: key,
      name: name,
      icon: d.icon,
      color: d.color,
      colorDark: d.colorDark,
      sortOrder: order,
      active: key == otherPlaceTypeKey || d.active,
    );
    if (await runAdminAction(context, () => _saveType(ref, row),
        success: 'Saved. Riders and drivers see the change straight away.')) {
      _dirty = false;
      _adding = false;
      _sel = key;
      _draft = row;
      ref.invalidate(adminPlaceTypesProvider);
    }
  }

  Future<void> _remove(int inUse) async {
    final key = _sel;
    if (key == null) return;
    final moved = inUse > 0;
    if (await runAdminAction(context, () => _removeType(ref, key, _moveTo),
        success: moved ? 'Type removed. Its places were moved.' : 'Type removed.')) {
      _dirty = false;
      _sel = null;
      _draft = null;
      ref
        ..invalidate(adminPlaceTypesProvider)
        ..invalidate(multiGatePlacesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _canEdit();
    final value = ref.watch(adminPlaceTypesProvider);
    final places = ref.watch(multiGatePlacesProvider).value;
    final counts = places == null ? null : placeTypeCounts([for (final p in places) p.values]);
    return AdminPage(
      title: 'Place types',
      page: placeTypesPage,
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(adminPlaceTypesProvider),
        data: (types) {
          final wide = MediaQuery.sizeOf(context).width >= 900;
          final list = _TypeList(
            types: types,
            counts: counts,
            selected: _adding ? null : _sel,
            canEdit: canEdit,
            onSelect: (t) => _select(t),
            onAdd: () => _add(types),
          );
          final editor = _draft == null
              ? const _Panel(key: ValueKey('place-type-editor'), child: Text('Pick a type, or add one.'))
              : _editor(context, types, counts, canEdit);
          final t = Theme.of(context);
          return ResponsiveCenter(
            maxWidth: 1100,
            child: ListView(
              key: const ValueKey('place-types'),
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                Text(
                  "Each Multi-Gate place has a type, one of Google's place types. Its icon and colour show next "
                  "to the place in the rider's search results, saved places and map, and to the driver at a pickup "
                  'or drop-off there.',
                  style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)),
                ),
                const SizedBox(height: 16),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 100, child: list),
                      const SizedBox(width: 16),
                      Expanded(flex: 110, child: editor),
                    ],
                  )
                else ...[
                  list,
                  const SizedBox(height: 16),
                  editor,
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _editor(BuildContext context, List<PlaceType> types, Map<String, int>? counts, bool canEdit) {
    final d = _draft!;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t));
    final shown = d.copyWith(name: _name.text.trim().isEmpty ? d.name : _name.text.trim());
    final isOther = d.key == otherPlaceTypeKey;
    final inUse = counts?[d.key] ?? 0;
    final others = [for (final x in types) if (x.key != d.key) x];
    Widget colourRow(String label, String hex, Brightness b, ValueChanged<String> onPicked, Key key) => ListTile(
          key: key,
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: Text(hex),
          trailing: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: parsePlaceTypeColor(hex),
              shape: BoxShape.circle,
              border: Border.all(color: t.colorScheme.outline),
            ),
          ),
          onTap: canEdit
              ? () async {
                  final v = await pickPlaceTypeColor(context, hex, label, placeTypeColorPresets);
                  if (v != null) onPicked(v);
                }
              : null,
        );
    return _Panel(
      key: const ValueKey('place-type-editor'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(shown.name, style: t.textTheme.titleMedium),
          Text(
            _adding
                ? 'Google place type: ${d.key}'
                : 'Google place type: ${d.key} · ${inUse == 1 ? 'used by 1 place' : 'used by $inUse places'}',
            key: const ValueKey('place-type-key'),
            style: muted,
          ),
          const SizedBox(height: 12),
          // How riders see it, on a light and on a dark screen.
          Row(
            children: [
              for (final b in Brightness.values)
                Expanded(
                  child: Theme(
                    data: b == t.brightness ? t : ThemeData(brightness: b, useMaterial3: true),
                    child: Builder(
                      builder: (c) => Container(
                        key: ValueKey('place-type-preview-${b.name}'),
                        margin: EdgeInsetsDirectional.only(end: b == Brightness.light ? 8 : 0),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(c).colorScheme.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: t.colorScheme.outlineVariant),
                        ),
                        child: Row(children: [
                          PlaceTypeIcon(type: shown, size: 36),
                          const SizedBox(width: 8),
                          Flexible(child: PlaceTypePill(type: shown)),
                        ]),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('place-type-name'),
            controller: _name,
            enabled: canEdit,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder(), isDense: true, counterText: ''),
            onChanged: (_) => _edit((d) => d),
          ),
          const SizedBox(height: 8),
          ListTile(
            key: const ValueKey('place-type-icon'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(d.iconData),
            title: const Text('Icon'),
            subtitle: Text(placeTypeIconLabel(d.icon)),
            trailing: canEdit ? const Icon(Icons.chevron_right) : null,
            onTap: canEdit
                ? () async {
                    final v = await pickPlaceTypeIcon(context, d.icon);
                    if (v != null) _edit((d) => d.copyWith(icon: v));
                  }
                : null,
          ),
          colourRow('Colour on a light screen', d.color, Brightness.light, (v) => _edit((d) => d.copyWith(color: v)),
              const ValueKey('place-type-colour-light')),
          colourRow('Colour on a dark screen', d.colorDark, Brightness.dark,
              (v) => _edit((d) => d.copyWith(colorDark: v)), const ValueKey('place-type-colour-dark')),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('place-type-order'),
            controller: _order,
            enabled: canEdit,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            decoration: const InputDecoration(
              labelText: 'Order',
              helperText: 'Lower numbers come first in the lists.',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => _edit((d) => d),
          ),
          SwitchListTile(
            key: const ValueKey('place-type-active'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            subtitle: Text(isOther
                ? 'Other is always on: places without a type use it.'
                : d.active
                    ? 'Offered for places'
                    : 'Hidden: its places show as Other'),
            value: isOther || d.active,
            onChanged: canEdit && !isOther ? (v) => _edit((d) => d.copyWith(active: v)) : null,
          ),
          if (canEdit) ...[
            const SizedBox(height: 12),
            if (_confirmRemove)
              Container(
                key: const ValueKey('place-type-remove-confirm'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(10)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      inUse == 0
                          ? 'Remove ${shown.name}? No place uses it.'
                          : '${inUse == 1 ? '1 place uses' : '$inUse places use'} ${shown.name}. '
                              'Move ${inUse == 1 ? 'it' : 'them'} to another type, then remove it.',
                      style: TextStyle(color: t.colorScheme.onErrorContainer),
                    ),
                    if (inUse > 0) ...[
                      const SizedBox(height: 8),
                      SearchableDropdownFormField<String>(
                        key: const ValueKey('place-type-move-to'),
                        isExpanded: true,
                        initialValue: others.any((x) => x.key == _moveTo) ? _moveTo : others.firstOrNull?.key,
                        decoration: const InputDecoration(labelText: 'Move its places to', isDense: true),
                        items: [
                          for (final x in others)
                            DropdownMenuItem(
                              value: x.key,
                              child: Row(children: [
                                PlaceTypeIcon(type: x, size: 24),
                                const SizedBox(width: 8),
                                Flexible(child: Text(x.name, overflow: TextOverflow.ellipsis)),
                              ]),
                            ),
                        ],
                        onChanged: (v) => setState(() => _moveTo = v ?? otherPlaceTypeKey),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          key: const ValueKey('place-type-remove-cancel'),
                          onPressed: () => setState(() => _confirmRemove = false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          key: const ValueKey('place-type-remove-yes'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            backgroundColor: t.colorScheme.error,
                            foregroundColor: t.colorScheme.onError,
                          ),
                          onPressed: () => _remove(inUse),
                          child: Text(inUse == 0 ? 'Remove type' : 'Move and remove'),
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
                    key: const ValueKey('place-type-save'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: () => _save(types),
                    child: Text(_adding ? 'Add type' : 'Save'),
                  ),
                  if (_adding)
                    OutlinedButton(
                      key: const ValueKey('place-type-add-cancel'),
                      onPressed: () => _select(types.firstOrNull),
                      child: const Text('Cancel'),
                    )
                  else if (!isOther)
                    OutlinedButton(
                      key: const ValueKey('place-type-remove'),
                      onPressed: () => setState(() => _confirmRemove = true),
                      child: const Text('Remove type'),
                    ),
                ],
              ),
            if (isOther) ...[
              const SizedBox(height: 6),
              Text("Other can't be removed: places go there when their type is removed.", style: muted),
            ],
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

/// The types with their icon and how many places use each, searchable.
class _TypeList extends StatelessWidget {
  const _TypeList({
    required this.types,
    required this.counts,
    required this.selected,
    required this.canEdit,
    required this.onSelect,
    required this.onAdd,
  });

  final List<PlaceType> types;

  /// Places per type key; null while the places load.
  final Map<String, int>? counts;
  final String? selected;
  final bool canEdit;
  final ValueChanged<PlaceType> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return _Panel(
      key: const ValueKey('place-type-list'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Types', style: t.textTheme.titleMedium)),
              if (canEdit)
                OutlinedButton.icon(
                  key: const ValueKey('place-type-add'),
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add type'),
                ),
            ],
          ),
          ListSearchFilter(
            count: types.length,
            hint: 'Search types',
            fieldKey: const ValueKey('place-type-search'),
            builder: (context, q) {
              final shown = [for (final x in types) if (q.isEmpty || searchSelectMatches(x.name, q)) x];
              if (shown.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(types.isEmpty ? 'No types yet.' : 'No type matches.',
                      style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
                );
              }
              return Column(
                children: [
                  for (final x in shown)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Material(
                        color: x.key == selected ? cs.primaryContainer : Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: x.key == selected ? cs.primary : cs.outlineVariant),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: ValueKey('place-type-${x.key}'),
                          onTap: () => onSelect(x),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              children: [
                                PlaceTypeIcon(type: x, size: 36),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        x.name,
                                        style: t.textTheme.titleSmall?.copyWith(
                                          color: x.key == selected ? cs.onPrimaryContainer : null,
                                        ),
                                      ),
                                      Text(
                                        x.active ? placeTypeIconLabel(x.icon) : 'Hidden',
                                        style: t.textTheme.bodySmall?.copyWith(
                                          color: x.key == selected ? cs.onPrimaryContainer : mutedTextColor(t),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  counts == null ? '' : '${counts![x.key] ?? 0}',
                                  key: ValueKey('place-type-count-${x.key}'),
                                  semanticsLabel: counts == null ? null : '${counts![x.key] ?? 0} places',
                                  style: t.textTheme.labelLarge?.copyWith(
                                    color: x.key == selected ? cs.onPrimaryContainer : mutedTextColor(t),
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
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
