// The passenger's side of a mid-trip handover (migration 0199): approve or
// decline the driver's request, then see the new driver on their way.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/trip_handover.dart';
import '../../data/models.dart';
import '../../data/trip_handover_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

class RiderHandoverCard extends ConsumerWidget {
  const RiderHandoverCard({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ride.status != RideStatus.onTrip || ride.fromCache) return const SizedBox.shrink();
    final h = ref.watch(rideHandoverProvider(ride.id));
    final t = Theme.of(context);
    if (h != null && h.status == TripHandoverStatus.awaitingRider) {
      final on = t.colorScheme.onTertiaryContainer;
      final repo = ref.read(tripHandoverRepositoryProvider);
      Future<void> answer(bool approve) async {
        try {
          await repo.riderAnswer(h.id, approve: approve);
          ref.invalidate(rideHandoversProvider(ride.id));
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      }

      return Card(
        key: ValueKey('rider-handover-ask-${h.id}'),
        color: t.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your driver asks to hand over your trip',
                style: t.textTheme.titleSmall?.copyWith(color: on, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${_capital(h.whoTakesOver)} would meet you where the car is and take you the rest of the way. '
                'Your fare stays the same.',
                style: t.textTheme.bodyMedium?.copyWith(color: on),
              ),
              if (h.note != null)
                Text(
                  '"${h.note}"',
                  style: t.textTheme.bodySmall?.copyWith(color: on, fontStyle: FontStyle.italic),
                ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  BusyButton.text(
                    key: ValueKey('rider-handover-decline-${h.id}'),
                    onPressed: () => answer(false),
                    child: const Text('Decline'),
                  ),
                  BusyButton.filled(
                    key: ValueKey('rider-handover-approve-${h.id}'),
                    onPressed: () => answer(true),
                    child: const Text('Approve'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final String? line = switch (h?.status) {
      _ when ride.handoverMeeting =>
        '${ride.partnerName ?? 'Your new driver'} is on the way to take you the rest of the way. Stay with the car.',
      TripHandoverStatus.offered => 'Finding a driver to take over. Your driver carries on until then.',
      _ => null,
    };
    if (line == null) return const SizedBox.shrink();
    final on = t.colorScheme.onSecondaryContainer;
    return Card(
      key: const ValueKey('rider-handover-status'),
      color: t.colorScheme.secondaryContainer,
      child: ListTile(
        leading: Icon(Icons.swap_horiz, color: on),
        title: Text(line, style: TextStyle(color: on)),
      ),
    );
  }
}

String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// How often the passenger's trip screen re-reads its handovers, so a
/// driver's request is seen even when the live update doesn't come.
const riderHandoverRefresh = Duration(seconds: 10);

/// The passenger's prompt for a driver's handover request: a dialog with
/// Approve and Decline the moment one waits on them. The request is
/// re-read every [riderHandoverRefresh] while the trip is on, and at once
/// when its push reaches the open app ([pushes]), not only on a live
/// update. Builds nothing itself; [RiderHandoverCard] stays in the sheet.
class RiderHandoverPrompt extends ConsumerStatefulWidget {
  const RiderHandoverPrompt({super.key, required this.ride, this.pushes});
  final RideRequest ride;

  /// Push data reaching the open app (PushService.received).
  final Stream<Map<String, dynamic>>? pushes;

  @override
  ConsumerState<RiderHandoverPrompt> createState() => _RiderHandoverPromptState();
}

class _RiderHandoverPromptState extends ConsumerState<RiderHandoverPrompt> {
  Timer? _refresh;
  StreamSubscription<Map<String, dynamic>>? _pushes;
  final _asked = <String>{};

  bool get _onTrip => widget.ride.status == RideStatus.onTrip && !widget.ride.fromCache;

  void _reread() => ref.invalidate(rideHandoversProvider(widget.ride.id));

  @override
  void initState() {
    super.initState();
    _pushes = widget.pushes?.listen((data) {
      if (data['type'] == 'trip_handover_approval' && '${data['request_id']}' == widget.ride.id) _reread();
    });
    _sync();
  }

  @override
  void didUpdateWidget(RiderHandoverPrompt old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (_onTrip) {
      _refresh ??= Timer.periodic(riderHandoverRefresh, (_) => _reread());
    } else {
      _refresh?.cancel();
      _refresh = null;
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _pushes?.cancel();
    super.dispose();
  }

  Future<void> _ask(TripHandover h) async {
    final rideId = widget.ride.id;
    await showAppDialog<void>(id: 'rider-handover.ask',
      context: context,
      builder: (_) => _HandoverAskDialog(rideId: rideId, handoverId: h.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(rideHandoverProvider(widget.ride.id), (_, h) {
      if (!_onTrip || h == null || h.status != TripHandoverStatus.awaitingRider || !_asked.add(h.id)) return;
      unawaited(_ask(h));
    });
    return const SizedBox.shrink();
  }
}

/// The request itself; closes on its own once it is no longer waiting on
/// the passenger (answered elsewhere, withdrawn or timed out).
class _HandoverAskDialog extends ConsumerWidget {
  const _HandoverAskDialog({required this.rideId, required this.handoverId});
  final String rideId;
  final String handoverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = ref.watch(rideHandoverProvider(rideId));
    if (h == null || h.id != handoverId || h.status != TripHandoverStatus.awaitingRider) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    Future<void> answer(bool approve) async {
      try {
        await ref.read(tripHandoverRepositoryProvider).riderAnswer(h.id, approve: approve);
        ref.invalidate(rideHandoversProvider(rideId));
        if (context.mounted) Navigator.of(context).pop();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return AlertDialog(
      key: ValueKey('rider-handover-dialog-${h.id}'),
      icon: const Icon(Icons.swap_horiz),
      title: const Text('Your driver asks to hand over your trip'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_capital(h.whoTakesOver)} would meet you where the car is and take you the rest of the way. '
            'Your fare stays the same.',
          ),
          if (h.note != null) ...[
            const SizedBox(height: 8),
            Text('"${h.note}"', style: const TextStyle(fontStyle: FontStyle.italic)),
          ],
        ],
      ),
      actions: [
        BusyButton.text(
          key: ValueKey('rider-handover-dialog-decline-${h.id}'),
          onPressed: () => answer(false),
          child: const Text('Decline'),
        ),
        BusyButton.filled(
          key: ValueKey('rider-handover-dialog-approve-${h.id}'),
          onPressed: () => answer(true),
          child: const Text('Approve'),
        ),
      ],
    );
  }
}
