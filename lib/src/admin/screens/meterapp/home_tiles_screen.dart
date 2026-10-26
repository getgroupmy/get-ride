// Admin → Display Settings → Home page → a tile row, wide tile row or promo
// cards: the heading (words, picture, the page it opens), how many tiles
// across, the last "see all" tile, and the tiles in order, each switched on
// or off; then per tile its words, second line, corner label (words, corner,
// colours), picture, background and page (core/home_tiles.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_layout.dart';
import '../../../core/home_tiles.dart';
import '../../../core/media_assets.dart' show MediaKind;
import '../../../core/partner_type_rules.dart' show RegionScope;
import '../../../core/service_boxes.dart' show argbHex;
import '../../../features/ride/home_parts.dart' show HomePromoRow, HomeTileRow;
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/media_image.dart' show MediaIcon;
import '../../../widgets/page_style_host.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import 'display_logic.dart' show routeLabelFor;
import 'display_screen.dart' show displayPage, pickRoute;
import 'display_store.dart';
import 'home_boxes_screen.dart' show saveHomeLayout;
import 'home_layout_screen.dart' show homeLayoutPlaceName;
import 'media_picker_sheet.dart' show showMediaPicker;

/// The section [id] of the place's layout, made to [edit].
Future<void> saveHomeSection(BuildContext context, WidgetRef ref, RegionScope place, String id,
        HomeSection Function(HomeSection) edit) =>
    saveHomeLayout(context, ref, place, (l, _) {
      final s = l.byId(id);
      return s == null ? l : HomeLayout([for (final x in l.sections) x.id == id ? edit(x) : x]);
    });

HomeSection? _sectionOf(Map<String, dynamic> settings, RegionScope place, String id) {
  final ls = HomeLayouts.fromSettings(settings);
  return (ls.ownLayout(place) ?? ls.layoutFor(place)).byId(id);
}

String _openLabel(String? route) => route == null ? 'Nothing yet — tapping shows Coming Soon' : routeLabelFor(route);

class HomeTilesScreen extends ConsumerWidget {
  const HomeTilesScreen({super.key, required this.place, required this.sectionId});
  final RegionScope place;
  final String sectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final value = ref.watch(displaySettingsProvider);
    final s = value.value == null ? null : _sectionOf(value.value!, place, sectionId);
    return Scaffold(
      appBar: AppBar(title: Text('${s?.type?.label ?? 'Section'} · ${homeLayoutPlaceName(place)}')),
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (settings) => s == null
            ? const Center(child: Text('This section has been removed.'))
            : _body(context, ref, s, canEdit),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, HomeSection s, bool canEdit) {
    final t = Theme.of(context);
    final promos = s.type == HomeSectionType.promos;
    final tiles = s.tiles;
    Future<void> edit(HomeSection Function(HomeSection) f) => saveHomeSection(context, ref, place, sectionId, f);
    Future<void> setTiles(List<HomeTile> next) => edit((x) => withTiles(x, next));
    final noun = promos ? 'card' : 'tile';

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: promos
              ? HomePromoRow(section: s, onOpen: (_, _) {})
              : HomeTileRow(section: s, onOpen: (_, _) {}),
        ),
      ),
      Text('As riders see it. Switched-off ${noun}s are left out.', style: t.textTheme.bodySmall),
      const SizedBox(height: 12),
      if (!promos) ...[
        TextFormField(
          key: ValueKey('home-tiles-title-${s.title}'),
          initialValue: s.title,
          enabled: canEdit,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Heading (empty: none)'),
          onFieldSubmitted: (v) => edit((x) => x.copyWith({'title': v.trim()})),
        ),
        BusyListTile(
          contentPadding: EdgeInsets.zero,
          leading: MediaIcon(s.headingIcon ?? '', fallback: Icons.image_outlined),
          title: const Text('Heading picture'),
          subtitle: Text(s.headingIcon == null ? 'None' : 'Set'),
          enabled: canEdit,
          onTap: () async {
            final v = await showMediaPicker(context, kind: MediaKind.icon, current: s.headingIcon, title: 'Heading picture', defaultLabel: 'None');
            if (v != null) await edit((x) => x.copyWith({'iconName': v.isEmpty ? null : v}));
          },
        ),
        BusyListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('The heading opens'),
          subtitle: Text(_openLabel(s.headingRoute)),
          trailing: const Icon(Icons.arrow_drop_down),
          enabled: canEdit,
          onTap: () async {
            final v = await pickRoute(context, current: s.headingRoute, noneLabel: 'None — tapping shows Coming Soon');
            if (v != null) await edit((x) => x.copyWith({'route': v.isEmpty ? null : v}));
          },
        ),
        const SizedBox(height: 8),
        Text('Tiles across the screen', style: t.textTheme.labelLarge),
        const SizedBox(height: 4),
        SegmentedButton<int>(
          key: const ValueKey('home-tiles-across'),
          segments: [for (final n in tilesAcrossChoices) ButtonSegment(value: n, label: Text('$n'))],
          selected: {s.across},
          onSelectionChanged: canEdit ? (v) => edit((x) => x.copyWith({'across': v.first})) : null,
        ),
        Text('More tiles scroll sideways; a little of the next one shows.', style: t.textTheme.bodySmall),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey('home-tiles-see-all-${s.seeAll}'),
          initialValue: s.seeAll,
          enabled: canEdit,
          maxLength: 30,
          decoration: const InputDecoration(
            labelText: 'Last tile (“see all”)',
            helperText: 'Empty for none. It opens what the heading opens.',
          ),
          onFieldSubmitted: (v) => edit((x) => x.copyWith({'seeAll': v.trim()})),
        ),
      ],
      const SizedBox(height: 12),
      Text(promos ? 'Cards' : 'Tiles', style: t.textTheme.titleMedium),
      Card(
        child: Column(children: [
          for (var i = 0; i < tiles.length; i++)
            BusySwitchListTile(
              key: ValueKey('home-tiles-item-$i'),
              value: tiles[i].on,
              onChanged: canEdit ? (v) => setTiles([...tiles]..[i] = tiles[i].copyWith({'on': v})) : null,
              title: Text(tiles[i].caption.isEmpty ? '(no words)' : tiles[i].caption),
              subtitle: Text(_openLabel(tiles[i].route), maxLines: 1, overflow: TextOverflow.ellipsis),
              secondary: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => Navigator.of(context).push(AppPageRoute(
                    id: 'display.home-tile',
                    builder: (_) => HomeTileScreen(place: place, sectionId: sectionId, index: i),
                  )),
                ),
                BusyIconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: canEdit && i > 0 ? () => setTiles([...tiles]..insert(i - 1, tiles[i])..removeAt(i + 1)) : null,
                ),
              ]),
            ),
        ]),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: BusyButton.filled(
          key: const ValueKey('home-tiles-add'),
          icon: const Icon(Icons.add),
          onPressed: canEdit ? () => setTiles([...tiles, newTile(s.type!)]) : null,
          child: Text('Add a $noun'),
        ),
      ),
    ]);
  }
}

/// One tile or card.
class HomeTileScreen extends ConsumerWidget {
  const HomeTileScreen({super.key, required this.place, required this.sectionId, required this.index});
  final RegionScope place;
  final String sectionId;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final value = ref.watch(displaySettingsProvider);
    return Scaffold(
      appBar: AppBar(title: Text('Tile ${index + 1}')),
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (settings) {
          final s = _sectionOf(settings, place, sectionId);
          if (s == null || index >= s.tiles.length) return const Center(child: Text('This tile has been removed.'));
          return _body(context, ref, s, s.tiles[index], canEdit);
        },
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, HomeSection s, HomeTile tile, bool canEdit) {
    final t = Theme.of(context);
    final promos = s.type == HomeSectionType.promos;
    final wide = s.type == HomeSectionType.wide;
    Future<void> patch(Map<String, dynamic> p) => saveHomeSection(context, ref, place, sectionId, (x) {
          final list = x.tiles;
          if (index >= list.length) return x;
          return withTiles(x, [...list]..[index] = list[index].copyWith(p));
        });

    Widget swatches(String key, List<int> colours, int? current, void Function(int?) pick, {bool none = false}) => Wrap(
          key: ValueKey(key),
          children: [
            if (none)
              _Swatch(colour: null, selected: current == null, onTap: canEdit ? () => pick(null) : null),
            for (final c in colours) _Swatch(colour: c, selected: c == current, onTap: canEdit ? () => pick(c) : null),
          ],
        );

    return ListView(padding: const EdgeInsets.all(16), children: [
      TextFormField(
        key: ValueKey('home-tile-caption-${tile.caption}'),
        initialValue: tile.caption,
        enabled: canEdit,
        maxLength: 40,
        decoration: InputDecoration(labelText: promos ? 'Words on the card' : 'Words under the tile'),
        onFieldSubmitted: (v) => patch({'caption': v.trim()}),
      ),
      if (wide)
        TextFormField(
          key: ValueKey('home-tile-sub-${tile.sub}'),
          initialValue: tile.sub,
          enabled: canEdit,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Second line (e.g. From RM 180)'),
          onFieldSubmitted: (v) => patch({'sub': v.trim()}),
        ),
      BusyListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Opens'),
        subtitle: Text(_openLabel(tile.route)),
        trailing: const Icon(Icons.arrow_drop_down),
        enabled: canEdit,
        onTap: () async {
          final v = await pickRoute(context, current: tile.route, noneLabel: 'None — tapping shows Coming Soon');
          if (v != null) await patch({'route': v.isEmpty ? null : v});
        },
      ),
      const Divider(),
      Text('Picture', style: t.textTheme.titleMedium),
      BusyListTile(
        contentPadding: EdgeInsets.zero,
        leading: MediaIcon(tile.iconName ?? '', fallback: Icons.apps),
        title: const Text('Icon'),
        subtitle: Text(tile.imageUri != null ? 'The picture below is used instead' : tile.iconName ?? 'Default'),
        enabled: canEdit,
        onTap: () async {
          final v = await showMediaPicker(context, kind: MediaKind.icon, current: tile.iconName, title: 'Icon');
          if (v != null) await patch({'iconName': v.isEmpty ? null : v});
        },
      ),
      Wrap(spacing: 8, children: [
        BusyButton.outlined(
          icon: const Icon(Icons.image_outlined),
          onPressed: canEdit
              ? () async {
                  final v = await showMediaPicker(
                    context,
                    kind: MediaKind.image,
                    alsoKinds: const {MediaKind.icon, MediaKind.logo},
                    current: tile.imageUri,
                    title: 'Picture filling the ${promos ? 'card' : 'tile'}',
                    offerDefault: false,
                  );
                  if (v != null && v.isNotEmpty) await patch({'imageUri': v});
                }
              : null,
          child: Text(tile.imageUri != null ? 'Replace picture' : 'Choose a picture'),
        ),
        if (tile.imageUri != null)
          BusyButton.text(
            icon: const Icon(Icons.close),
            onPressed: canEdit ? () => patch({'imageUri': null}) : null,
            child: const Text('Remove'),
          ),
      ]),
      if (!promos) ...[
        const SizedBox(height: 8),
        Text('Icon size (of the picture height)'),
        Wrap(children: [
          for (final v in const [50, 70, 80, 100, 120])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text('$v%'),
                selected: tile.size.round() == v,
                onSelected: canEdit ? (_) => patch({'size': v}) : null,
              ),
            ),
        ]),
      ],
      const SizedBox(height: 8),
      Text('Background', style: t.textTheme.labelLarge),
      swatches('home-tile-bg', tileBackgrounds, tile.background, (c) => patch({'bg': c == null ? null : argbHex(c)}), none: true),
      if (!promos) ...[
        const Divider(),
        Text('Corner label', style: t.textTheme.titleMedium),
        TextFormField(
          key: ValueKey('home-tile-label-${tile.label}'),
          initialValue: tile.label,
          enabled: canEdit,
          maxLength: 14,
          decoration: const InputDecoration(labelText: 'Words (e.g. 2 hours, -20%, New; empty for none)'),
          onFieldSubmitted: (v) => patch({'label': v.trim()}),
        ),
        if (tile.label.isNotEmpty) ...[
          SegmentedButton<String>(
            key: const ValueKey('home-tile-label-at'),
            segments: const [
              ButtonSegment(value: 'tl', label: Text('Top left')),
              ButtonSegment(value: 'tr', label: Text('Top right')),
              ButtonSegment(value: 'bl', label: Text('Bottom left')),
              ButtonSegment(value: 'br', label: Text('Bottom right')),
            ],
            selected: {tile.labelAt.key},
            onSelectionChanged: canEdit ? (v) => patch({'labelAt': v.first}) : null,
          ),
          const SizedBox(height: 8),
          Text('Label colour', style: t.textTheme.labelLarge),
          swatches('home-tile-label-bg', tileLabelFills, tile.labelFill, (c) => patch({'labelBg': argbHex(c!)})),
          Text('Words colour', style: t.textTheme.labelLarge),
          swatches('home-tile-label-fg', tileLabelInks, tile.labelInk, (c) => patch({'labelFg': argbHex(c!)})),
        ],
      ],
      const Divider(),
      Align(
        alignment: Alignment.centerLeft,
        child: BusyButton.text(
          key: const ValueKey('home-tile-remove'),
          icon: const Icon(Icons.delete_outline),
          onPressed: canEdit
              ? () async {
                  await saveHomeSection(context, ref, place, sectionId,
                      (x) => withTiles(x, [...x.tiles]..removeAt(index.clamp(0, x.tiles.length - 1))));
                  if (context.mounted) Navigator.of(context).pop();
                }
              : null,
          child: Text('Remove ${promos ? 'card' : 'tile'}'),
        ),
      ),
    ]);
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.colour, required this.selected, required this.onTap});

  /// Null: none (the box colour).
  final int? colour;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: colour == null ? 'None' : argbHex(colour!),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: colour == null ? c.surface : Color(colour!),
            shape: BoxShape.circle,
            border: Border.all(color: selected ? c.primary : c.outlineVariant, width: selected ? 3 : 1),
          ),
          child: colour == null ? Icon(Icons.block, size: 16, color: c.outline) : null,
        ),
      ),
    );
  }
}
