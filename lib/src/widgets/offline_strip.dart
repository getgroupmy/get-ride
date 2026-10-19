// "You're offline. Showing saved data.": a strip over a page that shows
// what was last read (Wallet, Trips, Notifications) while the app knows it
// can't reach GET.ride (appOfflineProvider).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_connection.dart';

const offlineStripText = "You're offline. Showing saved data.";

class OfflineStrip extends ConsumerWidget {
  const OfflineStrip({super.key});

  /// [child] with the strip above it while offline.
  static Widget over(Widget child) => Column(
    children: [
      const OfflineStrip(),
      Expanded(child: child),
    ],
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(appOfflineProvider)) return const SizedBox.shrink();
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        key: const ValueKey('offline-strip'),
        color: cs.tertiaryContainer,
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.cloud_off_outlined, size: 18, color: cs.onTertiaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    offlineStripText,
                    style: t.textTheme.bodySmall?.copyWith(color: cs.onTertiaryContainer, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
