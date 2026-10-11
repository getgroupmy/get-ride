// Shown over a trip while it is the copy kept on the phone (no connection).
import 'package:flutter/material.dart';

import '../core/format.dart' show formatTime;

class OfflineRideBanner extends StatelessWidget {
  const OfflineRideBanner({super.key, required this.cachedAt});
  final DateTime cachedAt;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('offline-ride-banner'),
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 18, color: cs.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'No connection. Showing the ride as of ${formatTime(cachedAt)}; it updates when you are back online.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
