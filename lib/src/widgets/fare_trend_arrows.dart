import 'package:flutter/material.dart';

import '../core/route_estimate.dart';

/// Three stacked chevrons before the recommended fare: red pointing up when
/// traffic makes the trip slower than usual, green pointing down when it is
/// quicker (Admin → Fare AI → Fare trend arrows). They light one after
/// another in the direction they point; still where the device asks for
/// reduced motion. The meaning is in the tooltip and for screen readers,
/// not in the colour alone.
class FareTrendArrows extends StatefulWidget {
  const FareTrendArrows({super.key, required this.trend, this.size = 18, this.color, this.animate = true});

  /// Overrides the colour (the admin page's preview).
  final Color? color;

  /// Off: drawn still (a preview).
  final bool animate;

  final FareTrend trend;

  /// The height of the stack.
  final double size;

  static const upLight = Color(0xFFE02424);
  static const upDark = Color(0xFFFF4D4D);
  static const downLight = Color(0xFF16A34A);
  static const downDark = Color(0xFF22C55E);

  @override
  State<FareTrendArrows> createState() => _FareTrendArrowsState();
}

class _FareTrendArrowsState extends State<FareTrendArrows> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = !widget.animate || (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (still) {
      _c.stop();
      _c.value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final up = widget.trend.direction == FareTrendDirection.up;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final admin = dark ? widget.trend.colorDark : widget.trend.colorLight;
    final color = widget.color ??
        (admin != null
            ? Color(admin)
            : up
                ? (dark ? FareTrendArrows.upDark : FareTrendArrows.upLight)
                : (dark ? FareTrendArrows.downDark : FareTrendArrows.downLight));
    return Tooltip(
      message: widget.trend.explanation,
      child: Semantics(
        key: ValueKey('fare-trend-${up ? 'up' : 'down'}'),
        label: widget.trend.explanation,
        child: ExcludeSemantics(
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                painter: _ChevronsPainter(
                  up: up,
                  color: color,
                  // The lit chevron travels the way the arrows point: up from
                  // the bottom one, down from the top one.
                  lit: _lit == null ? null : (up ? 2 - _lit! : _lit!),
                  glow: _glow,
                  // Dark on a light card; on a dark one, a glow of its own colour.
                  halo: dark ? color : Colors.black,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The chevron lit now (0 first, 2 last), or null between sweeps and
  /// when still.
  int? get _lit {
    if (!_c.isAnimating) return null;
    final v = _c.value;
    return v < 0.75 ? (v / 0.25).floor() : null;
  }

  /// How strongly it glows: in and out within its turn.
  double get _glow {
    final v = _c.value;
    if (v >= 0.75) return 0;
    final t = (v % 0.25) / 0.25;
    return t < 0.5 ? t * 2 : (1 - t) * 2;
  }
}

/// Three thick, flat-ended chevrons, top to bottom; the [lit] one glows.
class _ChevronsPainter extends CustomPainter {
  _ChevronsPainter({
    required this.up,
    required this.color,
    required this.lit,
    required this.glow,
    required this.halo,
  });

  final bool up;
  final Color color;
  final Color halo;
  final int? lit;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = h * 0.15;
    final rise = h * 0.2; // each chevron's height, centre line
    final pitch = h * 0.3; // from one chevron to the next
    final top0 = (h - rise - pitch * 2) / 2;
    Path chevron(int i) {
      final top = top0 + pitch * i;
      final tip = up ? top : top + rise, foot = up ? top + rise : top;
      return Path()
        ..moveTo(w * 0.1, foot)
        ..lineTo(w * 0.5, tip)
        ..lineTo(w * 0.9, foot);
    }

    Paint pen(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter;
    for (var i = 0; i < 3; i++) {
      final path = chevron(i);
      if (i == lit && glow > 0) {
        // A tight dark halo round it, as a lit sign's edge.
        canvas.drawPath(
          path,
          pen(halo.withValues(alpha: 0.75 * glow))
            ..strokeWidth = stroke * 1.45
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.3),
        );
        canvas.drawPath(path, pen(color));
      } else {
        canvas.drawPath(path, pen(color));
      }
    }
  }

  @override
  bool shouldRepaint(_ChevronsPainter old) =>
      old.up != up || old.color != color || old.lit != lit || old.glow != glow || old.halo != halo;
}
