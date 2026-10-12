// Admin → Bluetooth & safety report: how trips started (Bluetooth or the
// trip code) day by day, how the pickup handshake went, what the trip
// safety checks flagged, and the trips behind those numbers. Reads
// ble_safety_report / ble_safety_report_trips (0158).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/ble_handshake.dart';
import '../../../core/ble_report.dart';
import '../../../core/format.dart';
import '../../../data/reliability_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/loading_skeleton.dart';
import '../../widgets/admin_widgets.dart';

const bleReportPage = 'admin-ble-report';

class AdminBleReportScreen extends ConsumerStatefulWidget {
  const AdminBleReportScreen({super.key});

  @override
  ConsumerState<AdminBleReportScreen> createState() => _AdminBleReportScreenState();
}

class _AdminBleReportScreenState extends ConsumerState<AdminBleReportScreen> {
  int _days = 7;

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(bleSafetyReportProvider(_days));
    final trips = ref.watch(bleReportTripsProvider(_days));
    return AdminPage(
      title: 'Bluetooth & safety report',
      page: bleReportPage,
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: () {
            ref.invalidate(bleSafetyReportProvider(_days));
            ref.invalidate(bleReportTripsProvider(_days));
          },
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 900,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<int>(
                    key: const ValueKey('ble-report-period'),
                    segments: [for (final d in bleReportPeriods) ButtonSegment(value: d, label: Text('$d days'))],
                    selected: {_days},
                    onSelectionChanged: (s) => setState(() => _days = s.first),
                  ),
                ),
                const SizedBox(height: 16),
                report.when(
                  loading: () => const LoadingSkeleton(rows: 6),
                  error: (e, _) =>
                      EmptyState(icon: Icons.error_outline, title: "Couldn't load the report", message: '$e'),
                  data: (r) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StartsCard(r),
                      const SizedBox(height: 16),
                      _HandshakeCard(r),
                      const SizedBox(height: 16),
                      _SafetyCard(r),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _TripsCard(trips),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.child});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: t.textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// The three ways a trip starts, each with its series colour. Colour follows
/// the series, never its rank; text stays in the text colours.
class _Series {
  const _Series(this.label, this.color);
  final String label;
  final Color color;

  static List<_Series> of(ColorScheme c) => [
    _Series('Bluetooth', c.primary),
    _Series('Trip code', c.tertiary),
    _Series('Other', c.outline),
  ];
}

class _Legend extends StatelessWidget {
  const _Legend(this.series, this.values, this.total);

  final List<_Series> series;
  final List<int> values;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (var i = 0; i < series.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: series[i].color, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 6),
              Text('${series[i].label} ${values[i]} (${reportShare(values[i], total)})', style: t.textTheme.bodySmall),
            ],
          ),
      ],
    );
  }
}

class _StartsCard extends StatefulWidget {
  const _StartsCard(this.r);
  final BleSafetyReport r;

  @override
  State<_StartsCard> createState() => _StartsCardState();
}

class _StartsCardState extends State<_StartsCard> {
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final t = Theme.of(context);
    final series = _Series.of(t.colorScheme);
    final values = [r.startsBle, r.startsPin, r.startsOther];
    return _Section(
      title: 'How trips started',
      subtitle: 'Last ${r.days} days, Malaysian time',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${r.startsTotal}',
            key: const ValueKey('ble-report-starts-total'),
            style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            r.startsTotal == 1 ? 'trip started' : 'trips started',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _ShareBar(series: series, values: values),
          const SizedBox(height: 8),
          _Legend(series, values, r.startsTotal),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Text('Day by day', style: t.textTheme.titleSmall)),
              TextButton.icon(
                key: const ValueKey('ble-report-table-toggle'),
                onPressed: () => setState(() => _table = !_table),
                icon: Icon(_table ? Icons.bar_chart : Icons.table_rows_outlined, size: 18),
                label: Text(_table ? 'Show chart' : 'Show table'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_table) _DailyTable(r.daily) else _DailyBars(r.daily, series),
        ],
      ),
    );
  }
}

/// One bar split by share, 2px surface gaps between the parts.
class _ShareBar extends StatelessWidget {
  const _ShareBar({required this.series, required this.values});

  final List<_Series> series;
  final List<int> values;

  @override
  Widget build(BuildContext context) {
    final total = values.fold<int>(0, (a, b) => a + b);
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    if (total == 0) {
      return Container(
        height: 12,
        decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(6)),
      );
    }
    final parts = [
      for (var i = 0; i < values.length; i++)
        if (values[i] > 0) (series[i], values[i]),
    ];
    return SizedBox(
      height: 12,
      child: Row(
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              flex: parts[i].$2,
              child: Container(
                decoration: BoxDecoration(color: parts[i].$1.color, borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _dayLabel(DateTime d) => DateFormat('d MMM').format(d);

/// Starts per day as stacked bars on one axis, hover/long-press for the
/// numbers.
class _DailyBars extends StatelessWidget {
  const _DailyBars(this.days, this.series);

  final List<BleReportDay> days;
  final List<_Series> series;

  static const _height = 140.0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final max = days.fold<int>(0, (m, d) => d.total > m ? d.total : m);
    if (days.isEmpty || max == 0) {
      return SizedBox(
        height: 60,
        child: Center(child: Text('No trips started in this period.', style: t.textTheme.bodySmall)),
      );
    }
    final gap = days.length > 31 ? 1.0 : 3.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$max', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        SizedBox(
          key: const ValueKey('ble-report-daily-bars'),
          height: _height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final d in days)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: gap / 2),
                    child: Tooltip(
                      message: '${_dayLabel(d.day)}: ${d.ble} Bluetooth · ${d.pin} trip code · ${d.other} other',
                      child: SizedBox(
                        height: _height,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            for (final (i, v) in [(2, d.other), (1, d.pin), (0, d.ble)])
                              if (v > 0)
                                Container(
                                  height: (_height * v / max) - 2,
                                  margin: const EdgeInsets.only(top: 2),
                                  decoration: BoxDecoration(
                                    color: series[i].color,
                                    borderRadius: BorderRadius.circular(i == 0 && d.pin + d.other == 0 ? 4 : 2),
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: t.colorScheme.outlineVariant),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(_dayLabel(days.first.day), style: t.textTheme.labelSmall),
            const Spacer(),
            Text(_dayLabel(days.last.day), style: t.textTheme.labelSmall),
          ],
        ),
      ],
    );
  }
}

class _DailyTable extends StatelessWidget {
  const _DailyTable(this.days);
  final List<BleReportDay> days;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: DataTable(
      key: const ValueKey('ble-report-daily-table'),
      columns: const [
        DataColumn(label: Text('Day')),
        DataColumn(label: Text('Bluetooth'), numeric: true),
        DataColumn(label: Text('Trip code'), numeric: true),
        DataColumn(label: Text('Other'), numeric: true),
      ],
      rows: [
        for (final d in days.reversed)
          DataRow(
            cells: [
              DataCell(Text(_dayLabel(d.day))),
              DataCell(Text('${d.ble}')),
              DataCell(Text('${d.pin}')),
              DataCell(Text('${d.other}')),
            ],
          ),
      ],
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.icon, this.note});

  final String label;
  final String value;
  final IconData? icon;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[Icon(icon, size: 20, color: t.colorScheme.onSurfaceVariant), const SizedBox(width: 10)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: t.textTheme.bodyMedium),
                if (note != null)
                  Text(note!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _HandshakeCard extends StatelessWidget {
  const _HandshakeCard(this.r);
  final BleSafetyReport r;

  @override
  Widget build(BuildContext context) {
    final rssi = r.avgRssi;
    return _Section(
      title: 'Pickup handshake',
      subtitle: 'The phones finding each other over Bluetooth at the kerb',
      child: Column(
        children: [
          _Stat('Rides that used it', '${r.handshakeRides}', icon: Icons.bluetooth_searching),
          _Stat(
            'Both phones took part',
            '${r.bothPhones}',
            icon: Icons.phonelink_ring_outlined,
            note: '${reportShare(r.bothPhones, r.handshakeRides)} of those rides',
          ),
          _Stat(
            'The phones saw each other',
            '${r.seenBothWays}',
            icon: Icons.bluetooth_connected,
            note: '${reportShare(r.seenBothWays, r.bothPhones)} of rides where both took part',
          ),
          _Stat(
            'Sightings reported',
            '${r.reports}',
            icon: Icons.sensors,
            note: '${r.matchedReports} were the right phone (${reportShare(r.matchedReports, r.reports)})',
          ),
          _Stat(
            'Typical signal at a match',
            rssi == null ? '—' : '$rssi dBm',
            icon: Icons.signal_cellular_alt,
            note: rssi == null ? null : 'Roughly ${bleDistanceLabel(bleDistanceM(rssi))}',
          ),
        ],
      ),
    );
  }
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard(this.r);
  final BleSafetyReport r;

  @override
  Widget build(BuildContext context) => _Section(
    title: 'Trip safety',
    subtitle: 'What the safety checks flagged, and lost items',
    child: Column(
      children: [
        _Stat(bleReportKindLabel(BleReportKind.farApart), '${r.farApart}', icon: Icons.social_distance_outlined),
        _Stat(bleReportKindLabel(BleReportKind.noProximity), '${r.noProximity}', icon: Icons.bluetooth_disabled),
        _Stat(bleReportKindLabel(BleReportKind.separated), '${r.separations}', icon: Icons.call_split),
        _Stat(
          'Passenger answered "I\'m OK"',
          '${r.answeredOk}',
          icon: Icons.verified_user_outlined,
          note: '${reportShare(r.answeredOk, r.flagged)} of flagged trips',
        ),
        const Divider(height: 20),
        _Stat(
          'Lost items reported',
          '${r.lostTotal}',
          icon: Icons.luggage_outlined,
          note: '${r.lostOpen} open · ${r.lostFound} found · ${r.lostReturned} returned · ${r.lostNotFound} not found',
        ),
      ],
    ),
  );
}

IconData _kindIcon(BleReportKind k) => switch (k) {
  BleReportKind.farApart => Icons.social_distance_outlined,
  BleReportKind.noProximity => Icons.bluetooth_disabled,
  BleReportKind.separated => Icons.call_split,
  BleReportKind.lostItem => Icons.luggage_outlined,
};

class _TripsCard extends StatelessWidget {
  const _TripsCard(this.trips);
  final AsyncValue<List<BleReportTrip>> trips;

  @override
  Widget build(BuildContext context) => _Section(
    title: 'Flagged trips',
    subtitle: 'Newest first. Tap one for its details.',
    child: trips.when(
      loading: () => const LoadingSkeleton(rows: 3),
      error: (e, _) => Text("Couldn't load the trips: $e"),
      data: (list) => list.isEmpty
          ? const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Nothing flagged in this period.'))
          : Column(
              children: [
                for (final trip in list)
                  ListTile(
                    key: ValueKey('ble-report-trip-${trip.requestId}-${trip.kind.name}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_kindIcon(trip.kind)),
                    title: Text(bleReportKindLabel(trip.kind)),
                    subtitle: Text(
                      [trip.people, if (trip.pickupName != null) trip.pickupName!, formatDateTime(trip.at)].join(' · '),
                    ),
                    trailing: trip.answeredOk
                        ? const Chip(label: Text("I'm OK"), avatar: Icon(Icons.check, size: 16))
                        : null,
                    onTap: () => _showTrip(context, trip),
                  ),
              ],
            ),
    ),
  );
}

Future<void> _showTrip(BuildContext context, BleReportTrip trip) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) {
    final t = Theme.of(context);
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(label, style: t.textTheme.bodySmall)),
          Expanded(child: SelectableText(value, style: t.textTheme.bodyMedium)),
        ],
      ),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(bleReportKindLabel(trip.kind), style: t.textTheme.titleMedium),
            const SizedBox(height: 12),
            row('When', formatDateTime(trip.at)),
            row('Passenger', trip.riderName ?? '—'),
            row('Driver', trip.driverName ?? '—'),
            row('Pickup', trip.pickupName ?? '—'),
            row('Ride status', trip.rideStatus ?? '—'),
            row('Started by', trip.startedBy),
            if (trip.kind != BleReportKind.lostItem) row('Passenger said', trip.answeredOk ? "I'm OK" : 'No answer'),
            if (trip.detail != null) row('Item', trip.detail!),
            row('Ride ID', trip.requestId),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: trip.requestId));
                if (context.mounted) Navigator.of(context).pop();
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy ride ID'),
            ),
          ],
        ),
      ),
    );
  },
);
