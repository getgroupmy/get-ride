// Earnings → "Last 8 weeks": what the driver kept each week, as bars. One
// series, so one colour (the theme's primary, which light and dark each pick
// for themselves) and no legend. Tap a bar to read its week; the newest is
// read out to start with. Totals come from the server (my_earnings_series,
// migration 0201), the same calculation as the statements.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/partner_statement.dart';

class WeeklyEarningsChart extends StatefulWidget {
  const WeeklyEarningsChart({super.key, required this.weeks, required this.money});

  /// Oldest first.
  final List<EarningsBucket> weeks;
  final String Function(double) money;

  @override
  State<WeeklyEarningsChart> createState() => _WeeklyEarningsChartState();
}

class _WeeklyEarningsChartState extends State<WeeklyEarningsChart> {
  late int _selected = widget.weeks.length - 1;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String _day(DateTime d) => '${d.day} ${_months[d.month - 1]}';

  @override
  void didUpdateWidget(WeeklyEarningsChart old) {
    super.didUpdateWidget(old);
    if (_selected >= widget.weeks.length) _selected = widget.weeks.length - 1;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final weeks = widget.weeks;
    if (weeks.isEmpty) return const SizedBox.shrink();
    final w = weeks[_selected];
    final trips = w.totals.trips;
    return Card(
      key: const ValueKey('earnings-weekly-chart'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Last ${weeks.length} weeks', style: t.textTheme.titleSmall),
            const SizedBox(height: 2),
            // The read-out: text in text colours, never the bar colour.
            Text(
              'Week of ${_day(w.start)} · ${widget.money(w.totals.net)} · ${trips == 1 ? '1 trip' : '$trips trips'}',
              key: const ValueKey('earnings-week-readout'),
              style: t.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 150,
              child: LayoutBuilder(
                builder: (context, box) {
                  final slot = box.maxWidth / weeks.length;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _BarsPainter(
                            values: [for (final w in weeks) w.totals.net],
                            selected: _selected,
                            bar: t.colorScheme.primary,
                            baseline: t.colorScheme.outlineVariant,
                            surface: t.colorScheme.surfaceContainerHighest,
                          ),
                        ),
                      ),
                      // Hit targets: each whole column, bigger than its bar.
                      Row(
                        children: [
                          for (var i = 0; i < weeks.length; i++)
                            SizedBox(
                              width: slot,
                              child: Semantics(
                                button: true,
                                selected: i == _selected,
                                label:
                                    'Week of ${_day(weeks[i].start)}: ${widget.money(weeks[i].totals.net)}, '
                                    '${weeks[i].totals.trips} trips',
                                child: GestureDetector(
                                  key: ValueKey('earnings-week-$i'),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => setState(() => _selected = i),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < weeks.length; i++)
                  Expanded(
                    child: Text(
                      // Every other label on a narrow phone, so they never collide.
                      weeks.length > 6 && i.isOdd && i != weeks.length - 1 ? '' : _day(weeks[i].start),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: t.textTheme.labelSmall?.copyWith(
                        color: i == _selected ? t.colorScheme.onSurface : muted,
                        fontWeight: i == _selected ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bars anchored to a quiet baseline, rounded at the data end only; the
/// selected week is marked by a soft column behind it, not a new colour.
class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.values,
    required this.selected,
    required this.bar,
    required this.baseline,
    required this.surface,
  });

  final List<double> values;
  final int selected;
  final Color bar;
  final Color baseline;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final top = values.fold<double>(0, math.max);
    final slot = size.width / values.length;
    final barWidth = math.min(28.0, slot * 0.56);
    final floor = size.height - 1;

    final highlight = Paint()..color = surface;
    final left = slot * selected;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(left + 2, 0, slot - 4, size.height), const Radius.circular(6)),
      highlight,
    );

    final fill = Paint()..color = bar;
    for (var i = 0; i < values.length; i++) {
      final v = math.max(0.0, values[i]);
      if (v <= 0 || top <= 0) continue;
      // At least 2px so a small but real week is still visible.
      final h = math.max(2.0, (v / top) * (floor - 8));
      final x = slot * i + (slot - barWidth) / 2;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, floor - h, barWidth, h),
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        ),
        fill,
      );
    }
    canvas.drawLine(
      Offset(0, floor + 0.5),
      Offset(size.width, floor + 0.5),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.selected != selected ||
      old.bar != bar ||
      old.baseline != baseline ||
      old.surface != surface ||
      !_sameValues(old.values, values);

  static bool _sameValues(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
