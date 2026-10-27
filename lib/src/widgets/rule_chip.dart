import 'package:flutter/material.dart';

/// How a partner registration rule stands (0305), as a chip's colours.
enum RuleTone { ok, bad, wait, none }

/// The chip's background and text colour for [tone], light or dark.
(Color, Color) ruleToneColors(RuleTone tone, Brightness b) {
  final dark = b == Brightness.dark;
  return switch (tone) {
    RuleTone.ok => dark ? (const Color(0xFF1F3A26), const Color(0xFF9FD9AB)) : (const Color(0xFFE3F1E6), const Color(0xFF1D5B2B)),
    RuleTone.bad => dark ? (const Color(0xFF4A1C18), const Color(0xFFFFB4AB)) : (const Color(0xFFFCE8E6), const Color(0xFFA3261C)),
    RuleTone.wait => dark ? (const Color(0xFF43300F), const Color(0xFFFFCF8A)) : (const Color(0xFFFDF2E3), const Color(0xFF8A4B00)),
    RuleTone.none => dark ? (const Color(0xFF2C3138), const Color(0xFFC4CAD3)) : (const Color(0xFFECEFF3), const Color(0xFF3C4654)),
  };
}

/// The icon a rule row shows for [tone].
IconData ruleToneIcon(RuleTone tone) => switch (tone) {
      RuleTone.ok => Icons.check_circle,
      RuleTone.bad => Icons.cancel,
      RuleTone.wait => Icons.hourglass_top,
      RuleTone.none => Icons.remove_circle_outline,
    };

/// "Done", "Needed", "Failed" … in its tone's colours.
class RuleChip extends StatelessWidget {
  const RuleChip({super.key, required this.label, required this.tone, this.icon});
  final String label;
  final RuleTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = ruleToneColors(tone, Theme.of(context).brightness);
    return Container(
      constraints: const BoxConstraints(minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 6)],
        Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// A rule row: its icon, name and detail, and the chip.
class RuleRow extends StatelessWidget {
  const RuleRow({super.key, required this.name, required this.detail, required this.chip, required this.tone});
  final String name;
  final String detail;
  final String chip;
  final RuleTone tone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (_, fg) = ruleToneColors(tone, t.brightness);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(ruleToneIcon(tone), size: 22, color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: t.textTheme.titleSmall),
            if (detail.isNotEmpty)
              Text(detail, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 8),
        RuleChip(label: chip, tone: tone),
      ]),
    );
  }
}
