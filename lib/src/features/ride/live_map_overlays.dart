// Rider live map (migration 0322) on the home map: the overlays button (a
// honeycomb, at the top of the right-hand buttons), its picker, the layers
// it draws (the busy honeycomb, family members, company trips, the free
// cars) and the sheet each opens. Everything shown is what the server
// returned for this rider; nothing here decides who may see what.
//
// The layers are flutter_map layers drawn over the base map, so they show
// on every map the app draws: OpenStreetMap tiles, Google's own map on
// phones and Google's JavaScript map on the web (both drawn under the app's
// layers, google_native_layer.dart / google_js_layer.dart) and Amazon /
// MapLibre styles (maplibre_layer.dart).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart' show formatMoney;
import '../../core/rider_live_map.dart';
import '../../data/family_repository.dart' show familyMineProvider;
import '../../data/rider_live_map_repository.dart';
import '../../widgets/common.dart' show mutedTextColor;
import '../../widgets/map_brightness.dart' show mapIsDark;
import '../../widgets/page_style_host.dart';
import 'home_parts.dart' show PickupPill, VehicleTypeBar, demoCarMarker;

/// The overlays button, in [MapTypeButton]'s look, with a honeycomb (so it
/// is not taken for the map type) and how many overlays are on.
class MapOverlaysButton extends StatelessWidget {
  const MapOverlaysButton({super.key, required this.count, required this.onPressed});
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = count > 0;
    return Semantics(
      selected: active,
      child: Badge(
        isLabelVisible: active,
        label: Text('$count', key: const ValueKey('map-overlays-count')),
        offset: const Offset(2, -2),
        child: FloatingActionButton.small(
          key: const ValueKey('map-overlays'),
          heroTag: null,
          tooltip: 'Map overlays',
          backgroundColor: active ? scheme.primary : null,
          foregroundColor: active ? scheme.onPrimary : null,
          onPressed: onPressed,
          child: const Icon(Icons.hive),
        ),
      ),
    );
  }
}

/// The colour scale as a bar.
class BusyRampBar extends StatelessWidget {
  const BusyRampBar({super.key, required this.colours, this.width = 72, this.height = 10});
  final List<Color> colours;
  final double width, height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(height / 2),
      gradient: LinearGradient(colors: colours.length < 2 ? defaultBusyColours : colours),
    ),
  );
}

/// "Busy: low ▬ very high", in the pickup box's look, under the menu button.
class BusyLegend extends StatelessWidget {
  const BusyLegend({super.key, required this.colours});
  final List<Color> colours;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final ink = b == Brightness.dark ? Colors.white : const Color(0xFF111111);
    final style = TextStyle(fontSize: 12, height: 1.2, fontWeight: FontWeight.w500, color: ink);
    return Material(
      key: const ValueKey('busy-legend'),
      elevation: 3,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(20),
      color: PickupPill.fillFor(b),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('Busy:', style: style.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Text('low', style: style),
          const SizedBox(width: 6),
          BusyRampBar(colours: colours),
          const SizedBox(width: 6),
          Text('very high', style: style),
        ]),
      ),
    );
  }
}

// ---- The layers ----------------------------------------------------------------------------------

/// The honeycomb: see-through cells from pale yellow to deep red with thin
/// white edges and no numbers; the tapped one outlined.
List<Widget> busyLayers(BuildContext context, BusyAreas areas, {BusyCell? selected}) {
  if (!areas.on || areas.cells.isEmpty) return const [];
  final dark = mapIsDark(context);
  final edge = Colors.white.withValues(alpha: dark ? 0.55 : 0.85);
  return [
    PolygonLayer(
      key: const ValueKey('busy-honeycomb'),
      simplificationTolerance: 0,
      polygons: [
        for (final c in areas.cells)
          Polygon(points: areas.cornersOf(c), color: areas.fillOf(c, dark: dark), borderColor: edge, borderStrokeWidth: 1),
      ],
    ),
    if (selected != null)
      PolygonLayer(
        simplificationTolerance: 0,
        polygons: [
          Polygon(
            points: areas.cornersOf(selected),
            color: Colors.transparent,
            borderColor: dark ? Colors.white : const Color(0xFF111111),
            borderStrokeWidth: 3.5,
          ),
        ],
      ),
  ];
}

/// The routes kept for family members (only when the admin keeps a history).
List<Widget> trailLayers(LivePeople people) {
  final lines = [for (final p in people.onMap) if (p.trail.length > 1) [...p.trail, p.point!]];
  if (lines.isEmpty) return const [];
  return [
    PolylineLayer(polylines: [
      for (final l in lines) Polyline(points: l, strokeWidth: 5, color: const Color(0xFF2DABE2)),
    ]),
  ];
}

/// The free cars: the demo cars' look, in the car / bike / van colour.
List<Marker> carMarkers(LiveCars cars) => [
  for (final c in cars.cars) demoCarMarker((lat: c.lat, lng: c.lng, heading: c.heading), c.colourIndex),
];

const _personColours = [Color(0xFF7B1FA2), Color(0xFF00897B), Color(0xFFC2185B), Color(0xFF5D4037), Color(0xFF3949AB)];
const _teamColour = Color(0xFF0F4C81);

/// A family member's colour, kept by their place in the list.
Color personColour(int i) => _personColours[i % _personColours.length];

/// A name over a point, in the pickup box's look.
class _LabelBox extends StatelessWidget {
  const _LabelBox(this.text, {this.icon, this.picked = false});
  final String text;
  final IconData? icon;
  final bool picked;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final ink = b == Brightness.dark ? Colors.white : const Color(0xFF111111);
    return Material(
      elevation: 3,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(10),
      color: picked ? VehicleTypeBar.fillFor(b) : PickupPill.fillFor(b),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 15, color: ink), const SizedBox(width: 5)],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, height: 1.2, fontWeight: FontWeight.w600, color: ink),
            ),
          ),
        ]),
      ),
    );
  }
}

Widget _dot(Color fill, Widget child, {bool ring = false}) => Container(
  width: 30,
  height: 30,
  decoration: BoxDecoration(
    color: fill,
    shape: BoxShape.circle,
    border: Border.all(color: Colors.white, width: ring ? 3 : 2),
    boxShadow: [
      BoxShadow(
        blurRadius: ring ? 8 : 3,
        spreadRadius: ring ? 2 : 0,
        color: ring ? fill.withValues(alpha: 0.6) : Colors.black26,
      ),
    ],
  ),
  alignment: Alignment.center,
  child: child,
);

IconData _vehicleIcon(String v) => switch (v) { 'bike' => Icons.two_wheeler, 'van' => Icons.local_shipping, _ => Icons.directions_car };

/// Family members and company trips on the map: a dot with a name over it;
/// a tap opens its sheet.
List<Marker> personMarkers(
  List<LivePerson> people, {
  required bool team,
  required void Function(LivePerson) onTap,
  String? picked,
}) => [
  for (final (i, p) in people.indexed)
    if (p.point != null)
      Marker(
        key: ValueKey('live-${team ? 'team' : 'person'}-${p.id}'),
        point: p.point!,
        width: 220,
        height: 110,
        child: GestureDetector(
          onTap: () => onTap(p),
          behavior: HitTestBehavior.deferToChild,
          child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
            _LabelBox(
              p.mapLabel,
              icon: team
                  ? Icons.business_center
                  : (p.status == 'on_trip' || p.status == 'pickup' ? Icons.local_taxi : Icons.place_outlined),
              picked: picked == p.id,
            ),
            const SizedBox(height: 4),
            _dot(
              team ? _teamColour : personColour(i),
              team
                  ? Icon(_vehicleIcon(p.vehicle), size: 16, color: Colors.white)
                  : Text(p.initial, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
              ring: picked == p.id,
            ),
            const SizedBox(height: 40),
          ]),
        ),
      ),
];

// ---- The picker ----------------------------------------------------------------------------------

/// The overlays picker: the overlays this rider may use, each with a switch;
/// several may be on. Opened from [MapOverlaysButton].
Future<void> showOverlayPicker(BuildContext context, {required LiveMapConfig config, List<LivePerson> offMap = const [],
    void Function(LivePerson)? onOpen}) =>
    showAppSheet<void>(
      id: 'home.map-overlays',
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => OverlayPickerSheet(config: config, offMap: offMap, onOpen: onOpen),
    );

class OverlayPickerSheet extends ConsumerWidget {
  const OverlayPickerSheet({super.key, required this.config, this.offMap = const [], this.onOpen});
  final LiveMapConfig config;

  /// People or trips the rules show without a spot on the map.
  final List<LivePerson> offMap;
  final void Function(LivePerson)? onOpen;

  static const _icons = {
    LiveOverlay.busy: Icons.local_fire_department_outlined,
    LiveOverlay.people: Icons.family_restroom,
    LiveOverlay.team: Icons.business_center_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final on = ref.watch(liveMapPrefsProvider).overlays;
    Widget row(LiveOverlay o) {
      final active = on.contains(o);
      return SwitchListTile(
        key: ValueKey('overlay-${o.key}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        secondary: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: active ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(_icons[o], color: active ? t.colorScheme.onPrimaryContainer : t.colorScheme.onSurface),
        ),
        title: Text(o.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(o.hint, maxLines: 1, overflow: TextOverflow.ellipsis),
        value: active,
        onChanged: (v) {
          // The overlays on now, not as last drawn: two quick taps keep both.
          final next = {...ref.read(liveMapPrefsProvider).overlays};
          v ? next.add(o) : next.remove(o);
          ref.read(liveMapPrefsProvider.notifier).setOverlays(next);
        },
      );
    }

    return LiveSheetBody(key: const ValueKey('overlay-picker'), children: [
      const LiveSheetHead(title: 'Map overlays'),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
        child: Text('Turn on as many as you like.', style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t))),
      ),
      for (final o in LiveOverlay.values)
        if (config.overlays.contains(o)) row(o),
      for (final p in offMap)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: const Icon(Icons.person_pin_circle_outlined),
          title: Text(p.mapLabel),
          trailing: const Icon(Icons.chevron_right),
          onTap: onOpen == null ? null : () => onOpen!(p),
        ),
      const SizedBox(height: 4),
      if (config.carsOn)
        LiveNote(
          config.carsMayHide
              ? 'Cars near you show when your region has them on. You can hide them in Settings.'
              : 'Cars near you show when your region has them on.',
        ),
    ]);
  }
}

// ---- The sheets ----------------------------------------------------------------------------------

/// A sheet's top line: a title (and what goes with it) and an X.
class LiveSheetHead extends StatelessWidget {
  const LiveSheetHead({super.key, required this.title, this.leading, this.below});
  final String title;
  final Widget? leading, below;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (leading != null) ...[Padding(padding: const EdgeInsets.only(top: 2), child: leading!), const SizedBox(width: 12)],
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              if (below != null) ...[const SizedBox(height: 4), below!],
            ]),
          ),
        ),
        IconButton(
          key: const ValueKey('live-sheet-close'),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close),
        ),
      ]),
    );
  }
}

/// A label, its value, and an icon in a soft box.
class LiveInfoRow extends StatelessWidget {
  const LiveInfoRow(this.icon, this.label, this.value, {super.key, this.tone, this.pill = false});
  final IconData icon;
  final String label, value;
  final Color? tone;
  final bool pill;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final tone = this.tone ?? t.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: this.tone != null ? tone.withValues(alpha: 0.14) : t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: tone),
        ),
        const SizedBox(width: 12),
        Text(label, style: t.textTheme.bodyLarge?.copyWith(color: muted)),
        const SizedBox(width: 12),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: pill
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: tone.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
                    child: Text(value, style: TextStyle(color: tone, fontSize: 14, fontWeight: FontWeight.w700)),
                  )
                : Text(
                    value,
                    textAlign: TextAlign.right,
                    style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
          ),
        ),
      ]),
    );
  }
}

/// A small grey line with an icon.
class LiveNote extends StatelessWidget {
  const LiveNote(this.text, {super.key, this.icon = Icons.info_outline});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: muted),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: t.textTheme.bodySmall?.copyWith(color: muted))),
      ]),
    );
  }
}

class LiveSheetBody extends StatelessWidget {
  const LiveSheetBody({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    ),
  );
}

Widget _chip(BuildContext context, IconData icon, String text, {Key? key}) {
  final t = Theme.of(context);
  return Container(
    key: key,
    padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
    decoration: BoxDecoration(color: t.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: t.colorScheme.onPrimaryContainer),
      const SizedBox(width: 5),
      Flexible(
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.colorScheme.onPrimaryContainer),
        ),
      ),
    ]),
  );
}

Widget _progress(BuildContext context, String? from, String? to, double v) {
  final t = Theme.of(context);
  final muted = mutedTextColor(t);
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(value: v.clamp(0.0, 1.0), minHeight: 6, color: const Color(0xFF2DABE2)),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(child: Text(from ?? '', overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: muted))),
        const SizedBox(width: 8),
        Flexible(child: Text(to ?? '', overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: muted))),
      ]),
    ]),
  );
}

Widget _updated(BuildContext context, DateTime? at) {
  final t = Theme.of(context);
  final s = updatedAgo(at, DateTime.now());
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
    child: Row(children: [
      Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text('${s[0].toUpperCase()}${s.substring(1)}', style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
    ]),
  );
}

/// A busy cell: its level and the fields the region shows, a quieter place
/// near by, and "Set pickup here" (the cell's centre).
Future<void> showBusyAreaSheet(BuildContext context, {required BusyCell cell, required BusyAreas areas,
    required VoidCallback onSetPickup}) =>
    showAppSheet<void>(
      id: 'home.busy-area',
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => BusyAreaSheet(cell: cell, areas: areas, onSetPickup: onSetPickup),
    );

class BusyAreaSheet extends StatelessWidget {
  const BusyAreaSheet({super.key, required this.cell, required this.areas, required this.onSetPickup});
  final BusyCell cell;
  final BusyAreas areas;
  final VoidCallback onSetPickup;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final deep = t.brightness == Brightness.dark ? const Color(0xFFFF6E66) : const Color(0xFFB71C1C);
    final tone = cell.level >= 3 ? deep : (t.brightness == Brightness.dark ? const Color(0xFFFFB74D) : const Color(0xFFB45309));
    return LiveSheetBody(key: const ValueKey('busy-area-sheet'), children: [
      LiveSheetHead(
        title: cell.title,
        below: Text('Busy areas · ${updatedAgo(areas.at, DateTime.now())}', style: t.textTheme.bodyMedium?.copyWith(color: muted)),
      ),
      const SizedBox(height: 6),
      LiveInfoRow(Icons.local_fire_department, 'Busy level', busyLabel(cell.level), tone: tone, pill: true),
      if (cell.fareLine case final f?) LiveInfoRow(Icons.payments_outlined, 'Fares here now', f),
      if (cell.waitLine case final w?) LiveInfoRow(Icons.schedule, 'Pickup wait', w),
      if (cell.nextLine case final n?)
        LiveInfoRow(cell.next == 'down' ? Icons.trending_down : (cell.next == 'up' ? Icons.trending_up : Icons.trending_flat),
            'Next hour', n),
      if (cell.tip case final tip?)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Container(
            key: const ValueKey('busy-tip'),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: t.colorScheme.secondaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(Icons.lightbulb_outline, size: 20, color: t.colorScheme.onSecondaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tip.line,
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSecondaryContainer, fontWeight: FontWeight.w500),
                ),
              ),
            ]),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        child: FilledButton.icon(
          key: const ValueKey('busy-set-pickup'),
          onPressed: () {
            Navigator.of(context).maybePop();
            onSetPickup();
          },
          icon: const Icon(Icons.trip_origin),
          label: const Text('Set pickup here'),
        ),
      ),
    ]);
  }
}

/// A family member: their trip, the car (never the plate), how far along,
/// Call (the host has their number), and that they can see it is shared.
Future<void> showFamilyMemberSheet(BuildContext context, {required LivePerson person, required Color colour, DateTime? at}) =>
    showAppSheet<void>(
      id: 'home.family-member',
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FamilyMemberSheet(person: person, colour: colour, at: at),
    );

class FamilyMemberSheet extends ConsumerWidget {
  const FamilyMemberSheet({super.key, required this.person, required this.colour, this.at});
  final LivePerson person;
  final Color colour;
  final DateTime? at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = person;
    // The host's own family list has the member's number; nobody else's does.
    final phone = ref.watch(familyMineProvider).value?.members.where((m) => m.id == p.id).firstOrNull?.phone;
    final drop = p.dropoffAt;
    return LiveSheetBody(key: const ValueKey('family-member-sheet'), children: [
      LiveSheetHead(
        title: p.name,
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: colour,
          child: Text(p.initial, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
        ),
        below: Align(
          alignment: Alignment.centerLeft,
          child: _chip(context, Icons.family_restroom, 'Shared with family', key: const ValueKey('family-member-shared')),
        ),
      ),
      const SizedBox(height: 4),
      if (p.status != null)
        LiveInfoRow(p.status == 'here' ? Icons.place_outlined : Icons.local_taxi, p.tripLine,
            p.etaLine ?? (p.area ?? ''), tone: const Color(0xFF2DABE2)),
      if (p.car != null || p.driver != null)
        LiveInfoRow(Icons.directions_car_outlined, 'Car', [p.car, if (p.driver != null) 'with ${p.driver}'].nonNulls.join(', ')),
      if (drop != null)
        LiveInfoRow(Icons.flag_outlined, p.status == 'dropped' ? 'Dropped off' : 'Drop-off about',
            TimeOfDay.fromDateTime(drop).format(context)),
      if (p.progress != null) _progress(context, p.from, p.to, p.progress!),
      _updated(context, p.at ?? at),
      if (phone != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: OutlinedButton.icon(
            key: const ValueKey('family-member-call'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => launchUrl(Uri(scheme: 'tel', path: phone)),
            icon: const Icon(Icons.call_outlined),
            label: const Text('Call'),
          ),
        ),
      const SizedBox(height: 10),
      LiveNote("${p.name} can see that it's shared with the family and can stop sharing at any time.",
          icon: Icons.visibility_outlined),
    ]);
  }
}

/// A company trip: where it goes, the purpose, ETA and cost so far, and why
/// it is shown.
Future<void> showTeamTripSheet(BuildContext context, {required LivePerson trip, DateTime? at}) => showAppSheet<void>(
  id: 'home.team-trip',
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => TeamTripSheet(trip: trip, at: at),
);

class TeamTripSheet extends StatelessWidget {
  const TeamTripSheet({super.key, required this.trip, this.at});
  final LivePerson trip;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final p = trip;
    final company = p.company ?? 'Your company';
    return LiveSheetBody(key: const ValueKey('team-trip-sheet'), children: [
      LiveSheetHead(
        title: '${p.name} · Company trip',
        leading: const CircleAvatar(
          radius: 22,
          backgroundColor: _teamColour,
          child: Icon(Icons.business_center, color: Colors.white, size: 22),
        ),
        below: Align(alignment: Alignment.centerLeft, child: _chip(context, Icons.apartment, company)),
      ),
      const SizedBox(height: 4),
      if (p.to != null) LiveInfoRow(Icons.place_outlined, 'To', p.to!, tone: _teamColour),
      if (p.purpose != null) LiveInfoRow(Icons.work_outline, 'Purpose', p.purpose!),
      if (p.eta != null) LiveInfoRow(Icons.schedule, 'ETA', '${p.eta} min'),
      if (p.cost != null) LiveInfoRow(Icons.receipt_long_outlined, 'Cost so far', formatMoney(p.cost, p.currency)),
      if (p.progress != null) _progress(context, p.from, p.to, p.progress!),
      _updated(context, p.at ?? at),
      const SizedBox(height: 12),
      LiveNote('Shown because $company pays for this trip.', icon: Icons.verified_user_outlined),
    ]);
  }
}

/// The member's own company trip: "Company trip" and, on a tap, who can see
/// it and who looked lately.
class CompanyTripChip extends ConsumerStatefulWidget {
  const CompanyTripChip({super.key, required this.tripId});
  final String tripId;

  @override
  ConsumerState<CompanyTripChip> createState() => _CompanyTripChipState();
}

class _CompanyTripChipState extends ConsumerState<CompanyTripChip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final n = ref.watch(companyTripNoteProvider(widget.tripId)).value;
    if (n == null || !n.company) return const SizedBox.shrink();
    final c = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('company-trip-strip'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ActionChip(
          key: const ValueKey('company-trip-chip'),
          avatar: Icon(Icons.business_center, size: 18, color: c.primary),
          label: const Text('Company trip'),
          labelStyle: TextStyle(color: c.primary, fontWeight: FontWeight.w600),
          backgroundColor: c.primaryContainer.withValues(alpha: 0.5),
          side: BorderSide(color: c.primary),
          onPressed: () => setState(() => _open = !_open),
        ),
        if (_open)
          Card(
            key: const ValueKey('company-trip-who'),
            margin: const EdgeInsets.only(top: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n.whoLine),
                if (n.seenBy.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Looked lately: ${n.seenBy.join(', ')}', style: TextStyle(color: c.onSurfaceVariant)),
                ],
                const SizedBox(height: 4),
                Text('Your personal trips never show.', style: TextStyle(color: c.onSurfaceVariant)),
              ]),
            ),
          ),
      ]),
    );
  }
}
