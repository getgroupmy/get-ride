import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/fare_offer.dart';
import '../../core/payment_types.dart';
import 'confirm_parts.dart';

/// What "Offer your fare" hands back: the fare and the choices made on it,
/// and whether the rider asked to find a driver from there.
class OfferFareResult {
  const OfferFareResult({
    required this.fare,
    required this.payment,
    required this.autoAccept,
    required this.entrance,
    this.find = false,
  });

  /// The fare to offer; null when what was typed isn't one (kept as it was).
  final double? fare;
  final String payment;
  final bool autoAccept;
  final String entrance;
  final bool find;
}

/// "Offer your fare" (inDrive's), a page of its own: the fare large and
/// typed straight in, then the fare note, the payment and auto-accept, and
/// the pickup and route, with "Find a driver" and the options at the foot.
class OfferFareScreen extends StatefulWidget {
  const OfferFareScreen({
    super.key,
    required this.recommended,
    required this.current,
    required this.currencyLabel,
    required this.money,
    required this.payment,
    required this.autoAccept,
    required this.entrance,
    required this.pickupName,
    required this.routeLabel,
    this.onRoute,
    this.onAddStop,
    this.onOptions,
    this.optionsOn = false,
    this.payments = builtInPayments,
  });

  final double recommended;
  final double current;

  /// The currency as written before the amount ("RM").
  final String currencyLabel;
  final String Function(double) money;
  final String payment;

  /// The methods offered (Admin → Payment Type).
  final List<PaymentChoice> payments;
  final bool autoAccept;
  final String entrance;
  final String pickupName;

  /// The drop-off, or "N route stops".
  final String routeLabel;
  final VoidCallback? onRoute, onAddStop;
  final void Function(BuildContext context)? onOptions;
  final bool optionsOn;

  @override
  State<OfferFareScreen> createState() => _OfferFareScreenState();
}

/// The page's colours: a warm grey ground with white cards (charcoal on
/// dark), as inDrive's.
({Color ground, Color card}) _offerColours(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? (ground: const Color(0xFF121212), card: const Color(0xFF1F1F1F))
    : (ground: const Color(0xFFF3F2EF), card: Colors.white);

class _OfferFareScreenState extends State<OfferFareScreen> {
  late final _fare = TextEditingController(text: widget.current.round().toString());
  late String _payment = widget.payment;
  late bool _autoAccept = widget.autoAccept;
  late String _entrance = widget.entrance;

  @override
  void dispose() {
    _fare.dispose();
    super.dispose();
  }

  double? get _typed => double.tryParse(_fare.text);
  String? get _problem => fareOfferProblem(_typed, widget.recommended, widget.money);

  OfferFareResult _result({bool find = false}) => OfferFareResult(
    fare: _problem == null ? _typed : null,
    payment: _payment,
    autoAccept: _autoAccept,
    entrance: _entrance,
    find: find,
  );

  Widget _card(BuildContext context, Widget child, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: _offerColours(context).card,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ink = t.colorScheme.onSurface;
    final muted = t.colorScheme.onSurfaceVariant;
    final colours = _offerColours(context);
    final problem = _problem;
    final shown = _typed ?? widget.recommended;
    final big = t.textTheme.displayMedium?.copyWith(fontSize: 64, fontWeight: FontWeight.w800, height: 1.1);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _result());
      },
      child: Scaffold(
        key: const ValueKey('offer-fare-screen'),
        backgroundColor: colours.ground,
        appBar: AppBar(
          backgroundColor: colours.card,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          leading: IconButton(
            key: const ValueKey('offer-fare-back'),
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _result()),
          ),
          title: Text('Offer your fare', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        body: ListView(
          padding: EdgeInsets.zero,
          children: [
            // The fare, typed straight in: the currency grey, the amount
            // black, over a hairline; the recommended fare (or what's wrong)
            // below.
            Container(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: colours.card,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('You can change the recommended fare', style: t.textTheme.bodyLarge?.copyWith(color: muted)),
                  Container(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: t.colorScheme.outlineVariant)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text('${widget.currencyLabel} ', style: big?.copyWith(color: muted)),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('offer-fare-field'),
                            controller: _fare,
                            autofocus: true,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(5),
                            ],
                            style: big?.copyWith(color: ink),
                            cursorColor: ink,
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _fare.text.isNotEmpty && problem != null
                        ? problem
                        : 'Recommended fare: ${widget.money(widget.recommended)}',
                    key: const ValueKey('offer-fare-note'),
                    style: t.textTheme.bodyLarge?.copyWith(
                      color: _fare.text.isNotEmpty && problem != null ? t.colorScheme.error : ink,
                    ),
                  ),
                ],
              ),
            ),
            _card(
              context,
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: ink),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        "Fare doesn't include state entry tax, tolls, or parking fees",
                        style: t.textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _card(
              context,
              Column(
                children: [
                  ListTile(
                    key: const ValueKey('offer-fare-payment'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: Icon(
                      paymentLook(paymentChoiceFor(_payment, widget.payments).kind).$1,
                      color: const Color(0xFF6BBF2A),
                    ),
                    title: Text(
                      paymentChoiceFor(_payment, widget.payments).label,
                      style: t.textTheme.bodyLarge,
                    ),
                    trailing: Icon(Icons.chevron_right, color: muted),
                    onTap: () async {
                      final p = await showPaymentSheet(context, _payment, payments: widget.payments);
                      if (p != null && mounted) setState(() => _payment = p);
                    },
                  ),
                  ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                    leading: const AutoAcceptIcon(),
                    title: Text(
                      'Automatically accept the nearest driver for ${widget.money(shown)}',
                      style: t.textTheme.bodyLarge,
                    ),
                    trailing: ConfirmSwitch(
                      key: const ValueKey('offer-fare-auto-accept'),
                      value: _autoAccept,
                      onChanged: (v) => setState(() => _autoAccept = v),
                    ),
                  ),
                ],
              ),
            ),
            _card(
              context,
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.emoji_people, color: ink),
                      title: Text(
                        widget.pickupName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodyLarge,
                      ),
                      trailing: ActionChip(
                        key: const ValueKey('offer-fare-entrance'),
                        label: Text(_entrance.isEmpty ? 'Entrance' : 'Entrance $_entrance'),
                        shape: const StadiumBorder(),
                        side: BorderSide.none,
                        backgroundColor: t.colorScheme.surfaceContainerHighest,
                        onPressed: () async {
                          final v = await showEntranceSheet(context, _entrance);
                          if (v != null && mounted) setState(() => _entrance = v);
                        },
                      ),
                    ),
                    ListTile(
                      leading: Icon(Icons.flag, color: ink),
                      title: Text(
                        widget.routeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodyLarge,
                      ),
                      onTap: widget.onRoute,
                      trailing: widget.onAddStop == null
                          ? null
                          : IconButton(
                              key: const ValueKey('offer-fare-add-stop'),
                              tooltip: 'Add another stop',
                              icon: Icon(Icons.add, color: ink, size: 28),
                              onPressed: widget.onAddStop,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: FilledButton(
                      key: const ValueKey('offer-fare-find'),
                      style: FilledButton.styleFrom(
                        backgroundColor: confirmAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      onPressed: problem == null ? () => Navigator.pop(context, _result(find: true)) : null,
                      child: const Text('Find a driver'),
                    ),
                  ),
                ),
                if (widget.onOptions != null) ...[
                  const SizedBox(width: 12),
                  SizedBox.square(
                    dimension: 56,
                    child: Material(
                      color: confirmAccent,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        key: const ValueKey('offer-fare-options'),
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => widget.onOptions!(context),
                        child: Badge(
                          isLabelVisible: widget.optionsOn,
                          smallSize: 8,
                          child: const Icon(Icons.tune, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
