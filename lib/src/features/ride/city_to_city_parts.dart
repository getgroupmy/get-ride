// City to City, the rider's side (migration 0307): the colours and the
// small pieces the page, the trip steps and the trip screen share. Colours
// come from the theme, so the pages read in light and dark alike.
import 'package:flutter/material.dart';

import '../../widgets/common.dart' show inkOn, mutedTextColor;

/// The page's colours, from the theme.
class C2cLook {
  const C2cLook._(this.t);

  factory C2cLook.of(BuildContext context) => C2cLook._(Theme.of(context));

  final ThemeData t;

  bool get _dark => t.brightness == Brightness.dark;
  ColorScheme get cs => t.colorScheme;

  /// The accent: the pickup's dot, the step bars, the chosen card's edge.
  Color get accent => cs.primary;

  /// A chosen card's fill.
  Color get chosen => cs.primaryContainer;
  Color get onChosen => inkOn(chosen, preferred: cs.onPrimaryContainer);

  /// The grey boxes (summaries, tiles).
  Color get box => cs.surfaceContainerHighest;
  Color get onBox => inkOn(box, preferred: cs.onSurface);
  Color get mutedOnBox => mutedTextColor(t, background: box);
  Color get muted => mutedTextColor(t);

  /// The dark card (the page's hero, the leave time): dark by day, light by night.
  Color get hero => cs.inverseSurface;
  Color get onHero => inkOn(hero, preferred: cs.onInverseSurface);

  /// The drop-off's dot and anything that went wrong.
  Color get drop => cs.error;
  Color get bad => cs.errorContainer;
  Color get onBad => inkOn(bad, preferred: cs.onErrorContainer);

  /// Booked and done.
  Color get good => _dark ? const Color(0xFF1C3322) : const Color(0xFFF1F8F2);
  Color get onGood => inkOn(good, preferred: _dark ? const Color(0xFF9BD8A8) : const Color(0xFF1D5B2B));

  /// A gentle warning (a fare at the bottom of the range).
  Color get warn => _dark ? const Color(0xFF3A2A12) : const Color(0xFFFDF0E3);
  Color get onWarn => inkOn(warn, preferred: _dark ? const Color(0xFFF2C38B) : const Color(0xFF8A3B00));

  /// The stars.
  Color get star => _dark ? const Color(0xFFF2C14E) : const Color(0xFF8A5A00);

  /// The thin lines.
  Color get line => cs.outlineVariant;
}

/// A rounded box: grey by default.
class C2cBox extends StatelessWidget {
  const C2cBox({super.key, required this.child, this.color, this.border, this.padding = const EdgeInsets.all(14)});
  final Widget child;
  final Color? color;
  final Color? border;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final look = C2cLook.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? look.box,
        borderRadius: BorderRadius.circular(16),
        border: border == null ? null : Border.all(color: border!),
      ),
      child: child,
    );
  }
}

/// A line with an icon: the pickup (blue dot), the drop-off (red pin), the
/// car, the luggage.
class C2cIconLine extends StatelessWidget {
  const C2cIconLine({super.key, required this.icon, required this.text, this.color, this.sub, this.style});
  final IconData icon;
  final String text;
  final Color? color;
  final String? sub;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: color ?? look.muted),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: style ?? t.textTheme.bodyMedium),
            if (sub != null) Text(sub!, style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
          ]),
        ),
      ]),
    );
  }
}

/// A banner at the top of the trip: an icon, a title and a line.
class C2cBanner extends StatelessWidget {
  const C2cBanner({super.key, required this.icon, required this.title, this.line, required this.fill, required this.ink});
  final IconData icon;
  final String title;
  final String? line;
  final Color fill, ink;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return C2cBox(
      color: fill,
      child: Row(children: [
        Icon(icon, size: 28, color: ink),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.titleMedium?.copyWith(color: ink, fontWeight: FontWeight.w600)),
            if (line != null) Text(line!, style: t.textTheme.bodySmall?.copyWith(color: ink)),
          ]),
        ),
      ]),
    );
  }
}

/// A round minus or plus button (passengers, the fare).
class C2cRoundButton extends StatelessWidget {
  const C2cRoundButton({super.key, required this.icon, required this.tooltip, this.onPressed, this.filled = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) => filled
      ? IconButton.filled(tooltip: tooltip, onPressed: onPressed, icon: Icon(icon))
      : IconButton.outlined(tooltip: tooltip, onPressed: onPressed, icon: Icon(icon));
}

/// A driver's initials in a circle.
class C2cAvatar extends StatelessWidget {
  const C2cAvatar({super.key, required this.initials, this.size = 44});
  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    final look = C2cLook.of(context);
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: look.chosen,
      child: Text(initials, style: TextStyle(color: look.onChosen, fontWeight: FontWeight.w700)),
    );
  }
}
