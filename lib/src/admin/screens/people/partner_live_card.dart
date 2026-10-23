import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'partner_live.dart';
import 'partner_screens.dart' show partnerLiveProvider, partnerVehicleHoldersProvider;

/// The status's colour, light or dark.
Color partnerLiveColor(PartnerLive s, ThemeData t) {
  final dark = t.brightness == Brightness.dark;
  return switch (s) {
    PartnerLive.online => dark ? const Color(0xFF5FD38F) : const Color(0xFF1F8A4C),
    PartnerLive.offering || PartnerLive.unpaid || PartnerLive.noVehicle =>
      dark ? const Color(0xFFF2B25C) : const Color(0xFFA86400),
    PartnerLive.pickup || PartnerLive.waiting || PartnerLive.trip =>
      dark ? const Color(0xFFC3A5F5) : const Color(0xFF6A3FB5),
    PartnerLive.sos => t.colorScheme.error,
    PartnerLive.offline => t.colorScheme.onSurfaceVariant,
  };
}

/// A small coloured status label.
class PartnerLivePill extends StatelessWidget {
  const PartnerLivePill({super.key, required this.status, this.text, this.small = false});
  final PartnerLive status;
  final String? text;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = partnerLiveColor(status, t);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 8 : 10, vertical: small ? 2 : 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text ?? status.label,
              style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: small ? 11 : 13)),
        ),
      ]),
    );
  }
}

/// Edit Partner: the driver's real status, refreshed with ride changes and
/// every 20 s (an online phone goes quiet without a row changing).
class PartnerLiveCard extends ConsumerStatefulWidget {
  const PartnerLiveCard({super.key, required this.userId, required this.hasVehicle});
  final String userId;
  final bool hasVehicle;

  @override
  ConsumerState<PartnerLiveCard> createState() => _PartnerLiveCardState();
}

class _PartnerLiveCardState extends ConsumerState<PartnerLiveCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted) return;
      ref.invalidate(partnerLiveProvider((uid: widget.userId, hasVehicle: widget.hasVehicle)));
      ref.invalidate(partnerVehicleHoldersProvider(widget.userId));
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final live = ref.watch(partnerLiveProvider((uid: widget.userId, hasVehicle: widget.hasVehicle)));
    final v = live.value;
    return Card(
      key: const ValueKey('partner-live'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("Driver's real status", style: t.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (v == null)
            live.hasError
                ? Text('Status not available right now.', style: TextStyle(color: t.colorScheme.onSurfaceVariant))
                : const LinearProgressIndicator()
          else ...[
            Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              PartnerLivePill(key: ValueKey('partner-live-${v.status.name}'), status: v.status),
              Text(v.detail, style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
            ]),
            if (v.status.step case final at?) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 4, runSpacing: 4, children: [
                for (var i = 0; i < partnerLiveSteps.length; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: i == at ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      partnerLiveSteps[i],
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: i == at ? FontWeight.w600 : FontWeight.normal,
                        color: i == at
                            ? t.colorScheme.onPrimary
                            : i < at
                                ? t.colorScheme.onSurface
                                : t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ]),
            ],
          ],
        ]),
      ),
    );
  }
}
