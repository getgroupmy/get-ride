import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ride_bidding.dart';
import '../../data/models.dart';
import '../../data/ride_repository.dart';

/// Asks how much to counter-offer on [r]; answers the amount, or null.
Future<double?> askCounterOffer(BuildContext context, RideRequest r) => showModalBottomSheet<double>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _OfferSheet(ride: r),
);

class _OfferSheet extends StatefulWidget {
  const _OfferSheet({required this.ride});
  final RideRequest ride;

  @override
  State<_OfferSheet> createState() => _OfferSheetState();
}

class _OfferSheetState extends State<_OfferSheet> {
  late final double _fare = widget.ride.fare ?? widget.ride.effectiveFare ?? 0;
  late final _c = TextEditingController(text: counterOfferPresets(_fare).first.toStringAsFixed(0));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// The offer as the ride's region prices fares: a whole amount where
  /// fares are whole, else to the cent.
  double get _value => widget.ride.pricing.roundFare(double.tryParse(_c.text.trim()) ?? 0);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.ride;
    final problem = counterOfferProblem(_value, _fare);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Make an offer', style: t.textTheme.titleLarge),
          Text(
            'The rider asks ${r.fareText(_fare)} for ${r.pickupLabel} → ${r.dropLabel}.',
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final p in counterOfferPresets(_fare))
                ActionChip(
                  label: Text(r.fareText(p)),
                  onPressed: () => setState(() => _c.text = p.toStringAsFixed(0)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('offer-amount'),
            controller: _c,
            keyboardType: TextInputType.numberWithOptions(decimal: !r.pricing.wholeFare),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r.pricing.wholeFare ? r'[0-9]' : r'[0-9.]'))],
            decoration: InputDecoration(labelText: 'Your price', prefixText: 'RM ', errorText: problem),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('send-offer'),
            onPressed: problem == null ? () => Navigator.pop(context, _value) : null,
            child: Text('Offer ${r.fareText(_value)}'),
          ),
        ],
      ),
    );
  }
}

/// Waits on the rider's answer to an offer. Pops with the request when the
/// rider accepts (the trip is this partner's), or null otherwise. The offer
/// is withdrawn when the partner cancels or [counterOfferWindow] runs out.
/// How often a waiting offer reads the request itself.
const offerAnswerPoll = Duration(seconds: 3);

class OfferPendingDialog extends StatefulWidget {
  const OfferPendingDialog({
    super.key,
    required this.repo,
    required this.ride,
    required this.me,
    required this.amount,
    this.accepting = false,
    this.window = counterOfferWindow,
  });

  final RideRepository repo;
  final RideRequest ride;
  final String me;
  final double amount;

  /// An Accept at the rider's own fare rather than a counter-offer.
  final bool accepting;
  final Duration window;

  @override
  State<OfferPendingDialog> createState() => _OfferPendingDialogState();
}

/// How long a closed offer's message stays up before it closes itself.
const offerClosedAutoClose = Duration(seconds: 3);

class _OfferPendingDialogState extends State<OfferPendingDialog> with SingleTickerProviderStateMixin {
  StreamSubscription<RideRequest>? _sub;
  Timer? _tick;

  /// Reads the row every few seconds as well: the rider's answer must reach
  /// the driver even when a realtime update never arrives.
  Timer? _poll;
  late var _left = widget.window;
  String? _outcome;

  /// Runs down while the outcome is shown, then closes the dialog.
  late final _closing = AnimationController(vsync: this, duration: offerClosedAutoClose);
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.repo.watch(widget.ride.id).listen(_update, onError: (Object _) {});
    _poll = Timer.periodic(offerAnswerPoll, (_) => _check());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_outcome != null) return;
      setState(() => _left -= const Duration(seconds: 1));
      if (_left <= Duration.zero) {
        _finish('The rider did not answer in time. Your offer was withdrawn.', withdraw: true);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    _poll?.cancel();
    _closing.dispose();
    super.dispose();
  }

  void _update(RideRequest r) {
    // The answer can arrive twice (realtime and the read): act on it once.
    if (_outcome != null || _popped) return;
    final o = offerOutcome(r, me: widget.me, amount: widget.amount, fareWhenOffered: widget.ride.fare);
    switch (o) {
      case OfferOutcome.pending:
        return;
      case OfferOutcome.won:
        _stop();
        _popped = true;
        Navigator.of(context).pop(r);
      case OfferOutcome.outbid:
        _finish('Another driver got this ride.');
      case OfferOutcome.raised:
        _finish('The rider raised the fare to ${r.fareText(r.fare)}. You can accept it or offer again.');
      case OfferOutcome.declined:
        _finish('The rider declined your offer.');
      case OfferOutcome.closed:
        _finish('The rider cancelled this request.');
    }
  }

  Future<void> _check() async {
    if (_outcome != null) return;
    try {
      final r = await widget.repo.fetch(widget.ride.id);
      if (r != null && mounted) _update(r);
    } catch (_) {
      // The next read, or realtime, will tell.
    }
  }

  void _stop() {
    _tick?.cancel();
    _poll?.cancel();
    _sub?.cancel();
  }

  void _finish(String message, {bool withdraw = false}) {
    _stop();
    if (withdraw) unawaited(widget.repo.withdrawOffer(widget.ride.id).catchError((Object _) {}));
    if (!mounted) return;
    setState(() => _outcome = message);
    _closing.forward().whenComplete(() {
      if (mounted && _closing.isCompleted) _close();
    });
  }

  void _close() {
    if (_popped) return;
    _popped = true;
    _closing.stop();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final outcome = _outcome;
    return AlertDialog(
      key: const ValueKey('offer-pending'),
      title: Text(outcome == null ? (widget.accepting ? 'Sent to the passenger' : 'Offer sent') : 'Offer closed'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (outcome == null) ...[
            Text(
              widget.accepting
                  ? 'You accepted ${r.fareText(widget.amount)}. Waiting for the passenger to confirm…'
                  : 'You offered ${r.fareText(widget.amount)}. Waiting for the rider…',
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _left.inMilliseconds / widget.window.inMilliseconds),
            const SizedBox(height: 4),
            Text('${_left.inSeconds}s'),
          ] else ...[
            Text(outcome),
            const SizedBox(height: 12),
            AnimatedBuilder(
              animation: _closing,
              builder: (context, _) {
                final left = offerClosedAutoClose * (1 - _closing.value);
                return Column(
                  children: [
                    LinearProgressIndicator(key: const ValueKey('offer-closed-timer'), value: 1 - _closing.value),
                    const SizedBox(height: 4),
                    Text('Closing in ${(left.inMilliseconds / 1000).ceil()}s'),
                  ],
                );
              },
            ),
          ],
        ],
      ),
      actions: [
        if (outcome == null)
          TextButton(
            onPressed: () {
              _stop();
              unawaited(widget.repo.withdrawOffer(r.id).catchError((Object _) {}));
              Navigator.of(context).pop();
            },
            child: const Text('Withdraw offer'),
          )
        else
          TextButton(onPressed: _close, child: const Text('OK')),
      ],
    );
  }
}
