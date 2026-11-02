// A vehicle on the map drawn with its service's Map Icon (Vehicle Services
// › Map Icon, a Media Gallery upload; migration 0336):
//  * a multi-angle icon shows the frame drawn nearest the car's heading,
//    upright (the picture already faces that way), every frame loaded
//    ahead so turning never flickers;
//  * a single picture is turned to the heading, as the built-in arrow is;
//  * no icon, or one that can't be found, keeps the built-in look
//    ([fallback]).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/media_assets.dart';
import '../data/app_display_repository.dart' show rideServicesProvider;
import 'media_image.dart';

/// The Map Icon (`media:<id>`) of the ride service called [name], or null
/// when it has none or the catalogue isn't read yet.
final serviceMapIconProvider = Provider.family<String?, String?>((ref, name) {
  if (name == null || name.trim().isEmpty) return null;
  final services = ref.watch(rideServicesProvider).value ?? const [];
  for (final s in services) {
    if (s.name == name) return s.mapIcon;
  }
  return null;
});

class MapVehicleIcon extends ConsumerStatefulWidget {
  const MapVehicleIcon({
    super.key,
    required this.icon,
    required this.heading,
    required this.size,
    required this.fallback,
  });

  /// The service's Map Icon: `media:<id>`, or null/empty for none.
  final String? icon;

  /// Compass heading of the car in degrees (0 = north); null when unknown
  /// (a multi-angle icon then shows its 0° frame, a single one unturned).
  final double? heading;
  final double size;

  /// The built-in look, drawn when there is no icon to show.
  final Widget fallback;

  @override
  ConsumerState<MapVehicleIcon> createState() => _MapVehicleIconState();
}

/// The frames already asked for, by address: each is loaded once per run
/// and kept in the image cache.
final _precached = <String>{};

/// Forgets what was loaded ahead. For tests.
@visibleForTesting
void resetMapIconPrecache() => _precached.clear();

class _MapVehicleIconState extends ConsumerState<MapVehicleIcon> {
  void _precache(MediaAsset a) {
    final urls = [for (final f in a.angles) mediaUrlOf(f.path)].where((u) => !_precached.contains(u)).toList();
    if (urls.isEmpty) return;
    _precached.addAll(urls);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final u in urls) {
        precacheImage(NetworkImage(u), context, onError: (_, _) => _precached.remove(u));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = mediaRefId(widget.icon);
    if (id == null) return widget.fallback;
    final a = ref.watch(mediaAssetsByIdProvider).value?[id];
    if (a == null || a.kind != MediaKind.mapIcon && a.kind != MediaKind.icon) return widget.fallback;
    final side = widget.size;
    Widget picture(String path, {Key? key}) => Image(
      key: key,
      image: NetworkImage(mediaUrlOf(path)),
      width: side,
      height: side,
      fit: BoxFit.contain,
      // The last frame stays up while the next one loads: no flicker.
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => widget.fallback,
    );
    if (a.isMultiAngle) {
      _precache(a);
      final frame = a.frameFor(widget.heading ?? 0)!;
      return SizedBox.square(
        key: ValueKey('map-icon-frame-${frame.deg}'),
        dimension: side,
        child: picture(frame.path),
      );
    }
    final path = a.pathFor(dark: false);
    if (path == null || a.isSvg) return widget.fallback;
    final h = widget.heading;
    final single = SizedBox.square(key: const ValueKey('map-icon-single'), dimension: side, child: picture(path));
    return h == null ? single : Transform.rotate(angle: h * math.pi / 180, child: single);
  }
}
