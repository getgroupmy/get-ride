// A picture from the network, the way every page shows one: a shimmering
// skeleton in its place while it loads, the picture once it is painted, and
// the base icon only if it fails to load. A base icon shown while loading
// reads as the real thing and then jumps; the skeleton says "coming".
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

/// The skeleton in an image's place, in the app's light or dark theme.
class ImageBone extends StatelessWidget {
  const ImageBone({super.key, this.width, this.height, this.circle = false, this.radius = 8});

  final double? width, height;
  final bool circle;
  final double radius;

  @override
  Widget build(BuildContext context) => SkeletonizerConfig(
    data: SkeletonizerConfigData(brightness: Theme.of(context).brightness),
    child: LayoutBuilder(
      builder: (context, c) {
        double side(double? want, double max) => want ?? (max.isFinite ? max : 24);
        final w = side(width, c.maxWidth), h = side(height, c.maxHeight);
        return Skeletonizer.zone(
          key: const ValueKey('image-bone'),
          child: circle
              ? Bone.circle(size: math.min(w, h))
              : Bone(width: w, height: h, borderRadius: BorderRadius.circular(radius)),
        );
      },
    ),
  );
}

/// An [Image] frame builder that shows [ImageBone] until the first frame is
/// painted. An image already in memory paints at once, with no skeleton.
ImageFrameBuilder boneUntilPainted({double? width, double? height, bool circle = false, double radius = 8}) =>
    (context, child, frame, synchronous) =>
        synchronous || frame != null ? child : ImageBone(width: width, height: height, circle: circle, radius: radius);

/// A network picture: the skeleton while it loads, [fallback] (the base
/// icon) only if it fails.
class NetImage extends StatelessWidget {
  const NetImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.fallback,
    this.circle = false,
    this.radius = 8,
  });

  final String url;
  final double? width, height;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? fallback;
  final bool circle;
  final double radius;

  @override
  Widget build(BuildContext context) => Image.network(
    url,
    width: width,
    height: height,
    fit: fit,
    alignment: alignment,
    frameBuilder: boneUntilPainted(width: width, height: height, circle: circle, radius: radius),
    errorBuilder: (_, _, _) => fallback ?? SizedBox(width: width, height: height),
  );
}

/// A round picture (a person, a driver): the skeleton while it loads, the
/// [fallback] icon when there is no picture or it fails.
class NetAvatar extends StatelessWidget {
  const NetAvatar({super.key, required this.url, this.radius = 20, this.fallback, this.backgroundColor});

  final String? url;
  final double radius;
  final Widget? fallback;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final icon = fallback ?? Icon(Icons.person, size: radius);
    final u = url?.trim() ?? '';
    if (!u.startsWith('http')) {
      return CircleAvatar(radius: radius, backgroundColor: backgroundColor, child: icon);
    }
    return SizedBox.square(
      dimension: radius * 2,
      child: ClipOval(
        child: NetImage(
          u,
          width: radius * 2,
          height: radius * 2,
          circle: true,
          fallback: CircleAvatar(radius: radius, backgroundColor: backgroundColor, child: icon),
        ),
      ),
    );
  }
}
