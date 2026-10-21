// The Command Centre's look (Admin > Dashboard): its colours, from the app
// theme's accent where it has one, the glass panels on a faint grid, the
// KPI tile with its sparkline, the trend chart, the funnel, the mixes, the
// demand grid, the live dot and the small tables. Light and dark.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/admin_dashboard.dart';

// ---- Colours ---------------------------------------------------------------------------------------
/// The app's own accent when the theme carries none of its own (as in app.dart).
const _fallbackAccent = Color(0xFF2DABE2);

class CcColors {
  const CcColors._({
    required this.dark,
    required this.bg,
    required this.grid,
    required this.panel,
    required this.panelSolid,
    required this.line,
    required this.fg,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accent2,
    required this.series,
    required this.good,
    required this.goodBg,
    required this.warn,
    required this.warnBg,
    required this.bad,
    required this.badBg,
  });

  final bool dark;
  final Color bg, grid, panel, panelSolid, line, fg, muted, faint, accent, accent2;

  /// Five series colours: accent, violet, amber, green, pink.
  final List<Color> series;
  final Color good, goodBg, warn, warnBg, bad, badBg;

  Color get glow => accent.withValues(alpha: dark ? 0.20 : 0.18);

  Color tone(DeltaTone t) => switch (t) {
    DeltaTone.good => good,
    DeltaTone.bad => bad,
    DeltaTone.flat => muted,
  };

  /// The theme's accent hue: cyan in the dark, a deeper blue in the light.
  static Color _accent(ColorScheme s, bool dark) {
    Color? vivid(Color c) => HSLColor.fromColor(c).saturation > 0.35 && HSLColor.fromColor(c).lightness > 0.2 ? c : null;
    final seed = vivid(s.primary) ?? vivid(s.inversePrimary) ?? vivid(s.secondary) ?? _fallbackAccent;
    final hue = HSLColor.fromColor(seed).hue;
    return dark ? HSLColor.fromAHSL(1, hue, 1, 0.62).toColor() : HSLColor.fromAHSL(1, hue, 0.89, 0.38).toColor();
  }

  static CcColors of(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final accent = _accent(t.colorScheme, dark);
    return dark
        ? CcColors._(
            dark: true,
            bg: const Color(0xFF070B12),
            grid: const Color(0x0D5AAAFF),
            panel: const Color(0xC7101826),
            panelSolid: const Color(0xFF101826),
            line: const Color(0xFF1D2A3D),
            fg: const Color(0xFFE6EEF9),
            muted: const Color(0xFF8FA1BA),
            faint: const Color(0xFF5F7088),
            accent: accent,
            accent2: const Color(0xFF9B86FF),
            series: [accent, const Color(0xFF9B86FF), const Color(0xFFFFB057), const Color(0xFF3FD6A0), const Color(0xFFFF7EB0)],
            good: const Color(0xFF45D69A),
            goodBg: const Color(0xFF0F2A20),
            warn: const Color(0xFFFFBF5C),
            warnBg: const Color(0xFF2E2210),
            bad: const Color(0xFFFF7676),
            badBg: const Color(0xFF331617),
          )
        : CcColors._(
            dark: false,
            bg: const Color(0xFFEEF2F7),
            grid: const Color(0x0D143C78),
            panel: const Color(0xDBFFFFFF),
            panelSolid: Colors.white,
            line: const Color(0xFFD7DEE8),
            fg: const Color(0xFF0D1726),
            muted: const Color(0xFF5B6A80),
            faint: const Color(0xFF8A97AA),
            accent: accent,
            accent2: const Color(0xFF6A4FD8),
            series: [accent, const Color(0xFF6A4FD8), const Color(0xFFD9822B), const Color(0xFF1F9D74), const Color(0xFFC94F7C)],
            good: const Color(0xFF16865C),
            goodBg: const Color(0xFFE3F5EC),
            warn: const Color(0xFFA25D00),
            warnBg: const Color(0xFFFFF1DC),
            bad: const Color(0xFFC23B3B),
            badBg: const Color(0xFFFDE7E7),
          );
  }
}

/// Monospace, tabular figures.
TextStyle ccMono(double size, Color color, {FontWeight weight = FontWeight.w500}) => TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: const ['Menlo', 'Consolas', 'Roboto Mono', 'Courier New'],
  fontFeatures: const [ui.FontFeature.tabularFigures()],
  fontSize: size,
  fontWeight: weight,
  color: color,
  letterSpacing: -0.2,
);

// ---- Background and panels -----------------------------------------------------------------------------
/// The page's faint 32 px grid.
class CcGridBackground extends StatelessWidget {
  const CcGridBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    return ColoredBox(
      color: c.bg,
      child: CustomPaint(painter: _GridPainter(c.grid), child: child),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (var y = 0.0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

/// A glass panel with an uppercase title, a note beside it, and [trailing]
/// (tabs, a clock) at the end.
class CcPanel extends StatelessWidget {
  const CcPanel({super.key, this.title, this.note, this.trailing, required this.child, this.alert = false});

  final String? title;
  final String? note;
  final Widget? trailing;
  final Widget child;

  /// Edged red (an SOS waiting).
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.panel,
        border: Border.all(color: alert ? c.bad : c.line),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: title!.toUpperCase()),
                      if (note != null)
                        TextSpan(
                          text: '  $note',
                          style: ccMono(12, c.faint, weight: FontWeight.w400).copyWith(letterSpacing: 0),
                        ),
                    ],
                  ),
                  style: TextStyle(fontSize: 13, letterSpacing: 1.5, fontWeight: FontWeight.w600, color: c.muted),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

// ---- The live dot ------------------------------------------------------------------------------------
/// "● LIVE", the dot pulsing unless the reader asked for less motion.
class CcLiveDot extends StatefulWidget {
  const CcLiveDot({super.key});

  @override
  State<CcLiveDot> createState() => _CcLiveDotState();
}

class _CcLiveDotState extends State<CcLiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 2));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    return Semantics(
      label: 'Live',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              // Grows a fading ring over the first 70% of each beat.
              final t = (_pulse.value / 0.7).clamp(0.0, 1.0);
              return Container(
                key: const ValueKey('dashboard-live-dot'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: c.good,
                  shape: BoxShape.circle,
                  boxShadow: [
                    if (_pulse.isAnimating)
                      BoxShadow(color: c.good.withValues(alpha: 0.6 * (1 - t)), spreadRadius: 8 * t),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          Text('LIVE', style: ccMono(11, c.good, weight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ---- KPI tiles -------------------------------------------------------------------------------------
class CcKpiTile extends StatefulWidget {
  const CcKpiTile({
    super.key,
    required this.label,
    required this.value,
    required this.delta,
    required this.spark,
    required this.color,
    this.onTap,
  });

  final String label, value;
  final DashboardDelta? delta;
  final List<double> spark;
  final Color color;
  final VoidCallback? onTap;

  @override
  State<CcKpiTile> createState() => _CcKpiTileState();
}

class _CcKpiTileState extends State<CcKpiTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    final d = widget.delta;
    return Semantics(
      button: widget.onTap != null,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: widget.onTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              decoration: BoxDecoration(
                color: c.panel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _hover ? c.accent : c.line),
                boxShadow: [if (_hover) BoxShadow(color: c.glow, blurRadius: 24)],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(widget.value, maxLines: 1, style: ccMono(24, c.fg, weight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: d?.text ?? '—', style: TextStyle(color: c.tone(d?.tone ?? DeltaTone.flat))),
                        TextSpan(text: '  vs prev', style: TextStyle(color: c.faint)),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ccMono(11, c.muted),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 26,
                    width: double.infinity,
                    child: CustomPaint(painter: _SparkPainter(widget.spark, widget.color)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color);
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) {
      canvas.drawLine(
        Offset(0, size.height - 2),
        Offset(size.width, size.height - 2),
        Paint()
          ..color = color.withValues(alpha: 0.4)
          ..strokeWidth = 1.5,
      );
      return;
    }
    final top = values.fold<double>(0, math.max);
    final mx = top <= 0 ? 1.0 : top;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = size.height - 2 - (values[i] / mx) * (size.height - 4);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.color != color || !_same(old.values, values);
}

bool _same(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---- Metric tabs -------------------------------------------------------------------------------------
class CcTabs<T> extends StatelessWidget {
  const CcTabs({super.key, required this.values, required this.selected, required this.label, required this.onSelect});

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final v in values)
          Semantics(
            selected: v == selected,
            button: true,
            child: InkWell(
              key: ValueKey('dashboard-tab-$v'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => onSelect(v),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: v == selected ? c.accent : c.line),
                ),
                child: Text(
                  label(v).toUpperCase(),
                  style: ccMono(11, v == selected ? c.fg : c.muted, weight: FontWeight.w600).copyWith(letterSpacing: 0.5),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---- Trend chart -------------------------------------------------------------------------------------
/// This period (solid, with an area) against the previous one (dashed),
/// slot by slot, with a crosshair and a tooltip on hover or tap.
class CcTrendChart extends StatefulWidget {
  const CcTrendChart({
    super.key,
    required this.current,
    required this.previous,
    required this.slots,
    required this.slotLabel,
    required this.format,
    this.labelEvery = 1,
  });

  final List<double> current, previous;

  /// How many slots the axis spans (a day's 24 hours though only 10 have passed).
  final int slots;
  final String Function(int) slotLabel;
  final String Function(double) format;

  /// Label every n-th slot at most.
  final int labelEvery;

  @override
  State<CcTrendChart> createState() => _CcTrendChartState();
}

class _CcTrendChartState extends State<CcTrendChart> {
  int? _shown;
  static const _height = 240.0;
  static const _left = 46.0, _right = 10.0, _top = 10.0, _bottom = 26.0;

  int get _last => math.max(widget.current.length, widget.previous.length) - 1;

  void _at(double x, double width) {
    if (_last < 0) return;
    final span = math.max(1, widget.slots - 1);
    final i = ((x - _left) / math.max(1, width - _left - _right) * span).round().clamp(0, _last);
    if (i != _shown) setState(() => _shown = i);
  }

  @override
  void didUpdateWidget(CcTrendChart old) {
    super.didUpdateWidget(old);
    if (_shown != null && _shown! > _last) _shown = null;
  }

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final shown = _shown;
        final top = [...widget.current, ...widget.previous].fold<double>(0, math.max);
        final max = dashboardNiceCeil(top * 1.1);
        final span = math.max(1, widget.slots - 1);
        double xOf(int i) => _left + i / span * (w - _left - _right);
        double? at(List<double> l, int i) => i < l.length ? l[i] : null;
        return SizedBox(
          height: _height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: MouseRegion(
                  onHover: (e) => _at(e.localPosition.dx, w),
                  onExit: (_) => setState(() => _shown = null),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _at(d.localPosition.dx, w),
                    onHorizontalDragUpdate: (d) => _at(d.localPosition.dx, w),
                    child: CustomPaint(
                      key: const ValueKey('dashboard-chart'),
                      painter: _TrendPainter(
                        current: widget.current,
                        previous: widget.previous,
                        slots: widget.slots,
                        max: max,
                        colors: c,
                        selected: shown,
                        format: widget.format,
                        slotLabel: widget.slotLabel,
                        labelEvery: widget.labelEvery,
                        scaler: scaler,
                      ),
                    ),
                  ),
                ),
              ),
              if (shown != null)
                Positioned(
                  left: (xOf(shown) + 12).clamp(0.0, math.max(0.0, w - 170)),
                  top: 10,
                  child: IgnorePointer(
                    child: Container(
                      key: const ValueKey('dashboard-chart-tip'),
                      constraints: const BoxConstraints(minWidth: 140, maxWidth: 170),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.panelSolid,
                        border: Border.all(color: c.line),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: const [BoxShadow(color: Color(0x2E000000), blurRadius: 24, offset: Offset(0, 8))],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(widget.slotLabel(shown), style: TextStyle(fontSize: 12, color: c.muted)),
                          _tipLine('This period', at(widget.current, shown), c.fg, c),
                          _tipLine('Previous', at(widget.previous, shown), c.muted, c),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _tipLine(String label, double? v, Color color, CcColors c) => Text.rich(
    TextSpan(
      children: [
        TextSpan(text: '$label '),
        TextSpan(text: v == null ? '—' : widget.format(v), style: ccMono(12, color, weight: FontWeight.w600)),
      ],
    ),
    style: TextStyle(fontSize: 12, color: color),
  );
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.current,
    required this.previous,
    required this.slots,
    required this.max,
    required this.colors,
    required this.selected,
    required this.format,
    required this.slotLabel,
    required this.labelEvery,
    required this.scaler,
  });

  final List<double> current, previous;
  final int slots;
  final double max;
  final CcColors colors;
  final int? selected;
  final String Function(double) format;
  final String Function(int) slotLabel;
  final int labelEvery;
  final TextScaler scaler;

  static const _left = _CcTrendChartState._left, _right = _CcTrendChartState._right;
  static const _top = _CcTrendChartState._top, _bottom = _CcTrendChartState._bottom;

  @override
  void paint(Canvas canvas, Size size) {
    final c = colors;
    final span = math.max(1, slots - 1);
    double x(int i) => _left + i / span * (size.width - _left - _right);
    double y(double v) => _top + (1 - v / max) * (size.height - _top - _bottom);
    final label = ccMono(10, c.faint);

    void text(String s, Offset at, {TextAlign align = TextAlign.left}) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: label),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final dx = switch (align) {
        TextAlign.right => at.dx - tp.width,
        TextAlign.center => at.dx - tp.width / 2,
        _ => at.dx,
      };
      tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
    }

    // The grid and its values.
    final grid = Paint()
      ..color = c.line
      ..strokeWidth = 1;
    for (var k = 0; k <= 4; k++) {
      final v = max * k / 4;
      canvas.drawLine(Offset(_left, y(v)), Offset(size.width - _right, y(v)), grid);
      text(format(v), Offset(_left - 8, y(v)), align: TextAlign.right);
    }
    // The slots' labels, as many as fit.
    final fit = math.max(1, ((size.width - _left - _right) / 44).floor());
    final step = math.max(labelEvery, (slots / fit).ceil());
    for (var i = 0; i < slots; i += step) {
      text(slotLabel(i), Offset(x(i), size.height - 9), align: TextAlign.center);
    }

    Path line(List<double> l) {
      final p = Path();
      for (var i = 0; i < l.length; i++) {
        i == 0 ? p.moveTo(x(i), y(l[i])) : p.lineTo(x(i), y(l[i]));
      }
      return p;
    }

    // The previous period, dashed.
    if (previous.length > 1) {
      final dashed = Paint()
        ..color = c.faint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      for (final m in line(previous).computeMetrics()) {
        for (var d = 0.0; d < m.length; d += 8) {
          canvas.drawPath(m.extractPath(d, math.min(d + 4, m.length)), dashed);
        }
      }
    }
    // This period, with its area.
    if (current.isNotEmpty) {
      final last = current.length - 1;
      if (current.length > 1) {
        final area = line(current)
          ..lineTo(x(last), size.height - _bottom)
          ..lineTo(x(0), size.height - _bottom)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = ui.Gradient.linear(
              const Offset(0, _top),
              Offset(0, size.height - _bottom),
              [c.accent.withValues(alpha: 0.35), c.accent.withValues(alpha: 0)],
            ),
        );
        canvas.drawPath(
          line(current),
          Paint()
            ..color = c.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round,
        );
      }
      _dot(canvas, Offset(x(last), y(current[last])));
    }
    // The crosshair.
    final s = selected;
    if (s != null) {
      canvas.drawLine(
        Offset(x(s), _top),
        Offset(x(s), size.height - _bottom),
        Paint()
          ..color = c.muted.withValues(alpha: 0.5)
          ..strokeWidth = 1,
      );
      if (s < current.length) _dot(canvas, Offset(x(s), y(current[s])));
    }
  }

  void _dot(Canvas canvas, Offset at) {
    canvas.drawCircle(at, 5, Paint()..color = colors.panelSolid);
    canvas.drawCircle(at, 4, Paint()..color = colors.accent);
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.selected != selected ||
      old.max != max ||
      old.slots != slots ||
      old.colors.dark != colors.dark ||
      old.colors.accent != colors.accent ||
      !_same(old.current, current) ||
      !_same(old.previous, previous);
}

/// The chart's legend.
class CcLegend extends StatelessWidget {
  const CcLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    Widget item(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 3, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 14, runSpacing: 4, children: [item(c.accent, 'This period'), item(c.faint, 'Previous period')]),
    );
  }
}

// ---- Funnel -----------------------------------------------------------------------------------------
class CcFunnel extends StatelessWidget {
  const CcFunnel({super.key, required this.funnel});
  final DashboardFunnel funnel;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    final steps = funnel.steps;
    final top = math.max(1, funnel.requests);
    return Column(
      children: [
        for (final s in steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(width: 104, child: Text(s.label, style: TextStyle(fontSize: 13, color: c.fg))),
                const SizedBox(width: 10),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: (s.count / top).clamp(0.0, 1.0),
                      child: Container(
                        height: 22,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          gradient: LinearGradient(colors: [c.accent, c.accent2]),
                          boxShadow: [BoxShadow(color: c.glow, blurRadius: 14)],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 84,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: formatDashboardCount(s.count)),
                        if (s.share != null)
                          TextSpan(text: ' ${(s.share! * 100).round()}%', style: ccMono(11, c.muted)),
                      ],
                    ),
                    textAlign: TextAlign.right,
                    style: ccMono(13, c.fg),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---- Mixes -----------------------------------------------------------------------------------------
typedef CcMixRow = ({String name, num value, String text, Color color});

/// A stacked bar (with [bar]) and a row per part: its colour, name, value
/// and share.
class CcMix extends StatelessWidget {
  const CcMix({super.key, required this.rows, this.bar = true, this.empty = 'Nothing in this period'});

  final List<CcMixRow> rows;
  final bool bar;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    final total = rows.fold<num>(0, (s, r) => s + r.value);
    if (rows.isEmpty || total <= 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(empty, style: TextStyle(fontSize: 13, color: c.muted)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (bar) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 16,
              child: Row(
                children: [
                  for (final r in rows)
                    if (r.value > 0)
                      Expanded(
                        flex: math.max(1, (r.value / total * 1000).round()),
                        child: Container(
                          margin: const EdgeInsets.only(right: 2),
                          color: r.color,
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: r.color, borderRadius: BorderRadius.circular(3)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.fg)),
                ),
                Text(r.text, style: ccMono(13, c.fg)),
                SizedBox(
                  width: 48,
                  child: Text(formatDashboardShare(r.value, total), textAlign: TextAlign.right, style: ccMono(12, c.muted)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---- Demand by hour ---------------------------------------------------------------------------------
class CcHeat extends StatelessWidget {
  const CcHeat({super.key, required this.rows, required this.labels});

  /// Rows of 24 counts.
  final List<List<int>> rows;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    final top = rows.expand((r) => r).fold<int>(0, math.max);
    final small = ccMono(10, c.faint);
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(width: 40, child: Text(label, style: small)),
          const SizedBox(width: 6),
          Expanded(child: child),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows.length; r++)
          row(
            r < labels.length ? labels[r] : '',
            Row(
              children: [
                for (var h = 0; h < 24; h++)
                  Expanded(
                    child: Tooltip(
                      message: '${r < labels.length ? labels[r] : ''} ${h.toString().padLeft(2, '0')}:00 · '
                          '${formatDashboardCount(rows[r][h])} requests',
                      child: Padding(
                        padding: const EdgeInsets.all(1),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              color: Color.lerp(c.panelSolid, c.accent, top == 0 ? 0.06 : 0.06 + 0.9 * rows[r][h] / top),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        row(
          '',
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [for (final h in const ['00', '06', '12', '18', '23']) Text(h, style: small)],
          ),
        ),
      ],
    );
  }
}

// ---- Needs attention --------------------------------------------------------------------------------
enum CcCountTone { warn, bad, good }

class CcQueueRow extends StatelessWidget {
  const CcQueueRow({super.key, required this.count, required this.label, required this.tone, this.onTap});

  final int count;
  final String label;
  final CcCountTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    final (fg, bg) = count == 0
        ? (c.good, c.goodBg)
        : switch (tone) {
            CcCountTone.bad => (c.bad, c.badBg),
            CcCountTone.warn => (c.warn, c.warnBg),
            CcCountTone.good => (c.good, c.goodBg),
          };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(border: Border.all(color: c.line), borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                Container(
                  constraints: const BoxConstraints(minWidth: 34),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
                  child: Text(formatDashboardCount(count), textAlign: TextAlign.center, style: ccMono(13, fg, weight: FontWeight.w600)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: c.fg))),
                Text('›', style: ccMono(14, c.faint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Tables ----------------------------------------------------------------------------------------
/// A small table: a header row and rows of cells, numbers right-aligned in
/// monospace. Scrolls sideways where it is wider than the panel.
class CcTable extends StatelessWidget {
  const CcTable({super.key, required this.columns, required this.rows, this.onTapRow, this.empty = 'Nothing in this period'});

  /// Each column's title and whether it holds numbers.
  final List<({String title, bool numeric})> columns;
  final List<List<Widget>> rows;
  final void Function(int row)? onTapRow;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(empty, style: TextStyle(fontSize: 13, color: c.muted)),
      );
    }
    final head = TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w500, color: c.muted);
    final border = BorderSide(color: c.line);
    Widget cell(Widget child, bool numeric, {bool header = false, int? row}) {
      final padded = Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: header ? 6 : 8),
        child: Align(alignment: numeric ? Alignment.centerRight : Alignment.centerLeft, child: child),
      );
      if (row == null || onTapRow == null) return padded;
      return TableRowInkWell(onTap: () => onTapRow!(row), child: padded);
    }

    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: box.maxWidth),
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            columnWidths: const {0: IntrinsicColumnWidth(flex: 1)},
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder(horizontalInside: border, bottom: border),
            children: [
              TableRow(
                children: [
                  for (final col in columns) cell(Text(col.title.toUpperCase(), style: head), col.numeric, header: true),
                ],
              ),
              for (var r = 0; r < rows.length; r++)
                TableRow(
                  children: [
                    for (var i = 0; i < columns.length; i++)
                      cell(
                        DefaultTextStyle.merge(
                          style: columns[i].numeric ? ccMono(13, c.fg) : TextStyle(fontSize: 13, color: c.fg),
                          child: rows[r][i],
                        ),
                        columns[i].numeric,
                        row: r,
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- A labelled meter (airports and places) ----------------------------------------------------------
class CcMeterRow extends StatelessWidget {
  const CcMeterRow({super.key, required this.label, required this.value, required this.share, required this.color});

  final String label, value;

  /// How full the meter is, 0 to 1.
  final double share;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.fg))),
              const SizedBox(width: 8),
              Flexible(child: Text(value, textAlign: TextAlign.right, style: ccMono(12, c.fg))),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: c.line)),
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: share.clamp(0.0, 1.0),
                      child: ColoredBox(color: color),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Live tiles -------------------------------------------------------------------------------------
class CcLiveTile extends StatelessWidget {
  const CcLiveTile({super.key, required this.value, required this.label, this.alert = false, this.onTap});

  final String value, label;
  final bool alert;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: alert ? c.badBg : Color.lerp(c.panelSolid, c.bg, 0.4),
            border: Border.all(color: alert ? c.bad : c.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, maxLines: 1, style: ccMono(22, alert ? c.bad : c.fg, weight: FontWeight.w600)),
              ),
              const SizedBox(height: 2),
              Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

/// [children] in [columns] equal columns, rows as tall as their tallest.
class CcGrid extends StatelessWidget {
  const CcGrid({super.key, required this.columns, required this.children, this.gap = 8});

  final int columns;
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final row = children.sublist(i, math.min(i + columns, children.length));
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < columns; j++) ...[
                if (j > 0) SizedBox(width: gap),
                Expanded(child: j < row.length ? row[j] : const SizedBox.shrink()),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[if (i > 0) SizedBox(height: gap), rows[i]],
      ],
    );
  }
}
