import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/fare.dart';
import '../../core/home_layout.dart' show HomeSection, HomeSectionType, homeSearchDefaultText;
import '../../core/home_tiles.dart';
import '../../core/home_sections.dart';
import '../../core/service_boxes.dart';
import '../../data/geo_service.dart';
import '../../widgets/common.dart' show inkOn, mutedTextColor;
import '../../core/media_assets.dart' show isMediaRef;
import '../../widgets/media_image.dart';
import '../../widgets/net_image.dart';
import '../../widgets/scroll_fade.dart';
import '../../core/page_styles.dart' show homeSurface;
import '../../core/smart_address.dart' show placeSubtitle;
import '../../widgets/page_style_host.dart';

/// Whether [uri] is a picture that loads over the network (and so shows a
/// skeleton first): an address, or a Media Gallery upload (`media:<id>`).
/// Pure.
bool loadsOverNetwork(String? uri) => uri != null && (uri.startsWith('http') || isMediaRef(uri));

/// A stored picture: an http(s) or `data:` URL. [onSettled] runs once the
/// picture is painted or has fallen back to [fallback], after the frame.
Widget uriImage(
  String? uri, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.contain,
  Alignment alignment = Alignment.center,
  Widget? fallback,
  VoidCallback? onSettled,
}) {
  void settled() {
    if (onSettled != null) WidgetsBinding.instance.addPostFrameCallback((_) => onSettled());
  }

  final none = fallback ?? SizedBox(width: width, height: height);
  if (uri == null) return none;
  // A Media Gallery upload: looked up, then loaded (a skeleton meanwhile).
  if (isMediaRef(uri)) {
    return MediaImage(
      uri,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      fallback: none,
      onSettled: onSettled,
    );
  }
  if (uri.startsWith('data:')) {
    try {
      return Image.memory(
        base64Decode(uri.split(',').last),
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        errorBuilder: (_, _, _) => none,
      );
    } catch (_) {
      return none;
    }
  }
  if (uri.startsWith('http')) {
    final bone = boneUntilPainted(width: width, height: height);
    return Image.network(
      uri,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      frameBuilder: (context, child, frame, synchronous) {
        if (synchronous || frame != null) settled();
        return bone(context, child, frame, synchronous);
      },
      errorBuilder: (_, _, _) {
        settled();
        return none;
      },
    );
  }
  return none;
}

/// The vehicle-type bar while the service catalogue loads: the boxes' shape,
/// shimmering, with no names or icons that would then change.
class VehicleTypeBarSkeleton extends StatelessWidget {
  const VehicleTypeBarSkeleton({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 66,
    child: SkeletonizerConfig(
      data: SkeletonizerConfigData(brightness: Theme.of(context).brightness),
      child: Skeletonizer.zone(
        key: const ValueKey('vehicle-type-bar-skeleton'),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 4,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Bone(width: 30, height: 22, borderRadius: BorderRadius.circular(6)),
                const SizedBox(height: 8),
                Bone.text(words: i.isEven ? 1 : 2, fontSize: 13),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The vehicle-type bar (Expo `rideTypes`): one card per bookable service,
/// the selected one wider, with an "i" for its description. Nothing shows as
/// chosen, and nothing can be chosen, while a card's picture is still a
/// skeleton: the bar comes alive once every picture has painted or fallen
/// back to the car icon (vehicleBarReady).
class VehicleTypeBar extends StatefulWidget {
  const VehicleTypeBar({
    super.key,
    required this.services,
    required this.selected,
    required this.onSelect,
    this.onInfo,
  });

  final List<RideService> services;
  final RideService selected;
  final ValueChanged<RideService> onSelect;

  /// What the "i" opens: the fare details where the home screen knows the
  /// rates; the service's description alone otherwise.
  final ValueChanged<RideService>? onInfo;

  /// The chosen box's fill and its "i" (inDrive's indigo and blue): indigo
  /// with white text on a dark sheet, a light blue with dark text on a light one.
  static const selectedFill = Color(0xFF2B2E8C);
  static const selectedFillLight = Color(0xFFD8EEFB);
  static const infoBlue = Color(0xFF5468FF);

  static Color fillFor(Brightness b) => b == Brightness.dark ? selectedFill : selectedFillLight;

  @override
  State<VehicleTypeBar> createState() => _VehicleTypeBarState();
}

/// Whether every network picture among [images] has [settled] (painted or
/// fallen back); pictures that do not load over the network never wait.
/// Pure.
bool vehicleBarReady(Iterable<String?> images, Set<String> settled) =>
    images.every((u) => !loadsOverNetwork(u) || settled.contains(u));

class _VehicleTypeBarState extends State<VehicleTypeBar> {
  /// The pictures that have painted or fallen back.
  final _settled = <String>{};

  void _settle(String? uri) {
    if (uri == null || !mounted || _settled.contains(uri)) return;
    setState(() => _settled.add(uri));
  }

  List<RideService> get services => widget.services;
  RideService get selected => widget.selected;

  static const infoBlue = VehicleTypeBar.infoBlue;
  static Color fillFor(Brightness b) => VehicleTypeBar.fillFor(b);

  void _info(BuildContext context, RideService s) => showAppSheet<void>(id: 'home.vehicle-description',
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.image != null) Center(child: uriImage(s.image, height: 96)),
            const SizedBox(height: 12),
            Text(s.name, style: Theme.of(c).textTheme.titleLarge),
            if (s.description.isNotEmpty) ...[const SizedBox(height: 8), Text(s.description)],
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ready = vehicleBarReady(services.map((s) => s.image), _settled);
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    // App Page Settings → Home → Vehicle bar.
    final style = SurfaceStyle.of(context, homeSurface);
    // The words checked against what they sit on: the map sheet (an admin
    // colour or the theme's) for the others, the chosen card's fill for
    // the chosen one. The seats were the theme's secondary grey as it was,
    // 2.5:1 with an admin's light grey.
    final sheet = style.setColor('mapSheetColor', t.brightness) ?? t.colorScheme.surface;
    final chosenFill = style.color('vehicleSelected', t.brightness) ?? fillFor(t.brightness);
    final onFill = inkOn(chosenFill, preferred: dark ? Colors.white : t.colorScheme.onSurface);
    final ink = inkOn(sheet, preferred: t.colorScheme.onSurface);
    final muted = mutedTextColor(t, background: sheet);
    final radius = BorderRadius.circular(style.number('vehicleRadius'));
    return SizedBox(
      // Taller by as much as the phone's larger text makes the name line.
      height: style.number('vehicleBarHeight') + (MediaQuery.textScalerOf(context).scale(13) - 13) * 1.4,
      // Its far edge fades while there are more vehicles to scroll to (at
      // 317 wide the last was cut to "F…" with no sign the row goes on).
      child: HorizontalScrollFade(
        child: ListView.separated(
        key: const ValueKey('vehicle-type-bar'),
        scrollDirection: Axis.horizontal,
        itemCount: services.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final s = services[i];
          final on = ready && s.name == selected.name;
          final fg = on ? onFill : ink;
          final seats = on ? onFill : muted;
          // Unchosen boxes are the sheet itself; the chosen one is filled,
          // with the name in full and the seats pushed to its right edge.
          return Material(
            key: ValueKey('vehicle-type-${s.name}'),
            color: on ? chosenFill : Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: ready ? () => widget.onSelect(s) : null,
              child: Stack(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: IntrinsicWidth(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          // Flush with the name's left edge, as inDrive's.
                          uriImage(
                            s.image,
                            width: style.number('vehicleImageWidth'),
                            height: 26,
                            alignment: Alignment.centerLeft,
                            fallback: Icon(Icons.directions_car, size: 24, color: fg),
                            onSettled: () => _settle(s.image),
                          ),
                          if (on) ...[
                            const Spacer(),
                            const SizedBox(width: 12),
                            // Room for the (i), which stands over the box's corner
                            // (below) so its tap area can be 44 square.
                            SizedBox(width: style.number('infoIconSize')),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            s.name,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: style.number('vehicleNameSize'),
                              fontWeight: FontWeight.w500,
                              color: fg,
                            ),
                          ),
                          on ? const Spacer() : const SizedBox(width: 6),
                          if (on) const SizedBox(width: 12),
                          Icon(Icons.person, size: 13, color: seats),
                          Text('${s.seats}', style: TextStyle(fontSize: 13, color: seats)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // The chosen box's (i): a 44-square tap area in its top corner,
              // named for screen readers and on hover.
              if (on)
                Positioned(
                  top: 0,
                  right: 0,
                  width: 44,
                  height: 44,
                  child: Tooltip(
                    message: 'Fare details',
                    excludeFromSemantics: true,
                    child: Semantics(
                      // Its own node: not merged into the box's button.
                      container: true,
                      button: true,
                      label: 'Fare details for ${s.name}',
                      excludeSemantics: true,
                      child: InkResponse(
                        key: ValueKey('vehicle-info-${s.name}'),
                        radius: 22,
                        onTap: () => widget.onInfo != null ? widget.onInfo!(s) : _info(context, s),
                        child: Align(
                          // Where the icon stood in the row: the box's padding in.
                          alignment: const Alignment(0.4, -0.3),
                          child: Icon(
                            Icons.info_outline,
                            size: style.number('infoIconSize'),
                            color: style.color('infoIcon', t.brightness) ?? infoBlue,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          );
        },
        ),
      ),
    );
  }
}


/// "Where to & for how much?" (Expo `searchBar`).
class HomeSearchPill extends StatelessWidget {
  const HomeSearchPill({super.key, required this.onTap, this.text = homeSearchDefaultText});
  final VoidCallback onTap;

  /// Admin → Display Settings → Home page → Search bar's words.
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // App Page Settings → Home → Search bar.
    final style = SurfaceStyle.of(context, homeSurface);
    final radius = BorderRadius.circular(style.number('searchRadius'));
    return Material(
      color: style.color('searchColor', t.brightness) ?? t.colorScheme.surfaceContainerHighest,
      borderRadius: radius,
      child: InkWell(
        key: const ValueKey('home-search'),
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 18, vertical: style.number('searchPadding')),
          child: Row(
            children: [
              Icon(Icons.search, size: style.number('searchIconSize')),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontSize: style.number('searchFontSize'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How many recent places show with the home sheet all the way down.
const homeRecentAtRest = 2;

/// Recent destinations under the search bar (Expo `recentLocations`).
class HomeRecentPlaces extends StatelessWidget {
  const HomeRecentPlaces({super.key, required this.places, required this.onTap});
  final List<Place> places;
  final ValueChanged<Place> onTap;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final p in places)
        ListTile(
          key: ValueKey('home-recent-${p.name}'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.place_outlined),
          title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: switch (placeSubtitle(p.name, p.address)) {
            final a? => Text(a, maxLines: 1, overflow: TextOverflow.ellipsis),
            null => null,
          },
          onTap: () => onTap(p),
        ),
    ],
  );
}

const _boxIcons = <String, IconData>{
  'ShoppingBag': Icons.shopping_bag_outlined,
  'Car': Icons.directions_car_outlined,
  'Building2': Icons.apartment,
  'Package': Icons.inventory_2_outlined,
  'Truck': Icons.local_shipping_outlined,
  'Bike': Icons.pedal_bike,
  'Bus': Icons.directions_bus_outlined,
  'Plane': Icons.flight,
  'MapPin': Icons.place_outlined,
  'Navigation': Icons.navigation_outlined,
  'Clock': Icons.schedule,
  'Bell': Icons.notifications_outlined,
};

/// The service boxes in the rows the admin laid out (Display Settings →
/// Home page → Service boxes; before that, the big box on the left with two
/// beside it, then a row of two). Boxes fill the places in order; a place
/// past the last box stays empty. Each picture sits where the admin put it
/// and may run past the box's edge, which trims it.
class ServiceBoxesGrid extends StatelessWidget {
  const ServiceBoxesGrid({
    super.key,
    required this.boxes,
    required this.onOpen,
    this.rows = const [BoxRowKind.bigLeft, BoxRowKind.two],
  });
  final List<ServiceBoxView> boxes;
  final ValueChanged<ServiceBoxView> onOpen;
  final List<BoxRowKind> rows;

  @override
  Widget build(BuildContext context) {
    if (boxes.isEmpty || rows.isEmpty) return const SizedBox.shrink();
    // App Page Settings → Home → Service boxes.
    final style = SurfaceStyle.of(context, homeSurface);
    final short = style.number('boxHeight');
    final tall = short * 2 + boxGap;
    var next = 0;
    ServiceBoxView? take() => next < boxes.length ? boxes[next++] : null;
    Widget place(ServiceBoxView? b, bool isTall) => b == null
        ? SizedBox(height: isTall ? tall : short)
        : _ServiceBox(box: b, height: isTall ? tall : short, onOpen: onOpen);
    final out = <Widget>[];
    for (final row in rows) {
      final cells = [for (final t in row.tall) place(take(), t)];
      if (out.isNotEmpty) out.add(const SizedBox(height: boxGap));
      Widget beside(int i) => Expanded(child: cells[i]);
      out.add(switch (row) {
        BoxRowKind.bigLeft || BoxRowKind.bigRight => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            textDirection: row == BoxRowKind.bigRight ? TextDirection.rtl : TextDirection.ltr,
            children: [
              beside(0),
              const SizedBox(width: boxGap),
              Expanded(child: Column(children: [cells[1], const SizedBox(height: boxGap), cells[2]])),
            ],
          ),
        _ => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < cells.length; i++) ...[if (i > 0) const SizedBox(width: boxGap), beside(i)],
          ]),
      });
    }
    return Column(key: const ValueKey('service-boxes'), mainAxisSize: MainAxisSize.min, children: out);
  }
}

class _ServiceBox extends StatelessWidget {
  const _ServiceBox({required this.box, required this.height, required this.onOpen});
  final ServiceBoxView box;
  final double height;
  final ValueChanged<ServiceBoxView> onOpen;

  @override
  Widget build(BuildContext context) {
    final b = box;
    final t = Theme.of(context);
    final style = SurfaceStyle.of(context, homeSurface);
    final radius = BorderRadius.circular(style.number('boxRadius'));
    final fill = style.color('boxColor', t.brightness) ?? t.colorScheme.surfaceContainerHigh;
    final ink = style.color('boxTitleColor', t.brightness) ?? t.colorScheme.onSurface;
    final look = b.look;
    final badgeAt = look.badgeAt;
    return SizedBox(
      height: height,
      child: Material(
        color: fill,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('service-box-${b.index}'),
          onTap: () => onOpen(b),
          child: LayoutBuilder(builder: (context, c) {
            final pic = boxPictureRect(look, c.maxWidth, height);
            // The title keeps clear of a badge in a top corner beside it.
            final badgeTop = b.badgeWords.isNotEmpty && badgeAt.y < 0;
            return Stack(clipBehavior: Clip.hardEdge, children: [
              Positioned(
                left: pic.left,
                top: pic.top,
                width: pic.side,
                height: pic.side,
                child: IgnorePointer(child: _BoxPicture(box: b, side: pic.side)),
              ),
              Positioned(
                left: 14,
                // A badge top left: the title goes under it; top right: the
                // title stops short of it.
                top: badgeTop && badgeAt.x < 0 ? 16 + look.badgeY + look.badgeSize * 2.2 : 12,
                right: badgeTop && badgeAt.x > 0 ? 16 + look.badgeX + look.badgeSize * 5.5 : 12,
                child: Text(
                  b.title,
                  key: ValueKey('service-box-title-${b.index}'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ink, fontSize: style.number('boxTitleSize'), fontWeight: FontWeight.w500, height: 1.2),
                ),
              ),
              if (b.badgeWords.isNotEmpty)
                Positioned(
                  left: badgeAt.x < 0 ? 10 + look.badgeX : null,
                  right: badgeAt.x > 0 ? 10 + look.badgeX : null,
                  top: badgeAt.y < 0 ? 10 + look.badgeY : null,
                  bottom: badgeAt.y > 0 ? 10 + look.badgeY : null,
                  child: FlipBadge(
                    key: ValueKey('service-box-badge-${b.index}'),
                    words: b.badgeWords,
                    seconds: look.flipSeconds,
                    size: look.badgeSize,
                  ),
                ),
            ]);
          }),
        ),
      ),
    );
  }
}

/// A box's picture: the admin's image, else its icon (a Media Gallery one
/// or a built-in name), filling [side].
class _BoxPicture extends StatelessWidget {
  const _BoxPicture({required this.box, required this.side});
  final ServiceBoxView box;
  final double side;

  @override
  Widget build(BuildContext context) {
    final b = box;
    if (b.imageUri != null) return uriImage(b.imageUri, width: side, height: side, fit: BoxFit.contain);
    return FittedBox(
      child: isMediaRef(b.iconName)
          ? MediaIcon(b.iconName, fallback: Icons.apps, size: side, color: Color(b.accent))
          : Icon(_boxIcons[b.iconName] ?? Icons.apps, size: side, color: Color(b.accent)),
    );
  }
}

/// A badge whose words take turns, each for [seconds], flipping over
/// ("NEW", "50% OFF", "NEW", ...), each word in its own colours. One word
/// stays put; with reduced motion the words change without the flip.
class FlipBadge extends StatefulWidget {
  const FlipBadge({super.key, required this.words, this.seconds = badgeSecondsDefault, this.size = badgeSizeDefault});
  final List<BadgeWord> words;
  final double seconds;
  final double size;

  @override
  State<FlipBadge> createState() => _FlipBadgeState();
}

class _FlipBadgeState extends State<FlipBadge> {
  Timer? _timer;
  int _at = 0;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(FlipBadge old) {
    super.didUpdateWidget(old);
    if (old.seconds != widget.seconds || old.words.length != widget.words.length) {
      _at = 0;
      _arm();
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (widget.words.length < 2) return;
    final step = Duration(milliseconds: (widget.seconds * 1000).round().clamp(1000, 6000));
    _timer = Timer.periodic(step, (_) {
      if (mounted) setState(() => _at = (_at + 1) % widget.words.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.words[_at % widget.words.length];
    final size = widget.size;
    final pill = Container(
      key: ValueKey('badge-word-$_at-${w.text}'),
      padding: EdgeInsets.symmetric(horizontal: size * 0.8, vertical: size / 3),
      decoration: BoxDecoration(color: Color(w.fill), borderRadius: BorderRadius.circular(999)),
      child: Text(
        w.text,
        style: TextStyle(color: Color(w.ink), fontSize: size, fontWeight: FontWeight.w700, letterSpacing: 0.5, height: 1.1),
      ),
    );
    if (widget.words.length < 2 || MediaQuery.disableAnimationsOf(context)) return pill;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOut,
      // Only the incoming word shows: it flips down into place.
      layoutBuilder: (current, previous) => current ?? const SizedBox.shrink(),
      transitionBuilder: (child, anim) => AnimatedBuilder(
        animation: anim,
        child: child,
        builder: (_, c) => Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.004)
            ..rotateX((1 - anim.value) * -math.pi / 2),
          child: c,
        ),
      ),
      child: pill,
    );
  }
}

/// A picture for a tile or a heading: the admin's image filling it, else
/// its icon (a Media Gallery one or a built-in name) sized [iconSize].
Widget homePicture({String? imageUri, String? iconName, required double iconSize, Color? color, BoxFit fit = BoxFit.cover}) {
  if (imageUri != null) return uriImage(imageUri, fit: fit, width: double.infinity, height: double.infinity);
  return Center(
    child: isMediaRef(iconName)
        ? MediaIcon(iconName, fallback: Icons.apps, size: iconSize, color: color)
        : Icon(_boxIcons[iconName] ?? Icons.apps, size: iconSize, color: color),
  );
}

/// A tile row or a wide tile row (Display Settings → Home page): a heading
/// with its picture and an arrow, then tiles scrolling sideways with their
/// words under them, and a last "see all" tile. A wide tile also has a
/// second line, and any tile a corner label.
class HomeTileRow extends StatelessWidget {
  const HomeTileRow({super.key, required this.section, required this.onOpen});
  final HomeSection section;

  /// A tile's page (null: Coming Soon), with the words to say so.
  final void Function(String? route, String title) onOpen;

  @override
  Widget build(BuildContext context) {
    final s = section;
    final t = Theme.of(context);
    final style = SurfaceStyle.of(context, homeSurface);
    final fill = style.color('boxColor', t.brightness) ?? t.colorScheme.surfaceContainerHigh;
    final ink = style.color('boxTitleColor', t.brightness) ?? t.colorScheme.onSurface;
    final wide = s.type == HomeSectionType.wide;
    final tiles = s.shownTiles;
    return Column(key: ValueKey('home-tiles-${s.id}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (s.title.isNotEmpty)
        InkWell(
          key: ValueKey('home-tiles-heading-${s.id}'),
          onTap: () => onOpen(s.headingRoute, s.title),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              if (s.headingIcon != null) ...[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                  child: homePicture(iconName: s.headingIcon, iconSize: 22, color: ink),
                ),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(s.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: ink)),
              ),
              const SizedBox(width: 6),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                child: Icon(Icons.chevron_right, size: 16, color: ink),
              ),
            ]),
          ),
        ),
      LayoutBuilder(builder: (context, c) {
        final w = tileWidth(c.maxWidth, s.across);
        final pic = wide ? w * wideTileAspect : w;
        // The picture, its words (two lines), a second line on wide tiles,
        // at the phone's text size.
        final ts = MediaQuery.textScalerOf(context);
        final height = pic + 8 + ts.scale(16) * 1.25 * 2 + 6 + (wide ? ts.scale(14) * 1.5 : 0);
        final cards = <Widget>[
          for (final tile in tiles)
            _Tile(tile: tile, width: w, picture: pic, wide: wide, fill: fill, ink: ink, onTap: () => onOpen(tile.route, tile.caption)),
          if (s.seeAll.isNotEmpty)
            _Tile(
              key: ValueKey('home-tiles-see-all-${s.id}'),
              tile: HomeTile({'id': 'see-all', 'caption': s.seeAll, 'iconName': s.headingIcon}),
              width: w,
              picture: pic,
              wide: wide,
              fill: fill,
              ink: ink,
              arrow: true,
              onTap: () => onOpen(s.headingRoute, s.title),
            ),
        ];
        return SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(width: tileGap),
            itemBuilder: (_, i) => cards[i],
          ),
        );
      }),
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.tile,
    required this.width,
    required this.picture,
    required this.wide,
    required this.fill,
    required this.ink,
    required this.onTap,
    this.arrow = false,
  });
  final HomeTile tile;
  final double width, picture;
  final bool wide, arrow;
  final Color fill, ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bg = tile.background == null ? fill : Color(tile.background!);
    final at = tile.labelAt;
    const r = Radius.circular(12);
    return SizedBox(
      width: width,
      child: InkWell(
        key: ValueKey('home-tile-${tile.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: width,
              height: picture,
              color: bg,
              child: Stack(fit: StackFit.expand, children: [
                homePicture(imageUri: tile.imageUri, iconName: tile.iconName, iconSize: picture * tile.size / 100, color: ink),
                if (tile.label.isNotEmpty)
                  Positioned(
                    left: at.x < 0 ? 0 : null,
                    right: at.x > 0 ? 0 : null,
                    top: at.y < 0 ? 0 : null,
                    bottom: at.y > 0 ? 0 : null,
                    child: Container(
                      key: ValueKey('home-tile-label-${tile.id}'),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Color(tile.labelFill),
                        // Round on the side facing into the tile.
                        borderRadius: BorderRadius.only(
                          topLeft: at.x > 0 && at.y > 0 ? r : Radius.zero,
                          topRight: at.x < 0 && at.y > 0 ? r : Radius.zero,
                          bottomLeft: at.x > 0 && at.y < 0 ? r : Radius.zero,
                          bottomRight: at.x < 0 && at.y < 0 ? r : Radius.zero,
                        ),
                      ),
                      child: Text(tile.label,
                          style: TextStyle(color: Color(tile.labelInk), fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: tile.caption),
              if (arrow) const WidgetSpan(child: Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.arrow_forward, size: 16))),
            ]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.textTheme.bodyLarge?.copyWith(color: ink, height: 1.25),
          ),
          if (wide && tile.sub.isNotEmpty)
            Text(tile.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium?.copyWith(color: ink.withValues(alpha: 0.6))),
        ]),
      ),
    );
  }
}

/// Promo cards (Display Settings → Home page): small coloured cards with
/// their words, scrolling sideways.
class HomePromoRow extends StatelessWidget {
  const HomePromoRow({super.key, required this.section, required this.onOpen});
  final HomeSection section;
  final void Function(String? route, String title) onOpen;

  static const side = 96.0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fill = SurfaceStyle.of(context, homeSurface).color('boxColor', t.brightness) ?? t.colorScheme.surfaceContainerHigh;
    final cards = section.shownTiles;
    return SizedBox(
      key: ValueKey('home-promos-${section.id}'),
      height: side,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: tileGap),
        itemBuilder: (_, i) {
          final c = cards[i];
          final bg = c.background == null ? fill : Color(c.background!);
          // Words dark on a light card, white on a dark one.
          final ink = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : const Color(0xFF1B1D22);
          return SizedBox(
            width: side,
            child: Material(
              color: bg,
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('home-promo-${c.id}'),
                onTap: () => onOpen(c.route, c.caption),
                child: Stack(children: [
                  Positioned(
                    right: -10,
                    top: -6,
                    width: 76,
                    height: 76,
                    child: Opacity(opacity: c.imageUri == null ? 0.5 : 1, child: homePicture(imageUri: c.imageUri, iconName: c.iconName, iconSize: 70, color: ink)),
                  ),
                  Positioned(
                    left: 9,
                    right: 6,
                    bottom: 9,
                    child: Text(c.caption,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: ink, fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.2)),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The pickup pill over the map (Expo `addressBar`).
class PickupPill extends StatelessWidget {
  const PickupPill({super.key, required this.place, required this.onTap});
  final Place? place;
  final VoidCallback onTap;

  /// The box (inDrive's): white on a light map, charcoal on a dark one.
  static Color fillFor(Brightness b) => b == Brightness.dark ? const Color(0xFF262626) : Colors.white;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF111111);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
      child: Material(
        elevation: 3,
        shadowColor: Colors.black38,
        borderRadius: BorderRadius.circular(10),
        color: fillFor(t.brightness),
        child: InkWell(
          key: const ValueKey('pickup-pill'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Pickup point',
                        style: TextStyle(fontSize: 13, height: 1.25, color: dark ? Colors.white60 : const Color(0xFF7A7A7A)),
                      ),
                      Text(
                        // Large text: the short words, so the pill isn't cut off.
                        place?.name ??
                            (MediaQuery.textScalerOf(context).scale(1) > 1.15 ? 'Set pickup' : 'Set pickup location'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 17, height: 1.3, fontWeight: FontWeight.w600, color: ink),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Icon(Icons.chevron_right, size: 20, color: ink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Colours of the simulated cars, by the selected service's position.
const _carColors = [Color(0xFF111111), Color(0xFF0F4C81), Color(0xFF1F7A3A), Color(0xFF8B5A00)];

Marker demoCarMarker(DemoCar c, int serviceIndex) => Marker(
  point: LatLng(c.lat, c.lng),
  width: 30,
  height: 30,
  child: Container(
    decoration: BoxDecoration(
      color: _carColors[serviceIndex % _carColors.length],
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
    ),
    child: Transform.rotate(
      angle: c.heading * 3.141592653589793 / 180,
      child: const Icon(Icons.navigation, size: 16, color: Colors.white),
    ),
  ),
);
