// Telematics (migration 0255): the pieces every telematics page shares —
// the period picker, the tiles, the stacked chart, the kilometres table,
// trips by type and the period list. The driver's page (Side menu >
// Telematics), Admin > Telematics and the fleet owner's and stand admin's
// Dispatch tab are made of them.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/telematics.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/plate_chip.dart';
import '../../widgets/search_select.dart';

// ---- Colours ---------------------------------------------------------------------------------------
/// The chart's three series and the table's signs, chosen for light and
/// dark each.
class TelematicsColors {
  const TelematicsColors._(this.pickup, this.passenger, this.other, this.over, this.under);

  factory TelematicsColors.of(BuildContext context) => Theme.of(context).brightness == Brightness.dark
      ? const TelematicsColors._(
          Color(0xFF5B9BFF),
          Color(0xFFF0A35E),
          Color(0xFF5C6575),
          Color(0xFFF4C95D),
          Color(0xFF5AD08F),
        )
      : const TelematicsColors._(
          Color(0xFF2F6FDF),
          Color(0xFFE8853A),
          Color(0xFFA9B1BF),
          Color(0xFF8A5A00),
          Color(0xFF0D7A45),
        );

  /// To pickup, with passenger, other driving while online.
  final Color pickup, passenger, other;

  /// Actual over the estimate, and under it.
  final Color over, under;
}

// ---- The period ------------------------------------------------------------------------------------
/// Today / This week / This month / Custom, and for Custom the first and
/// last day typed in boxes (the calendar a shortcut).
class TelematicsPeriodPicker extends StatelessWidget {
  const TelematicsPeriodPicker({
    super.key,
    required this.period,
    required this.onPeriod,
    required this.first,
    required this.last,
    required this.onRange,
    required this.today,
  });

  final TelematicsPeriod period;
  final ValueChanged<TelematicsPeriod> onPeriod;

  /// The custom range's days (local dates).
  final DateTime first, last;
  final void Function(DateTime first, DateTime last) onRange;

  /// The latest day that may be picked.
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final short = box.maxWidth < 420;
            return SegmentedButton<TelematicsPeriod>(
              key: const ValueKey('telematics-period'),
              showSelectedIcon: false,
              segments: [
                for (final p in TelematicsPeriod.values)
                  ButtonSegment(
                    value: p,
                    label: Semantics(
                      label: p.label,
                      excludeSemantics: true,
                      child: Text(short ? p.shortLabel : p.label, maxLines: 1, softWrap: false),
                    ),
                  ),
              ],
              selected: {period},
              onSelectionChanged: (v) => onPeriod(v.first),
            );
          },
        ),
        if (period == TelematicsPeriod.custom) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 260,
                child: DateBoxesField(
                  key: const ValueKey('telematics-from'),
                  label: 'From',
                  initialValue: first,
                  firstDate: DateTime(2020),
                  lastDate: today,
                  onChanged: (d) {
                    if (d != null) onRange(d, d.isAfter(last) ? d : last);
                  },
                ),
              ),
              SizedBox(
                width: 260,
                child: DateBoxesField(
                  key: const ValueKey('telematics-to'),
                  label: 'To',
                  initialValue: last,
                  firstDate: DateTime(2020),
                  lastDate: today,
                  onChanged: (d) {
                    if (d != null) onRange(d.isBefore(first) ? d : first, d);
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ---- Tiles -----------------------------------------------------------------------------------------
class TelematicsTiles extends StatelessWidget {
  const TelematicsTiles({super.key, required this.summary});

  final TelematicsSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final share = s.tripShare;
    final tiles = [
      (
        'telematics-tile-online',
        s.onlineRecorded ? formatTelematicsKm(s.onlineKm) : '—',
        s.mode == 'stand' ? 'km driven online (not shown)' : 'km driven (online)',
      ),
      ('telematics-tile-trips', '${s.trips}', s.trips == 1 ? 'trip completed' : 'trips completed'),
      ('telematics-tile-trip-km', formatTelematicsKm(s.tripKm), 'km on trips'),
      ('telematics-tile-share', share == null ? '—' : '${(share * 100).round()}%', 'of km on trips'),
    ];
    final t = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth >= 520 ? 4 : 2;
        final w = (box.maxWidth - 8 * (cols - 1)) / cols;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (key, value, label) in tiles)
              SizedBox(
                width: w,
                child: Card(
                  key: ValueKey(key),
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          value,
                          key: ValueKey('$key-value'),
                          maxLines: 1,
                          style: t.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---- The chart -------------------------------------------------------------------------------------
/// Kilometres per bucket, stacked: to pickup, with the passenger, other
/// driving while online. Hover (or tap) a bar for its numbers.
class TelematicsChart extends StatefulWidget {
  const TelematicsChart({super.key, required this.buckets, required this.bucket, required this.days});

  final List<TelematicsBucketRow> buckets;
  final TelematicsBucket bucket;
  final int days;

  @override
  State<TelematicsChart> createState() => _TelematicsChartState();
}

class _TelematicsChartState extends State<TelematicsChart> {
  int? _shown;
  static const _height = 190.0;
  static const _axis = 34.0;

  void _show(int? i) {
    if (i != _shown) setState(() => _shown = i);
  }

  @override
  void didUpdateWidget(TelematicsChart old) {
    super.didUpdateWidget(old);
    if (_shown != null && _shown! >= widget.buckets.length) _shown = null;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = TelematicsColors.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final buckets = widget.buckets;
    final top = buckets.fold<double>(0, (m, b) => math.max(m, b.total));
    final max = top <= 0 ? 1.0 : _niceCeil(top * 1.05);
    Widget legend(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(label, style: t.textTheme.bodySmall?.copyWith(color: muted)),
      ],
    );
    return Column(
      key: const ValueKey('telematics-chart'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            legend(c.pickup, 'To pickup'),
            legend(c.passenger, 'With passenger'),
            legend(c.other, 'Other driving while online'),
          ],
        ),
        const SizedBox(height: 8),
        if (buckets.isEmpty || top <= 0)
          SizedBox(
            height: 60,
            child: Center(
              child: Text(
                'No kilometres in this period',
                key: const ValueKey('telematics-chart-empty'),
                style: t.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, box) {
              final plot = box.maxWidth - _axis;
              final slot = plot / buckets.length;
              final shown = _shown;
              final labels = telematicsLabelledBars(buckets.length, math.max(1, (plot / 34).floor()));
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: _height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _StackPainter(
                              buckets: buckets,
                              max: max,
                              axis: _axis,
                              colors: c,
                              grid: t.colorScheme.outlineVariant,
                              selected: shown,
                              highlight: t.colorScheme.surfaceContainerHighest,
                              labelStyle: t.textTheme.labelSmall?.copyWith(color: muted),
                              textScaler: MediaQuery.textScalerOf(context),
                            ),
                          ),
                        ),
                        Positioned(
                          left: _axis,
                          top: 0,
                          bottom: 0,
                          right: 0,
                          child: MouseRegion(
                            onExit: (_) => _show(null),
                            onHover: (e) => _show((e.localPosition.dx / slot).floor().clamp(0, buckets.length - 1)),
                            child: Row(
                              children: [
                                for (var i = 0; i < buckets.length; i++)
                                  SizedBox(
                                    width: slot,
                                    child: Semantics(
                                      button: true,
                                      label: _readout(buckets[i]),
                                      child: GestureDetector(
                                        key: ValueKey('telematics-bar-$i'),
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () => _show(shown == i ? null : i),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (shown != null)
                          Positioned(
                            top: 4,
                            left: (_axis + slot * shown + slot / 2 + 8).clamp(0.0, math.max(0.0, box.maxWidth - 190)),
                            child: IgnorePointer(child: _Tooltip(row: buckets[shown], bucket: widget.bucket, colors: c)),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 16,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final i in labels)
                          Positioned(
                            left: _axis + slot * i + slot / 2 - 20,
                            width: 40,
                            child: Text(
                              telematicsBucketLabel(buckets[i].start, widget.bucket, days: widget.days),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.visible,
                              style: t.textTheme.labelSmall?.copyWith(color: muted),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  String _readout(TelematicsBucketRow b) =>
      '${telematicsBucketTitle(b.start, widget.bucket)}: to pickup ${formatTelematicsKm(b.pickupKm)} km, '
      'with passenger ${formatTelematicsKm(b.tripKm)} km, other ${formatTelematicsKm(b.otherKm)} km';

  /// A round top for the axis: 1, 2 or 5 times a power of ten.
  static double _niceCeil(double v) {
    final p = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in [1, 2, 5, 10]) {
      if (m * p >= v) return m * p;
    }
    return 10 * p;
  }
}

class _Tooltip extends StatelessWidget {
  const _Tooltip({required this.row, required this.bucket, required this.colors});

  final TelematicsBucketRow row;
  final TelematicsBucket bucket;
  final TelematicsColors colors;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget line(Color color, String label, double km) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 6),
        Text('$label ${formatTelematicsKm(km)} km', style: t.textTheme.bodySmall),
      ],
    );
    return Material(
      key: const ValueKey('telematics-tooltip'),
      elevation: 4,
      color: t.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(telematicsBucketTitle(row.start, bucket), style: t.textTheme.labelLarge),
            const SizedBox(height: 4),
            line(colors.pickup, 'To pickup', row.pickupKm),
            line(colors.passenger, 'With passenger', row.tripKm),
            line(colors.other, 'Other', row.otherKm),
            Text(row.trips == 1 ? '1 trip' : '${row.trips} trips', style: t.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _StackPainter extends CustomPainter {
  _StackPainter({
    required this.buckets,
    required this.max,
    required this.axis,
    required this.colors,
    required this.grid,
    required this.selected,
    required this.highlight,
    required this.labelStyle,
    required this.textScaler,
  });

  final List<TelematicsBucketRow> buckets;
  final double max, axis;
  final TelematicsColors colors;
  final Color grid, highlight;
  final int? selected;
  final TextStyle? labelStyle;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 8.0;
    final floor = size.height - 1;
    final h = floor - top;
    double y(double v) => floor - v / max * h;
    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final v in [0.0, max / 2, max]) {
      canvas.drawLine(Offset(axis, y(v) + 0.5), Offset(size.width, y(v) + 0.5), line);
      final tp = TextPainter(
        text: TextSpan(text: v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1), style: labelStyle),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      tp.paint(canvas, Offset(axis - 6 - tp.width, y(v) - tp.height / 2));
      tp.dispose();
    }
    final slot = (size.width - axis) / buckets.length;
    final bar = math.min(28.0, math.max(3.0, slot * 0.64));
    if (selected != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(axis + slot * selected!, 0, slot, size.height), const Radius.circular(4)),
        Paint()..color = highlight,
      );
    }
    for (var i = 0; i < buckets.length; i++) {
      final b = buckets[i];
      final x = axis + slot * i + (slot - bar) / 2;
      var base = 0.0;
      for (final (v, color) in [(b.pickupKm, colors.pickup), (b.tripKm, colors.passenger), (b.otherKm, colors.other)]) {
        if (v <= 0) continue;
        final y0 = y(base), y1 = y(base + v);
        // A hair of space between the parts, and never under a pixel.
        final rect = Rect.fromLTRB(x, y1, x + bar, math.max(y1 + 1, y0 - 1));
        canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)), Paint()..color = color);
        base += v;
      }
    }
  }

  @override
  bool shouldRepaint(_StackPainter old) =>
      old.buckets != buckets ||
      old.max != max ||
      old.selected != selected ||
      old.colors.pickup != colors.pickup ||
      old.grid != grid ||
      old.highlight != highlight;
}

// ---- Kilometres, estimated and actual ----------------------------------------------------------------
class TelematicsKmTable extends StatelessWidget {
  const TelematicsKmTable({super.key, required this.km});

  final TelematicsKm km;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = TelematicsColors.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    const figures = [FontFeature.tabularFigures()];
    Widget cell(String text, {Key? key, bool head = false, bool strong = false, Color? color, bool left = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          child: Text(
            text,
            key: key,
            textAlign: left ? TextAlign.left : TextAlign.right,
            style: (head ? t.textTheme.bodySmall?.copyWith(color: muted) : t.textTheme.bodyMedium)?.copyWith(
              fontWeight: strong ? FontWeight.w700 : null,
              color: color,
              fontFeatures: figures,
            ),
          ),
        );
    Color? tone(double? d) => d == null || d.abs() < 0.05 ? null : (d > 0 ? c.over : c.under);
    TableRow row(String id, String label, double? est, double? act, double? diff, {bool strong = false}) => TableRow(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.colorScheme.outlineVariant))),
      children: [
        cell(label, left: true, strong: strong),
        cell(formatTelematicsKm(est), key: ValueKey('telematics-km-$id-est'), strong: strong),
        cell(formatTelematicsKm(act), key: ValueKey('telematics-km-$id-act'), strong: strong),
        cell(formatKmDiff(diff), key: ValueKey('telematics-km-$id-diff'), color: tone(diff), strong: strong),
      ],
    );
    final pairs = math.max(km.pickupPairs, km.tripPairs);
    return Column(
      key: const ValueKey('telematics-km-table'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Table(
          columnWidths: const {0: FlexColumnWidth(1.6), 1: FlexColumnWidth(), 2: FlexColumnWidth(), 3: FlexColumnWidth()},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              children: [
                cell('Completed trips, km', head: true, left: true),
                cell('Estimated', head: true),
                cell('Actual', head: true),
                cell('Diff', head: true),
              ],
            ),
            row('pickup', 'To pickup', km.estPickup, km.actPickup, km.pickupDiff),
            row('trip', 'Pickup to drop', km.estTrip, km.actTrip, km.tripDiff),
            row('total', 'Total', km.estTotal, km.actTotal, km.totalDiff, strong: true),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          [
            'Estimated: the app\'s route to the pickup when the trip was taken, and the booking\'s distance. '
                'Actual: the phone\'s GPS track, or the car\'s odometer when a reader was connected.',
            if (km.withActual == 0)
              'No actual km recorded in this period (trips before telematics have estimates only).'
            else
              'Diff compares the ${pairs == 1 ? 'trip' : '$pairs trips'} with both'
                  '${km.obd > 0 ? '; ${km.obd} read off the car' : ''}.',
          ].join(' '),
          key: const ValueKey('telematics-km-note'),
          style: t.textTheme.bodySmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}

// ---- Trips by type ------------------------------------------------------------------------------------
class TripTypeBars extends StatelessWidget {
  const TripTypeBars({super.key, required this.types});

  final List<TripTypeCount> types;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = TelematicsColors.of(context);
    if (types.isEmpty) {
      return Text(
        'No completed trips in this period',
        key: const ValueKey('telematics-types-empty'),
        style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
      );
    }
    final most = types.fold<int>(0, (m, e) => math.max(m, e.trips));
    return Column(
      key: const ValueKey('telematics-types'),
      children: [
        for (final e in types)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 130,
                  child: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: LinearProgressIndicator(
                      value: most == 0 ? 0 : e.trips / most,
                      minHeight: 10,
                      color: c.pickup,
                      backgroundColor: t.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${e.trips}',
                    key: ValueKey('telematics-type-${e.kind}'),
                    textAlign: TextAlign.right,
                    style: t.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---- The report -------------------------------------------------------------------------------------------
/// Tiles, the chart, the kilometres and trips by type for one summary.
class TelematicsReport extends StatelessWidget {
  const TelematicsReport({super.key, required this.summary, required this.range});

  final TelematicsSummary summary;
  final TelematicsRange range;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget head(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(text, style: t.textTheme.titleSmall),
    );
    final km = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [head('Kilometres'), TelematicsKmTable(km: summary.km)],
    );
    final types = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [head('Trips by type'), TripTypeBars(types: summary.types)],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TelematicsTiles(summary: summary),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Kilometres ${range.bucket.per}', style: t.textTheme.titleSmall),
                const SizedBox(height: 8),
                TelematicsChart(buckets: summary.buckets, bucket: range.bucket, days: range.days),
              ],
            ),
          ),
        ),
        if (summary.mode == 'stand')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              "Your stand's orders only: what drivers drive between them is not shown.",
              key: const ValueKey('telematics-stand-note'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
        LayoutBuilder(
          builder: (context, box) => box.maxWidth >= 760
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: km),
                    const SizedBox(width: 24),
                    Expanded(child: types),
                  ],
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [km, types]),
        ),
      ],
    );
  }
}

// ---- The period list --------------------------------------------------------------------------------------
/// Every driver, vehicle or pair in the period, searchable when long; a
/// row's tap picks it.
class TelematicsListTable extends StatelessWidget {
  const TelematicsListTable({super.key, required this.rows, required this.group, this.selected, this.onPick});

  final List<TelematicsListRow> rows;
  final TelematicsGroup group;
  final String? selected;
  final ValueChanged<TelematicsListRow>? onPick;

  bool _matches(TelematicsListRow r, String q) {
    if (q.isEmpty) return true;
    final hay = '${r.driverName ?? ''} ${r.driverCode ?? ''} ${r.plate ?? ''} ${r.vehicle ?? ''}'.toLowerCase();
    return hay.contains(q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'No ${group.plural} with trips or online km in this period',
          key: const ValueKey('telematics-list-empty'),
          style: t.textTheme.bodyMedium?.copyWith(color: muted),
        ),
      );
    }
    const figures = [FontFeature.tabularFigures()];
    Widget plate(TelematicsListRow r) => r.vehicleId == null
        ? Text('Not recorded', style: TextStyle(color: muted))
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlateChip(plate: r.plate ?? '—', fontSize: 11),
              if (r.vehicle != null && group == TelematicsGroup.vehicle) ...[
                const SizedBox(width: 8),
                Text(r.vehicle!, style: t.textTheme.bodySmall?.copyWith(color: muted)),
              ],
            ],
          );
    return ListSearchFilter(
      count: rows.length,
      hint: 'Search ${group.plural}',
      fieldKey: const ValueKey('telematics-list-search'),
      builder: (context, q) {
        final shown = rows.where((r) => _matches(r, q)).toList();
        return SingleChildScrollView(
          key: const ValueKey('telematics-list'),
          scrollDirection: Axis.horizontal,
          child: DataTable(
            showCheckboxColumn: false,
            headingTextStyle: t.textTheme.bodySmall?.copyWith(color: muted),
            columnSpacing: 20,
            columns: [
              if (group != TelematicsGroup.vehicle) const DataColumn(label: Text('Driver')),
              if (group != TelematicsGroup.driver) const DataColumn(label: Text('Vehicle')),
              const DataColumn(label: Text('km driven'), numeric: true),
              const DataColumn(label: Text('Trips'), numeric: true),
              const DataColumn(label: Text('Trip km est.'), numeric: true),
              const DataColumn(label: Text('Trip km actual'), numeric: true),
            ],
            rows: [
              for (final r in shown)
                DataRow(
                  selected: selected != null && r.key(group) == selected,
                  onSelectChanged: onPick == null ? null : (_) => onPick!(r),
                  cells: [
                    if (group != TelematicsGroup.vehicle)
                      DataCell(Text(r.driverLabel, key: ValueKey('telematics-row-${r.key(group)}'))),
                    if (group != TelematicsGroup.driver)
                      DataCell(
                        KeyedSubtree(
                          key: ValueKey('telematics-row-${group == TelematicsGroup.pair ? 'plate-' : ''}${r.key(group)}'),
                          child: plate(r),
                        ),
                      ),
                    DataCell(Text(formatTelematicsKm(r.onlineKm), style: const TextStyle(fontFeatures: figures))),
                    DataCell(Text('${r.trips}', style: const TextStyle(fontFeatures: figures))),
                    DataCell(Text(formatTelematicsKm(r.estKm), style: const TextStyle(fontFeatures: figures))),
                    DataCell(Text(formatTelematicsKm(r.actKm), style: const TextStyle(fontFeatures: figures))),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}
