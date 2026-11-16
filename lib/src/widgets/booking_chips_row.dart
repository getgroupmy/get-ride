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
    this.leading,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<ResolvedChip> chips;

  /// A widget drawn first in the row (e.g. the Now/Later segmented toggle that
  /// stands in for the Now and Later chips).
  final Widget? leading;

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
    if (chips.isEmpty && leading == null) return const SizedBox.shrink();
    final items = <Widget>[];
    if (leading != null) items.add(leading!);
    for (var i = 0; i < chips.length; i++) {
      final c = chips[i];
      if (items.isNotEmpty) items.add(const SizedBox(width: 8));
      items.add(BookingChip(
        chip: c,
        value: valueFor?.call(c),
        selected: c.id == selectedId,
        showNew: newIds.contains(c.id),
        showCaret: showCaret && c.id != bookingChipNowId,
        onTap: onTap == null ? null : () => onTap!(c),
      ));
    }
    // The whole row scales down to fit the sheet's width on one line rather
    // than scrolling — so the Luggage chip at the end is never clipped. When it
    // already fits, FittedBox leaves it at its natural size, centred.
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2) + padding,
      child: SizedBox(
        width: double.infinity,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          // The "NEW" badge perches above a chip's top-right corner, so it
          // overflows the pill; reserve 8px of headroom and 2px on the right
          // inside the measured box so FittedBox never shaves it.
          child: Padding(
            padding: const EdgeInsets.only(top: 8, right: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: items),
          ),
        ),
      ),
    );
  }
}

/// The animated **Now / Later** segmented toggle that stands in for the Now and
/// Later chips when the Later chip is on. A thumb slides to the selected side;
/// the Later side shows [laterLabel] (the booked time once one is set, else
/// "Later") with a chevron. Tapping either side calls its callback.
class NowLaterToggle extends StatelessWidget {
  const NowLaterToggle({
    super.key,
    required this.laterSelected,
    required this.laterLabel,
    required this.onNow,
    required this.onLater,
    this.nowLabel = 'Now',
  });

  /// True when a Later time is set (the thumb sits on the right).
  final bool laterSelected;

  /// The Now side's word (admin-renamable; defaults to "Now").
  final String nowLabel;

  /// The Later side's text: the booked time, or "Later" when none is set.
  final String laterLabel;
  final VoidCallback onNow;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // One connected toggle track holding the two flush segments (no gap), the
    // active one a filled stadium pill. The fill animates when the selection
    // flips, so Now ⇄ Later reads as a single segmented toggle (the mockup),
    // not two separate chips. Each segment sizes to its own content, so the
    // booked time is never clipped.
    Widget seg(Key key, bool selected, IconData icon, String text, VoidCallback onTap, {bool chevron = false}) {
      final fg = selected ? cs.onPrimaryContainer : cs.onSurfaceVariant;
      return GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: ShapeDecoration(
            color: selected ? cs.primaryContainer : Colors.transparent,
            shape: const StadiumBorder(),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: fg),
            if (text.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13.5)),
            ],
            if (chevron) ...[
              const SizedBox(width: 2),
              Icon(Icons.keyboard_arrow_down, size: 15, color: fg.withValues(alpha: .7)),
            ],
          ]),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(
        color: cs.surfaceContainerHighest,
        shape: StadiumBorder(side: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg(const ValueKey('nl-now'), !laterSelected, Icons.schedule, nowLabel, onNow),
        seg(const ValueKey('nl-later'), laterSelected, Icons.calendar_today_outlined, laterLabel, onLater, chevron: true),
      ]),
    );
  }
}
