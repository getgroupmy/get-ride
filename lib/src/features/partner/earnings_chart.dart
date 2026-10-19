// Earnings → "Last 8 weeks": what the driver kept each week, as bars. One
// series, so one colour (the theme's primary, which light and dark each pick
// for themselves) and no legend. Tap a bar to read its week; the newest is
// read out to start with. Totals come from the server (my_earnings_series,
// migration 0201), the same calculation as the statements.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/partner_statement.dart';

/// Whether week [i] of [count] gets its date under the bar: all of them up
/// to six weeks; beyond, every other one counted back from the newest, so
/// the spacing is even (8 weeks: 4 dates, the newest among them).
bool weeklyChartLabelShown(int i, int count) => count <= 6 || (count - 1 - i).isEven;

/// The weeks that get a date when every [step]th one is labelled, counted
/// back from the newest (which is always among them).
List<int> weeklyChartLabelsEvery(int step, int count) => [
  for (var i = 0; i < count; i++)
    if ((count - 1 - i) % step == 0) i,
];

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

  static TextPainter _paint(BuildContext context, String text, TextStyle? style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();

  static double _labelWidth(BuildContext context, String text, TextStyle? style) {
    final p = _paint(context, text, style);
    final w = p.width;
    p.dispose();
    return w;
  }

  static double _labelHeight(BuildContext context, TextStyle? style) {
    final p = _paint(context, '31 Aug', style);
    final h = p.height;
    p.dispose();
    return h;
  }

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
    // Nothing earned in any week: the header and a line, not 150 of empty
    // bars over the "No completed trips" below.
    if (weeks.every((w) => w.totals.net == 0 && w.totals.trips == 0)) {
      return Card(
        key: const ValueKey('earnings-weekly-chart'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Last ${weeks.length} weeks', style: t.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                'No earnings in the last ${weeks.length} weeks',
                key: const ValueKey('earnings-weekly-empty'),
                style: t.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      );
    }
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
            // Every date shown is "day month", centred under its bar and
            // clear of its neighbours. Where they don't fit,
            // fewer dates (every 2nd, then 4th, … counted back from the
            // newest), never a date cut to its day, never mixed formats.
            LayoutBuilder(
              builder: (context, box) {
                final slot = box.maxWidth / weeks.length;
                TextStyle? style(int i) => t.textTheme.labelSmall?.copyWith(
                  color: i == _selected ? t.colorScheme.onSurface : muted,
                  // The bold of the selected date is measured for every one,
                  // so tapping a bar never changes which dates fit.
                  fontWeight: i == _selected ? FontWeight.w700 : null,
                );
                // Each date's box: its own (bold) width, centred under its
                // bar and kept inside the chart at the ends.
                final bold = t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700);
                final width = <int, double>{
                  for (var i = 0; i < weeks.length; i++) i: _labelWidth(context, _day(weeks[i].start), bold) + 2,
                };
                double leftOf(int i) =>
                    ((i + 0.5) * slot - width[i]! / 2).clamp(0.0, math.max(0.0, box.maxWidth - width[i]!));
                // A little air between neighbours.
                const gap = 6.0;
                bool fits(List<int> idx) {
                  for (var k = 0; k < idx.length; k++) {
                    if (width[idx[k]]! > box.maxWidth) return false;
                    if (k > 0 && leftOf(idx[k - 1]) + width[idx[k - 1]]! + gap > leftOf(idx[k])) return false;
                  }
                  return true;
                }
                var step = weeks.length <= 6 ? 1 : 2;
                var kept = weeklyChartLabelsEvery(step, weeks.length);
                while (kept.length > 1 && !fits(kept)) {
                  step *= 2;
                  kept = weeklyChartLabelsEvery(step, weeks.length);
                }
                final height = _labelHeight(context, style(0));
                return SizedBox(
                  height: height,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final i in kept)
                        Positioned(
                          left: leftOf(i),
                          width: width[i]!,
                          top: 0,
                          child: Text(
                            _day(weeks[i].start),
                            key: ValueKey('earnings-week-label-$i'),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            style: style(i),
                          ),
                        ),
                    ],
                  ),
                );
              },
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

    // A week with nothing earned draws no bar, and its selection is no
    // tall column either (it read as a grey bar): a short mark on the
    // baseline instead.
    final highlight = Paint()..color = surface;
    final left = slot * selected;
    final selectedValue = selected >= 0 && selected < values.length ? values[selected] : 0.0;
    if (selectedValue > 0 && top > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(left + 2, 0, slot - 4, size.height), const Radius.circular(6)),
        highlight,
      );
    } else if (selected >= 0 && selected < values.length) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left + (slot - barWidth) / 2, floor - 3, barWidth, 3),
          const Radius.circular(1.5),
        ),
        Paint()..color = bar.withValues(alpha: 0.6),
      );
    }

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
