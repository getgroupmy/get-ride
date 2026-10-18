import 'package:flutter/material.dart';

/// A horizontal row that scrolls, its edges fading out where there is more
/// to see that way: a sign the row goes on (a last chip cut to "F…" with
/// nothing to say the row scrolls read as the whole row).
class HorizontalScrollFade extends StatefulWidget {
  const HorizontalScrollFade({super.key, required this.child, this.width = 32});

  /// The horizontal scrollable (a ListView or SingleChildScrollView).
  final Widget child;

  /// How far in from the edge the fade runs.
  final double width;

  @override
  State<HorizontalScrollFade> createState() => HorizontalScrollFadeState();
}

class HorizontalScrollFadeState extends State<HorizontalScrollFade> {
  bool _before = false, _after = false;

  /// Whether the start or the end edge is faded now (more to see that way).
  bool get fadesStart => _before;
  bool get fadesEnd => _after;

  bool _update(ScrollMetrics m) {
    if (m.axis != Axis.horizontal) return false;
    final before = m.extentBefore > 0.5, after = m.extentAfter > 0.5;
    if (before != _before || after != _after) {
      // Not in the middle of a layout: the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _before = before;
          _after = after;
        });
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final child = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _update(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _update(n.metrics),
        child: widget.child,
      ),
    );
    // Always the mask (opaque where nothing fades), so the row is never
    // rebuilt and keeps where it was scrolled to.
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final f = rect.width <= 0 ? 0.0 : (widget.width / rect.width).clamp(0.0, 0.5);
        return LinearGradient(
          colors: [
            _before ? Colors.transparent : Colors.black,
            Colors.black,
            Colors.black,
            _after ? Colors.transparent : Colors.black,
          ],
          stops: [0, f, 1 - f, 1],
        ).createShader(rect);
      },
      child: child,
    );
  }
}
