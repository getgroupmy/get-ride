// A picture from the network, the way every page shows one: a shimmering
// skeleton in its place while it loads, the picture once it is painted, and
// the base icon only if it fails to load. A base icon shown while loading
// reads as the real thing and then jumps; the skeleton says "coming".
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../config.dart';
import '../core/backend_route.dart';
import '../core/storage_links.dart';
import 'storage_image.dart';

/// The skeleton in an image's place, in the app's light or dark theme.
class ImageBone extends StatelessWidget {
  const ImageBone({super.key, this.width, this.height, this.circle = false, this.radius = 8});

  final double? width, height;
  final bool circle;
  final double radius;

  Widget _bone(double w, double h) => Skeletonizer.zone(
    key: const ValueKey('image-bone'),
    child: circle ? Bone.circle(size: math.min(w, h)) : Bone(width: w, height: h, borderRadius: BorderRadius.circular(radius)),
  );

  @override
  Widget build(BuildContext context) => SkeletonizerConfig(
    data: SkeletonizerConfigData(brightness: Theme.of(context).brightness),
    // A size the caller gave needs no LayoutBuilder, which would break an
    // intrinsic layout around it (the vehicle bar's IntrinsicWidth).
    child: width != null && height != null
        ? _bone(width!, height!)
        : LayoutBuilder(
            builder: (context, c) {
              double side(double? want, double max) => want ?? (max.isFinite ? max : 24);
              return _bone(side(width, c.maxWidth), side(height, c.maxHeight));
            },
          ),
  );
}

/// An [Image] frame builder that shows [ImageBone] until the first frame is
/// painted. An image already in memory paints at once, with no skeleton.
ImageFrameBuilder boneUntilPainted({double? width, double? height, bool circle = false, double radius = 8}) =>
    (context, child, frame, synchronous) =>
        synchronous || frame != null ? child : ImageBone(width: width, height: height, circle: circle, radius: radius);

/// The size to decode a picture at for a [width] x [height] box drawn with
/// [fit] at [dpr] device pixels per point, so a large photo is not held in
/// memory at full size for a small box. One side only, so the picture keeps
/// its shape: the box's width for most fits (or its height when only that is
/// known); for [BoxFit.cover], whose picture's shape decides which side
/// fills the box, twice the longer side, enough for pictures up to 2:1
/// either way. Both for [BoxFit.fill], which stretches anyway. Null for a
/// side left alone. The picture is never decoded larger than it is. Pure.
({int? width, int? height}) imageDecodeSize({
  double? width,
  double? height,
  required BoxFit fit,
  required double dpr,
}) {
  int? px(double? v, [double times = 1]) => v == null || !v.isFinite || v <= 0 ? null : (v * dpr * times).round();
  switch (fit) {
    case BoxFit.fill:
      return (width: px(width), height: px(height));
    case BoxFit.cover:
      if (width == null || height == null) return (width: null, height: null);
      return (width: px(math.max(width, height), 2), height: null);
    default:
      if (px(width) != null) return (width: px(width), height: null);
      return (width: null, height: px(height));
  }
}

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
  Widget build(BuildContext context) {
    final frame = boneUntilPainted(width: width, height: height, circle: circle, radius: radius);
    Widget error(BuildContext _, Object _, StackTrace? _) => fallback ?? SizedBox(width: width, height: height);
    final decode = imageDecodeSize(
      width: width,
      height: height,
      fit: fit,
      dpr: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    // A file in a private document bucket (a permit portrait, a vehicle
    // photo) opens through a signed link; anything else as it is.
    if (privateStorageRef(url) != null) {
      return StorageImage(
        url,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        frameBuilder: frame,
        errorBuilder: error,
        cacheWidth: decode.width,
        cacheHeight: decode.height,
      );
    }
    // A stored file on the project's host loads through whichever address
    // the app is on (core/backend_route.dart).
    return Image.network(
      onActiveBackend(url, AppConfig.supabaseUrl, activeBackendUrl(AppConfig.supabaseUrl)),
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      frameBuilder: frame,
      errorBuilder: error,
      cacheWidth: decode.width,
      cacheHeight: decode.height,
    );
  }
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
