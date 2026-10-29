// Hourly hire (migration 0326) in the app: the booking panel's "Go
// somewhere" / "Hire by time" switch, the hire side of the panel (hours,
// vehicles at their hourly price, the price and what isn't in it, payment,
// Now / Later), the hire on the rider's trip screen (time used, Extend, End
// hire, the driver's extension request) and on the driver's (the timer,
// Ask to extend, End hire with the km).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/fare.dart' show RideService;
import '../../core/hourly_hire.dart';
import '../../core/payment_types.dart';
import '../../core/region_pricing.dart';
import '../../data/geo_service.dart' show Place;
import '../../data/hourly_hire_repository.dart';
import '../../data/models.dart' show RideRequest;
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show showError, showInfo;
import '../../widgets/page_style_host.dart';
import 'confirm_parts.dart' show NowLaterButton, showPaymentSheet, confirmAccent, accentFill;

/// The booking panel's two sides.
class HireModeSwitch extends StatelessWidget {
  const HireModeSwitch({super.key, required this.config, required this.hire, required this.onChanged});

  final HourlyHireConfig config;
  final bool hire;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: SegmentedButton<bool>(
      key: const ValueKey('hire-mode-switch'),
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: false,
          icon: const Icon(Icons.place_outlined),
          label: Text(config.tripLabel, key: const ValueKey('hire-mode-trip'), maxLines: 1),
        ),
        ButtonSegment(
          value: true,
          icon: const Icon(Icons.schedule),
          label: Text(config.hireLabel, key: const ValueKey('hire-mode-hire'), maxLines: 1),
        ),
      ],
      selected: {hire},
      onSelectionChanged: (s) => onChanged(s.first),
    ),
  );
}

/// The hours: minus, the hours (a list on tap), plus.
class HireHoursStepper extends StatelessWidget {
  const HireHoursStepper({super.key, required this.config, required this.hours, required this.onChanged});

  final HourlyHireConfig config;
  final double hours;
  final ValueChanged<double> onChanged;

  Future<void> _pick(BuildContext context) async {
    final picked = await showAppSheet<double>(
      id: 'hire.hours',
      context: context,
      fitContent: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('How many hours?', style: Theme.of(c).textTheme.titleLarge),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final h in config.hourChoices)
                ListTile(
                  key: ValueKey('hire-hours-$h'),
                  title: Text(hireHoursText(h)),
                  trailing: h == hours ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(c, h),
                ),
            ]),
          ),
        ]),
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final canDown = hours - config.hourStep >= config.minHours - 1e-9;
    final canUp = hours + config.hourStep <= config.maxHours + 1e-9;
    return Row(children: [
      Expanded(child: Text('How long?', style: t.textTheme.titleMedium)),
      IconButton.outlined(
        key: const ValueKey('hire-hours-minus'),
        tooltip: 'Fewer hours',
        onPressed: canDown ? () => onChanged(config.clampHours(hours - config.hourStep)) : null,
        icon: const Icon(Icons.remove),
      ),
      TextButton(
        key: const ValueKey('hire-hours'),
        onPressed: () => _pick(context),
        child: Text(hireHoursText(hours), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ),
      IconButton.outlined(
        key: const ValueKey('hire-hours-plus'),
        tooltip: 'More hours',
        onPressed: canUp ? () => onChanged(config.clampHours(hours + config.hourStep)) : null,
        icon: const Icon(Icons.add),
      ),
    ]);
  }
}

/// A vehicle at its hourly price.
class HireServiceCard extends StatelessWidget {
  const HireServiceCard({
    super.key,
    required this.service,
    required this.quote,
    required this.price,
    required this.money,
    required this.selected,
    required this.onTap,
  });

  final RideService service;
  final HireQuote quote;

  /// What it comes to (the quote with the region's lines), formatted.
  final String price;
  final String Function(double) money;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    return Card(
      key: ValueKey('hire-card-${service.name}'),
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
                Text(hireRateLine(quote, money), style: t.textTheme.bodySmall),
              ]),
            ),
            Text(price, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

/// The price of the chosen hire, line by line, and what isn't in it.
class HireFareSummary extends StatelessWidget {
  const HireFareSummary({
    super.key,
    required this.quote,
    required this.regionLines,
    required this.money,
    this.wholeFare = false,
  });

  final HireQuote quote;

  /// Fares are whole amounts here: the hire price rounds up (0327).
  final bool wholeFare;

  /// The region's surcharges and taxes, as for a ride (with the place fees
  /// among the surcharges' base).
  final List<ChargeLine> regionLines;
  final String Function(double) money;

  double get total => hireTotal(quote, regionLines, wholeFare: wholeFare);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget row(String label, double amount, {bool bold = false, Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(label, style: bold ? t.textTheme.titleSmall : t.textTheme.bodyMedium)),
        Text(money(amount), style: bold ? t.textTheme.titleSmall : t.textTheme.bodyMedium),
      ]),
    );
    return Column(
      key: const ValueKey('hire-fare'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row('Hourly hire ${hireHoursText(quote.hours)}', hireBase(quote, wholeFare: wholeFare)),
        for (final f in quote.placeFees) row(f.name, f.amount),
        for (final l in regionLines) row(l.label, l.amount),
        const Divider(height: 12),
        row('Total', total, bold: true, key: const ValueKey('hire-total')),
        const SizedBox(height: 4),
        Text(
          hireTermsLine(quote, money),
          key: const ValueKey('hire-terms'),
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The hire's price: rounded up where fares are whole amounts, as a ride's
/// fare is (0327; the server stamps it so).
double hireBase(HireQuote q, {bool wholeFare = false}) => wholeFare ? (q.base - 1e-9).ceilToDouble() : q.base;

/// The quote's total with the region's lines.
double hireTotal(HireQuote q, List<ChargeLine> regionLines, {bool wholeFare = false}) =>
    ((hireBase(q, wholeFare: wholeFare) + q.placeFeesTotal + regionLines.fold(0.0, (a, l) => a + l.amount)) * 100)
        .roundToDouble() /
    100;

/// The region's lines on a hire: its surcharges and taxes, with the place
/// fees as fixed surcharges (the taxes are on them too), as the ride is stamped.
List<ChargeLine> hireRegionLines(RegionPricing pricing, HireQuote q) {
  final regionSurcharges = pricing.charges.where((c) => !c.isTax).length;
  final all = RegionPricing(
    wholeFare: pricing.wholeFare,
    tax: pricing.tax,
    charges: [
      ...pricing.charges,
      for (final f in q.placeFees) FareCharge(isTax: false, name: f.name, percent: false, value: f.amount),
    ],
  ).linesFor(hireBase(q, wholeFare: pricing.wholeFare));
  return [
    for (final (i, l) in all.indexed)
      if (l.isTax || i < regionSurcharges) l,
  ];
}

/// What a quote is asked for.
typedef HireQuoteArgs = ({
  double lat,
  double lng,
  double? dropLat,
  double? dropLng,
  String service,
  double hours,
  String? country,
  String? state,
  String? city,
  String? suburb,
});

final hireQuoteProvider = FutureProvider.autoDispose.family<HireQuote?, HireQuoteArgs>((ref, a) async {
  try {
    return await ref.watch(hourlyHireRepositoryProvider).quote(
      pickup: (lat: a.lat, lng: a.lng),
      drop: a.dropLat == null || a.dropLng == null ? null : (lat: a.dropLat!, lng: a.dropLng!),
      service: a.service,
      hours: a.hours,
      place: (country: a.country, state: a.state, city: a.city, suburb: a.suburb),
    );
  } catch (_) {
    return null;
  }
});

/// What the hire panel books.
typedef HireBooking = ({RideService service, double hours, HireQuote quote, double total});

/// The panel's "Hire by time" side.
class HireBookingPanel extends ConsumerStatefulWidget {
  const HireBookingPanel({
    super.key,
    required this.config,
    required this.pickup,
    required this.drop,
    required this.onPickup,
    required this.onDrop,
    required this.onClearDrop,
    required this.services,
    required this.place,
    required this.pricingFor,
    required this.money,
    required this.payments,
    required this.payment,
    required this.onPayment,
    required this.onBook,
    this.pickLater,
    this.whoRiding,
  });

  final HourlyHireConfig config;
  final Place? pickup;

  /// Optional for a hire: where the hire ends, if the rider knows.
  final Place? drop;
  final VoidCallback onPickup, onDrop, onClearDrop;
  final List<RideService> services;
  final HirePlace place;
  final RegionPricing Function(RideService) pricingFor;
  final String Function(double) money;

  /// The methods offered for a hire (cash left out unless the admin allows it).
  final List<PaymentChoice> payments;
  final String payment;
  final ValueChanged<String> onPayment;

  /// Books [b] now (at: null) or for later.
  final Future<void> Function(HireBooking b, DateTime? at) onBook;

  /// The pickup time sheet (Later); null when booking ahead is off.
  final Future<DateTime?> Function()? pickLater;

  /// Who's riding (book for someone else, Family).
  final Widget? whoRiding;

  @override
  ConsumerState<HireBookingPanel> createState() => _HireBookingPanelState();
}

class _HireBookingPanelState extends ConsumerState<HireBookingPanel> {
  late double _hours = widget.config.minHours;
  String? _serviceName;

  @override
  void didUpdateWidget(HireBookingPanel old) {
    super.didUpdateWidget(old);
    final h = widget.config.clampHours(_hours);
    if (h != _hours) _hours = h;
  }

  HireQuoteArgs? _args(RideService s) {
    final p = widget.pickup;
    if (p == null) return null;
    return (
      lat: p.point.latitude,
      lng: p.point.longitude,
      dropLat: widget.drop?.point.latitude,
      dropLng: widget.drop?.point.longitude,
      service: s.name,
      hours: _hours,
      country: widget.place.country,
      state: widget.place.state,
      city: widget.place.city,
      suburb: widget.place.suburb,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = widget.config;
    final offered = <(RideService, HireQuote)>[];
    var loading = false;
    for (final s in widget.services) {
      final a = _args(s);
      if (a == null) continue;
      final q = ref.watch(hireQuoteProvider(a));
      if (q.isLoading && !q.hasValue) loading = true;
      final v = q.value;
      if (v != null && v.rate != null && !{'HIRE_OFF', 'HIRE_SERVICE_OFF', 'HIRE_NO_RATE'}.contains(v.reason)) {
        offered.add((s, v));
      }
    }
    final chosen = offered.where((o) => o.$1.name == _serviceName).firstOrNull ?? offered.firstOrNull;
    final lines = chosen == null ? const <ChargeLine>[] : hireRegionLines(widget.pricingFor(chosen.$1), chosen.$2);
    final whole = chosen != null && widget.pricingFor(chosen.$1).wholeFare;
    final total = chosen == null ? 0.0 : hireTotal(chosen.$2, lines, wholeFare: whole);
    final pay = paymentChoiceFor(widget.payment, widget.payments);
    final cashRefused = pay.kind == PaymentKind.cash && !c.allowCash;
    final ready = chosen != null && chosen.$2.available && !cashRefused && widget.pickup != null;
    final label = 'Hire · ${widget.money(total)}';
    Future<void> book(DateTime? at) async {
      final ch = chosen;
      if (ch == null) return;
      await widget.onBook((service: ch.$1, hours: _hours, quote: ch.$2, total: total), at);
    }

    return Column(
      key: const ValueKey('hire-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Column(children: [
            ListTile(
              key: const ValueKey('hire-pickup'),
              leading: Icon(Icons.trip_origin, color: Colors.green.shade700),
              title: Text(widget.pickup?.name ?? 'Set pickup'),
              subtitle: widget.pickup == null
                  ? null
                  : Text(widget.pickup!.address, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: widget.onPickup,
            ),
            const Divider(indent: 56, height: 1),
            ListTile(
              key: const ValueKey('hire-drop'),
              leading: Icon(Icons.location_on, color: Colors.red.shade700),
              title: Text(widget.drop?.name ?? 'Where to? (optional)'),
              subtitle: widget.drop == null ? const Text('The driver stays with you; add a stop any time') : null,
              trailing: widget.drop == null
                  ? null
                  : IconButton(
                      key: const ValueKey('hire-drop-clear'),
                      tooltip: 'No drop-off',
                      icon: const Icon(Icons.close),
                      onPressed: widget.onClearDrop,
                    ),
              onTap: widget.onDrop,
            ),
          ]),
        ),
        const SizedBox(height: 8),
        HireHoursStepper(config: c, hours: _hours, onChanged: (h) => setState(() => _hours = h)),
        const SizedBox(height: 8),
        if (widget.pickup == null)
          Text('Set the pickup to see the prices.', style: t.textTheme.bodyMedium)
        else if (loading && offered.isEmpty)
          const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator())
        else if (offered.isEmpty)
          Text(
            'No vehicle can be hired by the hour here yet.',
            key: const ValueKey('hire-none'),
            style: t.textTheme.bodyMedium,
          )
        else ...[
          for (final (s, q) in offered)
            HireServiceCard(
              service: s,
              quote: q,
              price: widget.money(
                hireTotal(q, hireRegionLines(widget.pricingFor(s), q), wholeFare: widget.pricingFor(s).wholeFare),
              ),
              money: widget.money,
              selected: s.name == chosen?.$1.name,
              onTap: () => setState(() => _serviceName = s.name),
            ),
          if (chosen != null) ...[
            const SizedBox(height: 8),
            if (!chosen.$2.available && chosen.$2.hint != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(chosen.$2.hint!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error)),
              ),
            HireFareSummary(quote: chosen.$2, regionLines: lines, money: widget.money, wholeFare: whole),
          ],
        ],
        const SizedBox(height: 12),
        ?widget.whoRiding,
        Row(children: [
          Tooltip(
            message: 'Payment method: ${pay.label}. Change',
            child: InkResponse(
              key: const ValueKey('hire-payment'),
              onTap: () async {
                final p = await showPaymentSheet(context, widget.payment, payments: widget.payments);
                if (p != null) widget.onPayment(p);
              },
              child: SizedBox(
                width: 44,
                height: 52,
                child: Icon(
                  pay.kind == PaymentKind.cash ? Icons.payments_outlined : Icons.credit_card,
                  color: confirmAccent,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: c.allowNow && c.allowLater && widget.pickLater != null
                ? NowLaterButton(
                    label: label,
                    onNow: ready ? () => book(null) : null,
                    pickLater: ready ? widget.pickLater : null,
                    onLater: book,
                  )
                : BusyButton.filled(
                    key: const ValueKey('hire-book'),
                    style: FilledButton.styleFrom(
                      backgroundColor: accentFill,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(16),
                    ),
                    onPressed: !ready
                        ? null
                        : c.allowNow
                        ? () => book(null)
                        : widget.pickLater == null
                        ? null
                        : () async {
                            final at = await widget.pickLater!();
                            if (at != null) await book(at);
                          },
                    child: Text(c.allowNow ? label : 'Hire later · ${widget.money(total)}'),
                  ),
          ),
        ]),
        if (cashRefused)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Hourly hire is paid in the app. Choose GET.wallet.',
              key: const ValueKey('hire-cash-note'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
            ),
          )
        else if (chosen != null && pay.kind != PaymentKind.cash && chosen.$2.holdInWallet && chosen.$2.hold > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${widget.money(chosen.$2.hold)} is held in your GET.wallet until the hire ends.',
              key: const ValueKey('hire-hold-note'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

/// Ticks once a minute, for a hire's clock.
mixin _MinuteTick<T extends StatefulWidget> on State<T> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}

/// The extension choices with what each costs; the chosen minutes.
Future<int?> showHireExtendSheet(
  BuildContext context, {
  required String id,
  required RideHire hire,
  required List<int> choices,
  required String Function(double) money,
  required String title,
}) => showAppSheet<int>(
  id: id,
  context: context,
  fitContent: true,
  builder: (c) => SafeArea(
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title, style: Theme.of(c).textTheme.titleLarge),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('Overtime is ${money(hire.overtimeRate)} an hour, charged per ${hire.stepMinutes} min.'),
      ),
      for (final m in choices)
        ListTile(
          key: ValueKey('hire-extend-$m'),
          title: Text('${hireMinutesText(m)} more'),
          trailing: Text(money(hire.extensionAmount(m))),
          onTap: () => Navigator.pop(c, m),
        ),
      const SizedBox(height: 8),
    ]),
  ),
);

/// The driver asks for more time: Approve or Decline (null when closed).
Future<bool?> showHireExtendRequest(
  BuildContext context, {
  required HireExtension extension,
  required String Function(double) money,
}) => showAppDialog<bool>(
  id: 'hire.extend-request',
  context: context,
  barrierDismissible: false,
  builder: (c) => AlertDialog(
    key: const ValueKey('hire-extend-request'),
    title: const Text('Your driver asks for more time'),
    content: Text(
      '${hireMinutesText(extension.minutes)} more for ${money(extension.amount)}. '
      'It is added to the price when the hire ends.',
    ),
    actions: [
      TextButton(
        key: const ValueKey('hire-extend-decline'),
        onPressed: () => Navigator.pop(c, false),
        child: const Text('Decline'),
      ),
      FilledButton(
        key: const ValueKey('hire-extend-approve'),
        onPressed: () => Navigator.pop(c, true),
        child: const Text('Approve'),
      ),
    ],
  ),
);

/// The hire on the rider's trip screen.
class HireTripCard extends ConsumerStatefulWidget {
  const HireTripCard({super.key, required this.ride, required this.config, required this.money});

  final RideRequest ride;
  final HourlyHireConfig config;
  final String Function(double) money;

  @override
  ConsumerState<HireTripCard> createState() => _HireTripCardState();
}

class _HireTripCardState extends ConsumerState<HireTripCard> with _MinuteTick {
  String? _askedFor;

  RideHire? get _hire => RideHire.fromRow(widget.ride.raw);

  @override
  void didUpdateWidget(HireTripCard old) {
    super.didUpdateWidget(old);
    _maybeAsk();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAsk());
  }

  /// The driver's request comes up once, as a modal.
  Future<void> _maybeAsk() async {
    final p = _hire?.pending;
    if (p == null || p.askedBy != 'driver' || _askedFor == p.id || !mounted) return;
    _askedFor = p.id;
    final ok = await showHireExtendRequest(context, extension: p, money: widget.money);
    if (ok == null || !mounted) return;
    try {
      await ref.read(hourlyHireRepositoryProvider).answer(widget.ride.id, p.id, approve: ok);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _extend(RideHire h) async {
    final m = await showHireExtendSheet(
      context,
      id: 'hire.extend',
      hire: h,
      choices: widget.config.extendChoices,
      money: widget.money,
      title: 'Extend the hire',
    );
    if (m == null || !mounted) return;
    final ok = await showAppDialog<bool>(
      id: 'hire.extend-confirm',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Extend the hire?'),
        content: Text('${hireMinutesText(m)} more for ${widget.money(h.extensionAmount(m))}. '
            'It is added to the price when the hire ends.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('hire-extend-ok'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Extend'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(hourlyHireRepositoryProvider).extend(widget.ride.id, m);
      if (mounted) showInfo(context, 'The hire is ${hireMinutesText(m)} longer.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _end(RideHire h) async {
    final ok = await showAppDialog<bool>(
      id: 'hire.end',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('End the hire now?'),
        content: Text(
          '${h.isDay ? 'Ending early still pays the day.' : hireEarlyEndText(widget.config.earlyEndPays, h.minHours)} '
          'Overtime you approved and km past the ${h.kmIncluded.round()} km included are added.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          FilledButton(
            key: const ValueKey('hire-end-ok'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('End hire'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(hourlyHireRepositoryProvider).end(widget.ride.id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _hire;
    if (h == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final now = DateTime.now();
    final status = widget.ride.raw['status'];
    final onTrip = status == 'on_trip';
    final going = {'accepted', 'arrived', 'on_trip'}.contains(status);
    final pending = h.pending;
    return Card(
      key: const ValueKey('hire-trip-card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(h.heading, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          if (h.started) ...[
            Text('Time used: ${h.usedText(now)}', key: const ValueKey('hire-used')),
            if (h.endsAt != null) Text('Ends at ${hireClock(h.endsAt!)}', key: const ValueKey('hire-ends')),
          ] else
            Text('The clock starts when your trip starts. ${hireMinutesText(h.totalMinutes)} booked.'),
          if (h.kmUsed != null) Text('${h.kmUsed!.toStringAsFixed(1)} km of ${h.kmIncluded.round()} km included'),
          if (pending != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                pending.askedBy == 'driver'
                    ? 'Your driver asked for ${hireMinutesText(pending.minutes)} more.'
                    : 'Waiting for an answer on ${hireMinutesText(pending.minutes)} more.',
                style: t.textTheme.bodySmall,
              ),
            ),
          if (going) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                key: const ValueKey('hire-extend'),
                onPressed: pending == null ? () => _extend(h) : null,
                icon: const Icon(Icons.more_time),
                label: const Text('Extend'),
              ),
              if (onTrip && widget.config.riderCanEndEarly)
                OutlinedButton.icon(
                  key: const ValueKey('hire-end'),
                  onPressed: () => _end(h),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('End hire'),
                ),
            ]),
            if (pending != null && pending.askedBy == 'driver')
              TextButton(
                key: const ValueKey('hire-answer'),
                onPressed: () {
                  _askedFor = null;
                  _maybeAsk();
                },
                child: const Text('Answer your driver'),
              ),
          ],
        ]),
      ),
    );
  }
}

/// The hire on the driver's trip screen: the clock once the passenger is
/// on board, Ask to extend and End hire (with the km).
class DriverHireCard extends ConsumerStatefulWidget {
  const DriverHireCard({
    super.key,
    required this.ride,
    required this.config,
    required this.money,
    this.measuredKm,
    this.onEnded,
    this.showEnd = true,
  });

  final RideRequest ride;
  final HourlyHireConfig config;
  final String Function(double) money;

  /// Its own End hire button (off where the screen's main button ends it).
  final bool showEnd;

  /// The trip's km as the phone measured it, to start the km box from.
  final double? Function()? measuredKm;
  final VoidCallback? onEnded;

  @override
  ConsumerState<DriverHireCard> createState() => _DriverHireCardState();
}

class _DriverHireCardState extends ConsumerState<DriverHireCard> with _MinuteTick {
  RideHire? get _hire => RideHire.fromRow(widget.ride.raw);

  Future<void> _ask(RideHire h) async {
    final m = await showHireExtendSheet(
      context,
      id: 'hire.driver-extend',
      hire: h,
      choices: widget.config.extendChoices,
      money: widget.money,
      title: 'Ask the rider for more time',
    );
    if (m == null || !mounted) return;
    try {
      final e = await ref.read(hourlyHireRepositoryProvider).extend(widget.ride.id, m);
      if (mounted) {
        showInfo(
          context,
          e.approved ? 'The hire is ${hireMinutesText(m)} longer.' : 'Asked. The rider is told and answers in the app.',
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _end(RideHire h) async {
    final measured = widget.measuredKm?.call();
    final km = await showHireEndDialog(context, measuredKm: measured, kmIncluded: h.kmIncluded);
    if (km == null || !mounted) return;
    try {
      await ref.read(hourlyHireRepositoryProvider).end(widget.ride.id, kmUsed: km);
      widget.onEnded?.call();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _hire;
    if (h == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final now = DateTime.now();
    final onTrip = widget.ride.raw['status'] == 'on_trip';
    final left = h.endsAt?.difference(now);
    final nearEnd = left != null && left.inMinutes <= widget.config.reminderBeforeEndMin;
    return Card(
      key: const ValueKey('driver-hire-card'),
      color: nearEnd ? t.colorScheme.tertiaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(h.heading, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (h.started) ...[
            Text('Time used: ${h.usedText(now)}', key: const ValueKey('driver-hire-used')),
            if (h.endsAt != null) Text('Ends at ${hireClock(h.endsAt!)}'),
            if (nearEnd)
              Text(
                left.isNegative ? 'The booked time is up.' : 'Hire time nearly up.',
                key: const ValueKey('driver-hire-near-end'),
                style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
          ] else
            const Text('The clock starts when you start the trip.'),
          Text('${h.kmIncluded.round()} km included, then ${widget.money(h.extraKmRate)} / km'),
          if (h.pending case final p?)
            Text(
              p.askedBy == 'driver'
                  ? 'Waiting for the rider on ${hireMinutesText(p.minutes)} more.'
                  : 'The rider asked for ${hireMinutesText(p.minutes)} more.',
              style: t.textTheme.bodySmall,
            ),
          if (onTrip) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                key: const ValueKey('driver-hire-extend'),
                onPressed: h.pending == null ? () => _ask(h) : null,
                icon: const Icon(Icons.more_time),
                label: const Text('Ask to extend'),
              ),
              if (widget.showEnd)
                FilledButton.icon(
                key: const ValueKey('driver-hire-end'),
                onPressed: () => _end(h),
                icon: const Icon(Icons.flag),
                label: const Text('End hire'),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// The km driven, to end a hire: started from [measuredKm] when the phone
/// measured it. Null when cancelled.
Future<double?> showHireEndDialog(BuildContext context, {double? measuredKm, required double kmIncluded}) =>
    showAppDialog<double>(
      id: 'hire.driver-end',
      context: context,
      builder: (_) => _HireEndDialog(measuredKm: measuredKm, kmIncluded: kmIncluded),
    );

class _HireEndDialog extends StatefulWidget {
  const _HireEndDialog({required this.measuredKm, required this.kmIncluded});

  final double? measuredKm;
  final double kmIncluded;

  @override
  State<_HireEndDialog> createState() => _HireEndDialogState();
}

class _HireEndDialogState extends State<_HireEndDialog> {
  late final _text = TextEditingController(text: widget.measuredKm?.toStringAsFixed(1) ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final km = double.tryParse(_text.text.trim());
    final ok = km != null && km >= 0 && km <= 5000;
    return AlertDialog(
      title: const Text('End the hire'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${widget.kmIncluded.round()} km are included. Km past that are added to the price.'),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('hire-end-km'),
          controller: _text,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Km driven on this hire',
            helperText: widget.measuredKm == null ? null : 'Measured by the app',
            suffixText: 'km',
          ),
          onChanged: (_) => setState(() {}),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('hire-end-confirm'),
          onPressed: ok ? () => Navigator.pop(context, km) : null,
          child: const Text('End hire'),
        ),
      ],
    );
  }
}

/// The driver's "Take hourly hire" switch (off by default): hires are
/// offered only to drivers who turn it on. Shown while hire is on.
class TakeHourlyHireTile extends ConsumerStatefulWidget {
  const TakeHourlyHireTile({super.key});

  @override
  ConsumerState<TakeHourlyHireTile> createState() => _TakeHourlyHireTileState();
}

class _TakeHourlyHireTileState extends ConsumerState<TakeHourlyHireTile> {
  bool? _pending;

  Future<void> _set(bool on) async {
    setState(() => _pending = on);
    try {
      await ref.read(hourlyHireRepositoryProvider).setTakesHire(on);
      ref.invalidate(myTakesHireProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(hourlyHireConfigProvider).value ?? HourlyHireConfig.off;
    if (!config.enabled) return const SizedBox.shrink();
    final on = _pending ?? ref.watch(myTakesHireProvider).value ?? false;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: SwitchListTile(
        key: const ValueKey('take-hourly-hire'),
        secondary: const Icon(Icons.schedule),
        title: const Text('Take hourly hire'),
        subtitle: const Text('Riders hire you and your car by the hour, at a fixed price. You stay with them until the time is up.'),
        value: on,
        onChanged: _pending == null ? _set : null,
      ),
    );
  }
}
