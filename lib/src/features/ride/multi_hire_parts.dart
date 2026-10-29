// Hire for several days (migration 0327) in the app: the package chips on
// the booking panel's "Hire by time" side (Hourly, Daily), the days side of
// the panel (the first day in boxes, the start time, the days, the hours a
// day, the same driver, an overnight trip, a plan of stops, the vehicles
// at their day price), the review before booking (the price, what is paid
// now and on day 1, the free-cancel time, the rates), the rider's booking
// card (its days, cancel) and the driver's card for a whole booking.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/fare.dart' show RideService;
import '../../core/hourly_hire.dart' show hireClock, hireHoursText;
import '../../core/multi_day_hire.dart';
import '../../core/payment_types.dart';
import '../../core/region_pricing.dart';
import '../../core/scheduled_rides.dart' show ScheduledRidesConfig;
import '../../data/geo_service.dart' show Place;
import '../../data/hourly_hire_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show showError, showInfo;
import '../../widgets/date_boxes.dart';
import '../../widgets/page_style_host.dart';
import 'confirm_parts.dart' show showPaymentSheet, confirmAccent, accentFill;
import 'pickup_time_sheet.dart' show showPickupTimeSheet;

/// The hire packages offered: 'hourly' and those the admin turned on.
class HirePackageChips extends StatelessWidget {
  const HirePackageChips({super.key, required this.packages, required this.selected, required this.onChanged});

  /// Each package's key and its chip label, in order.
  final List<({String key, String label})> packages;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    key: const ValueKey('hire-packages'),
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final p in packages)
        ChoiceChip(
          key: ValueKey('hire-package-${p.key}'),
          label: Text(p.label),
          selected: p.key == selected,
          onSelected: (_) => onChanged(p.key),
        ),
    ],
  );
}

/// What a quote is asked for.
typedef MultiHireQuoteArgs = ({
  String package,
  double lat,
  double lng,
  double? dropLat,
  double? dropLng,
  String service,
  int days,
  double hours,
  DateTime firstAt,
  bool overnight,
  String? country,
  String? state,
  String? city,
  String? suburb,
});

final multiHireQuoteProvider = FutureProvider.autoDispose.family<MultiHireQuote?, MultiHireQuoteArgs>((ref, a) async {
  try {
    return await ref.watch(hourlyHireRepositoryProvider).multiQuote(
      package: a.package,
      pickup: (lat: a.lat, lng: a.lng),
      drop: a.dropLat == null || a.dropLng == null ? null : (lat: a.dropLat!, lng: a.dropLng!),
      service: a.service,
      days: a.days,
      hours: a.hours,
      firstAt: a.firstAt,
      overnight: a.overnight,
      place: (country: a.country, state: a.state, city: a.city, suburb: a.suburb),
    );
  } catch (_) {
    return null;
  }
});

/// What the days side of the panel books.
typedef MultiHireBooking = ({
  RideService service,
  MultiHireQuote quote,
  DateTime firstAt,
  int days,
  double hours,
  bool sameDriver,
  bool overnight,
  HirePayPlan plan,
  double total,
});

/// The first day at 9:00 am, [lead] hours ahead at least.
DateTime defaultFirstDay(DateTime now, int leadHours) {
  final soonest = now.add(Duration(hours: leadHours));
  var d = DateTime(soonest.year, soonest.month, soonest.day, 9);
  if (d.isBefore(soonest)) d = DateTime(soonest.year, soonest.month, soonest.day + 1, 9);
  return d;
}

/// The panel's "Hire by time" side for a package of days.
class MultiHirePanel extends ConsumerStatefulWidget {
  const MultiHirePanel({
    super.key,
    required this.config,
    required this.pickup,
    required this.drop,
    required this.onPickup,
    required this.onDrop,
    required this.onClearDrop,
    required this.stops,
    required this.onAddStop,
    required this.onRemoveStop,
    required this.services,
    required this.place,
    required this.pricingFor,
    required this.money,
    required this.payments,
    required this.payment,
    required this.onPayment,
    required this.onBook,
    this.whoRiding,
    this.clock = DateTime.now,
  });

  final MultiHireConfig config;
  final Place? pickup;
  final Place? drop;
  final VoidCallback onPickup, onDrop, onClearDrop;

  /// The plan: stops on the way, optional.
  final List<Place> stops;
  final VoidCallback onAddStop;
  final ValueChanged<int> onRemoveStop;
  final List<RideService> services;
  final HirePlace place;
  final RegionPricing Function(RideService) pricingFor;
  final String Function(double) money;

  /// The methods offered (GET.wallet, Family, a business account; no cash).
  final List<PaymentChoice> payments;
  final String payment;
  final ValueChanged<String> onPayment;
  final Future<void> Function(MultiHireBooking b) onBook;
  final Widget? whoRiding;
  final DateTime Function() clock;

  @override
  ConsumerState<MultiHirePanel> createState() => _MultiHirePanelState();
}

class _MultiHirePanelState extends ConsumerState<MultiHirePanel> {
  late DateTime _first = defaultFirstDay(widget.clock(), widget.config.leadHours);
  late final _date = TextEditingController(text: isoDate(_first));
  late int _days = widget.config.clampDays(2);
  late double _hours = widget.config.hoursPerDayDefault;
  late bool _sameDriver = widget.config.sameDriverDefault;
  bool _overnight = false;
  String? _serviceName;

  @override
  void dispose() {
    _date.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MultiHirePanel old) {
    super.didUpdateWidget(old);
    _days = widget.config.clampDays(_days);
    _hours = widget.config.clampHours(_hours);
  }

  MultiHireQuoteArgs? _args(RideService s) {
    final p = widget.pickup;
    if (p == null) return null;
    return (
      package: widget.config.package,
      lat: p.point.latitude,
      lng: p.point.longitude,
      dropLat: widget.drop?.point.latitude,
      dropLng: widget.drop?.point.longitude,
      service: s.name,
      days: _days,
      hours: _hours,
      firstAt: _first,
      overnight: _overnight,
      country: widget.place.country,
      state: widget.place.state,
      city: widget.place.city,
      suburb: widget.place.suburb,
    );
  }

  void _setDate(DateTime? d) {
    if (d == null) return;
    setState(() => _first = DateTime(d.year, d.month, d.day, _first.hour, _first.minute));
  }

  /// The start time each day, on the pickup time sheet (its day too).
  Future<void> _pickTime() async {
    final c = widget.config;
    final at = await showPickupTimeSheet(
      context,
      ScheduledRidesConfig(enabled: true, minLeadMinutes: c.leadHours * 60, maxDaysAhead: c.bookAheadDays),
      initial: _first,
      note: 'Each day starts at this time.',
    );
    if (at == null || !mounted) return;
    setState(() {
      _first = at;
      _date.text = isoDate(at);
    });
  }

  Future<void> _pickHours() async {
    final picked = await showAppSheet<double>(
      id: 'hire.day-hours',
      context: context,
      fitContent: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('How many hours a day?', style: Theme.of(c).textTheme.titleLarge),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final h in widget.config.hourChoices)
                ListTile(
                  key: ValueKey('hire-day-hours-$h'),
                  title: Text(hireHoursText(h)),
                  trailing: h == _hours ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(c, h),
                ),
            ]),
          ),
        ]),
      ),
    );
    if (picked != null) setState(() => _hours = picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = widget.config;
    final now = widget.clock();
    final offered = <(RideService, MultiHireQuote)>[];
    var loading = false;
    for (final s in widget.services) {
      final a = _args(s);
      if (a == null) continue;
      final q = ref.watch(multiHireQuoteProvider(a));
      if (q.isLoading && !q.hasValue) loading = true;
      final v = q.value;
      if (v != null && v.dayRate != null && !{'HIRE_OFF', 'HIRE_SERVICE_OFF', 'HIRE_NO_RATE'}.contains(v.reason)) {
        offered.add((s, v));
      }
    }
    final chosen = offered.where((o) => o.$1.name == _serviceName).firstOrNull ?? offered.firstOrNull;
    final pay = paymentChoiceFor(widget.payment, widget.payments);
    final plan = pay.kind == PaymentKind.business ? HirePayPlan.business : HirePayPlan.deposit;
    final totals = chosen == null ? null : multiHireTotals(chosen.$2, widget.pricingFor(chosen.$1), plan);
    final timeProblem = c.firstDayProblem(_first, now);
    final ready = chosen != null && chosen.$2.available && timeProblem == null && widget.pickup != null;

    Widget stepper(String label, String value, {required String id, VoidCallback? minus, VoidCallback? plus,
        VoidCallback? onTap}) =>
        Row(children: [
          Expanded(child: Text(label, style: t.textTheme.titleMedium)),
          IconButton.outlined(key: ValueKey('$id-minus'), tooltip: 'Less', onPressed: minus, icon: const Icon(Icons.remove)),
          TextButton(
            key: ValueKey(id),
            onPressed: onTap,
            child: Text(value, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          IconButton.outlined(key: ValueKey('$id-plus'), tooltip: 'More', onPressed: plus, icon: const Icon(Icons.add)),
        ]);

    return Column(
      key: ValueKey('hire-days-panel-${c.package}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Column(children: [
            ListTile(
              key: const ValueKey('hire-days-pickup'),
              leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
              title: Text(widget.pickup?.name ?? 'Set pickup'),
              subtitle: widget.pickup == null
                  ? null
                  : Text(widget.pickup!.address, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: widget.onPickup,
            ),
            const Divider(indent: 56, height: 1),
            for (final (i, s) in widget.stops.indexed) ...[
              ListTile(
                key: ValueKey('hire-days-stop-$i'),
                leading: Icon(Icons.more_vert, color: t.colorScheme.onSurfaceVariant),
                title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: 'Remove this stop',
                  icon: const Icon(Icons.close),
                  onPressed: () => widget.onRemoveStop(i),
                ),
              ),
              const Divider(indent: 56, height: 1),
            ],
            ListTile(
              key: const ValueKey('hire-days-drop'),
              leading: Icon(Icons.location_on, color: Colors.red.shade700),
              title: Text(widget.drop?.name ?? 'Where to? (optional)'),
              subtitle: widget.drop == null ? const Text('The driver stays with you all day') : null,
              trailing: widget.drop == null
                  ? null
                  : IconButton(
                      key: const ValueKey('hire-days-drop-clear'),
                      tooltip: 'No drop-off',
                      icon: const Icon(Icons.close),
                      onPressed: widget.onClearDrop,
                    ),
              onTap: widget.onDrop,
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('hire-days-add-stop'),
                onPressed: widget.onAddStop,
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const Text('Add a stop to the plan'),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        DateBoxesField(
          key: const ValueKey('hire-days-first'),
          label: 'First day',
          controller: _date,
          firstDate: DateTime(c.earliest(now).year, c.earliest(now).month, c.earliest(now).day),
          lastDate: c.latest(now),
          beforeFirstText: 'Book at least ${c.leadHours} hours ahead.',
          afterLastText: 'Book up to ${c.bookAheadDays} days ahead.',
          isRequired: true,
          onChanged: _setDate,
        ),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: Text('Starts at ${hireClock(_first)} each day', key: const ValueKey('hire-days-time-text')),
          ),
          OutlinedButton.icon(
            key: const ValueKey('hire-days-time'),
            onPressed: _pickTime,
            icon: const Icon(Icons.schedule),
            label: const Text('Start time'),
          ),
        ]),
        if (timeProblem != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(timeProblem, key: const ValueKey('hire-days-time-problem'),
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
          ),
        const SizedBox(height: 8),
        stepper(
          'How many days?',
          _days == 1 ? '1 day' : '$_days days',
          id: 'hire-days-count',
          minus: _days > 1 ? () => setState(() => _days--) : null,
          plus: _days < c.maxDays ? () => setState(() => _days++) : null,
        ),
        stepper(
          'Hours a day',
          hireHoursText(_hours),
          id: 'hire-days-hours',
          minus: _hours - 0.5 >= c.minHoursPerDay - 1e-9 ? () => setState(() => _hours = c.clampHours(_hours - 0.5)) : null,
          plus: _hours + 0.5 <= c.maxHoursPerDay + 1e-9 ? () => setState(() => _hours = c.clampHours(_hours + 0.5)) : null,
          onTap: _pickHours,
        ),
        SwitchListTile(
          key: const ValueKey('hire-days-same-driver'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Same driver every day'),
          subtitle: Text(_sameDriver
              ? 'If no one driver can take every day, we find a driver for each day.'
              : 'A driver is found for each day.'),
          value: _sameDriver,
          onChanged: (v) => setState(() => _sameDriver = v),
        ),
        CheckboxListTile(
          key: const ValueKey('hire-days-overnight'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Overnight trip'),
          subtitle: Text(chosen == null
              ? 'The driver stays away from home between the days.'
              : 'The driver stays away from home: ${widget.money(chosen.$2.overnightAllowance)} a night.'),
          value: _overnight,
          onChanged: _days > 1 ? (v) => setState(() => _overnight = v ?? false) : null,
        ),
        const SizedBox(height: 4),
        if (widget.pickup == null)
          Text('Set the pickup to see the prices.', style: t.textTheme.bodyMedium)
        else if (loading && offered.isEmpty)
          const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator())
        else if (offered.isEmpty)
          Text(
            'No vehicle can be hired by the day here yet.',
            key: const ValueKey('hire-days-none'),
            style: t.textTheme.bodyMedium,
          )
        else ...[
          for (final (s, q) in offered)
            _DayServiceCard(
              service: s,
              quote: q,
              price: widget.money(multiHireTotals(q, widget.pricingFor(s), plan).total),
              money: widget.money,
              selected: s.name == chosen?.$1.name,
              onTap: () => setState(() => _serviceName = s.name),
            ),
          if (chosen != null && !chosen.$2.available && chosen.$2.hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(chosen.$2.hint!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error)),
            ),
        ],
        const SizedBox(height: 12),
        ?widget.whoRiding,
        Row(children: [
          Tooltip(
            message: 'Payment method: ${pay.label}. Change',
            child: InkResponse(
              key: const ValueKey('hire-days-payment'),
              onTap: () async {
                final p = await showPaymentSheet(context, widget.payment, payments: widget.payments);
                if (p != null) widget.onPayment(p);
              },
              child: const SizedBox(width: 44, height: 52, child: Icon(Icons.credit_card, color: confirmAccent)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: BusyButton.filled(
              key: const ValueKey('hire-days-review'),
              style: FilledButton.styleFrom(
                backgroundColor: accentFill,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.all(16),
              ),
              onPressed: !ready
                  ? null
                  : () async {
                      final ch = chosen;
                      final planned = await showMultiHireReview(
                        context,
                        config: c,
                        quote: ch.$2,
                        pricing: widget.pricingFor(ch.$1),
                        money: widget.money,
                        service: ch.$1.name,
                        firstAt: _first,
                        sameDriver: _sameDriver,
                        business: plan == HirePayPlan.business,
                      );
                      if (planned == null || !mounted) return;
                      await widget.onBook((
                        service: ch.$1,
                        quote: ch.$2,
                        firstAt: _first,
                        days: _days,
                        hours: _hours,
                        sameDriver: _sameDriver,
                        overnight: _overnight,
                        plan: planned,
                        total: multiHireTotals(ch.$2, widget.pricingFor(ch.$1), planned).total,
                      ));
                    },
              child: Text(totals == null ? 'Review' : 'Review · ${widget.money(totals.total)}'),
            ),
          ),
        ]),
      ],
    );
  }
}

class _DayServiceCard extends StatelessWidget {
  const _DayServiceCard({
    required this.service,
    required this.quote,
    required this.price,
    required this.money,
    required this.selected,
    required this.onTap,
  });

  final RideService service;
  final MultiHireQuote quote;
  final String price;
  final String Function(double) money;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    return Card(
      key: ValueKey('hire-days-card-${service.name}'),
      margin: const EdgeInsets.only(bottom: 6),
      color: selected ? scheme.secondaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? confirmAccent : scheme.outlineVariant, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(Icons.directions_car, color: selected ? confirmAccent : scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(service.name, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                Text('${money(quote.perDay)} a day · ${quote.kmPerDay.round()} km a day', style: t.textTheme.bodySmall),
              ]),
            ),
            Text(price, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

/// The review before booking: the price line by line, what is paid now and
/// on day 1, the free-cancel time and the rates. The plan chosen, or null.
Future<HirePayPlan?> showMultiHireReview(
  BuildContext context, {
  required MultiHireConfig config,
  required MultiHireQuote quote,
  required RegionPricing pricing,
  required String Function(double) money,
  required String service,
  required DateTime firstAt,
  required bool sameDriver,
  required bool business,
}) => showAppSheet<HirePayPlan>(
  id: 'hire.days-review',
  context: context,
  isScrollControlled: true,
  fitContent: true,
  builder: (_) => MultiHireReview(
    config: config,
    quote: quote,
    pricing: pricing,
    money: money,
    service: service,
    firstAt: firstAt,
    sameDriver: sameDriver,
    business: business,
  ),
);

class MultiHireReview extends StatefulWidget {
  const MultiHireReview({
    super.key,
    required this.config,
    required this.quote,
    required this.pricing,
    required this.money,
    required this.service,
    required this.firstAt,
    required this.sameDriver,
    required this.business,
  });

  final MultiHireConfig config;
  final MultiHireQuote quote;
  final RegionPricing pricing;
  final String Function(double) money;
  final String service;
  final DateTime firstAt;
  final bool sameDriver, business;

  @override
  State<MultiHireReview> createState() => _MultiHireReviewState();
}

class _MultiHireReviewState extends State<MultiHireReview> {
  late HirePayPlan _plan = widget.business ? HirePayPlan.business : HirePayPlan.deposit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = widget.quote;
    final c = widget.config;
    final money = widget.money;
    final x = multiHireTotals(q, widget.pricing, _plan);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final until = hireFreeCancelUntil(widget.firstAt, c.freeCancelHours);
    Widget row(String label, double amount, {bool bold = false, Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(label, style: bold ? t.textTheme.titleSmall : t.textTheme.bodyMedium)),
        Text(money(amount), style: bold ? t.textTheme.titleSmall : t.textTheme.bodyMedium),
      ]),
    );
    final dates = hireDailyDates(widget.firstAt, q.days);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          key: const ValueKey('hire-days-review-sheet'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Review your ${c.title.toLowerCase()}', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${widget.service} · ${hireBookingSpan(widget.firstAt, q.days, q.hours)}', style: muted),
            Text(
              'First day ${formatDateForUser(widget.firstAt)}, last day ${formatDateForUser(dates.last)}',
              key: const ValueKey('hire-review-dates'),
              style: muted,
            ),
            if (widget.sameDriver) Text('The same driver every day.', style: muted),
            const Divider(height: 20),
            row('${q.days == 1 ? '1 day' : '${q.days} days'} × ${money(q.perDay)}', x.base, key: const ValueKey('hire-review-base')),
            for (final f in q.placeFees) row('${f.name} × ${q.days}', f.amount * q.days),
            if (q.mealAllowance > 0) row('Driver meal allowance × ${q.days}', q.mealAllowance * q.days),
            if (q.nights > 0) row('Overnight allowance × ${q.nights}', q.overnightAllowance * q.nights),
            for (final e in x.lines.entries) row(e.key, e.value),
            const Divider(height: 12),
            row('Total', x.total, bold: true, key: const ValueKey('hire-review-total')),
            if (_plan != HirePayPlan.business) ...[
              row(_plan == HirePayPlan.prepay ? 'Paid now' : 'Deposit now (${_plain(q.depositPercent)}%)', x.payNow,
                  key: const ValueKey('hire-review-now')),
              if (_plan == HirePayPlan.deposit) row('On day 1', x.balance, key: const ValueKey('hire-review-balance')),
            ] else
              Text('Charged to the business account as each day ends.', style: muted),
            const SizedBox(height: 8),
            Text(
              'Free cancellation until ${formatDateForUser(until)}, ${hireClock(until)}. ${hireLateCancelText(c)}',
              key: const ValueKey('hire-review-cancel'),
              style: muted,
            ),
            Text(
              '${q.kmPerDay.round()} km a day included. Overtime ${money(q.overtimePerHour)} / hr, '
              'extra km ${money(q.extraKm)} / km, fuel included. Tolls and parking are added as declared.',
              key: const ValueKey('hire-review-rates'),
              style: muted,
            ),
            if (!widget.business && q.allowPrepay && c.allowPrepay) ...[
              const SizedBox(height: 12),
              SegmentedButton<HirePayPlan>(
                key: const ValueKey('hire-review-plan'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: HirePayPlan.deposit, label: Text('Pay the deposit')),
                  ButtonSegment(value: HirePayPlan.prepay, label: Text('Pay it all now')),
                ],
                selected: {_plan},
                onSelectionChanged: (v) => setState(() => _plan = v.first),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('hire-review-book'),
              style: FilledButton.styleFrom(backgroundColor: accentFill, foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(16)),
              onPressed: () => Navigator.pop(context, _plan),
              child: Text(_plan == HirePayPlan.business ? 'Book' : 'Book · pay ${money(x.payNow)} now'),
            ),
          ],
        ),
      ),
    );
  }
}

String _plain(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// The rider's booking on Scheduled rides: its days, what was paid, cancel.
class HireBookingCard extends ConsumerWidget {
  const HireBookingCard({super.key, required this.booking, required this.money, this.days = const []});

  final HireDaysBooking booking;
  final String Function(double) money;

  /// The booking's days: number, pickup time, a status line.
  final List<({int day, DateTime at, String status})> days;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(hourlyHireRepositoryProvider);
    try {
      final terms = await repo.cancelQuote(booking.id);
      if (!context.mounted) return;
      final ok = await showAppDialog<bool>(
        id: 'hire.booking-cancel',
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Cancel your ${booking.title.toLowerCase()}?'),
          content: Text(
            terms.started
                ? 'The days still to come are cancelled. ${money(terms.refund)} comes back to your GET.wallet.'
                : terms.free
                ? 'It is free to cancel now. ${money(terms.refund)} comes back to your GET.wallet.'
                : '${money(terms.fee)} is kept for cancelling late. ${money(terms.refund)} comes back to your GET.wallet.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
            FilledButton(
              key: const ValueKey('hire-booking-cancel-ok'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Cancel the hire'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await repo.cancelBooking(booking.id);
      ref.invalidate(myHireBookingsProvider);
      if (context.mounted) showInfo(context, 'Your hire is cancelled.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final b = booking;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Card(
      key: ValueKey('hire-booking-${b.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(b.title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Text(money(b.price), style: t.textTheme.titleSmall),
          ]),
          Text('${b.service} · ${hireBookingSpan(b.firstAt, b.days, b.hoursPerDay)}', style: muted),
          const SizedBox(height: 4),
          Text(b.statusLabel, key: ValueKey('hire-booking-status-${b.id}'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary)),
          Text(b.paymentText(money), style: muted),
          if (b.pickupAddress != null) Text('From ${b.pickupAddress}', maxLines: 2, overflow: TextOverflow.ellipsis),
          for (final d in days)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${hireDayText(d.day, b.days)} · ${hireDate(d.at)}, ${hireClock(d.at)} · ${d.status}',
                key: ValueKey('hire-booking-day-${b.id}-${d.day}'),
                style: t.textTheme.bodySmall,
              ),
            ),
          if (b.open)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: ValueKey('hire-booking-cancel-${b.id}'),
                onPressed: () => _cancel(context, ref),
                child: const Text('Cancel the hire'),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A booking a driver can take for all its days.
class OpenHireBookingCard extends ConsumerWidget {
  const OpenHireBookingCard({super.key, required this.booking, required this.money});

  final OpenHireBooking booking;
  final String Function(double) money;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final b = booking;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Card(
      key: ValueKey('open-hire-booking-${b.id}'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: t.colorScheme.primary),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text('${b.title} · ${b.days == 1 ? '1 day' : '${b.days} days'}',
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Text(money(b.fare), style: t.textTheme.titleSmall),
          ]),
          Text(
            '${b.service} · ${hireHoursText(b.hoursPerDay)} a day'
            '${b.kmPerDay == null ? '' : ' · ${b.kmPerDay!.round()} km a day'}'
            '${b.overnight ? ' · overnight' : ''}',
            style: muted,
          ),
          const SizedBox(height: 4),
          for (final d in b.dayList)
            Text('${hireDayText(d.day, b.days)} · ${hireDate(d.at)}, ${hireClock(d.at)} · ${money(d.fare)}',
                key: ValueKey('open-hire-day-${b.id}-${d.day}'), style: t.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text('From ${b.pickupAddress ?? 'pickup'}', maxLines: 2, overflow: TextOverflow.ellipsis),
          if (b.dropAddress != null) Text('To ${b.dropAddress}', maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: BusyButton.filled(
              key: ValueKey('open-hire-accept-${b.id}'),
              onPressed: () async {
                try {
                  await ref.read(hourlyHireRepositoryProvider).acceptBooking(b.id);
                  ref.invalidate(openHireBookingsProvider);
                  if (context.mounted) {
                    showInfo(context, 'Every day is yours, from ${hireDate(b.firstAt)}. The passenger is told.');
                  }
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: const Text('Take every day'),
            ),
          ),
        ]),
      ),
    );
  }
}
