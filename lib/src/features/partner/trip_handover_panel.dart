// Handing a trip over mid-way (migration 0199), on the driver's trip screen:
// the driver who asks (by code, or to partners nearby), and the partner who
// takes over and meets the car.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/trip_handover.dart';
import '../../data/models.dart';
import '../../data/trip_handover_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../ride/driver_code_sheet.dart';

/// The trip went to another partner: this driver is done with it.
bool tripHandedAway(TripHandover? h) => h != null && !h.incoming && h.status == TripHandoverStatus.accepted;

/// The partner who took the trip over, on their way to the car.
bool tripHandoverMeeting(RideRequest r, TripHandover? h) => r.handoverMeeting && (h?.incoming ?? false);

/// How the driver asks: one partner by code, or the first nearby to accept.
enum HandoverAsk { code, nearby }

/// On the trip screen while the trip is on: the Hand over button, a request
/// still waiting (with Withdraw), or the new driver's meet-the-car card.
class TripHandoverPanel extends ConsumerWidget {
  const TripHandoverPanel({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ride.status != RideStatus.onTrip || ride.fromCache) return const SizedBox.shrink();
    final h = ref.watch(rideHandoverProvider(ride.id));
    if (tripHandoverMeeting(ride, h)) return _MeetCard(ride: ride, handover: h!);
    if (h != null && h.status.open && !h.incoming) return _WaitingCard(handover: h);
    final c = ref.watch(tripHandoverConfigProvider).value;
    if (c == null || !c.enabled || ride.handoverMeeting) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton.icon(
        key: const ValueKey('trip-handover'),
        icon: const Icon(Icons.swap_horiz),
        label: const Text('Hand over trip'),
        onPressed: () => _ask(context, ref, c),
      ),
    );
  }

  Future<void> _ask(BuildContext context, WidgetRef ref, TripHandoverConfig c) async {
    final choice = await showModalBottomSheet<(HandoverAsk, String)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => HandoverAskSheet(config: c),
    );
    if (choice == null || !context.mounted) return;
    final (how, note) = choice;
    String? code;
    if (how == HandoverAsk.code) {
      code = await askDriverCode(
        context,
        title: 'Hand over to a partner',
        message: "Scan their QR, or type their My Ride code. They'll be asked once the passenger approves.",
        action: 'Ask them',
      );
      if (code == null || !context.mounted) return;
    }
    try {
      await ref.read(tripHandoverRepositoryProvider).request(ride.id, code: code, note: note.isEmpty ? null : note);
      ref.invalidate(rideHandoversProvider(ride.id));
      if (context.mounted) showInfo(context, 'Asked the passenger to approve.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

/// Choosing who to ask, with a note for the passenger and the partner.
class HandoverAskSheet extends StatefulWidget {
  const HandoverAskSheet({super.key, required this.config});
  final TripHandoverConfig config;

  @override
  State<HandoverAskSheet> createState() => _HandoverAskSheetState();
}

class _HandoverAskSheetState extends State<HandoverAskSheet> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _pick(HandoverAsk how) => Navigator.pop(context, (how, _note.text.trim()));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = widget.config;
    final km = c.nearbyRadiusKm == c.nearbyRadiusKm.roundToDouble()
        ? c.nearbyRadiusKm.toStringAsFixed(0)
        : c.nearbyRadiusKm.toStringAsFixed(1);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          key: const ValueKey('handover-ask-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Hand over this trip', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'The passenger approves first. The partner who takes over meets you where the car is, '
              'collects the fare and pays the commission, and passes you a share of the net earnings '
              'as GET credit when the trip ends.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('handover-note'),
              controller: _note,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Reason (optional)', hintText: 'e.g. car trouble'),
            ),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    key: const ValueKey('handover-by-code'),
                    leading: const Icon(Icons.qr_code_scanner),
                    title: const Text('A partner I choose'),
                    subtitle: const Text('Scan their QR or enter their code'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pick(HandoverAsk.code),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    key: const ValueKey('handover-nearby'),
                    leading: const Icon(Icons.near_me_outlined),
                    title: const Text('Partners nearby'),
                    subtitle: Text('Online within $km km · the first to accept takes it'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pick(HandoverAsk.nearby),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The driver's request, still waiting for the passenger or a partner.
class _WaitingCard extends ConsumerWidget {
  const _WaitingCard({required this.handover});
  final TripHandover handover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: ValueKey('trip-handover-waiting-${handover.id}'),
      margin: const EdgeInsets.only(top: 8),
      color: t.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.hourglass_top, color: t.colorScheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    handover.driverStatusLabel,
                    style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Keep driving until another partner takes over.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSecondaryContainer),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: BusyButton.text(
                key: ValueKey('trip-handover-withdraw-${handover.id}'),
                onPressed: () async {
                  try {
                    await ref.read(tripHandoverRepositoryProvider).cancel(handover.id);
                    ref.invalidate(rideHandoversProvider(handover.rideId));
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('Withdraw'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The partner who took over: meet the car, then tell the app the
/// passenger is with them.
class _MeetCard extends ConsumerWidget {
  const _MeetCard({required this.ride, required this.handover});
  final RideRequest ride;
  final TripHandover handover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('trip-handover-meet'),
      margin: const EdgeInsets.only(top: 8),
      color: t.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Meet ${handover.fromName ?? 'the driver'} and ${ride.passengerName} where the car is',
              style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onTertiaryContainer),
            ),
            const SizedBox(height: 4),
            Text(
              'You collect the fare and pay the commission. '
              '${handover.sharePercent == null ? 'A share' : '${_pct(handover.sharePercent!)}%'} of the net '
              'goes to ${handover.fromName ?? 'them'} as GET credit when the trip ends.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onTertiaryContainer),
            ),
            const SizedBox(height: 12),
            BusyButton.filled(
              key: const ValueKey('trip-handover-boarded'),
              onPressed: () async {
                try {
                  await ref.read(tripHandoverRepositoryProvider).boarded(handover.id);
                  ref.invalidate(rideHandoversProvider(ride.id));
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: const Text('The passenger is with me'),
            ),
          ],
        ),
      ),
    );
  }
}

String _pct(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// The first driver's screen once the trip is handed over.
class HandedOverView extends StatelessWidget {
  const HandedOverView({super.key, required this.ride, required this.handover, required this.onDone});
  final RideRequest ride;
  final TripHandover handover;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      key: const ValueKey('trip-handed-over'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.handshake_outlined, size: 48, color: t.colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            'Trip handed over',
            textAlign: TextAlign.center,
            style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            '${handover.toName ?? 'Another partner'} is taking ${ride.passengerName} the rest of the way. '
            'Wait with the passenger until they arrive.',
            textAlign: TextAlign.center,
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text(
            handover.shareLabel(ride.currency),
            textAlign: TextAlign.center,
            style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const ValueKey('trip-handed-over-done'),
            onPressed: onDone,
            child: const Text('Back to requests'),
          ),
        ],
      ),
    );
  }
}

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// On the Drive screen: trips another driver asks this partner to take
/// over. The first to accept takes it, and goes straight to the trip.
class HandoverOffersCard extends ConsumerWidget {
  const HandoverOffersCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offers = ref.watch(handoverOffersProvider).value ?? const <HandoverOffer>[];
    if (offers.isEmpty) return const SizedBox.shrink();
    return Column(children: [for (final o in offers) _OfferCard(offer: o)]);
  }
}

class _OfferCard extends ConsumerWidget {
  const _OfferCard({required this.offer});
  final HandoverOffer offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final on = t.colorScheme.onTertiaryContainer;
    final repo = ref.read(tripHandoverRepositoryProvider);
    return Card(
      key: ValueKey('handover-offer-${offer.id}'),
      color: t.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.swap_horiz, color: on),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    offer.title,
                    style: t.textTheme.titleSmall?.copyWith(color: on, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (offer.dropAddress != null)
              Text(
                'To ${offer.dropAddress}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: on),
              ),
            Text(offer.terms, style: t.textTheme.bodySmall?.copyWith(color: on)),
            if (offer.note != null)
              Text(
                '"${offer.note}"',
                style: t.textTheme.bodySmall?.copyWith(color: on, fontStyle: FontStyle.italic),
              ),
            Text(
              'Meet them where the car is · answer by ${_clock(offer.answerBy)}',
              style: t.textTheme.bodySmall?.copyWith(color: on),
            ),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                BusyButton.text(
                  key: ValueKey('handover-offer-decline-${offer.id}'),
                  onPressed: () async {
                    try {
                      await repo.decline(offer.id);
                      ref.invalidate(handoverOffersProvider);
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  child: const Text('Decline'),
                ),
                BusyButton.filled(
                  key: ValueKey('handover-offer-accept-${offer.id}'),
                  onPressed: () async {
                    try {
                      await repo.accept(offer.id);
                      ref.invalidate(handoverOffersProvider);
                      if (context.mounted) context.push('/drive/trip/${offer.rideId}');
                    } catch (e) {
                      ref.invalidate(handoverOffersProvider);
                      if (context.mounted) showError(context, e);
                    }
                  },
                  child: const Text('Take over'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
