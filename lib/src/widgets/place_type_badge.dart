// A place's type (migration 0264) as riders and drivers see it: the white
// Material glyph on a rounded square of the type's colour (Google Maps'
// category colours; drawn here, never Google's marker images), a coloured
// label, or both in one line.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/place_types.dart';
import '../data/place_types_repository.dart';

/// The type's white icon on a rounded square of its colour ([background]
/// instead: the colour Google gave the place).
class PlaceTypeIcon extends StatelessWidget {
  const PlaceTypeIcon({super.key, required this.type, this.size = 40, this.background});
  final PlaceType type;
  final double size;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Semantics(
      label: type.name,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background ?? type.colorFor(b),
          borderRadius: BorderRadius.circular(size * 0.27),
        ),
        child: Icon(type.iconData, size: size * 0.58, color: Colors.white),
      ),
    );
  }
}

/// The type's name on a faint pill of its colour.
class PlaceTypePill extends StatelessWidget {
  const PlaceTypePill({super.key, required this.type, this.fontSize = 12});
  final PlaceType type;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: type.fillFor(b), borderRadius: BorderRadius.circular(6)),
      child: Text(
        type.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600, color: type.labelColorFor(b)),
      ),
    );
  }
}

/// The icon and the name in one line, in the type's colour (a driver's
/// pickup or drop-off at a place).
class PlaceTypeTag extends StatelessWidget {
  const PlaceTypeTag({super.key, required this.type});
  final PlaceType type;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final c = type.labelColorFor(b);
    return Container(
      padding: const EdgeInsets.fromLTRB(2, 2, 8, 2),
      decoration: BoxDecoration(color: type.fillFor(b), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        PlaceTypeIcon(type: type, size: 20),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            type.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: c, fontWeight: FontWeight.w600),
          ),
        ),
      ]),
    );
  }
}

/// [PlaceTypeTag] for a ride end's stamped type key (0264); nothing when
/// the end is at no place.
class RidePlaceTypeTag extends ConsumerWidget {
  const RidePlaceTypeTag({super.key, required this.typeKey, this.padding = EdgeInsets.zero});
  final String? typeKey;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = typeKey;
    if (k == null || k.trim().isEmpty) return const SizedBox.shrink();
    final type = placeTypeFor(k, placeTypesNow(ref));
    return Padding(
      padding: padding,
      child: Align(alignment: AlignmentDirectional.centerStart, child: PlaceTypeTag(type: type)),
    );
  }
}
