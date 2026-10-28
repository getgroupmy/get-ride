// GET.Plus on the booking card (migration 0316): the member banner over the
// vehicles. The member's prices, with the full one struck through, are on
// each card (ConfirmServiceCard.was).
import 'package:flutter/material.dart';

import '../../core/premium_plus.dart';

/// The banner's colours: warm, readable in light and dark.
({Color background, Color icon, Color text}) plusBannerColors(ThemeData t) => t.brightness == Brightness.dark
    ? (background: const Color(0xFF3A2B14), icon: const Color(0xFFFFB960), text: const Color(0xFFF6E7D2))
    : (background: const Color(0xFFFDF2E3), icon: const Color(0xFF8A4B00), text: const Color(0xFF3B2A12));

/// "GET.Plus member: 10% off, priority matching, 2 free cancels left this month".
class PlusMemberBanner extends StatelessWidget {
  const PlusMemberBanner({super.key, required this.benefits});
  final PlusBenefits benefits;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = plusBannerColors(t);
    return Container(
      key: const ValueKey('plus-member-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.workspace_premium, color: c.icon),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            plusBannerLine(benefits),
            style: t.textTheme.bodyMedium?.copyWith(color: c.text, height: 1.4),
          ),
        ),
      ]),
    );
  }
}
