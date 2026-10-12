// The driver's My Ride marks on a request (migration 0160): the gold star on
// a request from a rider who has them as a favourite (or offered to them as
// one), and, while the rider's favourites window runs, "Your regular rider ·
// for you first" with the seconds left.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/driver_request_radius.dart';
import '../../data/models.dart';

/// The star's gold: a deep amber on light surfaces (≥ 3:1 on white and on
/// the alert card's tint) and a bright one on dark (≥ 3:1 on near-black).
Color myRideStarColor(Brightness b) => b == Brightness.dark ? const Color(0xFFFFC107) : const Color(0xFFB06A00);

/// The label's text gold, readable as text (≥ 4.5:1) in either theme.
Color myRideTextColor(Brightness b) => b == Brightness.dark ? const Color(0xFFFFD54F) : const Color(0xFF8A5300);

/// The gold star on a starred request.
class MyRideStar extends StatelessWidget {
  const MyRideStar({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Your regular rider',
    child: Icon(Icons.star, size: size, color: myRideStarColor(Theme.of(context).brightness)),
  );
}

/// "Your regular rider · for you first · 42 s" while [request] is still
/// offered to [me] first; nothing otherwise. Ticks itself once a second off
/// [clock] and disappears when the window ends.
class MyRideForYouLabel extends StatefulWidget {
  const MyRideForYouLabel({super.key, required this.request, required this.me, required this.clock});

  final RideRequest request;
  final String? me;
  final DateTime Function() clock;

  @override
  State<MyRideForYouLabel> createState() => _MyRideForYouLabelState();
}

class _MyRideForYouLabelState extends State<MyRideForYouLabel> {
  Timer? _tick;

  bool _running(DateTime now) => myRideForMeFirst(
    me: widget.me,
    targetDriverIds: widget.request.targetDriverIds,
    targetedUntil: widget.request.targetedUntil,
    now: now,
  );

  void _schedule() {
    _tick?.cancel();
    _tick = null;
    if (!_running(widget.clock())) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (!_running(widget.clock())) {
        _tick?.cancel();
        _tick = null;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(MyRideForYouLabel old) {
    super.didUpdateWidget(old);
    if (_tick == null) _schedule();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.clock();
    if (!_running(now)) return const SizedBox.shrink();
    final t = Theme.of(context);
    final gold = myRideTextColor(t.brightness);
    final left = myRideWindowCountdown(widget.request.myRideWindowRemainingAt(now));
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        key: ValueKey('my-ride-for-you-${widget.request.id}'),
        children: [
          Icon(Icons.star, size: 16, color: myRideStarColor(t.brightness)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Your regular rider · for you first',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.labelMedium?.copyWith(color: gold, fontWeight: FontWeight.w700),
            ),
          ),
          if (left != null)
            Text(
              left,
              key: ValueKey('my-ride-window-${widget.request.id}'),
              style: t.textTheme.labelMedium?.copyWith(
                color: gold,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}
