// City to City for drivers, one trip (migration 0308):
//
//   An open request   the trip in full (only the areas when the driver may
//                     not take it, with what is missing), the rider, the
//                     fare and the range, what the driver keeps; Make offer
//                     (the sheet: a price within the range, or the fixed
//                     fare, and a time within the rider's window) or Accept
//                     at the rider's fare; Change or Withdraw an offer sent.
//   Booked            the steps on the day through c2c_driver_progress: On my
//                     way, Rider picked up, Complete trip (the commission is
//                     charged then); Navigate, Call (c2c_contact) and Chat
//                     (the in-app ride chat, 0308);
//                     Give up trip before the time to leave (it goes back to
//                     open for other drivers, c2c_driver_cancel), with the
//                     region's give-up fee said first (0309); how the trip is
//                     paid ("Paid in app, held"), and a cancel fee the rider
//                     owes to collect in cash, marked Collected (0309).
//   Done, or gone     what the driver kept; or that the request is no
//                     longer open.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../family/family_trip_parts.dart' show DriverChildCheck;
import '../../core/city_to_city.dart';
import '../../core/navigation_app.dart' show navigationUri;
import '../../data/city_to_city_repository.dart';
import '../../providers.dart' show currentUserIdProvider, navigationAppProvider;
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show AsyncView, EmptyState, showError, showInfo;
import '../../widgets/date_boxes.dart';
import '../../widgets/page_style_host.dart';
import '../ride/city_to_city_parts.dart';
import '../ride/city_to_city_steps.dart' show c2cClockProvider;
import '../ride/city_to_city_trip.dart' show c2cLauncherProvider, openC2cChat;
import 'city_to_city_driver_screen.dart' show acceptC2cFare, makeC2cOffer, withdrawC2cOffer;

/// Opens request or trip [id].
Future<void> openC2cDriverTrip(BuildContext context, String id) => Navigator.of(context)
    .push<void>(AppPageRoute(id: 'driver.city-to-city-trip', builder: (_) => C2cDriverTripScreen(bookingId: id)));

void _refresh(WidgetRef ref, String id) {
  ref.invalidate(c2cDriverFeedProvider);
  ref.invalidate(c2cDriverTripsProvider);
  ref.invalidate(c2cBookingProvider(id));
}

class C2cDriverTripScreen extends ConsumerWidget {
  const C2cDriverTripScreen({super.key, required this.bookingId});
  final String bookingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(c2cDriverFeedProvider);
    final request = feed.value?.requests.where((r) => r.id == bookingId).firstOrNull;
    final booking = ref.watch(c2cBookingProvider(bookingId));
    final me = ref.watch(currentUserIdProvider);
    final b = booking.value;
    final mine = b != null && me != null && b.driverId == me;
    final title = request != null
        ? 'Trip request'
        : mine && b.status == C2cStatus.completed
        ? 'Trip done'
        : 'Your trip';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: request != null
            ? _RequestView(request: request, feed: feed.value!)
            : feed.isLoading && !feed.hasValue
            ? const Center(child: CircularProgressIndicator())
            : AsyncView<C2cBooking?>(
                value: booking,
                onRetry: () => ref.invalidate(c2cBookingProvider(bookingId)),
                data: (b) => b == null || me == null || b.driverId != me
                    ? const EmptyState(
                        key: ValueKey('c2c-driver-gone'),
                        icon: Icons.route,
                        title: 'This request is no longer open',
                        message: 'Another driver was picked, or the rider cancelled it.',
                      )
                    : b.status.withDriver
                    ? _BookedView(booking: b)
                    : _DoneView(booking: b),
              ),
      ),
    );
  }
}

/// The trip in a grey box: when, from, to, the size, the rider's note.
class _Summary extends StatelessWidget {
  const _Summary({required this.booking, this.full = true});
  final C2cBooking booking;

  /// The addresses; only the areas otherwise.
  final bool full;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    return C2cBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c2cLeaveText(b.leaveAt),
            style: t.textTheme.titleMedium?.copyWith(color: look.onBox, fontWeight: FontWeight.w700)),
        Text(c2cFlexText(b.leaveAt, b.flexible), style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
        const SizedBox(height: 6),
        C2cIconLine(
          icon: Icons.trip_origin,
          color: look.accent,
          text: full ? b.pickupLine : c2cAreaLine(b.pickupPlace, b.pickupName),
          style: t.textTheme.bodyMedium?.copyWith(color: look.onBox),
        ),
        C2cIconLine(
          icon: Icons.location_on,
          color: look.drop,
          text: full ? b.dropLine : c2cAreaLine(b.dropPlace, b.dropName),
          style: t.textTheme.bodyMedium?.copyWith(color: look.onBox),
        ),
        const SizedBox(height: 4),
        Text('${c2cTripLine(b.passengers, b.luggage)} · ${b.payment.label}',
            style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
        if (b.distanceKm > 0)
          Text(c2cTripSize(b.distanceKm, b.durationMin), style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
        if (b.note != null) ...[
          const SizedBox(height: 4),
          Text('Note: ${b.note}', style: t.textTheme.bodySmall?.copyWith(color: look.onBox)),
        ],
      ]),
    );
  }
}

// ---- An open request ------------------------------------------------------------------------------------

class _RequestView extends ConsumerWidget {
  const _RequestView({required this.request, required this.feed});
  final C2cRequest request;
  final C2cDriverFeed feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final r = request;
    final b = r.booking;
    final q = b.quote;
    final fixed = q?.fareMode == C2cFareMode.fixed;
    final mine = r.myOffer;
    final lock = c2cLockLine(r.eligibility);
    final years = c2cYearsLine(r.eligibility);
    final fareLine = fixed
        ? 'Fixed fare ${c2cMoney(q!.suggested, b.currency)} on this route.'
        : q?.low != null && q?.high != null
        ? 'Offer between ${c2cMoney(q!.low!, b.currency)} and ${c2cMoney(q.high!, b.currency)}.'
        : null;
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            Row(children: [
              Expanded(child: Text(b.route, style: t.textTheme.titleLarge)),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(c2cMoney(b.fare, b.currency),
                    key: const ValueKey('c2c-driver-fare'),
                    style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                Text("Rider's fare", style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
              ]),
            ]),
            const SizedBox(height: 10),
            _Summary(booking: b, full: !r.locked),
            const SizedBox(height: 10),
            Row(children: [
              C2cAvatar(initials: c2cInitials(r.riderName), size: 36),
              const SizedBox(width: 10),
              Expanded(child: Text(c2cRiderLine(r.riderName, r.riderRating), style: t.textTheme.titleSmall)),
            ]),
            const SizedBox(height: 12),
            if (lock != null)
              C2cBox(
                key: const ValueKey('c2c-driver-lock'),
                color: look.warn,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Icon(Icons.lock, color: look.onWarn),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(lock, style: t.textTheme.titleSmall?.copyWith(color: look.onWarn)),
                    ),
                  ]),
                  if (years != null) ...[
                    const SizedBox(height: 4),
                    Text(years, style: t.textTheme.bodySmall?.copyWith(color: look.onWarn)),
                  ],
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (r.eligibility.needs.isNotEmpty)
                      OutlinedButton.icon(
                        key: const ValueKey('c2c-driver-upload-permit'),
                        style: OutlinedButton.styleFrom(foregroundColor: look.onWarn),
                        onPressed: () => context.push('/drive/permits'),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Upload permit'),
                      ),
                    if (!r.eligibility.experienceOk && feed.canSetDrivingSince)
                      OutlinedButton.icon(
                        key: const ValueKey('c2c-driver-add-date'),
                        style: OutlinedButton.styleFrom(foregroundColor: look.onWarn),
                        onPressed: () => askC2cDrivingSince(context, ref),
                        icon: const Icon(Icons.event),
                        label: const Text('Add date'),
                      ),
                  ]),
                ]),
              )
            else ...[
              if (fareLine != null)
                Text(fareLine, key: const ValueKey('c2c-driver-range'), style: t.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(
                'At ${c2cKeepLine(mine?.price ?? b.fare, r.commissionRate, b.currency)}.',
                key: const ValueKey('c2c-driver-keep'),
                style: t.textTheme.bodySmall?.copyWith(color: look.muted),
              ),
              if (mine != null) ...[
                const SizedBox(height: 12),
                C2cBanner(
                  key: const ValueKey('c2c-driver-sent'),
                  icon: Icons.hourglass_top,
                  title: c2cOfferSentLine(mine.price, b.currency),
                  line: 'You can leave at ${c2cClock(mine.leaveAt)}.',
                  fill: look.chosen,
                  ink: look.onChosen,
                ),
              ],
            ],
          ],
        ),
      ),
      if (lock == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(children: [
            if (mine != null) ...[
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: BusyButton.outlined(
                    key: const ValueKey('c2c-driver-withdraw'),
                    onPressed: () => withdrawC2cOffer(context, ref, mine.id),
                    child: const Text('Withdraw offer'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: FilledButton(
                    key: const ValueKey('c2c-driver-change'),
                    onPressed: () => makeC2cOffer(context, ref, b, price: mine.price, leaveAt: mine.leaveAt),
                    child: const Text('Change offer'),
                  ),
                ),
              ),
            ] else ...[
              if (!fixed || b.flexible) ...[
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: OutlinedButton(
                      key: const ValueKey('c2c-driver-make-offer'),
                      onPressed: () => makeC2cOffer(context, ref, b),
                      child: const Text('Make offer'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: BusyButton.filled(
                    key: const ValueKey('c2c-driver-accept'),
                    style: FilledButton.styleFrom(backgroundColor: look.hero, foregroundColor: look.onHero),
                    onPressed: () => acceptC2cFare(context, ref, b),
                    child: Text('Accept ${c2cMoney(fixed ? c2cOfferStart(b) : b.fare, b.currency)}'),
                  ),
                ),
              ),
            ],
          ]),
        ),
    ]);
  }
}

/// The driver's pick in the offer sheet.
typedef C2cOfferPick = ({double price, DateTime leaveAt});

/// The offer sheet for [b]: the price (RM 5 at a time within the range; the
/// fixed fare on a fixed route) and when the driver can leave.
Future<C2cOfferPick?> showC2cOfferSheet(BuildContext context, C2cBooking b, {required double price, DateTime? leaveAt}) =>
    showAppSheet<C2cOfferPick>(
      id: 'driver.city-to-city-offer',
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => C2cOfferSheet(booking: b, price: price, leaveAt: leaveAt),
    );

class C2cOfferSheet extends StatefulWidget {
  const C2cOfferSheet({super.key, required this.booking, required this.price, this.leaveAt});
  final C2cBooking booking;
  final double price;
  final DateTime? leaveAt;

  @override
  State<C2cOfferSheet> createState() => _C2cOfferSheetState();
}

class _C2cOfferSheetState extends State<C2cOfferSheet> {
  late double _price = widget.price;
  late final List<DateTime> _times = c2cLeaveChoices(widget.booking.leaveAt, widget.booking.flexible);
  late DateTime _leave = _times.firstWhere(
    (x) => widget.leaveAt != null && x.isAtSameMomentAs(widget.leaveAt!),
    orElse: () => widget.booking.leaveAt,
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = widget.booking;
    final q = b.quote;
    final fixed = q == null || q.fareMode == C2cFareMode.fixed;
    final problem = c2cOfferPriceProblem(_price, b);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Your offer', style: t.textTheme.titleLarge),
          Text(b.route, style: t.textTheme.bodyMedium?.copyWith(color: look.muted)),
          const SizedBox(height: 14),
          Row(children: [
            if (!fixed)
              C2cRoundButton(
                key: const ValueKey('c2c-offer-down'),
                icon: Icons.remove,
                tooltip: 'Lower by ${c2cMoney(5, b.currency)}',
                onPressed: q.low == null || _price > q.low! ? () => setState(() => _price = c2cStepFare(_price, -1, q)) : null,
              ),
            Expanded(
              child: Text(c2cMoney(_price, b.currency),
                  key: const ValueKey('c2c-offer-price'),
                  textAlign: TextAlign.center,
                  style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (!fixed)
              C2cRoundButton(
                key: const ValueKey('c2c-offer-up'),
                icon: Icons.add,
                tooltip: 'Raise by ${c2cMoney(5, b.currency)}',
                filled: true,
                onPressed: q.high == null || _price < q.high! ? () => setState(() => _price = c2cStepFare(_price, 1, q)) : null,
              ),
          ]),
          const SizedBox(height: 4),
          Text(
            fixed
                ? 'This route has a fixed fare.'
                : "${c2cOfferDiff(_price, b.fare, b.currency)} on the rider's ${c2cMoney(b.fare, b.currency)}",
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: look.muted),
          ),
          if (problem != null) ...[
            const SizedBox(height: 4),
            Text(problem, textAlign: TextAlign.center, style: t.textTheme.bodySmall?.copyWith(color: look.drop)),
          ],
          const SizedBox(height: 16),
          Text('When can you leave?', style: t.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final x in _times)
              ChoiceChip(
                key: ValueKey('c2c-offer-time-${c2cClock(x)}'),
                label: Text(c2cClock(x)),
                selected: x.isAtSameMomentAs(_leave),
                onSelected: (_) => setState(() => _leave = x),
              ),
          ]),
          const SizedBox(height: 4),
          Text(
            b.flexible ? 'The rider is fine with 30 minutes either side.' : 'The rider needs this exact time.',
            style: t.textTheme.bodySmall?.copyWith(color: look.muted),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: FilledButton(
              key: const ValueKey('c2c-offer-send'),
              onPressed: problem != null ? null : () => Navigator.pop<C2cOfferPick>(context, (price: _price, leaveAt: _leave)),
              child: Text('Send offer ${c2cMoney(_price, b.currency)}'),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Asks when the driver's licence was first issued and sends it (once).
Future<void> askC2cDrivingSince(BuildContext context, WidgetRef ref) async {
  final since = await showAppDialog<DateTime>(
    id: 'driver.city-to-city-driving-since',
    context: context,
    builder: (_) => const _DrivingSinceDialog(),
  );
  if (since == null || !context.mounted) return;
  try {
    await ref.read(cityToCityRepositoryProvider).setDrivingSince(since);
    ref.invalidate(c2cDriverFeedProvider);
    if (context.mounted) showInfo(context, 'Saved. Routes that need more years of driving open as you reach them.');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class _DrivingSinceDialog extends StatefulWidget {
  const _DrivingSinceDialog();

  @override
  State<_DrivingSinceDialog> createState() => _DrivingSinceDialogState();
}

class _DrivingSinceDialogState extends State<_DrivingSinceDialog> {
  DateTime? _date;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    return AlertDialog(
      title: const Text('When did you start driving?'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('The date your driving licence was first issued. You can set it once; support can change it.'),
        const SizedBox(height: 12),
        DateBoxesField(
          key: const ValueKey('c2c-driving-since'),
          label: 'Licence first issued',
          firstDate: DateTime(1930),
          lastDate: today,
          afterLastText: "The date can't be in the future",
          isRequired: true,
          onChanged: (d) => setState(() => _date = d),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
        FilledButton(
          key: const ValueKey('c2c-driving-since-save'),
          onPressed: _date == null || _date!.isAfter(today) ? null : () => Navigator.pop(context, _date),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---- Booked: the day ------------------------------------------------------------------------------------

class _BookedView extends ConsumerWidget {
  const _BookedView({required this.booking});
  final C2cBooking booking;

  Future<void> _contact(BuildContext context, WidgetRef ref, String scheme) async {
    try {
      final c = await ref.read(cityToCityRepositoryProvider).contact(booking.id);
      final phone = c?.phone;
      if (!context.mounted) return;
      if (phone == null) return showInfo(context, "The rider's phone number isn't available.");
      await ref.read(c2cLauncherProvider)(Uri(scheme: scheme, path: phone));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _navigate(WidgetRef ref, double lat, double lng) =>
      ref.read(c2cLauncherProvider)(navigationUri(ref.read(navigationAppProvider), lat, lng));

  Future<void> _step(BuildContext context, WidgetRef ref, C2cStatus to) async {
    if (to == C2cStatus.completed) {
      final ok = await showAppDialog<bool>(
        id: 'driver.city-to-city-complete',
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Complete this trip?'),
          content: Text(booking.payment == C2cPayment.cash
              ? 'Collect ${c2cMoney(booking.price, booking.currency)} in cash from the rider first.'
              : 'The rider is at the drop-off.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not yet')),
            FilledButton(
              key: const ValueKey('c2c-driver-complete-confirm'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Complete trip'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    try {
      await ref.read(cityToCityRepositoryProvider).driverProgress(booking.id, to);
      _refresh(ref, booking.id);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _collected(BuildContext context, WidgetRef ref) async {
    try {
      final v = await ref.read(cityToCityRepositoryProvider).markCollected(booking.id);
      _refresh(ref, booking.id);
      if (context.mounted) {
        showInfo(context, v > 0
            ? 'Marked collected: ${c2cMoney(v, booking.currency)} is charged to your GET.credit, as you hold it in cash.'
            : 'Nothing left to collect: the rider has already paid it.');
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _giveUp(BuildContext context, WidgetRef ref, C2cGiveUpRule? rule) async {
    final now = ref.read(c2cClockProvider)();
    final fee = c2cGiveUpFee(rule, booking.leaveAt, now).fee;
    final why = await showAppDialog<String>(
      id: 'driver.city-to-city-cancel',
      context: context,
      builder: (_) => _GiveUpDialog(
        feeLine: fee > 0
            ? 'You pay ${c2cMoney(fee, booking.currency)} from your GET wallet for giving it up now.'
            : 'There is no fee.',
      ),
    );
    if (why == null || !context.mounted) return;
    try {
      await ref.read(cityToCityRepositoryProvider).driverCancel(booking.id, reason: why.isEmpty ? null : why);
      _refresh(ref, booking.id);
      if (!context.mounted) return;
      final nav = Navigator.of(context);
      await nav.maybePop();
      if (nav.mounted) showInfo(nav.context, 'Trip given up. The rider can pick another driver.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    final now = ref.watch(c2cClockProvider)();
    final next = c2cNextStep(b.status);
    final rules = ref.watch(c2cGiveUpRulesProvider).value ?? const <C2cGiveUpRule>[];
    final giveUp = c2cRegionRuleFor(rules, b.pickupPlace);
    final collect = c2cCollectLine(b);
    final (title, icon) = switch (b.status) {
      C2cStatus.driverArriving => ('On your way to the pickup', Icons.directions_car),
      C2cStatus.onTrip => ('Rider on board', Icons.route),
      _ => ('Booked', Icons.check_circle),
    };
    final goTo = b.status == C2cStatus.onTrip
        ? (b.dropLat, b.dropLng)
        : (b.pickupLat, b.pickupLng);
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            C2cBanner(
              key: const ValueKey('c2c-driver-banner'),
              icon: icon,
              title: title,
              line: 'Booking ${b.ref} · whole car · ${c2cKeepLine(b.price, b.commissionRate, b.currency)}',
              fill: look.good,
              ink: look.onGood,
            ),
            const SizedBox(height: 12),
            Text(c2cLeaveText(b.leaves), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            C2cIconLine(
              icon: Icons.trip_origin,
              color: look.accent,
              text: b.pickupLine,
              sub: 'Pickup at the address',
              style: t.textTheme.titleSmall,
            ),
            C2cIconLine(
              icon: Icons.location_on,
              color: look.drop,
              text: b.dropLine,
              sub: c2cArriveText(b.leaves, b.durationMin),
              style: t.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              '${c2cTripLine(b.passengers, b.luggage)} · ${c2cDriverPayLine(b)}',
              key: const ValueKey('c2c-driver-payment'),
              style: t.textTheme.bodySmall?.copyWith(color: look.muted),
            ),
            if (b.note != null) ...[
              const SizedBox(height: 4),
              Text('Note: ${b.note}', style: t.textTheme.bodySmall),
            ],
            if (collect != null) ...[
              const SizedBox(height: 10),
              C2cBox(
                key: const ValueKey('c2c-driver-collect'),
                color: look.warn,
                child: Row(children: [
                  Icon(Icons.receipt_long, color: look.onWarn),
                  const SizedBox(width: 8),
                  Expanded(child: Text(collect, style: t.textTheme.bodyMedium?.copyWith(color: look.onWarn))),
                  TextButton(
                    key: const ValueKey('c2c-driver-collected'),
                    style: TextButton.styleFrom(foregroundColor: look.onWarn),
                    onPressed: () => _collected(context, ref),
                    child: const Text('Collected'),
                  ),
                ]),
              ),
            ],
            // Family (0317): a child passenger's photo and pickup code before pickup.
            if (b.status != C2cStatus.onTrip) DriverChildCheck(tripId: b.id),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (goTo.$1 != null && goTo.$2 != null)
                OutlinedButton.icon(
                  key: const ValueKey('c2c-driver-navigate'),
                  onPressed: () => _navigate(ref, goTo.$1!, goTo.$2!),
                  icon: const Icon(Icons.navigation_outlined),
                  label: Text(b.status == C2cStatus.onTrip ? 'Navigate to drop-off' : 'Navigate to pickup'),
                ),
              OutlinedButton.icon(
                key: const ValueKey('c2c-driver-call'),
                onPressed: () => _contact(context, ref, 'tel'),
                icon: const Icon(Icons.call),
                label: const Text('Call'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('c2c-driver-chat'),
                onPressed: () => openC2cChat(context, b.id, driver: true),
                icon: const Icon(Icons.chat),
                label: const Text('Chat'),
              ),
            ]),
            if (c2cDriverCanCancel(b, now)) ...[
              const SizedBox(height: 16),
              Text("Can't make it?", style: t.textTheme.titleSmall),
              Text('Give the trip up before the time to leave. It goes back to drivers in the area.',
                  style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
              const SizedBox(height: 2),
              Text(c2cGiveUpLine(giveUp, b.currency),
                  key: const ValueKey('c2c-driver-give-up-rule'), style: t.textTheme.bodyMedium),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('c2c-driver-give-up'),
                  style: TextButton.styleFrom(foregroundColor: look.drop),
                  onPressed: () => _giveUp(context, ref, giveUp),
                  child: const Text('Give up trip'),
                ),
              ),
            ],
          ],
        ),
      ),
      if (next != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            height: 56,
            width: double.infinity,
            // Not a busy button: it would spin while Complete trip asks first.
            child: FilledButton(
              key: const ValueKey('c2c-driver-next'),
              onPressed: () => _step(context, ref, next.to),
              child: Text(next.label),
            ),
          ),
        ),
    ]);
  }
}

/// Give up this trip? With an optional reason; the reason ('' for none)
/// when confirmed.
class _GiveUpDialog extends StatefulWidget {
  const _GiveUpDialog({required this.feeLine});

  /// "There is no fee.", or what giving up costs now.
  final String feeLine;

  @override
  State<_GiveUpDialog> createState() => _GiveUpDialogState();
}

class _GiveUpDialogState extends State<_GiveUpDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Give up this trip?'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'The request goes back to drivers in the area so the rider can pick another, and the rider is told. '
            '${widget.feeLine}',
            key: const ValueKey('c2c-driver-cancel-fee'),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('c2c-driver-cancel-reason'),
            controller: _reason,
            maxLength: 300,
            decoration: const InputDecoration(labelText: 'Why? (optional)'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep trip')),
        FilledButton(
          key: const ValueKey('c2c-driver-cancel-confirm'),
          style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
          onPressed: () => Navigator.pop(context, _reason.text.trim()),
          child: const Text('Give up trip'),
        ),
      ],
    );
  }
}

// ---- Done ------------------------------------------------------------------------------------------------

class _DoneView extends StatelessWidget {
  const _DoneView({required this.booking});
  final C2cBooking booking;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    final done = b.status == C2cStatus.completed;
    final commission = b.commissionAmount;
    final stars = b.riderStars;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        C2cBanner(
          key: const ValueKey('c2c-driver-done'),
          icon: done ? Icons.check_circle : Icons.cancel,
          title: done ? 'Trip completed' : c2cDriverTag(b.status),
          line: done
              ? [
                  'Booking ${b.ref} · ${c2cMoney(b.price, b.currency)} '
                      '${b.payment == C2cPayment.cash ? 'in cash' : 'in the app'}',
                  if (commission != null && commission > 0)
                    'Commission ${c2cMoney(commission, b.currency)}, you keep '
                        '${c2cMoney(c2cRound2(b.price - commission), b.currency)}',
                ].join('. ')
              : 'Booking ${b.ref}',
          fill: done ? look.good : look.box,
          ink: done ? look.onGood : look.onBox,
        ),
        const SizedBox(height: 12),
        _Summary(booking: b),
        if (stars != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Text('The rider rated you', style: t.textTheme.titleSmall),
            const SizedBox(width: 8),
            for (var i = 1; i <= 5; i++) Icon(i <= stars ? Icons.star : Icons.star_border, size: 20, color: look.star),
          ]),
        ],
      ],
    );
  }
}
