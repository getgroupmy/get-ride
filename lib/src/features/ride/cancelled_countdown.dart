import 'package:flutter/material.dart';

import '../../core/ride_chat.dart' show rideCancelledClose;

/// The bar on a cancelled trip: it drains over [duration], says how long is
/// left, and calls [onDone] once when it runs out.
class CancelledCountdown extends StatefulWidget {
  const CancelledCountdown({super.key, required this.onDone, this.duration = rideCancelledClose, this.label});

  final VoidCallback onDone;
  final Duration duration;

  /// What happens at the end, e.g. "Back to requests"; "Closing" by default.
  final String? label;

  @override
  State<CancelledCountdown> createState() => _CancelledCountdownState();
}

class _CancelledCountdownState extends State<CancelledCountdown> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) widget.onDone();
    })
    ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final left = (widget.duration.inMilliseconds * (1 - _c.value) / 1000).ceil();
        return Column(key: const ValueKey('cancelled-countdown'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: 1 - _c.value,
              minHeight: 6,
              semanticsLabel: '${widget.label ?? 'Closing'} in ${left}s',
              color: t.colorScheme.error,
              backgroundColor: t.colorScheme.errorContainer,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.label ?? 'Closing'} in ${left}s',
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ]);
      },
    );
  }
}
