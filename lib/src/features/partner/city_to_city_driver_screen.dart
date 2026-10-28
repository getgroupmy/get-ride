// City to City for drivers (migration 0308; the approved mockup's DriverTab
// board), at /drive/city-to-city, from the driver menu and the Drive card:
//
//   Requests   every open request in reach, soonest first, live. One the
//              driver may take: Offer (a price and a time, the sheet) or
//              Accept (an offer at the rider's fare and time). One they may
//              not: what is missing (permits, years of driving), with Upload
//              permit or Add date. The cards come and go with the locked
//              offer motion (lib/src/widgets/offer_motion.dart).
//   My trips   today's, later and done trips, and the offers waiting.
//   Post a trip  Post a trip (per seat, 0310) and the driver's posted trips
//                with their requests and passengers
//                (city_to_city_post_trip.dart).
//
// The trip itself (request detail, the steps on the day, Call and SMS, give
// a trip up) is city_to_city_driver_trip.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/city_to_city.dart';
import '../../core/city_to_city_seats.dart' show C2cTrip, C2cTripStatus;
import '../../data/city_to_city_repository.dart';
import '../../providers.dart' show partnerProvider;
import '../../widgets/back_or_go_button.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show AsyncView, EmptyState, showError, showInfo;
import '../../widgets/offer_motion.dart';
import '../ride/city_to_city_parts.dart';
import '../ride/city_to_city_steps.dart' show c2cClockProvider;
import 'city_to_city_driver_trip.dart';
import 'city_to_city_post_trip.dart';

/// Which tab the page opens on.
enum C2cDriverTab { requests, trips, post }

class CityToCityDriverScreen extends ConsumerStatefulWidget {
  const CityToCityDriverScreen({super.key, this.initialTab = C2cDriverTab.requests});
  final C2cDriverTab initialTab;

  @override
  ConsumerState<CityToCityDriverScreen> createState() => _CityToCityDriverScreenState();
}

class _CityToCityDriverScreenState extends ConsumerState<CityToCityDriverScreen> {
  late C2cDriverTab _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final feed = ref.watch(c2cDriverFeedProvider);
    final trips = ref.watch(c2cDriverTripsProvider).value ?? const <C2cBooking>[];
    final now = ref.watch(c2cClockProvider)();
    final requests = feed.value?.requests ?? const <C2cRequest>[];
    final groups = c2cDriverTrips(trips, now);
    final offered = [for (final r in requests) if (r.myOffer != null) r];
    final header = c2cCommissionHeader([for (final r in requests) r.commissionRate]);
    return Scaffold(
      appBar: AppBar(
        leading: const BackOrGoButton(fallback: '/drive'),
        title: const Text('City to City'),
        actions: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(header,
                    key: const ValueKey('c2c-driver-commission'),
                    style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: _Tabs(
              tab: _tab,
              tripsLabel: c2cTripsTabLabel(groups.today.length + groups.later.length + offered.length),
              seatRequests: [
                for (final x in ref.watch(c2cDriverSeatTripsProvider).value ?? const <C2cTrip>[])
                  if (x.status == C2cTripStatus.scheduled) ...x.requests,
              ].length,
              onTab: (v) => setState(() => _tab = v),
            ),
          ),
          Expanded(
            child: switch (_tab) {
              C2cDriverTab.requests => _RequestsTab(feed: feed),
              C2cDriverTab.trips => _TripsTab(groups: groups, offered: offered),
              C2cDriverTab.post => const C2cPostedTripsTab(),
            },
          ),
        ]),
      ),
    );
  }
}

void _refresh(WidgetRef ref) {
  ref.invalidate(c2cDriverFeedProvider);
  ref.invalidate(c2cDriverTripsProvider);
}

/// Requests, My trips, Post a trip: three pills, the chosen one dark.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.tab, required this.tripsLabel, required this.onTab, this.seatRequests = 0});
  final C2cDriverTab tab;
  final String tripsLabel;

  /// Seat requests waiting on the driver's posted trips.
  final int seatRequests;
  final ValueChanged<C2cDriverTab> onTab;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    Widget pill(C2cDriverTab v, String label, {String? sub}) {
      final on = v == tab;
      final ink = on ? look.onHero : look.onBox;
      return Expanded(
        child: Semantics(
          selected: on,
          button: true,
          child: Material(
            color: on ? look.hero : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              key: ValueKey('c2c-driver-tab-${v.name}'),
              borderRadius: BorderRadius.circular(20),
              onTap: () => onTab(v),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(label,
                          textAlign: TextAlign.center,
                          style: t.textTheme.labelLarge?.copyWith(color: ink, fontWeight: FontWeight.w500)),
                      if (sub != null)
                        Text(sub, style: t.textTheme.labelSmall?.copyWith(color: ink, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: look.box, borderRadius: BorderRadius.circular(24)),
      child: Row(children: [
        pill(C2cDriverTab.requests, 'Requests'),
        const SizedBox(width: 4),
        pill(C2cDriverTab.trips, tripsLabel),
        const SizedBox(width: 4),
        pill(C2cDriverTab.post, 'Post a trip',
            sub: seatRequests == 0 ? null : '$seatRequests ${seatRequests == 1 ? 'request' : 'requests'}'),
      ]),
    );
  }
}

// ---- Requests ----------------------------------------------------------------------------------------

class _RequestsTab extends ConsumerWidget {
  const _RequestsTab({required this.feed});
  final AsyncValue<C2cDriverFeed> feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    return RefreshIndicator(
      onRefresh: () async => _refresh(ref),
      child: AsyncView<C2cDriverFeed>(
        value: feed,
        onRetry: () => ref.invalidate(c2cDriverFeedProvider),
        data: (f) {
          final block = c2cDriverBlock(f);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              if (block != null)
                EmptyState(
                  key: const ValueKey('c2c-driver-blocked'),
                  icon: Icons.lock_outline,
                  title: "You can't take City to City trips yet",
                  message: block,
                )
              else ...[
                if (f.canSetDrivingSince) ...[
                  const _DrivingSinceCard(),
                  const SizedBox(height: 10),
                ],
                Row(children: [
                  Icon(Icons.check_circle, size: 18, color: look.onGood),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Skip any request: no penalty',
                        style: t.textTheme.bodySmall?.copyWith(color: look.onGood)),
                  ),
                ]),
                const SizedBox(height: 10),
                if (f.requests.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: EmptyState(
                      key: const ValueKey('c2c-driver-no-requests'),
                      icon: Icons.route,
                      title: 'No City to City requests right now',
                      message: 'Requests from your service area show here as riders send them.',
                    ),
                  ),
                // Kept mounted while empty, so the last card still slides out.
                OfferMotionList(
                  gap: 10,
                  children: [
                    for (final r in f.requests)
                      C2cRequestCard(key: ValueKey('c2c-request-motion-${r.id}'), request: r, feed: f),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Opens Upload permit (the driver's permits page).
void _openPermits(BuildContext context) => context.push('/drive/permits');

/// One request: the route, when and how many, from and to, the rider's fare
/// and the rider; then Offer and Accept, what is missing, or the offer sent.
class C2cRequestCard extends ConsumerWidget {
  const C2cRequestCard({super.key, required this.request, required this.feed});
  final C2cRequest request;
  final C2cDriverFeed feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final r = request;
    final b = r.booking;
    final fixed = b.quote?.fareMode == C2cFareMode.fixed;
    final start = c2cOfferStart(b);
    final mine = r.myOffer;
    final lock = c2cLockLine(r.eligibility);
    return Material(
      key: ValueKey('c2c-request-${r.id}'),
      color: r.locked ? look.box : t.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: look.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => openC2cDriverTrip(context, r.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _RouteTitle(booking: b),
                  const SizedBox(height: 2),
                  Text(c2cRequestWhen(b), style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
                  const SizedBox(height: 2),
                  _SmallLine(icon: Icons.trip_origin, color: look.accent, text: 'Pickup: ${c2cAreaLine(b.pickupPlace, b.pickupName)}'),
                  _SmallLine(icon: Icons.location_on, color: look.drop, text: 'Drop-off: ${c2cAreaLine(b.dropPlace, b.dropName)}'),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(c2cMoney(b.fare, b.currency),
                    style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                Text(c2cRiderLine(r.riderName, r.riderRating),
                    style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
              ]),
            ]),
            const SizedBox(height: 10),
            if (lock != null)
              Row(children: [
                Icon(Icons.lock, size: 20, color: look.mutedOnBox),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(lock,
                      key: ValueKey('c2c-request-lock-${r.id}'),
                      style: t.textTheme.bodyMedium?.copyWith(color: look.mutedOnBox, fontWeight: FontWeight.w500)),
                ),
                const SizedBox(width: 8),
                if (r.eligibility.needs.isNotEmpty)
                  OutlinedButton.icon(
                    key: ValueKey('c2c-upload-permit-${r.id}'),
                    onPressed: () => _openPermits(context),
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Upload permit'),
                  )
                else if (!r.eligibility.experienceOk && feed.canSetDrivingSince)
                  OutlinedButton.icon(
                    key: ValueKey('c2c-add-driving-since-${r.id}'),
                    onPressed: () => askC2cDrivingSince(context, ref),
                    icon: const Icon(Icons.event),
                    label: const Text('Add date'),
                  ),
              ])
            else if (mine != null)
              Row(children: [
                Icon(Icons.hourglass_top, size: 20, color: look.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(c2cOfferSentLine(mine.price, b.currency),
                      key: ValueKey('c2c-request-sent-${r.id}'),
                      style: t.textTheme.bodyMedium?.copyWith(color: look.accent, fontWeight: FontWeight.w500)),
                ),
                BusyButton.text(
                  key: ValueKey('c2c-withdraw-${r.id}'),
                  onPressed: () => withdrawC2cOffer(context, ref, mine.id),
                  child: const Text('Withdraw'),
                ),
              ])
            else
              Row(children: [
                if (!fixed || b.flexible) ...[
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        key: ValueKey('c2c-offer-${r.id}'),
                        onPressed: () => makeC2cOffer(context, ref, b, price: start),
                        child: Text(fixed ? 'Pick a time' : 'Offer ${c2cMoney(start, b.currency)}'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: BusyButton.filled(
                      key: ValueKey('c2c-accept-${r.id}'),
                      style: FilledButton.styleFrom(backgroundColor: look.hero, foregroundColor: look.onHero),
                      onPressed: () => acceptC2cFare(context, ref, b),
                      child: Text('Accept ${c2cMoney(fixed ? start : b.fare, b.currency)}'),
                    ),
                  ),
                ),
              ]),
          ]),
        ),
      ),
    );
  }
}

/// "Kuala Lumpur", an arrow, "Ipoh".
class _RouteTitle extends StatelessWidget {
  const _RouteTitle({required this.booking});
  final C2cBooking booking;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    final style = t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
      Text(b.pickupPlace.city ?? b.pickupPlace.state ?? b.pickupName, style: style),
      Icon(Icons.arrow_forward, size: 18, color: look.muted, semanticLabel: 'to'),
      Text(b.dropPlace.city ?? b.dropPlace.state ?? b.dropName, style: style),
    ]);
  }
}

class _SmallLine extends StatelessWidget {
  const _SmallLine({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Expanded(child: Text(text, style: t.textTheme.bodySmall)),
      ]),
    );
  }
}

/// While the server knows no driving start date: ask for it once.
class _DrivingSinceCard extends ConsumerWidget {
  const _DrivingSinceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    return C2cBox(
      key: const ValueKey('c2c-driving-since-card'),
      color: look.warn,
      child: Row(children: [
        Icon(Icons.badge_outlined, color: look.onWarn),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Most routes need a few years of driving. Add when your licence was first issued.',
              style: t.textTheme.bodySmall?.copyWith(color: look.onWarn)),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: const ValueKey('c2c-driving-since-open'),
          style: TextButton.styleFrom(foregroundColor: look.onWarn),
          onPressed: () => askC2cDrivingSince(context, ref),
          child: const Text('Add date'),
        ),
      ]),
    );
  }
}

// ---- Actions shared with the trip page ---------------------------------------------------------------

/// Opens the offer sheet for [b] at [price] and sends what the driver picks.
Future<void> makeC2cOffer(BuildContext context, WidgetRef ref, C2cBooking b, {double? price, DateTime? leaveAt}) async {
  final pick = await showC2cOfferSheet(context, b, price: price ?? c2cOfferStart(b), leaveAt: leaveAt);
  if (pick == null || !context.mounted) return;
  try {
    await ref.read(cityToCityRepositoryProvider).makeOffer(b.id, pick.price, leaveAt: pick.leaveAt);
    _refresh(ref);
    if (context.mounted) showInfo(context, c2cOfferSentLine(pick.price, b.currency));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// An offer at the rider's fare (the fixed fare on a fixed route) and time.
Future<void> acceptC2cFare(BuildContext context, WidgetRef ref, C2cBooking b) async {
  final fixed = b.quote?.fareMode == C2cFareMode.fixed;
  final price = fixed ? c2cOfferStart(b) : b.fare;
  try {
    await ref.read(cityToCityRepositoryProvider).makeOffer(b.id, price);
    _refresh(ref);
    if (context.mounted) showInfo(context, c2cOfferSentLine(price, b.currency));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Takes back the driver's open offer [offerId].
Future<void> withdrawC2cOffer(BuildContext context, WidgetRef ref, String offerId) async {
  try {
    await ref.read(cityToCityRepositoryProvider).withdrawOffer(offerId);
    _refresh(ref);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

// ---- My trips ----------------------------------------------------------------------------------------

class _TripsTab extends ConsumerWidget {
  const _TripsTab({required this.groups, required this.offered});
  final ({List<C2cBooking> today, List<C2cBooking> later, List<C2cBooking> done}) groups;
  final List<C2cRequest> offered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final g = groups;
    Widget heading(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
      child: Text(s, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
    );
    final empty = g.today.isEmpty && g.later.isEmpty && g.done.isEmpty && offered.isEmpty;
    return RefreshIndicator(
      onRefresh: () async => _refresh(ref),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          if (empty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: EmptyState(
                key: ValueKey('c2c-driver-no-trips'),
                icon: Icons.event_outlined,
                title: 'No City to City trips yet',
                message: 'Offer on a request. When the rider picks you, the trip shows here.',
              ),
            ),
          if (g.today.isNotEmpty) ...[
            heading('Today'),
            for (final b in g.today) _TripRow(booking: b),
          ],
          if (g.later.isNotEmpty) ...[
            heading('Booked'),
            for (final b in g.later) _TripRow(booking: b),
          ],
          if (offered.isNotEmpty) ...[
            heading('Offered'),
            for (final r in offered)
              _TripRow(
                booking: r.booking,
                tag: 'Offered',
                when: c2cRequestWhen(r.booking),
                money: c2cKeepLine(r.myOffer!.price, r.commissionRate, r.booking.currency),
              ),
          ],
          if (g.done.isNotEmpty) ...[
            heading('Done'),
            for (final b in g.done) _TripRow(booking: b),
          ],
          if (!empty) ...[
            const SizedBox(height: 8),
            Text('Riders see your car and plate once booked.',
                style: t.textTheme.bodySmall?.copyWith(color: look.muted)),
          ],
        ],
      ),
    );
  }
}

class _TripRow extends StatelessWidget {
  const _TripRow({required this.booking, this.tag, this.when, this.money});
  final C2cBooking booking;
  final String? tag, when, money;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = C2cLook.of(context);
    final b = booking;
    final label = tag ?? c2cDriverTag(b.status);
    final good = b.status.withDriver || b.status == C2cStatus.completed;
    final (fill, ink) = tag != null
        ? (look.chosen, look.onChosen)
        : good
        ? (look.good, look.onGood)
        : (look.line, look.onBox);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: look.box,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: ValueKey('c2c-driver-trip-${b.id}'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => openC2cDriverTrip(context, b.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(b.route, style: t.textTheme.titleMedium?.copyWith(color: look.onBox))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
                  child: Text(label, style: t.textTheme.labelSmall?.copyWith(color: ink, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 4),
              Text(when ?? c2cBookedWhen(b), style: t.textTheme.bodySmall?.copyWith(color: look.mutedOnBox)),
              const SizedBox(height: 2),
              Text(money ?? c2cKeepLine(b.price, b.commissionRate, b.currency),
                  style: t.textTheme.bodySmall?.copyWith(color: look.onBox)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Drive: City to City, with how many requests are open and the next trip;
/// opens the page. Nothing while the service is off or before approval.
class PartnerCityToCityCard extends ConsumerWidget {
  const PartnerCityToCityCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(c2cServiceActiveProvider).value ?? false)) return const SizedBox.shrink();
    if (!(ref.watch(partnerProvider).value?.approved ?? false)) return const SizedBox.shrink();
    final t = Theme.of(context);
    final now = ref.watch(c2cClockProvider)();
    final open = [
      for (final r in ref.watch(c2cDriverFeedProvider).value?.requests ?? const <C2cRequest>[])
        if (!r.locked && r.myOffer == null) r,
    ];
    final trips = c2cDriverTrips(ref.watch(c2cDriverTripsProvider).value ?? const [], now);
    final next = [...trips.today, ...trips.later].firstOrNull;
    return Card(
      key: const ValueKey('partner-city-to-city'),
      child: ListTile(
        leading: const Icon(Icons.route),
        title: Text(
          ['City to City', if (open.isNotEmpty) '${open.length} ${open.length == 1 ? 'request' : 'requests'}'].join(' · '),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          next == null ? 'Whole-car trips to other cities' : 'Next: ${next.route}, ${c2cDayTime(next.leaves)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push(next == null ? c2cDriverRoute : '$c2cDriverRoute?tab=trips'),
      ),
    );
  }
}
