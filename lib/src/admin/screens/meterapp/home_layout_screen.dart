// Admin → Display Settings → Home page: the sections under the rider's map,
// in their order, each switched on or off. One master layout, and any
// country, state, city or suburb with its own; a place without one follows
// the nearest place above it that has one, else the master
// (core/home_layout.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_layout.dart';
import '../../../core/partner_type_rules.dart' show RegionScope;
import '../../../core/ride_option_places.dart' show OptionPlaceScope;
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../geo/geo_data.dart' show regionsProvider;
import '../geo/geo_logic.dart' show RegionEntry;
import 'display_screen.dart' show applyDisplay, displayPage;
import 'display_store.dart';

/// The places to pick from: Master, every region the admin has, and any
/// place with a layout whose region has since gone. Outermost first.
List<RegionScope> homeLayoutPlaceChoices(List<RegionEntry> regions, HomeLayouts layouts) {
  final out = <String, RegionScope>{'': RegionScope.all};
  for (final r in regions) {
    final s = RegionScope(country: r.country, state: r.state, city: r.city, suburb: r.suburb);
    if (s.path.isNotEmpty) out.putIfAbsent(s.key, () => s);
  }
  for (final p in layouts.places.values) {
    out.putIfAbsent(p.place.key, () => p.place);
  }
  return out.values.toList()
    ..sort((a, b) => a.path.join('\u0000').toLowerCase().compareTo(b.path.join('\u0000').toLowerCase()));
}

/// "Master" or the place's narrowest name.
String homeLayoutPlaceName(RegionScope? p) => p == null || p.isAll ? 'Master' : p.placeName;

/// What one section is, in a line.
String homeSectionHelp(HomeSection s) => switch (s.type) {
      HomeSectionType.search => s.on
          ? '“${s.text}”'
          : 'Off: a plain “Where to?” row stands in its place, so riders can always book',
      HomeSectionType.vehicles => 'The vehicle services riders can book where they are (Vehicle Services)',
      HomeSectionType.pickup => 'A “Set pickup” row; useful with the pickup box over the map switched off',
      HomeSectionType.upcoming => 'Shows only when the rider has a booked ride coming up',
      HomeSectionType.recent =>
        '${s.atRest} with the sheet down${s.more ? ', the rest with it up' : ''}',
      HomeSectionType.boxes => 'Set the boxes under Display Settings › Service Boxes',
      HomeSectionType.fold => 'Above this line shows with the sheet all the way down; below it only with the sheet up',
      null => 'From a newer version of the app: kept as it is',
    };

class HomeLayoutScreen extends ConsumerStatefulWidget {
  const HomeLayoutScreen({super.key});

  @override
  ConsumerState<HomeLayoutScreen> createState() => _HomeLayoutScreenState();
}

class _HomeLayoutScreenState extends ConsumerState<HomeLayoutScreen> {
  RegionScope _place = RegionScope.all;

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final settings = ref.watch(displaySettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Home page')),
      body: AsyncView(
        value: settings,
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (s) => _body(context, s, canEdit),
      ),
    );
  }

  Future<void> _save(HomeLayout? layout) => applyDisplay(
        context,
        ref,
        (x) => _place.isAll
            ? withMasterHomeLayout(x, layout ?? HomeLayouts.fromSettings(x).master)
            : withPlaceHomeLayout(x, _place, layout),
      );

  Widget _body(BuildContext context, Map<String, dynamic> s, bool canEdit) {
    final layouts = HomeLayouts.fromSettings(s);
    final regions = ref.watch(regionsProvider).value ?? const <RegionEntry>[];
    final choices = homeLayoutPlaceChoices(regions, layouts);
    final own = layouts.ownLayout(_place);
    final source = layouts.sourceFor(_place.isAll ? null : _place.parent);
    final t = Theme.of(context);

    Future<void> pick() async {
      final picked = await showSearchPicker<RegionScope>(
        context,
        title: 'Home page for',
        selected: _place,
        choices: [
          for (final c in choices)
            (
              value: c,
              label: homeLayoutPlaceName(c),
              subtitle: c.isAll
                  ? 'Every place without its own'
                  : layouts.places.containsKey(c.key)
                      ? '${c.label} · own layout'
                      : '${c.label} · follows ${homeLayoutPlaceName(layouts.sourceFor(c))}',
              leading: c.isAll || layouts.places.containsKey(c.key)
                  ? const Icon(Icons.dashboard_customize_outlined, size: 20)
                  : null,
            ),
        ],
      );
      if (picked != null && mounted) setState(() => _place = picked);
    }

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ListTile(
            key: const ValueKey('home-layout-place'),
            leading: const Icon(Icons.place_outlined),
            title: Text(homeLayoutPlaceName(_place)),
            subtitle: Text(_place.isAll
                ? 'The master layout: every place without its own'
                : own != null
                    ? '${_place.label} · own layout'
                    : '${_place.label} · follows ${homeLayoutPlaceName(source)}'),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: pick,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              if (layouts.places.isEmpty)
                Text('No place has its own layout: every rider sees the master.', style: t.textTheme.bodySmall)
              else
                for (final p in layouts.places.values)
                  ActionChip(
                    key: ValueKey('home-layout-chip-${p.place.key}'),
                    label: Text(homeLayoutPlaceName(p.place)),
                    onPressed: () => setState(() => _place = p.place),
                  ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      if (own == null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${homeLayoutPlaceName(_place)} follows ${homeLayoutPlaceName(source)}',
                  style: t.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text('Riders here see the ${homeLayoutPlaceName(source)} layout, and every change to it.'),
              const SizedBox(height: 12),
              BusyButton.filled(
                key: const ValueKey('home-layout-own'),
                icon: const Icon(Icons.add),
                onPressed: canEdit ? () => _save(layouts.layoutFor(_place)) : null,
                child: Text('Give ${homeLayoutPlaceName(_place)} its own layout'),
              ),
              const SizedBox(height: 6),
              Text("It starts as a copy of ${homeLayoutPlaceName(source)}'s, then changes only here.",
                  style: t.textTheme.bodySmall),
            ]),
          ),
        )
      else ...[
        if (!_place.isAll)
          Align(
            alignment: Alignment.centerLeft,
            child: BusyButton.text(
              key: const ValueKey('home-layout-follow'),
              icon: const Icon(Icons.undo),
              onPressed: canEdit ? () => _save(null) : null,
              child: Text('Go back to following ${homeLayoutPlaceName(source)}'),
            ),
          ),
        Card(
          child: Column(children: [
            for (var i = 0; i < own.sections.length; i++)
              _SectionTile(
                key: ValueKey('home-section-${own.sections[i].id}'),
                section: own.sections[i],
                first: i == 0,
                last: i == own.sections.length - 1,
                canEdit: canEdit,
                onMove: (by) => _save(own.moved(i, i + by)),
                onEdit: (patch) => _save(own.edited(own.sections[i].id, patch)),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Text('Each part can be moved and switched off, not removed. A switched-off part keeps its settings.',
            style: t.textTheme.bodySmall),
      ],
    ]);
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    super.key,
    required this.section,
    required this.first,
    required this.last,
    required this.canEdit,
    required this.onMove,
    required this.onEdit,
  });

  final HomeSection section;
  final bool first, last, canEdit;
  final Future<void> Function(int by) onMove;
  final Future<void> Function(Map<String, dynamic> patch) onEdit;

  @override
  Widget build(BuildContext context) {
    final s = section;
    final fold = s.type == HomeSectionType.fold;
    final moves = Row(mainAxisSize: MainAxisSize.min, children: [
      BusyIconButton(
        tooltip: 'Move up',
        icon: const Icon(Icons.arrow_upward),
        onPressed: canEdit && !first ? () => onMove(-1) : null,
      ),
      BusyIconButton(
        tooltip: 'Move down',
        icon: const Icon(Icons.arrow_downward),
        onPressed: canEdit && !last ? () => onMove(1) : null,
      ),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (!first) const Divider(height: 1),
      if (fold)
        ListTile(
          leading: const Icon(Icons.horizontal_rule),
          title: Text(HomeSectionType.fold.label),
          subtitle: Text(homeSectionHelp(s)),
          trailing: moves,
        )
      else
        BusySwitchListTile(
          title: Text(s.type?.label ?? 'Unknown part'),
          subtitle: Text(homeSectionHelp(s)),
          value: s.on,
          onChanged: canEdit && s.type != null ? (v) => onEdit({'on': v}) : null,
          secondary: moves,
        ),
      if (s.type == HomeSectionType.search && s.on)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextFormField(
            key: ValueKey('home-search-text-${s.text}'),
            initialValue: s.text,
            enabled: canEdit,
            maxLength: homeSearchMaxText,
            decoration: const InputDecoration(labelText: 'Words in the bar', isDense: true),
            onFieldSubmitted: (v) => onEdit({'text': v.trim()}),
          ),
        ),
      if (s.type == HomeSectionType.recent && s.on)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Column(children: [
            Row(children: [
              const Expanded(child: Text('With the sheet pulled down')),
              BusyIconButton(
                tooltip: 'Fewer',
                icon: const Icon(Icons.remove),
                onPressed: canEdit && s.atRest > 0 ? () => onEdit({'atRest': s.atRest - 1}) : null,
              ),
              Text('${s.atRest}', key: const ValueKey('home-recent-at-rest')),
              BusyIconButton(
                tooltip: 'More',
                icon: const Icon(Icons.add),
                onPressed: canEdit && s.atRest < homeRecentAtRestMax ? () => onEdit({'atRest': s.atRest + 1}) : null,
              ),
            ]),
            BusySwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('The rest with the sheet up'),
              value: s.more,
              onChanged: canEdit ? (v) => onEdit({'more': v}) : null,
            ),
          ]),
        ),
    ]);
  }
}
