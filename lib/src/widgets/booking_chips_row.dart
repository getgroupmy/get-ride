import 'package:flutter/material.dart';

import '../core/app_branding.dart' show brandHexColor;
import '../core/booking_chips.dart';
import 'media_image.dart' show MediaIcon;

/// The default icon each built-in chip falls back to when its stored icon name
/// resolves to nothing (so the row always draws a sensible glyph).
const _builtInChipIcons = <String, IconData>{
  bookingChipNowId: Icons.schedule,
  bookingChipLaterId: Icons.calendar_today_outlined,
  bookingChipPassengersId: Icons.person_outline,
  bookingChipLuggageId: Icons.luggage_outlined,
};

/// The chips the ride sheet marks "NEW".
const defaultNewBookingChips = {bookingChipPassengersId, bookingChipLuggageId};

/// One booking-row chip, drawn as the ride sheet's pill. [value] is the trailing
/// count a Passengers/Luggage chip shows; [selected] gives the accent-filled
/// "on" look (the Now/Later pair); [showNew] draws the small NEW badge. A chip
/// the admin recoloured uses its own text/fill ([ResolvedChip.fg] / [bg]);
/// otherwise it follows the theme.
class BookingChip extends StatelessWidget {
  const BookingChip({
    super.key,
    required this.chip,
    this.value,
    this.selected = false,
    this.showNew = false,
    this.showCaret = true,
    this.onTap,
  });

  final ResolvedChip chip;
  final String? value;
  final bool selected;
  final bool showNew;
  final bool showCaret;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = brandHexColor(chip.bg) ?? (selected ? cs.primaryContainer : cs.surfaceContainerHighest);
    final fg = brandHexColor(chip.fg) ?? (selected ? cs.onPrimaryContainer : cs.onSurface);
    final icon = brandHexColor(chip.fg) ?? cs.primary;
    final fallback = _builtInChipIcons[chip.id] ?? Icons.star_border;

    final pill = Material(
      color: bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            MediaIcon(chip.iconName, fallback: fallback, color: icon, size: 16),
            if (chip.label.trim().isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(chip.label, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13.5)),
            ],
            if (value != null && value!.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(value!, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13.5)),
            ],
            if (showCaret) ...[
              const SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_down, size: 15, color: fg.withValues(alpha: .55)),
            ],
          ]),
        ),
      ),
    );
    if (!showNew) return pill;
    return Stack(clipBehavior: Clip.none, children: [
      pill,
      Positioned(
        top: -7,
        right: -2,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(color: cs.error, borderRadius: BorderRadius.circular(999)),
          child: Text('NEW',
              style: TextStyle(color: cs.onError, fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: .4)),
        ),
      ),
    ]);
  }
}

/// The ride sheet's booking row: the visible [chips], centered, and collapsed
/// to nothing when empty (every chip hidden). Falls back to a left-aligned
/// scroll when the chips are too wide to fit, so the first is never clipped.
class BookingChipsRow extends StatelessWidget {
  const BookingChipsRow({
    super.key,
    required this.chips,
    this.valueFor,
    this.selectedId,
    this.newIds = defaultNewBookingChips,
    this.onTap,
    this.showCaret = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<ResolvedChip> chips;

  /// The gutter either side of the row (so it can sit inside an already-padded
  /// column with [EdgeInsets.zero]).
  final EdgeInsets padding;

  /// The trailing count for a chip (a Passengers/Luggage chip), or null/empty
  /// for none.
  final String? Function(ResolvedChip chip)? valueFor;

  /// The chip drawn with the accent-filled "on" look (e.g. the active Now/Later).
  final String? selectedId;
  final Set<String> newIds;
  final void Function(ResolvedChip chip)? onTap;
  final bool showCaret;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    final items = <Widget>[];
    for (var i = 0; i < chips.length; i++) {
      final c = chips[i];
      if (i > 0) items.add(const SizedBox(width: 8));
      items.add(BookingChip(
        chip: c,
        value: valueFor?.call(c),
        selected: c.id == selectedId,
        showNew: newIds.contains(c.id),
        showCaret: showCaret && c.id != bookingChipNowId,
        onTap: onTap == null ? null : () => onTap!(c),
      ));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: (c.maxWidth - padding.horizontal).clamp(0.0, double.infinity)),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: items),
          ),
        ),
      ),
    );
  }
}
