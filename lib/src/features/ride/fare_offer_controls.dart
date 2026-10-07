import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/fare_offer.dart';

/// One −/+ press on the rider's offer: [onAdjust] with the new adjustment.
/// Past the allowed range it calls [onLimit] (the confirm sheet shakes the
/// chosen card, as Expo does), or shows a note when there is none.
void stepFareOffer(
  BuildContext context, {
  required double recommended,
  required double adjust,
  required String Function(double) money,
  required ValueChanged<double> onAdjust,
  required double step,
  VoidCallback? onLimit,
}) {
  final next = stepFareAdjustment(recommended, adjust, step);
  if (next == null && onLimit != null) return onLimit();
  if (next == null) {
    final range = fareOfferRange(recommended);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(step < 0 ? 'Minimum fare is ${money(range.min)}' : "That's the most you can add here")),
      );
    return;
  }
  onAdjust(next);
}

/// "Offer your fare": the typed amount, as an adjustment, to [onAdjust].
Future<void> editFareOffer(
  BuildContext context, {
  required double recommended,
  required double adjust,
  required String Function(double) money,
  required ValueChanged<double> onAdjust,
}) async {
  final fare = await showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FareOfferSheet(recommended: recommended, current: recommended + adjust, money: money),
  );
  if (fare != null) onAdjust(fare - recommended);
}

/// The selected service's fare with −/+ buttons (Expo `ride-confirm`): the
/// amount, "Recommended fare" (or the recommended amount once changed),
/// and a tap on the amount to type an offer. Shown only where bidding is on.
class FareOfferRow extends StatelessWidget {
  const FareOfferRow({
    super.key,
    required this.recommended,
    required this.adjust,
    required this.money,
    required this.onAdjust,
  });

  final double recommended;
  final double adjust;
  final String Function(double) money;
  final ValueChanged<double> onAdjust;

  void _step(BuildContext context, double step) =>
      stepFareOffer(context, recommended: recommended, adjust: adjust, money: money, onAdjust: onAdjust, step: step);

  Future<void> _type(BuildContext context) =>
      editFareOffer(context, recommended: recommended, adjust: adjust, money: money, onAdjust: onAdjust);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fare = recommended + adjust;
    return Card(
      key: const ValueKey('fare-offer'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('fare-lower'),
              tooltip: 'Lower fare by ${money(fareOfferStep)}',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: () => _step(context, -fareOfferStep),
            ),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _type(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: [
                      Text(money(fare), style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                        adjust == 0
                            ? 'Recommended fare · tap to offer your own'
                            : 'Recommended fare: ${money(recommended)}',
                        style: t.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('fare-raise'),
              tooltip: 'Raise fare by ${money(fareOfferStep)}',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _step(context, fareOfferStep),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Offer your fare": a whole amount from 70% to 400% of the recommended
/// fare, with the limit it breaks named under the field. Pops the fare.
class FareOfferSheet extends StatefulWidget {
  const FareOfferSheet({super.key, required this.recommended, required this.current, required this.money});

  final double recommended;
  final double current;
  final String Function(double) money;

  @override
  State<FareOfferSheet> createState() => _FareOfferSheetState();
}

class _FareOfferSheetState extends State<FareOfferSheet> {
  late final _c = TextEditingController(text: widget.current.round().toString());

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final typed = double.tryParse(_c.text);
    final problem = fareOfferProblem(typed, widget.recommended, widget.money);
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Offer your fare', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Recommended fare: ${widget.money(widget.recommended)}', style: t.textTheme.bodyMedium),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('fare-offer-field'),
            controller: _c,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
            style: t.textTheme.headlineMedium,
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              errorText: _c.text.isEmpty ? null : problem,
              helperText: problem == null ? 'Drivers see this fare and can accept or counter it.' : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: problem == null ? () => Navigator.pop(context, typed) : null,
            child: const Text('Set fare'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, widget.recommended),
            child: const Text('Use recommended fare'),
          ),
        ],
      ),
    );
  }
}
