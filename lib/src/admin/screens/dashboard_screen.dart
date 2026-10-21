// Admin > Dashboard, the "Command Centre" (migration 0261). A period bar
// (Today, Yesterday, This week, This month, Custom; Malaysia's days, kept
// per admin), eight KPI tiles against the previous period, trips over time,
// the live "Right now" panel, the request funnel, the service mix, demand by
// hour, what needs attention, the top areas and drivers, payments, airports
// and places, and quality. A 12-column grid on wide screens, one column on
// a phone. Read on the Dashboard page (admin-dashboard) or as a full admin.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../../core/admin_dashboard.dart';
import '../../core/format.dart' show formatMoney;
import '../../data/admin_dashboard_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/date_boxes.dart';
import '../../widgets/search_select.dart';
import '../widgets/admin_widgets.dart';
import 'dashboard_panels.dart';
import 'safety/safety_incidents_screen.dart' show openSafetyIncidents;

/// From this width the panels sit side by side on a 12-column grid.
const dashboardWideFrom = 980.0;

class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  ConsumerState<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen> {
  DashboardChoice _choice = DashboardChoice.initial;

  /// The custom period's days as typed, before Apply (local dates).
  late DateTime _draftFirst, _draftLast;
  late DashboardRange _range;
  DashboardMetric _metric = DashboardMetric.trips;

  /// What was last shown, kept on screen while the next read lands.
  DashboardSummary? _shown;
  DashboardRange? _shownRange;
  Timer? _tick;

  DateTime _now() => ref.read(adminDashboardClockProvider)();

  DateTime _localToday() {
    final t = malaysiaClock(_now());
    return DateTime(t.year, t.month, t.day);
  }

  DashboardRange _rangeFor(DashboardChoice c) => dashboardRange(c.period, _now(), first: c.first, last: c.last);

  @override
  void initState() {
    super.initState();
    _draftLast = _localToday();
    _draftFirst = _draftLast.subtract(const Duration(days: 6));
    _range = _rangeFor(_choice);
    unawaited(_restore());
    final every = ref.read(adminDashboardRefreshProvider);
    // A period that runs to now moves on with the clock.
    if (every != null) _tick = Timer.periodic(every * 3, (_) => _roll());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _restore() async {
    final saved = await ref.read(dashboardChoiceStoreProvider).load();
    if (!mounted || saved == _choice) return;
    setState(() {
      _choice = saved;
      if (saved.first != null && saved.last != null) {
        _draftFirst = saved.first!;
        _draftLast = saved.last!;
      }
      _range = _rangeFor(saved);
    });
  }

  void _choose(DashboardChoice c) {
    setState(() {
      _choice = c;
      _range = _rangeFor(c);
    });
    unawaited(ref.read(dashboardChoiceStoreProvider).save(c));
  }

  void _roll() {
    if (!mounted || _choice.period == DashboardPeriod.yesterday || _choice.period == DashboardPeriod.custom) return;
    final next = _rangeFor(_choice);
    if (next != _range) setState(() => _range = next);
  }

  void _refresh() {
    ref.invalidate(adminDashboardSummaryProvider(_range));
    ref.invalidate(adminDashboardLiveProvider);
    _roll();
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(adminDashboardSummaryProvider(_range));
    if (summary.hasValue && !summary.isLoading) {
      _shown = summary.value;
      _shownRange = _range;
    }
    final c = CcColors.of(context);
    return AdminPage(
      title: 'Dashboard',
      module: 'dashboard',
      actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh)],
      body: CcGridBackground(
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= dashboardWideFrom;
            final shown = summary.hasError ? null : (summary.value ?? _shown);
            final range = summary.value != null ? _range : (_shownRange ?? _range);
            return DefaultTextStyle.merge(
              style: TextStyle(color: c.fg),
              child: ListView(
                key: const ValueKey('dashboard-scroll'),
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1320),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _header(c, wide),
                          if (_choice.period == DashboardPeriod.custom) ...[const SizedBox(height: 12), _custom(c)],
                          const SizedBox(height: 10),
                          Text(
                            dashboardRangeText(_range, _now()),
                            key: const ValueKey('dashboard-range'),
                            style: ccMono(12, c.muted),
                          ),
                          const SizedBox(height: 16),
                          if (summary.hasError)
                            AsyncView<DashboardSummary>(
                              value: summary,
                              errorTitle: "Couldn't load the dashboard",
                              onRetry: () => ref.invalidate(adminDashboardSummaryProvider(_range)),
                              data: (_) => const SizedBox.shrink(),
                            )
                          else if (shown == null)
                            Skeletonizer(
                              key: const ValueKey('dashboard-skeleton'),
                              child: _DashboardBody(
                                summary: _placeholder,
                                range: _range,
                                metric: _metric,
                                onMetric: (_) {},
                                wide: wide,
                                width: box.maxWidth,
                              ),
                            )
                          else
                            _DashboardBody(
                              summary: shown,
                              range: range,
                              metric: _metric,
                              onMetric: (m) => setState(() => _metric = m),
                              wide: wide,
                              width: box.maxWidth,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header(CcColors c, bool wide) {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('GET.RIDE · ADMIN', style: ccMono(11, c.accent).copyWith(letterSpacing: 1.6)),
        const SizedBox(height: 2),
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Command Centre',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: c.fg, letterSpacing: 0.3),
            ),
            const CcLiveDot(),
          ],
        ),
      ],
    );
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [title, _periods(c)],
    );
  }

  Widget _periods(CcColors c) => Container(
    key: const ValueKey('dashboard-periods'),
    padding: const EdgeInsets.all(5),
    decoration: BoxDecoration(
      color: c.panel,
      border: Border.all(color: c.line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final p in DashboardPeriod.values)
          Semantics(
            selected: p == _choice.period,
            button: true,
            child: Material(
              color: p == _choice.period ? c.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                key: ValueKey('dashboard-period-${p.name}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => _choose(
                  p == DashboardPeriod.custom
                      ? DashboardChoice(p, first: _draftFirst, last: _draftLast)
                      : DashboardChoice(p),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: p == _choice.period
                      ? BoxDecoration(borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: c.glow, blurRadius: 18)])
                      : null,
                  child: Text(
                    p.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p == _choice.period ? c.panelSolid : c.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _custom(CcColors c) {
    final today = _localToday();
    return Container(
      key: const ValueKey('dashboard-custom'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: c.panel,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 250,
            child: DateBoxesField(
              key: const ValueKey('dashboard-from'),
              label: 'From',
              initialValue: _draftFirst,
              firstDate: DateTime(2020),
              lastDate: today,
              onChanged: (d) {
                if (d != null) setState(() => _draftFirst = d);
              },
            ),
          ),
          SizedBox(
            width: 250,
            child: DateBoxesField(
              key: const ValueKey('dashboard-to'),
              label: 'To',
              initialValue: _draftLast,
              firstDate: DateTime(2020),
              lastDate: today,
              onChanged: (d) {
                if (d != null) setState(() => _draftLast = d);
              },
            ),
          ),
          FilledButton(
            key: const ValueKey('dashboard-apply'),
            style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
            onPressed: () => _choose(DashboardChoice(DashboardPeriod.custom, first: _draftFirst, last: _draftLast)),
            child: const Text('Apply'),
          ),
          Text("Day, month and year in your country's order", style: TextStyle(fontSize: 12, color: c.faint)),
        ],
      ),
    );
  }
}

/// What the skeleton draws while the first read is on its way.
final _placeholder = DashboardSummary(
  current: DashboardPeriodFigures(
    kpis: const DashboardKpis(trips: 1234, bookings: 38000, commission: 4500, requests: 1500, accepted: 1300, cancelled: 160),
    buckets: [for (var i = 0; i < 12; i++) DashboardBucketRow(start: DateTime.utc(2026), trips: 10 + i % 4)],
    funnel: const DashboardFunnel(requests: 100, offered: 90, accepted: 80, pickedUp: 75, completed: 72),
    services: const [DashboardMix(name: 'Ride', trips: 60, bookings: 1800), DashboardMix(name: 'Comfort', trips: 30, bookings: 1200)],
    payments: const [DashboardMix(name: 'Cash', trips: 60, bookings: 1800), DashboardMix(name: 'GET.wallet', trips: 30, bookings: 1200)],
  ),
  areas: const [DashboardArea(name: 'An area name', trips: 40, bookings: 1200, prevTrips: 35)],
  drivers: const [DashboardDriver(profileId: '', name: 'A driver name', trips: 12, earned: 300)],
);

// ---- The body -------------------------------------------------------------------------------------------
class _DashboardBody extends ConsumerWidget {
  const _DashboardBody({
    required this.summary,
    required this.range,
    required this.metric,
    required this.onMetric,
    required this.wide,
    required this.width,
  });

  final DashboardSummary summary;
  final DashboardRange range;
  final DashboardMetric metric;
  final ValueChanged<DashboardMetric> onMetric;
  final bool wide;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = CcColors.of(context);
    final cur = summary.current, prev = summary.previous;
    final currency = cur.currency;
    String money(num v, [int? decimals]) => formatMoney(v, currency, decimals);

    // ---- KPIs.
    final kpiColours = [c.series[0], c.series[1], c.series[3], c.series[2], c.series[0], c.series[4], c.series[1], c.series[2]];
    final kpis = [
      for (final (i, k) in DashboardKpi.values.indexed)
        CcKpiTile(
          key: ValueKey('dashboard-kpi-${k.name}'),
          label: k.label,
          value: k.format(k.valueOf(cur.kpis), currency),
          delta: k.delta(cur.kpis, prev.kpis),
          spark: k.spark(cur.buckets),
          color: kpiColours[i],
          onTap: () => context.go(k.route),
        ),
    ];
    final kpiColumns = width >= 760 ? 4 : 2;

    // ---- Trips over time.
    final slots = range.axisSlots(cur.buckets.length);
    final chart = CcPanel(
      key: const ValueKey('dashboard-panel-chart'),
      title: 'Trips over time',
      trailing: CcTabs<DashboardMetric>(
        values: DashboardMetric.values,
        selected: metric,
        label: (m) => m == DashboardMetric.bookings ? 'Bookings $currency' : m.label,
        onSelect: onMetric,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CcTrendChart(
            current: [for (final b in cur.buckets) b.metric(metric)],
            previous: [for (final b in prev.buckets) b.metric(metric)],
            slots: slots,
            slotLabel: (i) => dashboardSlotLabel(range, i),
            labelEvery: range.oneDay ? 3 : 1,
            format: (v) => metric == DashboardMetric.bookings ? formatDashboardAxis(v) : formatDashboardCount(v.round()),
          ),
          const CcLegend(),
        ],
      ),
    );

    // ---- Funnel and mixes.
    final funnel = CcPanel(
      key: const ValueKey('dashboard-panel-funnel'),
      title: 'Request funnel',
      note: 'requests to completed trips',
      child: CcFunnel(funnel: cur.funnel),
    );
    final services = CcPanel(
      key: const ValueKey('dashboard-panel-services'),
      title: 'Service mix',
      note: 'completed trips',
      child: CcMix(
        rows: [
          for (final (i, s) in cur.services.indexed)
            (name: s.name, value: s.trips, text: formatDashboardCount(s.trips), color: c.series[i % c.series.length]),
        ],
      ),
    );
    final payments = CcPanel(
      key: const ValueKey('dashboard-panel-payments'),
      title: 'Payments',
      note: 'share of bookings',
      child: CcMix(
        bar: false,
        rows: [
          for (final (i, s) in cur.payments.indexed)
            (name: s.name, value: s.bookings, text: money(s.bookings, 0), color: c.series[(i + 2) % c.series.length]),
        ],
      ),
    );

    // ---- Demand by hour.
    final heatRows = dashboardHeatRows(cur.heat, oneRow: range.oneDay);
    final heat = CcPanel(
      key: const ValueKey('dashboard-panel-heat'),
      title: 'Demand by hour',
      note: 'requests, darker = busier',
      child: CcHeat(
        rows: heatRows,
        labels: range.oneDay
            ? [range.period == DashboardPeriod.today ? 'Today' : (range.period == DashboardPeriod.yesterday ? 'Yest.' : 'Day')]
            : const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
      ),
    );

    // ---- Needs attention.
    final a = summary.attention;
    final docs = a.partnerDocsPending + a.vehicleDocsPending;
    final attention = CcPanel(
      key: const ValueKey('dashboard-panel-attention'),
      title: 'Needs attention',
      child: Column(
        children: [
          CcQueueRow(
            count: a.partnersPending,
            label: 'Partners awaiting approval',
            tone: CcCountTone.warn,
            onTap: () => context.go('/admin/partners?status=unapproved'),
          ),
          CcQueueRow(
            count: docs,
            label: 'Documents to review',
            tone: CcCountTone.warn,
            onTap: () => context.go(
              a.partnerDocsPending == 0 && a.vehicleDocsPending > 0 ? '/admin/documents?kind=vehicle' : '/admin/documents',
            ),
          ),
          CcQueueRow(
            count: a.vehiclesNoPermit,
            label: 'Vehicles without a valid permit',
            tone: CcCountTone.bad,
            onTap: () => context.go('/admin/m/vehicle-permits'),
          ),
          CcQueueRow(
            count: a.permitsExpiring,
            label: 'Permits expiring in 15 days',
            tone: CcCountTone.warn,
            onTap: () => context.go('/admin/m/vehicle-permits'),
          ),
          CcQueueRow(
            count: a.ticketsOpen,
            label: 'Open support tickets',
            tone: CcCountTone.warn,
            onTap: () => context.go('/admin/support'),
          ),
        ],
      ),
    );

    // ---- Top areas and drivers.
    final areas = CcPanel(
      key: const ValueKey('dashboard-panel-areas'),
      title: 'Top areas',
      note: 'completed trips',
      child: CcTable(
        columns: const [
          (title: 'Area', numeric: false),
          (title: 'Trips', numeric: true),
          (title: 'Bookings', numeric: true),
          (title: 'Avg fare', numeric: true),
          (title: 'vs prev', numeric: true),
        ],
        rows: [
          for (final r in summary.areas)
            [
              Text(
                r.name == null ? 'Not recorded' : (r.city == null ? r.name! : '${r.name}, ${r.city}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(formatDashboardCount(r.trips)),
              Text(money(r.bookings, 0)),
              Text(r.averageFare == null ? '—' : money(r.averageFare!)),
              _DeltaText(DashboardDelta.of(r.trips, r.prevTrips)),
            ],
        ],
      ),
    );
    final showOnline = summary.onlineRecorded;
    final drivers = CcPanel(
      key: const ValueKey('dashboard-panel-drivers'),
      title: 'Top drivers',
      note: 'by completed trips',
      child: CcTable(
        columns: [
          (title: 'Driver', numeric: false),
          (title: 'Trips', numeric: true),
          (title: 'Earned', numeric: true),
          (title: 'Rating', numeric: true),
          if (showOnline) (title: 'Online', numeric: true),
        ],
        onTapRow: (i) {
          final id = summary.drivers[i].partnerId;
          if (id != null) context.push(Uri(path: '/admin/m/partner-edit', queryParameters: {'id': id}).toString());
        },
        rows: [
          for (final d in summary.drivers)
            [
              Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(formatDashboardCount(d.trips)),
              Text(money(d.earned, 0)),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '★ ', style: TextStyle(color: c.series[2])),
                    TextSpan(text: d.rating == null ? '—' : d.rating!.toStringAsFixed(2)),
                  ],
                ),
              ),
              if (showOnline) Text(formatDashboardOnline(d.onlineSeconds)),
            ],
        ],
      ),
    );

    // ---- Airports and places.
    final most = summary.airports.fold<int>(1, (m, x) => math.max(m, math.max(x.waiting, x.pickups)));
    final airports = CcPanel(
      key: const ValueKey('dashboard-panel-airports'),
      title: 'Airports & places',
      child: summary.airports.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('No airports or places are set up', style: TextStyle(fontSize: 13, color: c.muted)),
            )
          : ListSearchFilter(
              count: summary.airports.length,
              hint: 'Search airports and places',
              fieldKey: const ValueKey('dashboard-airports-search'),
              builder: (context, q) => Column(
                children: [
                  for (final x in summary.airports)
                    if (q.isEmpty || x.name.toLowerCase().contains(q.toLowerCase()))
                      InkWell(
                        onTap: () => context.go('/admin/m/airport-areas'),
                        child: CcMeterRow(
                          label: x.name,
                          value: '${formatDashboardCount(x.waiting)} waiting · ${formatDashboardCount(x.pickups)} pickups',
                          share: (x.kind == 'place' ? x.pickups : x.waiting) / most,
                          color: x.kind == 'place' ? c.series[1] : c.series[3],
                        ),
                      ),
                ],
              ),
            ),
    );

    // ---- Quality.
    Widget q(String label, String value, DashboardDelta? d, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: c.fg))),
          Text(value, style: ccMono(13, c.fg)),
          SizedBox(width: 92, child: Align(alignment: Alignment.centerRight, child: _DeltaText(d))),
        ],
      ),
    );
    String pct(double? v) => v == null ? '—' : formatDashboardPercent(v);
    final quality = CcPanel(
      key: const ValueKey('dashboard-panel-quality'),
      title: 'Quality',
      child: Column(
        children: [
          q(
            'Rider rating given',
            cur.quality.ratingAvg?.toStringAsFixed(2) ?? '—',
            DashboardDelta.of(cur.quality.ratingAvg, prev.quality.ratingAvg, kind: DeltaKind.absolute, decimals: 2),
          ),
          q(
            'Driver cancel rate',
            pct(cur.driverCancelRate),
            DashboardDelta.of(cur.driverCancelRate, prev.driverCancelRate, kind: DeltaKind.points, lowerIsBetter: true),
          ),
          q(
            'Rider cancel rate',
            pct(cur.riderCancelRate),
            DashboardDelta.of(cur.riderCancelRate, prev.riderCancelRate, kind: DeltaKind.points, lowerIsBetter: true),
          ),
          q(
            'Avg time to pickup',
            cur.quality.pickupMin == null ? '—' : '${cur.quality.pickupMin!.toStringAsFixed(1)} min',
            DashboardDelta.of(cur.quality.pickupMin, prev.quality.pickupMin, kind: DeltaKind.absolute, lowerIsBetter: true),
          ),
          q(
            'Complaints',
            formatDashboardCount(cur.quality.complaints),
            DashboardDelta.of(cur.quality.complaints, prev.quality.complaints, lowerIsBetter: true),
          ),
        ],
      ),
    );

    const live = _LivePanel(key: ValueKey('dashboard-panel-live'));

    const gap = 12.0;
    Widget row(List<(int, Widget)> cells) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, (span, w)) in cells.indexed) ...[
          if (i > 0) const SizedBox(width: gap),
          Expanded(flex: span, child: w),
        ],
      ],
    );
    final panels = wide
        ? [
            row([(8, chart), (4, live)]),
            row([(6, funnel), (6, services)]),
            row([(8, heat), (4, attention)]),
            row([(6, areas), (6, drivers)]),
            row([(4, payments), (4, airports), (4, quality)]),
          ]
        : [chart, live, funnel, services, heat, attention, areas, drivers, payments, airports, quality];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CcGrid(key: const ValueKey('dashboard-kpis'), columns: kpiColumns, gap: 10, children: kpis),
        for (final p in panels) ...[const SizedBox(height: gap), p],
      ],
    );
  }
}

class _DeltaText extends StatelessWidget {
  const _DeltaText(this.delta);
  final DashboardDelta? delta;

  @override
  Widget build(BuildContext context) {
    final c = CcColors.of(context);
    return Text(delta?.text ?? '—', style: ccMono(12, c.tone(delta?.tone ?? DeltaTone.flat)));
  }
}

// ---- Right now ---------------------------------------------------------------------------------------
class _LivePanel extends ConsumerWidget {
  const _LivePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = CcColors.of(context);
    final live = ref.watch(adminDashboardLiveProvider);
    final l = live.value;
    final clock = malaysiaClock(DateTime.now());
    String two(int n) => n.toString().padLeft(2, '0');
    Widget body(DashboardLive l) {
      final queue = l.queues.length == 1 ? 'Waiting at ${l.queues.first.name}' : 'Waiting in airport & place queues';
      return CcGrid(
        columns: 2,
        children: [
          CcLiveTile(
            key: const ValueKey('dashboard-live-online'),
            value: formatDashboardCount(l.driversOnline),
            label: 'Drivers online',
            onTap: () => context.go('/admin/telematics'),
          ),
          CcLiveTile(
            value: formatDashboardCount(l.ridesInProgress),
            label: 'Rides in progress',
            onTap: () => context.go('/admin/rides?status=active'),
          ),
          CcLiveTile(
            value: formatDashboardCount(l.openRequests),
            label: 'Open requests',
            onTap: () => context.go('/admin/rides?status=open'),
          ),
          CcLiveTile(
            value: l.firstOfferSeconds == null ? '—' : formatDashboardWait(l.firstOfferSeconds!),
            label: 'Avg time to first offer today',
          ),
          CcLiveTile(
            value: formatDashboardCount(l.queueWaiting),
            label: queue,
            onTap: () => context.go('/admin/m/airport-areas'),
          ),
          CcLiveTile(
            key: const ValueKey('dashboard-live-sos'),
            value: formatDashboardCount(l.sosOpen),
            label: 'SOS open',
            alert: l.sosOpen > 0,
            onTap: () => openSafetyIncidents(context),
          ),
        ],
      );
    }

    return CcPanel(
      title: 'Right now',
      alert: (l?.sosOpen ?? 0) > 0,
      trailing: Text('${two(clock.hour)}:${two(clock.minute)} MYT', style: ccMono(12, c.faint, weight: FontWeight.w400)),
      child: l != null
          ? body(l)
          : live.hasError
          ? AsyncView<DashboardLive>(
              value: live,
              errorTitle: "Couldn't load what is happening now",
              onRetry: () => ref.invalidate(adminDashboardLiveProvider),
              data: (_) => const SizedBox.shrink(),
            )
          : Skeletonizer(child: body(const DashboardLive(driversOnline: 48, ridesInProgress: 17, openRequests: 6))),
    );
  }
}
