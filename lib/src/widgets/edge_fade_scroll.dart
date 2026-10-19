// A row that scrolls sideways with a fade at the edge that has more: one
// line instead of a wrap that pushes the page down, and still a visible hint
// that the row goes on (the last chip half faded, not cut clean).
import 'package:flutter/material.dart';

/// [child] (a row) scrolled sideways, fading at the right edge while more
/// lies to the right and at the left once scrolled. [fade] is the fade's
/// width.
class EdgeFadeScroll extends StatefulWidget {
  const EdgeFadeScroll({super.key, required this.child, this.fade = 32, this.padding});

  final Widget child;
  final double fade;
  final EdgeInsetsGeometry? padding;

  @override
  State<EdgeFadeScroll> createState() => _EdgeFadeScrollState();
}

class _EdgeFadeScrollState extends State<EdgeFadeScroll> {
  bool _left = false, _right = false;

  bool _update(ScrollMetrics m) {
    final left = m.pixels > m.minScrollExtent + 0.5;
    final right = m.pixels < m.maxScrollExtent - 0.5;
    if (left != _left || right != _right) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _left = left;
            _right = right;
          });
        }
      });
    }
    return false;
  }

  /// Whether the right edge fades now (more to see), for tests.
  bool get fadesRight => _right;

  @override
  Widget build(BuildContext context) {
    final scroll = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _update(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _update(n.metrics),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: widget.padding,
          child: widget.child,
        ),
      ),
    );
    if (!_left && !_right) return scroll;
    return ShaderMask(
      key: const ValueKey('edge-fade'),
      blendMode: BlendMode.dstIn,
      shaderCallback: (r) {
        final f = r.width <= 0 ? 0.0 : (widget.fade / r.width).clamp(0.0, 0.5);
        return LinearGradient(
          colors: [
            _left ? Colors.transparent : Colors.black,
            Colors.black,
            Colors.black,
            _right ? Colors.transparent : Colors.black,
          ],
          stops: [0, f, 1 - f, 1],
        ).createShader(r);
      },
      child: scroll,
    );
  }
}
