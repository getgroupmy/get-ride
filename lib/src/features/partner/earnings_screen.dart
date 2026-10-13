// Driver menu → Earnings: today's, this week's or this month's completed
// trips, what passengers paid, the commission and what the driver kept, then
// the same per day. Totals are worked out in core/driver_earnings.dart.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/driver_earnings.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import '../../platform/web_download.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/image_share.dart' show shareOriginOf;
import '../../widgets/side_menu_host.dart';
import 'earnings_chart.dart';

/// The driver's completed trips far enough back for the month and the
/// weekly chart: every period and the chart are slices of it, so switching
/// period reads nothing new.
final driverMonthTripsProvider = FutureProvider.autoDispose<List<RideRequest>>((ref) {
  return ref.watch(rideRepositoryProvider).completedAsDriver(earningsHistoryStart(DateTime.now()));
});

/// Hands the earnings CSV to the system share sheet (Save to Files, email,
/// Drive…); the website downloads it. Where neither works it goes on the
/// clipboard. Answers how it went. Overridden in tests.
final earningsCsvSharerProvider = Provider<Future<CsvShareOutcome> Function(String csv, String fileName, Rect? origin)>(
  (ref) => (csv, fileName, origin) async {
    final bytes = Uint8List.fromList(utf8.encode(csv));
    if (kIsWeb) {
      return webDownload(bytes, fileName: fileName, mimeType: 'text/csv')
          ? CsvShareOutcome.downloaded
          : CsvShareOutcome.failed;
    }
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'text/csv', name: fileName)],
          fileNameOverrides: [fileName],
          sharePositionOrigin: origin,
        ),
      );
      return CsvShareOutcome.shared;
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: csv));
      return CsvShareOutcome.copied;
    }
  },
);

enum CsvShareOutcome { shared, downloaded, copied, failed }

class EarningsScreen extends ConsumerStatefulWidget {
  const EarningsScreen({super.key});

  @override
  ConsumerState<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends ConsumerState<EarningsScreen> {
  EarningsPeriod _period = EarningsPeriod.today;

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(currentUserIdProvider);
    return Scaffold(
      appBar: AppBar(
        leading: sideMenuLeading(context),
        title: const Text('Earnings'),
        actions: [
          Builder(
            builder: (button) => IconButton(
              key: const ValueKey('earnings-export'),
              tooltip: 'Export ${_period.label.toLowerCase()} as CSV',
              icon: const Icon(Icons.file_download_outlined),
              onPressed: ref.watch(driverMonthTripsProvider).hasValue ? () => _export(button) : null,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(driverMonthTripsProvider.future),
        child: AsyncView(
          value: ref.watch(driverMonthTripsProvider),
          onRetry: () => ref.invalidate(driverMonthTripsProvider),
          data: (rides) {
            final s = summarizeEarnings(rides, driverId: uid ?? '', period: _period, now: DateTime.now());
            String money(double v) => formatMoney(v, s.currency);
            return ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                ResponsiveCenter(
                  maxWidth: 760,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      SegmentedButton<EarningsPeriod>(
                        key: const ValueKey('earnings-period'),
                        segments: [
                          for (final p in EarningsPeriod.values) ButtonSegment(value: p, label: Text(p.label)),
                        ],
                        selected: {_period},
                        showSelectedIcon: false,
                        onSelectionChanged: (v) => setState(() => _period = v.first),
                      ),
                      const SizedBox(height: 12),
                      _TotalsCard(totals: s.totals, money: money),
                      WeeklyEarningsChart(
                        weeks: weeklyEarnings(rides, driverId: uid ?? '', now: DateTime.now()),
                        money: money,
                      ),
                      if (s.days.isEmpty)
                        const EmptyState(
                          icon: Icons.payments_outlined,
                          title: 'No completed trips',
                          message: 'Trips you complete in this period show up here.',
                        )
                      else ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
                          child: Text('By day', style: Theme.of(context).textTheme.titleSmall),
                        ),
                        for (final d in s.days)
                          Card(
                            child: ListTile(
                              title: Text(_dayLabel(d.date)),
                              subtitle: Text(
                                '${_trips(d.totals.trips)} · ${_km(d.totals.distanceKm)}'
                                '${d.totals.commission > 0 ? ' · commission ${money(d.totals.commission)}' : ''}',
                              ),
                              trailing: Text(money(d.totals.net), style: Theme.of(context).textTheme.titleMedium),
                            ),
                          ),
                      ],
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => context.push('/trips'),
                        icon: const Icon(Icons.receipt_long_outlined),
                        label: const Text('Trip history and receipts'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The selected period's trips as a CSV, through the share sheet.
  Future<void> _export(BuildContext button) async {
    final rides = ref.read(driverMonthTripsProvider).value ?? const <RideRequest>[];
    final uid = ref.read(currentUserIdProvider) ?? '';
    final now = DateTime.now();
    final csv = earningsCsv(rides, driverId: uid, period: _period, now: now);
    final messenger = ScaffoldMessenger.of(context);
    // Only the header line: nothing to hand an accountant.
    if (csv.split('\r\n').where((l) => l.isNotEmpty).length <= 1) {
      messenger.showSnackBar(SnackBar(content: Text('No completed trips ${_period.label.toLowerCase()} to export.')));
      return;
    }
    final outcome = await ref.read(earningsCsvSharerProvider)(
      csv,
      earningsCsvFileName(_period, now),
      shareOriginOf(button),
    );
    final note = switch (outcome) {
      CsvShareOutcome.shared => null,
      CsvShareOutcome.downloaded => 'Downloaded.',
      CsvShareOutcome.copied => 'Couldn\'t open sharing; the CSV is on your clipboard.',
      CsvShareOutcome.failed => 'Couldn\'t export the CSV.',
    };
    if (note != null) messenger.showSnackBar(SnackBar(content: Text(note)));
  }

  static String _trips(int n) => n == 1 ? '1 trip' : '$n trips';

  static String _km(double km) => '${km.toStringAsFixed(km >= 100 ? 0 : 1)} km';

  static String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (d == today) return 'Today';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals, required this.money});

  final EarningsTotals totals;
  final String Function(double) money;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    Widget row(String label, String value, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: muted)),
          ),
          Text(value, key: key),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You earned', style: t.textTheme.labelLarge?.copyWith(color: muted)),
            Text(
              money(totals.net),
              key: const ValueKey('earnings-net'),
              style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            row('Completed trips', '${totals.trips}', key: const ValueKey('earnings-trips')),
            row('Passengers paid', money(totals.gross)),
            row('Commission', totals.commission > 0 ? '− ${money(totals.commission)}' : money(0)),
            row('Distance', '${totals.distanceKm.toStringAsFixed(1)} km'),
          ],
        ),
      ),
    );
  }
}
