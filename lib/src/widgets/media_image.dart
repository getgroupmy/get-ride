// How the app draws an icon or picture an admin set: a built-in icon name
// (`Truck`, as older apps store it too), an upload from the Media Gallery
// (`media:<id>`, looked up in `media_assets` and loaded from the public
// `media` bucket), or a picture's own address (http(s) or `data:`). A
// skeleton shows while an upload is looked up or loads; the fallback only
// if it can't be shown.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/backend_route.dart';
import '../core/icon_pack.dart';
import '../core/media_assets.dart';
import '../data/media_repository.dart';
import 'net_image.dart';

/// The built-in icons by the names settings store (the Expo app's lucide
/// names), as Material icons. Every icon picker offers these.
const builtInIconData = <String, IconData>{
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
  'BookOpen': Icons.menu_book_outlined,
  'FileText': Icons.description_outlined,
  'Gift': Icons.card_giftcard,
  'HelpCircle': Icons.help_outline,
  'Heart': Icons.favorite_border,
  'Mail': Icons.mail_outline,
  'MessageCircle': Icons.chat_bubble_outline,
  'Phone': Icons.phone_outlined,
  'Settings': Icons.settings_outlined,
  'Shield': Icons.shield_outlined,
  'Star': Icons.star_border,
  'Tag': Icons.sell_outlined,
  'User': Icons.person_outline,
  'Wallet': Icons.account_balance_wallet_outlined,
  'ShoppingCart': Icons.shopping_cart_outlined,
  'Utensils': Icons.restaurant_outlined,
  'Pill': Icons.medication_outlined,
  'Landmark': Icons.account_balance_outlined,
  'Receipt': Icons.receipt_long_outlined,
  'Coffee': Icons.local_cafe_outlined,
  'Store': Icons.storefront_outlined,
  'Zap': Icons.bolt_outlined,
  'Hotel': Icons.hotel_outlined,
  'Banknote': Icons.payments_outlined,
  'CreditCard': Icons.credit_card_outlined,
};

/// The Material icon of a built-in icon [name]; null for anything else.
IconData? builtInIcon(String? name) => name == null ? null : builtInIconData[name.trim()];

/// The uploads by id, live.
final mediaAssetsByIdProvider = Provider<AsyncValue<Map<String, MediaAsset>>>(
  (ref) => ref.watch(mediaAssetsProvider).whenData((list) => {for (final a in list) a.id: a}),
);

/// The public address of an upload's file on this app's project.
String mediaUrlOf(String path) => onActiveBackend(
  mediaPublicUrl(AppConfig.supabaseUrl, path),
  AppConfig.supabaseUrl,
  activeBackendUrl(AppConfig.supabaseUrl),
);

/// The client SVG files load through; tests give their own.
@visibleForTesting
http.Client? svgHttpClient;

/// An SVG upload at [url]: a skeleton while it loads, [fallback] if it
/// can't be drawn, in [tint] when given ("Follow the theme colour").
Widget svgNetwork(
  String url, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.contain,
  Alignment alignment = Alignment.center,
  Color? tint,
  required Widget fallback,
}) => SvgPicture.network(
  url,
  httpClient: svgHttpClient,
  width: width,
  height: height,
  fit: fit,
  alignment: alignment,
  colorFilter: tint == null ? null : ColorFilter.mode(tint, BlendMode.srcIn),
  placeholderBuilder: (_) => ImageBone(width: width, height: height),
  errorBuilder: (_, _, _) => fallback,
);

/// An icon slot: [value] is a built-in icon name, a `media:<id>` upload, or
/// empty for [fallback] (the slot's own icon in code). An upload marked
/// "Follow the theme colour" is drawn in [color] (else the icon theme's).
class MediaIcon extends ConsumerWidget {
  const MediaIcon(this.value, {super.key, required this.fallback, this.size, this.color, this.semanticLabel});

  final String? value;
  final IconData fallback;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pack = packRefName(value);
    if (pack != null) {
      final side = size ?? IconTheme.of(context).size ?? 24;
      return Image.asset(
        packAsset(pack),
        width: side,
        height: side,
        fit: BoxFit.contain,
        semanticLabel: semanticLabel,
        errorBuilder: (_, _, _) => Icon(fallback, size: side, color: color),
      );
    }
    final id = mediaRefId(value);
    if (id == null) {
      return Icon(builtInIcon(value) ?? fallback, size: size, color: color, semanticLabel: semanticLabel);
    }
    final side = size ?? IconTheme.of(context).size ?? 24;
    Widget plain() => Icon(fallback, size: side, color: color, semanticLabel: semanticLabel);
    final assets = ref.watch(mediaAssetsByIdProvider);
    if (assets.isLoading && !assets.hasValue) return ImageBone(width: side, height: side, radius: 4);
    final a = assets.value?[id];
    final path = a?.pathFor(dark: Theme.of(context).brightness == Brightness.dark);
    if (a == null || path == null) return plain();
    final ink = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    if (a.isSvg) {
      final svg = svgNetwork(mediaUrlOf(path), width: side, height: side, tint: a.tint ? ink : null, fallback: plain());
      return Semantics(label: semanticLabel, image: true, child: SizedBox.square(dimension: side, child: svg));
    }
    Widget image = NetImage(mediaUrlOf(path), width: side, height: side, fit: BoxFit.contain, radius: 4, fallback: plain());
    if (a.tint) {
      image = ColorFiltered(colorFilter: ColorFilter.mode(ink, BlendMode.srcIn), child: image);
    }
    return Semantics(label: semanticLabel, image: true, child: SizedBox.square(dimension: side, child: image));
  }
}

/// A picture slot: [value] is a `media:<id>` upload, an http(s) address or
/// a `data:` address; [fallback] when there is none or it fails. [onSettled]
/// runs once it has painted or fallen back.
class MediaImage extends ConsumerWidget {
  const MediaImage(
    this.value, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.fallback,
    this.onSettled,
  });

  final String? value;
  final double? width, height;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? fallback;
  final VoidCallback? onSettled;

  void _settled() {
    final s = onSettled;
    if (s != null) WidgetsBinding.instance.addPostFrameCallback((_) => s());
  }

  Widget _network(String url, Widget none) => Image.network(
    url,
    width: width,
    height: height,
    fit: fit,
    alignment: alignment,
    frameBuilder: (context, child, frame, sync) {
      if (sync || frame != null) _settled();
      return boneUntilPainted(width: width, height: height)(context, child, frame, sync);
    },
    errorBuilder: (_, _, _) {
      _settled();
      return none;
    },
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final none = fallback ?? SizedBox(width: width, height: height);
    final v = value?.trim() ?? '';
    final pack = packRefName(v);
    if (pack != null) {
      _settled();
      return Image.asset(
        packAsset(pack),
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        errorBuilder: (_, _, _) => none,
      );
    }
    final id = mediaRefId(v);
    if (id != null) {
      final assets = ref.watch(mediaAssetsByIdProvider);
      if (assets.isLoading && !assets.hasValue) return ImageBone(width: width, height: height);
      final a = assets.value?[id];
      final path = a?.pathFor(dark: Theme.of(context).brightness == Brightness.dark);
      if (a == null || path == null) {
        _settled();
        return none;
      }
      if (a.isSvg) {
        _settled();
        return svgNetwork(mediaUrlOf(path), width: width, height: height, fit: fit, alignment: alignment, fallback: none);
      }
      return _network(mediaUrlOf(path), none);
    }
    if (v.startsWith('data:')) {
      _settled();
      try {
        return Image.memory(
          base64Decode(v.split(',').last),
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
    if (v.startsWith('http')) {
      if (v.toLowerCase().split('?').first.endsWith('.svg')) {
        _settled();
        return svgNetwork(v, width: width, height: height, fit: fit, alignment: alignment, fallback: none);
      }
      return _network(v, none);
    }
    _settled();
    return none;
  }
}
