// Driver menu → Earnings: today's, this week's or this month's earnings,
// deductions and net, then the same per day and the last eight weeks. The
// server works the totals out (migration 0201), the same calculation as the
// partner statements; the CSV export lists the trips themselves.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/driver_earnings.dart';
import '../../core/format.dart';
import '../../core/partner_statement.dart';
import '../../data/models.dart';
import '../../data/partner_statement_repository.dart';
import '../../platform/web_download.dart';
import '../../providers.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/common.dart';
import '../../widgets/image_share.dart' show shareOriginOf;
import '../../widgets/side_menu_host.dart';
import 'earnings_chart.dart';

/// The driver's completed trips far enough back for the month and the
/// weekly chart: every period and the chart are slices of it, so switching
/// period reads nothing new.
final driverMonthTripsProvider = FutureProvider.autoDispose<List<RideRequest>>((ref) {
  return ref.watch(rideRepositoryProvider).completedAsDriver(earningsHistoryStart(ref.watch(earningsClockProvider)()));
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

/// Whether the period picker [width] wide takes the short labels: the full
/// ones with each segment's padding (24 a side) and border don't fit.
bool earningsPeriodsShort(BuildContext context, double width) {
  final style = Theme.of(context).textTheme.labelLarge;
  final scaler = MediaQuery.textScalerOf(context);
  var need = 0.0;
  for (final p in EarningsPeriod.values) {
    final tp = TextPainter(
      text: TextSpan(text: p.label, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    need += tp.width + 48 + 1;
    tp.dispose();
  }
  return need > width;
}

class EarningsScreen extends ConsumerStatefulWidget {
  const EarningsScreen({super.key});

  @override
  ConsumerState<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends ConsumerState<EarningsScreen> {
  EarningsPeriod _period = EarningsPeriod.today;

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(earningsTotalsProvider(_period));
    final weeks = ref.watch(earningsWeeksProvider);
    String money(double v) => formatMoney(v);
    return Scaffold(
      appBar: AppBar(
        leading: sideMenuLeading(context),
        title: const Text('Earnings'),
        actions: [
          IconButton(
            key: const ValueKey('earnings-statements'),
            tooltip: 'Statements',
            icon: const Icon(Icons.description_outlined),
            onPressed: () => context.push('/drive/statements'),
          ),
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
        onRefresh: () {
          ref.invalidate(earningsWeeksProvider);
          ref.invalidate(driverMonthTripsProvider);
          return ref.refresh(earningsTotalsProvider(_period).future);
        },
        child: AsyncView(
          value: summary,
          onRetry: () => ref.invalidate(earningsTotalsProvider(_period)),
          data: (s) => ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              ResponsiveCenter(
                maxWidth: 760,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    // "Today / Week / Month" where the full labels would
                    // wrap ("This month" on two lines at 317 wide); a screen
                    // reader always hears them in full.
                    LayoutBuilder(builder: (context, box) {
                      final short = earningsPeriodsShort(context, box.maxWidth);
                      return SegmentedButton<EarningsPeriod>(
                        key: const ValueKey('earnings-period'),
                        segments: [
                          for (final p in EarningsPeriod.values)
                            ButtonSegment(
                              value: p,
                              label: Semantics(
                                label: p.label,
                                excludeSemantics: true,
                                child: Text(short ? p.shortLabel : p.label, maxLines: 1, softWrap: false),
                              ),
                            ),
                        ],
                        selected: {_period},
                        showSelectedIcon: false,
                        onSelectionChanged: (v) => setState(() => _period = v.first),
                      );
                    }),
                    const SizedBox(height: 12),
                    EarningsTotalsCard(totals: s.totals, money: money),
                    if (weeks.value case final w?) WeeklyEarningsChart(weeks: w, money: money),
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
                            title: Text(_dayLabel(d.start, ref.read(earningsClockProvider)())),
                            subtitle: Text(
                              '${_trips(d.totals.trips)} · ${_km(d.totals.distanceKm)}'
                              '${d.totals.commission > 0 ? ' · commission ${money(d.totals.commission)}' : ''}',
                            ),
                            trailing: Text(money(d.totals.net), style: Theme.of(context).textTheme.titleMedium),
                          ),
                        ),
                    ],
                    const SizedBox(height: 8),
                    // A row to open, as Account's: icon, title, chevron.
                    Card(
                      child: ListTile(
                        key: const ValueKey('earnings-trip-history'),
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: const Text('Trip history and receipts'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/trips'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The selected period's trips as a CSV, through the share sheet.
  Future<void> _export(BuildContext button) async {
    final rides = ref.read(driverMonthTripsProvider).value ?? const <RideRequest>[];
    final uid = ref.read(currentUserIdProvider) ?? '';
    final now = ref.read(earningsClockProvider)();
    // The week starts as the totals' does (Admin → statement settings).
    final sunday = ref.read(statementSettingsProvider).value?.weekStartsSunday ?? false;
    final csv = earningsCsv(rides, driverId: uid, period: _period, now: now, sunday: sunday);
    // Only the header line: nothing to hand an accountant.
    if (csv.split('\r\n').where((l) => l.isNotEmpty).length <= 1) {
      unawaited(showAppNotice(
        id: 'notice.earnings',
        context: context,
        message: 'No completed trips ${_period.label.toLowerCase()} to export.',
      ));
      return;
    }
    final outcome = await ref.read(earningsCsvSharerProvider)(
      csv,
      earningsCsvFileName(_period, now, sunday: sunday),
      shareOriginOf(button),
    );
    final note = switch (outcome) {
      CsvShareOutcome.shared => null,
      CsvShareOutcome.downloaded => 'Downloaded.',
      CsvShareOutcome.copied => 'Couldn\'t open sharing; the CSV is on your clipboard.',
      CsvShareOutcome.failed => 'Couldn\'t export the CSV.',
    };
    if (note != null && mounted) {
      unawaited(showAppNotice(
        id: 'notice.earnings',
        context: context,
        message: note,
        kind: outcome == CsvShareOutcome.failed ? NoticeKind.error : NoticeKind.info,
      ));
    }
  }

  static String _trips(int n) => n == 1 ? '1 trip' : '$n trips';

  static String _km(double km) => '${km.toStringAsFixed(km >= 100 ? 0 : 1)} km';

  static String _dayLabel(DateTime d, DateTime now) {
    final today = malaysiaDate(now);
    d = DateTime.utc(d.year, d.month, d.day);
    if (d == today) return 'Today';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }
}

/// The period's earnings, deductions and net; taxes and tolls apart, as
/// collected for others and not income. The same lines as a statement.
class EarningsTotalsCard extends StatelessWidget {
  const EarningsTotalsCard({super.key, required this.totals, required this.money});

  final StatementTotals totals;
  final String Function(double) money;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final s = totals;
    Widget row(String label, String value, {Key? key, bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: strong ? null : TextStyle(color: muted)),
          ),
          Text(
            value,
            key: key,
            style: strong ? const TextStyle(fontWeight: FontWeight.w600) : null,
          ),
        ],
      ),
    );
    String less(double v) => v > 0 ? '− ${money(v)}' : money(0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You earned', style: t.textTheme.labelLarge?.copyWith(color: muted)),
            Text(
              money(s.net),
              key: const ValueKey('earnings-net'),
              style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            row('Completed trips', '${s.trips}', key: const ValueKey('earnings-trips')),
            if (s.meterTrips != 0)
              row('Of which meter / TEKSI', '${s.meterTrips}', key: const ValueKey('earnings-meter-trips')),
            row('Fares', money(s.fares), key: const ValueKey('earnings-fares')),
            if (s.surcharges != 0) row('Surcharges', money(s.surcharges)),
            if (s.feesCollected != 0) row('Fees collected for GET.ride', money(s.feesCollected)),
            if (s.incentives != 0) row('Incentives', money(s.incentives), key: const ValueKey('earnings-incentives')),
            if (s.handoverIn != 0) row('Handover share received', money(s.handoverIn)),
            row('Commission', less(s.commission)),
            if (s.platformFees != 0) row('Platform fees', less(s.platformFees)),
            if (s.handoverOut != 0) row('Handover share paid', less(s.handoverOut)),
            if (s.adjustments != 0)
              row('Adjustments', money(s.adjustments), key: const ValueKey('earnings-adjustments')),
            if (s.passThrough != 0)
              Theme(
                data: t.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const ValueKey('earnings-pass-through'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 4),
                  title: Text('Collected for others ${money(s.passThrough)}', style: t.textTheme.bodyMedium),
                  subtitle: Text('Taxes and tolls: not part of what you earned', style: TextStyle(color: muted)),
                  children: [
                    if (s.taxes != 0) row('Taxes', money(s.taxes), key: const ValueKey('earnings-taxes')),
                    if (s.tolls != 0) row('Tolls', money(s.tolls)),
                    if (s.otherCharges != 0) row('Other charges', money(s.otherCharges)),
                    if (s.otherSurcharges != 0) row('Other surcharges', money(s.otherSurcharges)),
                  ],
                ),
              ),
            const Divider(height: 20),
            row('Hours online', s.onlineHours.toStringAsFixed(1)),
            row('Distance', '${s.distanceKm.toStringAsFixed(1)} km'),
          ],
        ),
      ),
    );
  }
}
