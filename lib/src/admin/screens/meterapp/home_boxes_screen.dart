// Admin → Display Settings → Home page → Service boxes: the rows the boxes
// sit in, the boxes in order (any number), and per box its service, page,
// picture size and place, and a badge whose words take turns, flipping over
// (core/service_boxes.dart). For the master layout or a place's own.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_layout.dart';
import '../../../core/home_sections.dart' show serviceBoxViews, serviceBoxOpensText;
import '../../../core/media_assets.dart' show MediaKind, isMediaRef;
import '../../../core/partner_type_rules.dart' show RegionScope;
import '../../../core/service_boxes.dart';
import '../../../features/ride/home_parts.dart' show ServiceBoxesGrid;
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/media_image.dart' show MediaIcon;
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import 'display_logic.dart';
import 'display_screen.dart' show applyDisplay, displayPage, pickRoute;
import 'display_store.dart';
import 'home_layout_screen.dart' show homeLayoutPlaceName;
import 'media_picker_sheet.dart' show showMediaPicker;

/// The boxes as the admin edits them: the section's own, else Display
/// Settings' five (the first with NEW when its old switch is on).
List<Map<String, dynamic>> editableBoxes(Map<String, dynamic> settings, HomeSection section) {
  final own = section.boxes;
  if (own != null) return own;
  final five = normalizeBoxes(settings['serviceBoxes']);
  if (displayBool(settings, 'serviceBoxBadge') && five.isNotEmpty) {
    five[0] = {
      ...five[0],
      'badgeOn': true,
      'badgeWords': [const BadgeWord('NEW').toJson()],
    };
  }
  return five;
}

/// The layout with its boxes section given [boxes] and [rows].
HomeLayout withBoxes(HomeLayout layout, List<Map<String, dynamic>> boxes, List<BoxRowKind> rows) {
  final id = layout.of(HomeSectionType.boxes)?.id ?? HomeSectionType.boxes.key;
  return layout.edited(id, {'boxes': boxes, 'rows': [for (final r in rows) r.key]});
}

/// A new box: closed (Coming soon) until linked, its badge SOON.
Map<String, dynamic> newBox() => {'id': 'box-${DateTime.now().microsecondsSinceEpoch}', 'name': 'New box', 'iconName': 'Package', 'comingSoon': true, 'size': boxPictureDefault};

/// Saves an edit of the place's layout (the master when [place] is All).
Future<void> saveHomeLayout(BuildContext context, WidgetRef ref, RegionScope place, HomeLayout Function(HomeLayout, Map<String, dynamic>) edit) =>
    applyDisplay(context, ref, (x) {
      final ls = HomeLayouts.fromSettings(x);
      final own = ls.ownLayout(place) ?? ls.layoutFor(place);
      final next = edit(own, x);
      return place.isAll ? withMasterHomeLayout(x, next) : withPlaceHomeLayout(x, place, next);
    });

class HomeBoxesScreen extends ConsumerWidget {
  const HomeBoxesScreen({super.key, required this.place});
  final RegionScope place;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    return Scaffold(
      appBar: AppBar(title: Text('Service boxes · ${homeLayoutPlaceName(place)}')),
      body: AsyncView(
        value: ref.watch(displaySettingsProvider),
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (s) => _body(context, ref, s, canEdit),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, Map<String, dynamic> s, bool canEdit) {
    final ls = HomeLayouts.fromSettings(s);
    final layout = ls.ownLayout(place) ?? ls.layoutFor(place);
    final section = layout.of(HomeSectionType.boxes) ?? HomeSection.of(HomeSectionType.boxes);
    final boxes = editableBoxes(s, section);
    final rows = section.rows;
    final places = boxPlaces(rows);
    final t = Theme.of(context);

    Future<void> save(List<Map<String, dynamic>> b, List<BoxRowKind> r) =>
        saveHomeLayout(context, ref, place, (l, x) => withBoxes(l, b, r));

    final views = serviceBoxViews(s, boxes: boxes);
    return ListView(padding: const EdgeInsets.all(16), children: [
      // What riders see.
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: ServiceBoxesGrid(
                key: const ValueKey('home-boxes-preview'),
                boxes: views,
                rows: rows,
                onOpen: (b) => _openBox(context, b.index),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text('Rows', style: t.textTheme.titleMedium),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in boxRowPresets.entries)
          ActionChip(
            key: ValueKey('home-boxes-preset-${e.key}'),
            label: Text(e.key),
            onPressed: canEdit ? () => save(boxes, boxRowsOf(e.value)) : null,
          ),
      ]),
      const SizedBox(height: 8),
      Card(
        child: Column(children: [
          for (var r = 0; r < rows.length; r++)
            ListTile(
              key: ValueKey('home-boxes-row-$r'),
              leading: Text('${r + 1}', style: t.textTheme.titleMedium),
              title: SearchableDropdownFormField<String>(
                key: ValueKey('home-boxes-row-kind-$r-${rows[r].key}'),
                initialValue: rows[r].key,
                isExpanded: true,
                decoration: const InputDecoration(isDense: true, labelText: 'Shape'),
                items: [for (final k in BoxRowKind.values) DropdownMenuItem(value: k.key, child: Text(k.label))],
                onChanged: canEdit ? (v) => save(boxes, [...rows]..[r] = BoxRowKind.of(v)) : null,
              ),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                BusyIconButton(
                  tooltip: 'Move row up',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: canEdit && r > 0 ? () => save(boxes, [...rows]..insert(r - 1, rows[r])..removeAt(r + 1)) : null,
                ),
                BusyIconButton(
                  tooltip: 'Remove row',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: canEdit && rows.length > 1 ? () => save(boxes, [...rows]..removeAt(r)) : null,
                ),
              ]),
            ),
        ]),
      ),
      Row(children: [
        BusyButton.text(
          key: const ValueKey('home-boxes-add-row'),
          icon: const Icon(Icons.add),
          onPressed: canEdit ? () => save(boxes, [...rows, BoxRowKind.two]) : null,
          child: const Text('Add a row'),
        ),
        Expanded(
          child: Text(
            '${places.length} places · ${boxes.length} boxes'
            '${boxes.length > places.length ? ' · ${boxes.length - places.length} not shown' : places.length > boxes.length ? ' · ${places.length - boxes.length} empty' : ''}',
            key: const ValueKey('home-boxes-count'),
            textAlign: TextAlign.end,
            style: t.textTheme.bodySmall,
          ),
        ),
      ]),
      const SizedBox(height: 12),
      Text('Boxes', style: t.textTheme.titleMedium),
      Text('Boxes fill the places in order. Those past the last place are kept, not shown.', style: t.textTheme.bodySmall),
      const SizedBox(height: 6),
      Card(
        child: Column(children: [
          for (var i = 0; i < boxes.length; i++)
            ListTile(
              key: ValueKey('home-boxes-box-$i'),
              title: Text(views[i].title.replaceAll('\n', ' ')),
              subtitle: Text(i < places.length ? places[i].name : 'Not shown'),
              onTap: () => _openBox(context, i),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                BusyIconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: canEdit && i > 0 ? () => save([...boxes]..insert(i - 1, boxes[i])..removeAt(i + 1), rows) : null,
                ),
                BusyIconButton(
                  tooltip: 'Move down',
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: canEdit && i < boxes.length - 1
                      ? () => save([...boxes]..insert(i + 2, boxes[i])..removeAt(i), rows)
                      : null,
                ),
              ]),
            ),
        ]),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: BusyButton.filled(
          key: const ValueKey('home-boxes-add'),
          icon: const Icon(Icons.add),
          // Into the first empty place; with every place taken, a new row of two.
          onPressed: canEdit
              ? () => save([...boxes, newBox()],
                  boxes.length >= places.length ? [...rows, BoxRowKind.two] : rows)
              : null,
          child: const Text('Add a box'),
        ),
      ),
    ]);
  }

  void _openBox(BuildContext context, int index) => Navigator.of(context).push(AppPageRoute(
        id: 'display.home-box',
        builder: (_) => HomeBoxScreen(place: place, index: index),
      ));
}

/// One box: its words, service, page, picture and badge.
class HomeBoxScreen extends ConsumerWidget {
  const HomeBoxScreen({super.key, required this.place, required this.index});
  final RegionScope place;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    return Scaffold(
      appBar: AppBar(title: Text('Box ${index + 1}')),
      body: AsyncView(
        value: ref.watch(displaySettingsProvider),
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (s) => _body(context, ref, s, canEdit),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, Map<String, dynamic> s, bool canEdit) {
    final ls = HomeLayouts.fromSettings(s);
    final layout = ls.ownLayout(place) ?? ls.layoutFor(place);
    final section = layout.of(HomeSectionType.boxes) ?? HomeSection.of(HomeSectionType.boxes);
    final boxes = editableBoxes(s, section);
    if (index >= boxes.length) return const Center(child: Text('This box has been removed.'));
    final box = boxes[index];
    final look = BoxLook(box);
    final view = serviceBoxViews(s, boxes: boxes)[index];
    final services = [...(ref.watch(settingsEntriesProvider('service-settings')).value ?? const <Map<String, dynamic>>[])];
    final linked = services.where((x) => x['id'] == box['serviceId']).firstOrNull;
    final linkedName = linked == null ? null : '${(linked['values'] as Map?)?['name'] ?? ''}'.trim();
    final t = Theme.of(context);

    Future<void> patch(Map<String, dynamic> p) => saveHomeLayout(context, ref, place, (l, x) {
          final b = editableBoxes(x, l.of(HomeSectionType.boxes) ?? HomeSection.of(HomeSectionType.boxes));
          if (index >= b.length) return l;
          b[index] = {...b[index], ...p}..removeWhere((k, v) => v == null);
          return withBoxes(l, b, (l.of(HomeSectionType.boxes) ?? section).rows);
        });

    Widget slider(String key, String label, double value, double min, double max, String Function(double) shown,
            void Function(double) onEnd, {int? divisions}) =>
        _SliderTile(
          key: ValueKey('$key-${value.toStringAsFixed(1)}'),
          label: label,
          value: value,
          min: min,
          max: max,
          divisions: divisions ?? (max - min).round(),
          shown: shown,
          onChangeEnd: canEdit ? onEnd : null,
        );

    final words = look.badgeWords;
    final badgeMode = switch (look.badgeOn) { null => 'auto', false => 'off', true => 'own' };

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: ServiceBoxesGrid(boxes: [view], rows: const [BoxRowKind.twoTall], onOpen: (_) {})),
            const SizedBox(width: 12),
            Expanded(child: ServiceBoxesGrid(boxes: [view], rows: const [BoxRowKind.one], onOpen: (_) {})),
          ]),
        ),
      ),
      Text('Tall and short, as riders see it.', style: t.textTheme.bodySmall),
      const SizedBox(height: 12),
      TextFormField(
        key: ValueKey('home-box-name-${box['name']}'),
        initialValue: '${box['name'] ?? ''}',
        enabled: canEdit,
        decoration: const InputDecoration(labelText: 'Label (empty: the service name)'),
        onFieldSubmitted: (v) => patch({'name': v.trim().isEmpty ? null : v.trim()}),
      ),
      BusyListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Service'),
        subtitle: Text(linkedName ?? 'None'),
        trailing: const Icon(Icons.arrow_drop_down),
        enabled: canEdit,
        onTap: () async {
          final picked = await showSearchPicker<String>(
            context,
            title: 'Choose Service',
            selected: '${box['serviceId'] ?? ''}',
            choices: [
              (value: '', label: 'None', subtitle: null, leading: null),
              for (final svc in services)
                (value: '${svc['id']}', label: '${(svc['values'] as Map?)?['name'] ?? 'Unnamed'}', subtitle: null, leading: null),
            ],
          );
          if (picked != null) await patch({'serviceId': picked.isEmpty ? null : picked});
        },
      ),
      BusyListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Opens'),
        subtitle: Text(serviceBoxOpensText(route: box['route'] as String?, title: view.title, linked: linkedName)),
        trailing: const Icon(Icons.arrow_drop_down),
        enabled: canEdit,
        onTap: () async {
          final picked = await pickRoute(context, current: box['route'] as String?, noneLabel: 'None — tapping shows Coming Soon');
          if (picked == null) return;
          await patch(picked.isEmpty ? {'route': null} : {'route': picked, 'comingSoon': false});
        },
      ),
      BusySwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Coming soon'),
        subtitle: const Text('Shows the Coming Soon notice instead of opening the page'),
        value: box['comingSoon'] == true || box['route'] == null,
        onChanged: canEdit && box['route'] != null ? (v) => patch({'comingSoon': v}) : null,
      ),
      const Divider(),
      Text('Picture', style: t.textTheme.titleMedium),
      BusyListTile(
        contentPadding: EdgeInsets.zero,
        leading: MediaIcon('${box['iconName'] ?? ''}', fallback: Icons.apps),
        title: const Text('Icon'),
        subtitle: Text(box['imageUri'] != null ? 'The image below is used instead' : isMediaRef(box['iconName'] as String?) ? 'From the Media Gallery' : '${box['iconName'] ?? 'Default'}'),
        enabled: canEdit,
        onTap: () async {
          final picked = await showMediaPicker(context, kind: MediaKind.icon, current: box['iconName'] as String?, title: 'Icon for box ${index + 1}');
          if (picked != null) await patch({'iconName': picked.isEmpty ? null : picked});
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
                    current: box['imageUri'] as String?,
                    title: 'Picture for box ${index + 1}',
                    offerDefault: false,
                  );
                  if (v != null && v.isNotEmpty) await patch({'imageUri': v});
                }
              : null,
          child: Text(box['imageUri'] != null ? 'Replace picture' : 'Choose a picture'),
        ),
        if (box['imageUri'] != null)
          BusyButton.text(
            icon: const Icon(Icons.close),
            onPressed: canEdit ? () => patch({'imageUri': null}) : null,
            child: const Text('Remove'),
          ),
      ]),
      Text('A PNG with a see-through background looks best.', style: t.textTheme.bodySmall),
      slider('home-box-size', 'Picture size (of the box height)', look.size, boxPictureMin.toDouble(), boxPictureMax.toDouble(),
          (v) => '${v.round()}%', (v) => patch({'size': v.round()})),
      const SizedBox(height: 4),
      Text('Picture sits at', style: t.textTheme.labelLarge),
      _AnchorPicker(
        key: const ValueKey('home-box-anchor'),
        value: look.anchor,
        choices: BoxAnchor.values,
        onChanged: canEdit ? (a) => patch({'anchor': a.key, 'x': 0, 'y': 0}) : null,
      ),
      slider('home-box-x', 'Move sideways', look.shiftX, -boxShiftMax.toDouble(), boxShiftMax.toDouble(), (v) => '${v.round()}',
          (v) => patch({'x': v.round()})),
      slider('home-box-y', 'Move up or down', look.shiftY, -boxShiftMax.toDouble(), boxShiftMax.toDouble(), (v) => '${v.round()}',
          (v) => patch({'y': v.round()})),
      const Divider(),
      Text('Badge', style: t.textTheme.titleMedium),
      const SizedBox(height: 6),
      SegmentedButton<String>(
        key: const ValueKey('home-box-badge-mode'),
        segments: const [
          ButtonSegment(value: 'auto', label: Text('Automatic')),
          ButtonSegment(value: 'own', label: Text('My words')),
          ButtonSegment(value: 'off', label: Text('None')),
        ],
        selected: {badgeMode},
        onSelectionChanged: canEdit
            ? (v) => patch({
                  'badgeOn': switch (v.first) { 'own' => true, 'off' => false, _ => null },
                  if (v.first == 'own' && words.isEmpty) 'badgeWords': [const BadgeWord('NEW').toJson()],
                })
            : null,
      ),
      Text(
        switch (badgeMode) {
          'auto' => 'SOON while the box can\'t open yet, else none.',
          'off' => 'No badge, even while the box can\'t open.',
          _ => 'Your words. Two or more take turns, flipping over.',
        },
        style: t.textTheme.bodySmall,
      ),
      if (badgeMode == 'own') ...[
        for (var w = 0; w < words.length; w++)
          _WordTile(
            key: ValueKey('home-box-word-$w-${words[w].text}-${words[w].fill}-${words[w].ink}'),
            word: words[w],
            index: w,
            canEdit: canEdit,
            canRemove: words.length > 1,
            onChanged: (next) => patch({
              'badgeWords': [for (var k = 0; k < words.length; k++) (k == w ? next : words[k]).toJson()],
            }),
            onRemove: () => patch({
              'badgeWords': [for (var k = 0; k < words.length; k++) if (k != w) words[k].toJson()],
            }),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: BusyButton.text(
            key: const ValueKey('home-box-add-word'),
            icon: const Icon(Icons.add),
            onPressed: canEdit
                ? () => patch({
                      'badgeWords': [
                        for (final x in words) x.toJson(),
                        (words.length == 1 ? const BadgeWord('50% OFF', fill: badgeGreen) : const BadgeWord('NEW')).toJson(),
                      ],
                    })
                : null,
            child: const Text('Add a word'),
          ),
        ),
        BusySwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Flip between the words'),
          subtitle: const Text('Off: only the first word shows'),
          value: look.flip,
          onChanged: canEdit ? (v) => patch({'flip': v}) : null,
        ),
        if (look.flip)
          slider('home-box-flip', 'Each word shows for', look.flipSeconds, badgeSecondsMin, badgeSecondsMax,
              (v) => '${v.toStringAsFixed(1)} s', (v) => patch({'flipSecs': (v * 2).round() / 2}),
              divisions: ((badgeSecondsMax - badgeSecondsMin) * 2).round()),
      ],
      if (badgeMode != 'off') ...[
        slider('home-box-badge-size', 'Badge size', look.badgeSize, badgeSizeMin, badgeSizeMax, (v) => '${v.round()}',
            (v) => patch({'badgeSize': v.round()})),
        const SizedBox(height: 4),
        Text('Badge corner', style: t.textTheme.labelLarge),
        _AnchorPicker(
          key: const ValueKey('home-box-badge-at'),
          value: look.badgeAt,
          choices: BoxAnchor.corners,
          onChanged: canEdit ? (a) => patch({'badgeAt': a.key, 'badgeX': 0, 'badgeY': 0}) : null,
        ),
        slider('home-box-badge-x', 'Away from the side', look.badgeX, badgeShiftMin, badgeShiftMax, (v) => '${v.round()}',
            (v) => patch({'badgeX': v.round()})),
        slider('home-box-badge-y', 'Away from the top or bottom', look.badgeY, badgeShiftMin, badgeShiftMax,
            (v) => '${v.round()}', (v) => patch({'badgeY': v.round()})),
      ],
      const Divider(),
      Align(
        alignment: Alignment.centerLeft,
        child: BusyButton.text(
          key: const ValueKey('home-box-remove'),
          icon: const Icon(Icons.delete_outline),
          onPressed: canEdit
              ? () async {
                  await saveHomeLayout(context, ref, place, (l, x) {
                    final b = editableBoxes(x, l.of(HomeSectionType.boxes) ?? HomeSection.of(HomeSectionType.boxes));
                    if (index < b.length) b.removeAt(index);
                    return withBoxes(l, b, (l.of(HomeSectionType.boxes) ?? section).rows);
                  });
                  if (context.mounted) Navigator.of(context).pop();
                }
              : null,
          child: const Text('Remove box'),
        ),
      ),
    ]);
  }
}

/// A slider that saves when let go, showing its value as it moves.
class _SliderTile extends StatefulWidget {
  const _SliderTile({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.shown,
    required this.onChangeEnd,
  });
  final String label;
  final double value, min, max;
  final int divisions;
  final String Function(double) shown;
  final void Function(double)? onChangeEnd;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  late double _v = widget.value;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(widget.label)),
          Text(widget.shown(_v), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        ]),
        Slider(
          value: _v.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          label: widget.shown(_v),
          onChanged: widget.onChangeEnd == null ? null : (v) => setState(() => _v = v),
          onChangeEnd: widget.onChangeEnd,
        ),
      ]);
}

/// A 3 × 3 (or corners only) picker of where something sits in the box.
class _AnchorPicker extends StatelessWidget {
  const _AnchorPicker({super.key, required this.value, required this.choices, required this.onChanged});
  final BoxAnchor value;
  final List<BoxAnchor> choices;
  final ValueChanged<BoxAnchor>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    Widget cell(BoxAnchor? a) => SizedBox(
          width: 40,
          height: 40,
          child: a == null
              ? null
              : IconButton(
                  key: ValueKey('anchor-${a.key}'),
                  tooltip: a.name,
                  isSelected: a == value,
                  style: IconButton.styleFrom(
                    backgroundColor: a == value ? c.primary : c.surfaceContainerHighest,
                    foregroundColor: a == value ? c.onPrimary : c.onSurfaceVariant,
                  ),
                  icon: const Icon(Icons.circle, size: 10),
                  onPressed: onChanged == null ? null : () => onChanged!(a),
                ),
        );
    BoxAnchor? at(int x, int y) => choices.where((a) => a.x == x && a.y == y).firstOrNull;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final y in const [-1, 0, 1])
        if (choices.any((a) => a.y == y))
          Row(mainAxisSize: MainAxisSize.min, children: [for (final x in const [-1, 0, 1]) cell(at(x, y))]),
    ]);
  }
}

/// One badge word: its text, its colour and its letters' colour.
class _WordTile extends StatelessWidget {
  const _WordTile({
    super.key,
    required this.word,
    required this.index,
    required this.canEdit,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });
  final BadgeWord word;
  final int index;
  final bool canEdit, canRemove;
  final Future<void> Function(BadgeWord) onChanged;
  final Future<void> Function() onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget swatch(int c, bool on, VoidCallback? tap) => Semantics(
          button: true,
          selected: on,
          label: argbHex(c),
          child: InkWell(
            onTap: tap,
            customBorder: const CircleBorder(),
            child: Container(
              width: 26,
              height: 26,
              margin: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Color(c),
                shape: BoxShape.circle,
                border: Border.all(color: on ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: on ? 3 : 1),
              ),
            ),
          ),
        );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Color(word.fill), borderRadius: BorderRadius.circular(999)),
              child: Text(word.text, style: TextStyle(color: Color(word.ink), fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                key: ValueKey('home-box-word-text-$index'),
                initialValue: word.text,
                enabled: canEdit,
                maxLength: 12,
                decoration: InputDecoration(labelText: 'Word ${index + 1}', isDense: true, counterText: ''),
                onFieldSubmitted: (v) =>
                    v.trim().isEmpty ? null : onChanged(BadgeWord(v.trim(), fill: word.fill, ink: word.ink)),
              ),
            ),
            BusyIconButton(
              tooltip: 'Remove word',
              icon: const Icon(Icons.close),
              onPressed: canEdit && canRemove ? onRemove : null,
            ),
          ]),
          Text('Colour', style: t.textTheme.labelMedium),
          Wrap(children: [
            for (final c in badgeFills)
              swatch(c, c == word.fill, canEdit ? () => onChanged(BadgeWord(word.text, fill: c, ink: word.ink)) : null),
          ]),
          Text('Letters', style: t.textTheme.labelMedium),
          Wrap(children: [
            for (final c in badgeInks)
              swatch(c, c == word.ink, canEdit ? () => onChanged(BadgeWord(word.text, fill: word.fill, ink: c)) : null),
          ]),
        ]),
      ),
    );
  }
}
