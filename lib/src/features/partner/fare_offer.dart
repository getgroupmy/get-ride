import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
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

  double get _value => ((double.tryParse(_c.text.trim()) ?? 0) * 100).roundToDouble() / 100;

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
            'The rider asks ${formatMoney(_fare, r.currency)} for ${r.pickupLabel} → ${r.dropLabel}.',
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final p in counterOfferPresets(_fare))
                ActionChip(
                  label: Text(formatMoney(p, r.currency)),
                  onPressed: () => setState(() => _c.text = p.toStringAsFixed(0)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('offer-amount'),
            controller: _c,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(labelText: 'Your price', prefixText: 'RM ', errorText: problem),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('send-offer'),
            onPressed: problem == null ? () => Navigator.pop(context, _value) : null,
            child: Text('Offer ${formatMoney(_value, r.currency)}'),
          ),
        ],
      ),
    );
  }
}

/// Waits on the rider's answer to an offer. Pops with the request when the
/// rider accepts (the trip is this partner's), or null otherwise. The offer
/// is withdrawn when the partner cancels or [counterOfferWindow] runs out.
class OfferPendingDialog extends StatefulWidget {
  const OfferPendingDialog({
    super.key,
    required this.repo,
    required this.ride,
    required this.me,
    required this.amount,
    this.window = counterOfferWindow,
  });

  final RideRepository repo;
  final RideRequest ride;
  final String me;
  final double amount;
  final Duration window;

  @override
  State<OfferPendingDialog> createState() => _OfferPendingDialogState();
}

class _OfferPendingDialogState extends State<OfferPendingDialog> {
  StreamSubscription<RideRequest>? _sub;
  Timer? _tick;
  late var _left = widget.window;
  String? _outcome;

  @override
  void initState() {
    super.initState();
    _sub = widget.repo.watch(widget.ride.id).listen(_update, onError: (Object _) {});
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
    super.dispose();
  }

  void _update(RideRequest r) {
    if (_outcome != null) return;
    final o = offerOutcome(r, me: widget.me, amount: widget.amount, fareWhenOffered: widget.ride.fare);
    switch (o) {
      case OfferOutcome.pending:
        return;
      case OfferOutcome.won:
        _stop();
        Navigator.of(context).pop(r);
      case OfferOutcome.outbid:
        _finish('Another driver got this ride.');
      case OfferOutcome.raised:
        _finish('The rider raised the fare to ${formatMoney(r.fare, r.currency)}. You can accept it or offer again.');
      case OfferOutcome.declined:
        _finish('The rider declined your offer.');
      case OfferOutcome.closed:
        _finish('The rider cancelled this request.');
    }
  }

  void _stop() {
    _tick?.cancel();
    _sub?.cancel();
  }

  void _finish(String message, {bool withdraw = false}) {
    _stop();
    if (withdraw) unawaited(widget.repo.withdrawOffer(widget.ride.id).catchError((Object _) {}));
    if (mounted) setState(() => _outcome = message);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;
    final outcome = _outcome;
    return AlertDialog(
      title: Text(outcome == null ? 'Offer sent' : 'Offer closed'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (outcome == null) ...[
            Text('You offered ${formatMoney(widget.amount, r.currency)}. Waiting for the rider…'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _left.inMilliseconds / widget.window.inMilliseconds),
            const SizedBox(height: 4),
            Text('${_left.inSeconds}s'),
          ] else
            Text(outcome),
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
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
      ],
    );
  }
}
