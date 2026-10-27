// Shared pieces of the City to City admin pages (migration 0306): a stepper
// row, place chips and the place picker.
import 'package:flutter/material.dart';

import '../../../core/city_to_city.dart';
import '../../../widgets/search_select.dart';
import '../geo/geo_logic.dart' show RegionEntry;

/// A labelled value with − and + buttons.
class C2cStepper extends StatelessWidget {
  const C2cStepper({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.onDown,
    this.onUp,
    this.valueKey,
  });

  final String label;
  final String? hint;
  final String value;

  /// Null: that way is at its limit, or the page is read-only.
  final VoidCallback? onDown, onUp;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
            if (hint != null)
              Text(hint!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
        IconButton.outlined(tooltip: 'Lower $label', icon: const Icon(Icons.remove), onPressed: onDown),
        SizedBox(
          width: 84,
          child: Text(value, key: valueKey, textAlign: TextAlign.center, style: t.textTheme.titleMedium),
        ),
        IconButton.outlined(tooltip: 'Raise $label', icon: const Icon(Icons.add), onPressed: onUp),
      ]),
    );
  }
}

/// A card's heading: an icon and a title.
class C2cCardTitle extends StatelessWidget {
  const C2cCardTitle(this.icon, this.title, {super.key});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, color: t.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

/// Every region as a place a rule can name, broadest level first.
List<C2cPlace> c2cPlaceChoices(List<RegionEntry> regions) {
  final out = <C2cPlace>[];
  final seen = <String>{};
  for (final e in regions) {
    final p = C2cPlace(
      level: e.level.name,
      country: e.country,
      state: e.state.isEmpty ? null : e.state,
      city: e.city.isEmpty ? null : e.city,
      suburb: e.suburb.isEmpty ? null : e.suburb,
    );
    if (p.problem == null && seen.add(p.key)) out.add(p);
  }
  out.sort((a, b) {
    final c = a.rank.compareTo(b.rank);
    return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

/// Asks for a place not already in [taken], searchable by name, level and
/// the places around it ("city", "Perak").
Future<C2cPlace?> pickC2cPlace(
  BuildContext context, {
  required String title,
  required List<C2cPlace> choices,
  Iterable<C2cPlace> taken = const [],
}) {
  final skip = {for (final p in taken) p.key};
  return showSearchPicker<C2cPlace>(
    context,
    title: title,
    choices: [
      for (final p in choices)
        if (!skip.contains(p.key))
          (
            value: p,
            label: p.label,
            subtitle: p.within.isEmpty ? null : p.within,
            leading: Icon(switch (p.level) {
              'country' => Icons.public,
              'state' => Icons.map_outlined,
              'city' => Icons.location_city_outlined,
              _ => Icons.holiday_village_outlined,
            }),
          ),
    ],
  );
}

/// A rule end's places as chips, each removable while [onRemove] is set.
class C2cPlaceChips extends StatelessWidget {
  const C2cPlaceChips({super.key, required this.places, this.onRemove, this.onAdd, this.from = true, this.keyPrefix = ''});

  final List<C2cPlace> places;
  final ValueChanged<C2cPlace>? onRemove;
  final VoidCallback? onAdd;

  /// From (pickup) or To (drop-off) colours.
  final bool from;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final bg = from ? s.secondaryContainer : s.tertiaryContainer;
    final fg = from ? s.onSecondaryContainer : s.onTertiaryContainer;
    return Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final p in places)
        onRemove == null
            ? Chip(
                key: ValueKey('$keyPrefix${p.key}'),
                label: Text(p.label, style: TextStyle(color: fg)),
                backgroundColor: bg,
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              )
            : InputChip(
                key: ValueKey('$keyPrefix${p.key}'),
                label: Text(p.label, style: TextStyle(color: fg)),
                backgroundColor: bg,
                side: BorderSide.none,
                deleteIcon: Icon(Icons.close, size: 18, color: fg),
                deleteButtonTooltipMessage: 'Remove ${p.name}',
                onDeleted: () => onRemove!(p),
              ),
      if (onAdd != null)
        ActionChip(
          key: ValueKey('${keyPrefix}add'),
          avatar: const Icon(Icons.search, size: 18),
          label: const Text('Add place'),
          onPressed: onAdd,
        ),
    ]);
  }
}
