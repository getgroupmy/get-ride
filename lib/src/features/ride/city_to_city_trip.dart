// City to City, one trip (migration 0307; the approved mockup's Offers and
// Booked boards): while no driver is picked, the drivers' offers with the
// locked offer motion (lib/src/widgets/offer_motion.dart: in from the
// right, out to the left with a tilt) and Accept / Decline, Cancel request
// and Change fare; once booked, the driver, the car and plate, Call and
// Chat (the in-app ride chat, 0308), the payment and the cancel rule with Cancel booking (the fee as
// the settings say); after the trip, the fare and the rating; a cancelled
// or expired trip says so. All of it follows the rows live.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../family/family_trip_parts.dart' show FamilyTripStrip;
import '../../core/city_to_city.dart';
import '../../core/city_to_city_seats.dart' show c2cBookingKind, c2cSeatEndLine;
import '../../data/city_to_city_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show AsyncView, EmptyState, showError, showInfo;
import '../../widgets/offer_motion.dart';
import '../../widgets/page_style_host.dart';
import 'city_to_city_parts.dart';
import 'city_to_city_pay.dart';
import 'city_to_city_seats.dart' show C2cSeatDriverCard, C2cSeatRequestedView, openC2cSeatSearch;
import 'city_to_city_steps.dart' show c2cClockProvider, openC2cSteps;
import 'ride_chat_screen.dart' show RideChatScreen;

/// Opens trip [id]; [replace] swaps it for the page that opened it (the
/// steps, once the request is sent).
Future<void> openC2cTrip(BuildContext context, String id, {bool replace = false}) {
  final route = AppPageRoute<void>(id: 'ride.city-to-city-trip', builder: (_) => C2cTripScreen(bookingId: id));
  final nav = Navigator.of(context);
  return replace ? nav.pushReplacement(route) : nav.push(route);
}

/// Opens booking [bookingId]'s chat in the app (the ride chat, 0308): its
/// route where the app's router is (so a push for it while it is open is
/// not shown again), else as a page; [driver] for the driver's side.
Future<void> openC2cChat(BuildContext context, String bookingId, {bool driver = false}) async {
  final router = GoRouter.maybeOf(context);
  if (router != null) {
    final id = Uri.encodeComponent(bookingId);
    await router.push<void>(driver ? '/drive/city-to-city/$id/chat' : '/city-to-city/$id/chat');
    return;
  }
  await Navigator.of(context).push<void>(
    AppPageRoute(id: 'city-to-city.chat', builder: (_) => RideChatScreen.cityToCity(bookingId: bookingId)),
  );
}

/// Opens a phone link (tel:). Overridden in tests.
final c2cLauncherProvider = Provider<Future<bool> Function(Uri)>((_) => (u) => launchUrl(u));

class C2cTripScreen extends ConsumerWidget {
  const C2cTripScreen({super.key, required this.bookingId});
  final String bookingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booking = ref.watch(c2cBookingProvider(bookingId));
    final b = booking.value;
    final title = b == null
        ? 'City to City'
        : b.status.waiting
        ? 'Offers from drivers'
        : b.status == C2cStatus.requested
        ? 'Seat request'
        : b.status == C2cStatus.completed
        ? 'Trip done'
        : 'Your trip';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: AsyncView<C2cBooking?>(
          value: booking,
          onRetry: () => ref.invalidate(c2cBookingProvider(bookingId)),
          data: (b) => b == null
              ? const EmptyState(icon: Icons.route, title: 'Trip not found')
              : b.status.waiting
              ? _OffersView(booking: b)
              : b.status == C2cStatus.requested
              ? C2cSeatRequestedView(booking: b, onCancel: () => _cancelRequest(context, ref, b))
              : b.status.withDriver
              ? _BookedView(booking: b)
              : b.status == C2cStatus.completed
              ? _DoneView(booking: b)
              : _EndedView(booking: b),
        ),
      ),
    );
  }
}

/// Cancels seat request [b] (free: no driver has taken it yet).
Future<void> _cancelRequest(BuildContext context, WidgetRef ref, C2cBooking b) async {
  final ok = await showAppDialog<bool>(
    id: 'city-to-city.seat-request-cancel',
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Cancel this request?'),
      content: Text(b.payStatus == 'held'
          ? 'It is free. The fare held comes back to you.'
          : 'It is free. The driver is told.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep request')),
        FilledButton(
          key: const ValueKey('c2c-seat-request-cancel-confirm'),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Cancel request'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await ref.read(cityToCityRepositoryProvider).cancel(b.id);
    _refresh(ref, b.id);
    if (context.mounted) showInfo(context, 'Request cancelled.');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

void _refresh(WidgetRef ref, String id) {
  ref.invalidate(c2cBookingProvider(id));
  ref.invalidate(c2cOffersProvider(id));
  ref.invalidate(c2cMyTripsProvider);
}

/// The trip in a grey box: when, from, to, and what.
class _TripSummary extends StatelessWidget {
  const _TripSummary({required this.booking});
  final C2cBooking booking;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    return C2cBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(children: [
          TextSpan(text: c2cLeaveText(b.leaveAt), style: t.textTheme.titleMedium?.copyWith(color: look.onBox, fontWeight: FontWeight.w700)),
          if (b.flexible)
            TextSpan(text: '  (± 30 min)', style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
        ])),
        const SizedBox(height: 4),
        C2cIconLine(icon: Icons.trip_origin, color: look.accent, text: b.pickupLine),
        C2cIconLine(icon: Icons.location_on, color: look.drop, text: b.dropLine),
        const SizedBox(height: 2),
        Text.rich(TextSpan(style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox), children: [
          TextSpan(text: '${c2cTripLine(b.passengers, b.luggage)} · your fare '),
          TextSpan(
            text: c2cMoney(b.fare, b.currency),
            style: TextStyle(color: look.onBox, fontWeight: FontWeight.w700),
          ),
        ])),
      ]),
    );
  }
}

// ---- Waiting for a driver ------------------------------------------------------------------------------

class _OffersView extends ConsumerWidget {
  const _OffersView({required this.booking});
  final C2cBooking booking;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final ok = await showAppDialog<bool>(
      id: 'city-to-city.cancel-request',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this request?'),
        content: const Text('No driver is booked yet, so it is free. Drivers stop seeing it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(
            key: const ValueKey('c2c-cancel-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Cancel request'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(cityToCityRepositoryProvider).cancel(booking.id);
      _refresh(ref, booking.id);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _changeFare(BuildContext context, WidgetRef ref) async {
    final q = booking.quote;
    if (q == null) return;
    final fare = await showAppDialog<double>(
      id: 'city-to-city.change-fare',
      context: context,
      builder: (_) => _FareDialog(quote: q, fare: booking.fare),
    );
    if (fare == null || fare == booking.fare || !context.mounted) return;
    try {
      await ref.read(cityToCityRepositoryProvider).setFare(booking.id, fare);
      _refresh(ref, booking.id);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final offers = ref.watch(c2cOffersProvider(booking.id)).value ?? const <C2cOffer>[];
    final open = [for (final o in offers) if (o.open) o];
    final now = ref.watch(c2cClockProvider)();
    final fixed = booking.quote?.fareMode == C2cFareMode.fixed;
    return Column(children: [
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async => _refresh(ref, booking.id),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              if (booking.driverDroppedAt != null) ...[
                C2cBanner(
                  key: const ValueKey('c2c-driver-dropped'),
                  icon: Icons.info_outline,
                  title: 'Your driver had to cancel',
                  line: c2cDriverDroppedLine,
                  fill: C2cLook.of(context).warn,
                  ink: C2cLook.of(context).onWarn,
                ),
                const SizedBox(height: 12),
              ],
              _TripSummary(booking: booking),
              const SizedBox(height: 12),
              Text(c2cOffersLine(open.length, booking.expiresAt, now),
                  key: const ValueKey('c2c-offers-line'), style: t.textTheme.titleSmall),
              const SizedBox(height: 10),
              // Kept mounted while empty, so the last offer still slides out.
              OfferMotionList(
                gap: 10,
                children: [
                  for (final o in open)
                    _OfferCard(key: ValueKey('c2c-offer-motion-${o.id}'), offer: o, booking: booking),
                ],
              ),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(children: [
          Expanded(
            child: SizedBox(
              height: 52,
              child: OutlinedButton(
                key: const ValueKey('c2c-cancel-request'),
                onPressed: () => _cancel(context, ref),
                child: const Text('Cancel request'),
              ),
            ),
          ),
          if (!fixed && booking.quote != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton.tonal(
                  key: const ValueKey('c2c-change-fare'),
                  onPressed: () => _changeFare(context, ref),
                  child: const Text('Change fare'),
                ),
              ),
            ),
          ],
        ]),
      ),
    ]);
  }
}

/// One driver's offer: who, the car, when they can leave, the price, and
/// Decline / Accept.
class _OfferCard extends ConsumerWidget {
  const _OfferCard({super.key, required this.offer, required this.booking});
  final C2cOffer offer;
  final C2cBooking booking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final o = offer;
    final diff = c2cOfferDiff(o.price, booking.fare, booking.currency);
    final repo = ref.read(cityToCityRepositoryProvider);
    return Card(
      key: ValueKey('c2c-offer-${o.id}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: look.line)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            C2cAvatar(initials: o.initials),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(o.driverName, style: t.textTheme.titleSmall),
                Row(children: [
                  Icon(Icons.star, size: 16, color: look.star),
                  const SizedBox(width: 2),
                  Flexible(child: Text(o.ratingLine, style: t.textTheme.bodySmall?.copyWith(color: look.muted))),
                ]),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(c2cMoney(o.price, booking.currency), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              Text(diff, style: t.textTheme.bodySmall?.copyWith(color: diff == 'Your fare' ? look.onGood : look.muted)),
            ]),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 14, runSpacing: 4, children: [
            if (o.carLine.isNotEmpty)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.directions_car, size: 18, color: look.muted),
                const SizedBox(width: 4),
                Text(o.carLine, style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
              ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.schedule, size: 18, color: look.muted),
              const SizedBox(width: 4),
              Text('Can leave ${c2cClock(o.leaveAt)}', style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
            ]),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: BusyButton.outlined(
                key: ValueKey('c2c-decline-${o.id}'),
                onPressed: () async {
                  try {
                    await repo.declineOffer(o.id);
                    _refresh(ref, booking.id);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('Decline'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: BusyButton.filled(
                key: ValueKey('c2c-accept-${o.id}'),
                onPressed: () async {
                  // Cash, or In app paid after the trip, at once; held at
                  // booking through the pay sheet (0309).
                  final container = ProviderScope.containerOf(context);
                  await acceptC2cOffer(context, ref, booking, o, onBooked: () {
                    // The card may be gone by then (the trip was booked).
                    container.invalidate(c2cBookingProvider(booking.id));
                    container.invalidate(c2cOffersProvider(booking.id));
                    container.invalidate(c2cMyTripsProvider);
                  });
                },
                child: const Text('Accept'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// A new fare within the range, a step of RM 5 at a time.
class _FareDialog extends StatefulWidget {
  const _FareDialog({required this.quote, required this.fare});
  final C2cQuote quote;
  final double fare;

  @override
  State<_FareDialog> createState() => _FareDialogState();
}

class _FareDialogState extends State<_FareDialog> {
  late double _fare = widget.fare;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = widget.quote;
    return AlertDialog(
      title: const Text('Change your fare'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Between ${c2cMoney(q.low ?? 0, q.currency)} and ${c2cMoney(q.high ?? 0, q.currency)} on this route.'),
        const SizedBox(height: 12),
        Row(children: [
          C2cRoundButton(
            icon: Icons.remove,
            tooltip: 'Lower fare by ${c2cMoney(5, q.currency)}',
            onPressed: q.low == null || _fare > q.low! ? () => setState(() => _fare = c2cStepFare(_fare, -1, q)) : null,
          ),
          Expanded(
            child: Text(c2cMoney(_fare, q.currency),
                key: const ValueKey('c2c-new-fare'),
                textAlign: TextAlign.center,
                style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          ),
          C2cRoundButton(
            key: const ValueKey('c2c-new-fare-up'),
            icon: Icons.add,
            tooltip: 'Raise fare by ${c2cMoney(5, q.currency)}',
            filled: true,
            onPressed: q.high == null || _fare < q.high! ? () => setState(() => _fare = c2cStepFare(_fare, 1, q)) : null,
          ),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep')),
        FilledButton(
          key: const ValueKey('c2c-new-fare-save'),
          onPressed: () => Navigator.pop(context, _fare),
          child: const Text('Save fare'),
        ),
      ],
    );
  }
}

// ---- Booked -----------------------------------------------------------------------------------------

/// The accepted offer of [booking], for the driver's name, car and plate.
C2cOffer? _acceptedOf(List<C2cOffer> offers, C2cBooking booking) =>
    offers.where((o) => o.status == 'accepted' && o.driverId == booking.driverId).firstOrNull;

class _BookedView extends ConsumerWidget {
  const _BookedView({required this.booking});
  final C2cBooking booking;

  Future<void> _contact(BuildContext context, WidgetRef ref, String scheme) async {
    try {
      final c = await ref.read(cityToCityRepositoryProvider).contact(booking.id);
      final phone = c?.phone;
      if (!context.mounted) return;
      if (phone == null) return showInfo(context, "The driver's phone number isn't available yet.");
      await ref.read(c2cLauncherProvider)(Uri(scheme: scheme, path: phone));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, C2cSettings s) async {
    final now = ref.read(c2cClockProvider)();
    final fee = c2cCancelFee(s, booking.leaveAt, now, booked: booking.status.withDriver);
    final ok = await showAppDialog<bool>(
      id: 'city-to-city.cancel-booking',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this booking?'),
        content: Text(fee > 0
            ? 'It is less than ${s.cancelFreeHours} hours before you leave, so the cancel fee of '
                  '${c2cMoney(fee, s.currency)} applies. '
                  '${booking.payStatus == 'held' ? 'It is kept from the fare held; the rest comes back to you.' : 'It comes from your GET wallet and goes to the driver.'}'
            : booking.payStatus == 'held'
            ? 'It is free to cancel now. The fare held comes back to you, and the driver is told.'
            : 'It is free to cancel now. The driver is told.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep booking')),
          FilledButton(
            key: const ValueKey('c2c-cancel-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: Text(fee > 0 ? 'Cancel and pay ${c2cMoney(fee, s.currency)}' : 'Cancel booking'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final r = await ref.read(cityToCityRepositoryProvider).cancel(booking.id);
      _refresh(ref, booking.id);
      if (!context.mounted) return;
      showInfo(
        context,
        switch (r.feeStatus) {
          'charged' when booking.payStatus == 'held' =>
            'Booking cancelled. The fare held came back to you, less the ${c2cMoney(r.fee, s.currency)} cancel fee.',
          'charged' => 'Booking cancelled. ${c2cMoney(r.fee, s.currency)} was taken from your GET wallet.',
          _ when booking.payStatus == 'held' => 'Booking cancelled. The fare held came back to your wallet.',
          'due' => 'Booking cancelled. Your GET wallet was short, so the fee of ${c2cMoney(r.fee, s.currency)} is owed.',
          _ => 'Booking cancelled.',
        },
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    final s = ref.watch(c2cSettingsProvider).value ?? const C2cSettings();
    final offer = _acceptedOf(ref.watch(c2cOffersProvider(b.id)).value ?? const [], b);
    final contact = Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          key: const ValueKey('c2c-chat'),
          onPressed: () => openC2cChat(context, booking.id),
          icon: const Icon(Icons.chat),
          label: const Text('Chat'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: OutlinedButton.icon(
          key: const ValueKey('c2c-call'),
          onPressed: () => _contact(context, ref, 'tel'),
          icon: const Icon(Icons.call),
          label: const Text('Call'),
        ),
      ),
    ]);
    final (bannerTitle, bannerIcon) = switch (b.status) {
      C2cStatus.driverArriving => ('Your driver is on the way', Icons.directions_car),
      C2cStatus.onTrip => ('On the trip', Icons.route),
      _ => ('Booked', Icons.check_circle),
    };
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            C2cBanner(
              key: const ValueKey('c2c-booked-banner'),
              icon: bannerIcon,
              title: bannerTitle,
              line: 'Booking ${b.ref} · ${c2cBookingKind(b)} · ${c2cMoney(b.price, b.currency)}',
              fill: look.good,
              ink: look.onGood,
            ),
            // Family (0317): "Shared with family" and who can see, "Paid with Family".
            FamilyTripStrip(tripId: b.id, host: true),
            const SizedBox(height: 12),
            Text.rich(TextSpan(children: [
              TextSpan(text: c2cLeaveText(b.leaves), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              if (b.flexible && b.driverLeaveAt == null)
                TextSpan(text: '  (± 30 min)', style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
            ])),
            const SizedBox(height: 8),
            C2cIconLine(
              icon: Icons.trip_origin,
              color: look.accent,
              text: b.pickupLine,
              sub: !b.perSeat
                  ? 'Pickup at the address'
                  : b.pickupKind == 'door'
                  ? 'Door pickup${b.doorExtra == null ? '' : ', + ${c2cMoney(b.doorExtra!, b.currency)}'}'
                  : 'Meeting point',
              style: t.textTheme.titleSmall,
            ),
            C2cIconLine(
              icon: Icons.location_on,
              color: look.drop,
              text: b.dropLine,
              sub: c2cArriveText(b.leaves, b.durationMin),
              style: t.textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: _Tile(
                  label: 'Trip',
                  value: b.perSeat
                      ? '${c2cBookingKind(b)}${b.seatPrice == null ? '' : ' at ${c2cMoney(b.seatPrice!, b.currency)}'}'
                      : '${c2cCarLine(b.passengers)}, ${b.luggage.label.toLowerCase()}',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Tile(
                  label: 'Payment',
                  value: c2cRiderPayLabel(b),
                  icon: switch (b.payment) {
                    C2cPayment.inApp => Icons.credit_card,
                    C2cPayment.family => Icons.family_restroom,
                    C2cPayment.cash => Icons.payments,
                  },
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (b.perSeat)
              C2cSeatDriverCard(booking: b, actions: contact)
            else
            C2cBox(
              color: Colors.transparent,
              border: look.line,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  C2cAvatar(initials: offer?.initials ?? '?', size: 48),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(offer?.driverName ?? 'Your driver', style: t.textTheme.titleMedium),
                      if (offer != null)
                        Row(children: [
                          Icon(Icons.star, size: 16, color: look.star),
                          const SizedBox(width: 2),
                          Text(offer.ratingLine, style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                        ]),
                    ]),
                  ),
                ]),
                if (offer != null && offer.carLine.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  C2cIconLine(icon: Icons.directions_car, text: offer.carLine),
                ],
                const SizedBox(height: 8),
                contact,
              ]),
            ),
            const SizedBox(height: 14),
            Text('If plans change', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(c2cCancelText(s, b.leaveAt),
                key: const ValueKey('c2c-cancel-text'), style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
          ],
        ),
      ),
      if (b.status != C2cStatus.onTrip)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: OutlinedButton(
              key: const ValueKey('c2c-cancel-booking'),
              style: OutlinedButton.styleFrom(foregroundColor: look.drop, side: BorderSide(color: look.drop)),
              onPressed: () => _cancel(context, ref, s),
              child: const Text('Cancel booking'),
            ),
          ),
        ),
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, this.icon});
  final String label, value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    return C2cBox(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
        Row(children: [
          if (icon != null) ...[Icon(icon, size: 18, color: look.onBox), const SizedBox(width: 4)],
          Flexible(child: Text(value, style: t.textTheme.bodyMedium?.copyWith(color: look.onBox, fontWeight: FontWeight.w500))),
        ]),
      ]),
    );
  }
}

// ---- After the trip -----------------------------------------------------------------------------------

class _DoneView extends ConsumerStatefulWidget {
  const _DoneView({required this.booking});
  final C2cBooking booking;

  @override
  ConsumerState<_DoneView> createState() => _DoneViewState();
}

class _DoneViewState extends ConsumerState<_DoneView> {
  int _stars = 0;
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _rate() async {
    try {
      await ref.read(cityToCityRepositoryProvider).rateDriver(widget.booking.id, _stars,
          comment: _comment.text.trim().isEmpty ? null : _comment.text.trim());
      _refresh(ref, widget.booking.id);
      if (mounted) showInfo(context, 'Thank you. Your rating helps other riders.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = widget.booking;
    final offer = _acceptedOf(ref.watch(c2cOffersProvider(b.id)).value ?? const [], b);
    final rated = b.riderStars;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        C2cBanner(
          key: const ValueKey('c2c-done-banner'),
          icon: Icons.check_circle,
          title: 'You have arrived',
          line: 'Booking ${b.ref} · ${c2cMoney(b.price, b.currency)} '
              '${b.payment == C2cPayment.cash ? 'in cash' : b.unpaid ? 'to pay in the app' : 'in the app'}',
          fill: look.good,
          ink: look.onGood,
        ),
        const SizedBox(height: 12),
        if (b.unpaid) ...[
          C2cBox(
            key: const ValueKey('c2c-pay-after'),
            color: Colors.transparent,
            border: look.line,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Pay for your trip', style: t.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('In this region the fare is paid in the app after the trip: ${c2cMoney(b.price, b.currency)}.',
                  style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('c2c-pay-after-open'),
                onPressed: () async {
                  final out = await showC2cPaySheet(context, booking: b);
                  if (out != null) _refresh(ref, b.id);
                },
                child: Text('Pay ${c2cMoney(b.price, b.currency)}'),
              ),
            ]),
          ),
          const SizedBox(height: 12),
        ],
        C2cIconLine(icon: Icons.trip_origin, color: look.accent, text: b.pickupLine),
        C2cIconLine(icon: Icons.location_on, color: look.drop, text: b.dropLine),
        const SizedBox(height: 14),
        C2cBox(
          color: Colors.transparent,
          border: look.line,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              C2cAvatar(initials: offer?.initials ?? '?'),
              const SizedBox(width: 10),
              Expanded(
                child: Text(rated == null ? 'How was ${offer?.driverName ?? 'your driver'}?' : 'You rated this trip',
                    style: t.textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  key: ValueKey('c2c-star-$i'),
                  tooltip: '$i ${i == 1 ? 'star' : 'stars'}',
                  iconSize: 36,
                  onPressed: rated != null ? null : () => setState(() => _stars = i),
                  icon: Icon(
                    i <= (rated ?? _stars) ? Icons.star : Icons.star_border,
                    color: i <= (rated ?? _stars) ? look.star : look.muted,
                  ),
                ),
            ]),
            if (rated == null) ...[
              TextField(
                key: const ValueKey('c2c-rate-comment'),
                controller: _comment,
                maxLength: 500,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Anything to add? (optional)'),
              ),
              const SizedBox(height: 4),
              BusyButton.filled(
                key: const ValueKey('c2c-rate-send'),
                onPressed: _stars == 0 ? null : _rate,
                child: const Text('Send rating'),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: const ValueKey('c2c-plan-again'),
          onPressed: () => openC2cSteps(context),
          icon: const Icon(Icons.route),
          label: const Text('Plan another trip'),
        ),
      ],
    );
  }
}

// ---- Cancelled or expired -------------------------------------------------------------------------------

class _EndedView extends ConsumerWidget {
  const _EndedView({required this.booking});
  final C2cBooking booking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = C2cLook.of(context);
    final b = booking;
    final expired = b.status == C2cStatus.expired;
    final fee = b.cancelFee ?? 0;
    final seatLine = b.perSeat ? c2cSeatEndLine(b) : '';
    final line = seatLine.isNotEmpty
        ? seatLine
        : expired
        ? 'No driver took this trip before the time to leave.'
        : b.payStatus == 'refunded' && fee == 0
        ? 'Cancelled. The fare held in the app was given back.'
        : fee > 0 && b.payStatus == 'refunded'
        ? 'Cancelled. The fare held was given back, less the ${c2cMoney(fee, b.currency)} cancel fee.'
        : fee > 0
        ? (b.cancelFeeStatus == 'due'
              ? 'A cancel fee of ${c2cMoney(fee, b.currency)} is owed. Pay it in Wallet.'
              : 'A cancel fee of ${c2cMoney(fee, b.currency)} was paid from your GET wallet.')
        : b.cancelledBy == 'admin'
        ? 'Cancelled by GET.ride. No fee.'
        : 'Cancelled. No fee.';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        C2cBanner(
          key: const ValueKey('c2c-ended-banner'),
          icon: expired ? Icons.hourglass_disabled : Icons.cancel,
          title: b.status.label,
          line: line,
          fill: look.box,
          ink: look.onBox,
        ),
        const SizedBox(height: 12),
        _TripSummary(booking: b),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('c2c-plan-again'),
          onPressed: () => b.perSeat ? openC2cSeatSearch(context) : openC2cSteps(context),
          icon: const Icon(Icons.route),
          label: Text(b.perSeat ? 'Find another trip' : 'Plan the trip again'),
        ),
      ],
    );
  }
}
