// The confirm-ride screen's parts, drawn as Expo's `app/ride-confirm.tsx`:
// the address card floating over the map, the vehicle cards with the fare
// inside the chosen one, the fixed bar with "Find a driver", and the
// entrance, route-stops, payment and promo-code sheets.
import 'package:flutter/material.dart';

import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../core/fare.dart';
import '../../core/fare_offer.dart';
import '../../data/geo_service.dart';
import '../../widgets/busy.dart';
import '../../widgets/map_sheet_layout.dart' show MapSheetReveal;
import '../../widgets/shake.dart';
import 'fare_offer_controls.dart';
import 'home_parts.dart' show uriImage;

/// Expo's accent: the "Find a driver" bar, the add-stop button, the
/// payment icon and the auto-accept switch.
const confirmAccent = Color(0xFF2DABE2);

const _pickupGreen = Color(0xFF22C55E);
const _dropRed = Color(0xFFEF4444);

/// A ringed dot, as the address card marks pickup and drop-off.
class _Dot extends StatelessWidget {
  const _Dot(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    margin: const EdgeInsets.only(top: 1, right: 12),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 4),
    ),
  );
}

/// Pickup and drop-off over the map (Expo's top overlay): tap either to
/// change it, "Entrance" to say which door, + to add a stop. With stops it
/// reads "N route stops" and opens them.
class ConfirmAddressCard extends StatelessWidget {
  const ConfirmAddressCard({
    super.key,
    required this.pickup,
    required this.drop,
    required this.stops,
    required this.duration,
    required this.entrance,
    required this.onPickup,
    required this.onDrop,
    required this.onEntrance,
    required this.onStops,
    this.onAddStop,
  });

  final Place? pickup;
  final Place drop;
  final List<Place> stops;

  /// "~25 min", or empty while the route is worked out.
  final String duration;
  final String entrance;
  final VoidCallback onPickup, onDrop, onEntrance, onStops;

  /// Null once the trip has all the stops it may have.
  final VoidCallback? onAddStop;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = t.textTheme.bodyLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w500);
    return Material(
      key: const ValueKey('confirm-address-card'),
      elevation: 4,
      color: t.colorScheme.surface.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Dot(_pickupGreen),
                Expanded(
                  child: InkWell(
                    key: const ValueKey('confirm-pickup'),
                    onTap: onPickup,
                    child: Text(
                      pickup?.name ?? 'Set pickup',
                      style: text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  key: const ValueKey('confirm-entrance'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: onEntrance,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      entrance.isEmpty ? 'Entrance' : 'Entrance $entrance',
                      style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Dot(_dropRed),
                Expanded(
                  child: InkWell(
                    key: const ValueKey('confirm-drop'),
                    onTap: stops.isEmpty ? onDrop : onStops,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: stops.isEmpty ? drop.name : '${stops.length + 1} route stops'),
                          if (duration.isNotEmpty)
                            TextSpan(
                              text: '  $duration',
                              style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w400),
                            ),
                        ],
                      ),
                      style: text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (onAddStop != null) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Add another stop',
                    child: InkResponse(
                      key: const ValueKey('confirm-add-stop'),
                      onTap: onAddStop,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: const BoxDecoration(color: confirmAccent, shape: BoxShape.circle),
                        child: const Icon(Icons.add, color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Expo's "Set entrance" keypad: the entrance (a door or gate number) the
/// driver should come to. Pops the new value, or null when closed.
Future<String?> showEntranceSheet(BuildContext context, String current) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _EntranceSheet(current: current),
);

class _EntranceSheet extends StatefulWidget {
  const _EntranceSheet({required this.current});
  final String current;

  @override
  State<_EntranceSheet> createState() => _EntranceSheetState();
}

class _EntranceSheetState extends State<_EntranceSheet> {
  late String _value = widget.current;

  Widget _key(String label, {VoidCallback? onTap, Widget? child}) => Expanded(
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: 52,
        child: TextButton(
          key: ValueKey('entrance-key-$label'),
          onPressed:
              onTap ?? () => setState(() => _value = (_value + label).substring(0, (_value.length + 1).clamp(0, 6))),
          child: child ?? Text(label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500)),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: 48),
                Expanded(
                  child: Text('Set entrance', textAlign: TextAlign.center, style: t.textTheme.titleMedium),
                ),
                IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            Container(
              key: const ValueKey('entrance-value'),
              height: 56,
              alignment: Alignment.center,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_value, style: t.textTheme.headlineSmall),
            ),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(children: [for (final k in row) _key(k)]),
            Row(
              children: [
                const Expanded(child: SizedBox()),
                _key('0'),
                _key(
                  'back',
                  onTap: () => setState(() => _value = _value.isEmpty ? '' : _value.substring(0, _value.length - 1)),
                  child: const Icon(Icons.backspace_outlined),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('entrance-done'),
                style: FilledButton.styleFrom(backgroundColor: confirmAccent, padding: const EdgeInsets.all(16)),
                onPressed: () => Navigator.pop(context, _value),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Destination addresses" (inDrive's): every place after the pickup, in
/// order — the stops numbered, the destination with a flag. A row's ✕
/// takes it out and its handle drags it into a new place; whichever ends up
/// last is the destination. Changes apply as they are made ([onChanged]
/// with the new order), and the last one left can't be removed.
Future<void> showRouteStopsSheet(
  BuildContext context, {
  required List<Place> destinations,
  required ValueChanged<List<Place>> onChanged,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: false,
  builder: (_) => _DestinationsSheet(destinations: destinations, onChanged: onChanged),
);

class _DestinationsSheet extends StatefulWidget {
  const _DestinationsSheet({required this.destinations, required this.onChanged});
  final List<Place> destinations;
  final ValueChanged<List<Place>> onChanged;

  @override
  State<_DestinationsSheet> createState() => _DestinationsSheetState();
}

class _DestinationsSheetState extends State<_DestinationsSheet> {
  late final _list = List.of(widget.destinations);

  void _changed() {
    setState(() {});
    widget.onChanged(List.of(_list));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final last = _list.length - 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 12),
        child: Column(
          key: const ValueKey('route-stops'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Text('Destination addresses', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    key: const ValueKey('route-stops-back'),
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: _list.length,
                onReorderItem: (from, to) {
                  _list.insert(to, _list.removeAt(from));
                  _changed();
                },
                itemBuilder: (_, i) {
                  final p = _list[i];
                  return ListTile(
                    key: ValueKey('route-stop-${p.point.latitude},${p.point.longitude},$i'),
                    contentPadding: const EdgeInsets.only(left: 12, right: 4),
                    leading: SizedBox(
                      width: 28,
                      child: Center(
                        child: i == last
                            ? const Icon(Icons.flag, key: ValueKey('route-stop-flag'))
                            : Text('${i + 1}', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                      ),
                    ),
                    title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_list.length > 1)
                        IconButton(
                          key: ValueKey('route-stop-remove-$i'),
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _list.removeAt(i);
                            _changed();
                          },
                        ),
                      ReorderableDragStartListener(
                        index: i,
                        child: Padding(
                          key: ValueKey('route-stop-drag-$i'),
                          padding: const EdgeInsets.all(12),
                          child: const Icon(Icons.drag_handle),
                        ),
                      ),
                    ]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One vehicle on the confirm sheet (Expo's ride option): the car, its
/// name, seats and description, and the price. The chosen one is a grey
/// pill with a pencil in place of the price and the fare inside it.
class ConfirmServiceCard extends StatelessWidget {
  const ConfirmServiceCard({
    super.key,
    required this.service,
    required this.price,
    required this.selected,
    required this.onTap,
    this.fare,
    this.onEdit,
  });

  final RideService service;
  final String price;
  final bool selected;
  final VoidCallback onTap;

  /// The fare section shown inside the chosen card.
  final Widget? fare;

  /// The pencil: the rider's own fare (only where bidding is on).
  final VoidCallback? onEdit;

  Widget _row(BuildContext context, {required Widget trailing}) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        SizedBox(
          width: 72,
          height: 45,
          child: uriImage(
            service.image,
            width: 72,
            height: 45,
            fallback: Icon(service.name == 'Teksi' ? Icons.local_taxi : Icons.directions_car, size: 36, color: muted),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(service.name, style: t.textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w500)),
              Row(
                children: [
                  Icon(Icons.people_outline, size: 13, color: muted),
                  const SizedBox(width: 3),
                  Text('${service.seats}', style: t.textTheme.bodySmall?.copyWith(color: muted)),
                ],
              ),
              if (service.description.isNotEmpty)
                Text(
                  service.description,
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        trailing,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (!selected) {
      return InkWell(
        key: ValueKey('service-${service.name}'),
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: _row(
            context,
            trailing: Text(price, style: t.textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
      );
    }
    // Shaken by the fare's −/+ when a step would leave the range, and kept
    // whole above the pinned footer, as Expo scrolls the chosen one.
    return Shake(
      child: MapSheetReveal(
      child: Container(
        key: ValueKey('service-${service.name}'),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(24)),
        child: Column(
          children: [
            Material(
              color: t.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: onEdit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
                  child: _row(
                    context,
                    trailing: onEdit == null
                        ? Text(price, style: t.textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w600))
                        : IconButton(
                            key: const ValueKey('fare-edit'),
                            tooltip: 'Edit fare',
                            icon: Icon(Icons.edit_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
                            onPressed: onEdit,
                          ),
                  ),
                ),
              ),
            ),
            ?fare,
          ],
        ),
      ),
      ),
    );
  }
}

/// The fare inside the chosen card (Expo's fare section): the amount and
/// "Recommended fare" always; the round −/+ only where bidding is on; then
/// the coins it earns and the tolls on the way.
class ConfirmFareSection extends StatelessWidget {
  const ConfirmFareSection({
    super.key,
    required this.recommended,
    required this.adjust,
    required this.money,
    required this.bidding,
    required this.onAdjust,
    this.earn,
    this.tollBooths = 0,
    this.onTollBooths,
    this.tollCharges,
  });

  final double recommended;
  final double adjust;
  final String Function(double) money;
  final bool bidding;
  final ValueChanged<double> onAdjust;

  /// "Earn 12 GC on this booking"; null for none.
  final String? earn;
  final int tollBooths;
  final VoidCallback? onTollBooths;

  /// The estimated toll charges, formatted; null for none.
  final String? tollCharges;

  Widget _round(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tip,
    required double step,
  }) => Tooltip(
    message: tip,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      child: InkWell(
        key: key,
        customBorder: const CircleBorder(),
        onTap: () => stepFareOffer(
          context,
          recommended: recommended,
          adjust: adjust,
          money: money,
          onAdjust: onAdjust,
          step: step,
          // Past the range the chosen card shakes, as Expo's does; no note.
          onLimit: Shake.maybeOf(context)?.shake,
        ),
        child: SizedBox.square(dimension: 56, child: Icon(icon, size: 24)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final center = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          money(recommended + adjust),
          key: const ValueKey('confirm-fare'),
          style: t.textTheme.headlineSmall?.copyWith(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        Text(
          adjust == 0 ? 'Recommended fare' : 'Recommended fare: ${money(recommended)}',
          style: t.textTheme.bodySmall?.copyWith(color: muted),
        ),
        if (earn != null)
          Container(
            key: const ValueKey('booking-coin-earn'),
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(999)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.toll, size: 11, color: Color(0xFFB45309)),
                const SizedBox(width: 4),
                Text(
                  earn!,
                  style: const TextStyle(fontSize: 11, color: Color(0xFFB45309), fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        if (tollBooths > 0)
          InkWell(
            key: const ValueKey('route-toll-booths'),
            onTap: onTollBooths,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Est. Toll Booths: $tollBooths',
                style: t.textTheme.bodySmall?.copyWith(color: muted, decoration: TextDecoration.underline),
              ),
            ),
          ),
        if (tollCharges != null)
          Padding(
            key: const ValueKey('route-tolls'),
            padding: const EdgeInsets.only(top: 2),
            child: Text('Est. Toll Charges $tollCharges', style: t.textTheme.bodySmall?.copyWith(color: muted)),
          ),
      ],
    );
    return Padding(
      key: const ValueKey('fare-offer'),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      child: Row(
        children: [
          if (bidding)
            _round(
              context,
              key: const ValueKey('fare-lower'),
              icon: Icons.remove,
              tip: 'Lower fare by ${money(fareOfferStep)}',
              step: -fareOfferStep,
            ),
          Expanded(
            child: bidding
                ? InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => editFareOffer(
                      context,
                      recommended: recommended,
                      adjust: adjust,
                      money: money,
                      onAdjust: onAdjust,
                    ),
                    child: center,
                  )
                : center,
          ),
          if (bidding)
            _round(
              context,
              key: const ValueKey('fare-raise'),
              icon: Icons.add,
              tip: 'Raise fare by ${money(fareOfferStep)}',
              step: fareOfferStep,
            ),
        ],
      ),
    );
  }
}

/// "Fare does not include state entry tax, tolls, or parking fees".
class ConfirmDisclaimer extends StatelessWidget {
  const ConfirmDisclaimer({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      key: const ValueKey('confirm-disclaimer'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Fare does not include state entry tax, tolls, or parking fees',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// The payment methods the confirm sheet offers, by stored value.
const confirmPayments = <(String, String, IconData)>[
  ('Cash', 'Cash', Icons.payments_outlined),
  ('Get Pay', 'GET.wallet', Icons.account_balance_wallet_outlined),
];

/// Expo's payment sheet, opened from the card icon beside "Find a driver".
Future<String?> showPaymentSheet(BuildContext context, String current) => showModalBottomSheet<String>(
  context: context,
  builder: (c) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(title: Text('Payment method', style: Theme.of(c).textTheme.titleMedium)),
        for (final (value, label, icon) in confirmPayments)
          ListTile(
            key: ValueKey('payment-$value'),
            leading: Icon(icon, color: confirmAccent),
            title: Text(label),
            trailing: value == current ? const Icon(Icons.check, color: confirmAccent) : null,
            onTap: () => Navigator.pop(c, value),
          ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);

/// Expo's fixed bottom: the GET.coin switch, "Auto-accept offer of RM x",
/// then the payment icon and "Find a driver".
class ConfirmFooter extends StatelessWidget {
  const ConfirmFooter({
    super.key,
    required this.payment,
    required this.onPayment,
    required this.autoAcceptLabel,
    required this.autoAccept,
    required this.onAutoAccept,
    required this.label,
    required this.onFind,
    this.coinTitle,
    this.coinSubtitle,
    this.useCoins = false,
    this.onUseCoins,
  });

  final String payment;
  final VoidCallback onPayment;
  final String autoAcceptLabel;
  final bool autoAccept;
  final ValueChanged<bool> onAutoAccept;
  final String label;

  /// Null while the booking can't go (still pricing the route, or a
  /// passenger's details missing).
  final Future<void> Function()? onFind;

  /// The GET.coin row, shown only with both.
  final String? coinTitle;
  final String? coinSubtitle;
  final bool useCoins;
  final ValueChanged<bool>? onUseCoins;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final payLabel = confirmPayments.firstWhere((p) => p.$1 == payment, orElse: () => confirmPayments.first).$2;
    return Material(
      key: const ValueKey('confirm-footer'),
      color: t.colorScheme.surface,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (coinTitle != null && coinSubtitle != null)
                Row(
                  key: const ValueKey('use-coins'),
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: const BoxDecoration(color: Color(0xFFFEF3C7), shape: BoxShape.circle),
                      child: const Icon(Icons.toll, size: 16, color: Color(0xFFB45309)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(coinTitle!, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                          Text(
                            coinSubtitle!,
                            style: t.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      key: const ValueKey('use-coins-switch'),
                      value: useCoins,
                      activeThumbColor: const Color(0xFFEAB308),
                      activeTrackColor: const Color(0xFFFDE68A),
                      onChanged: onUseCoins,
                    ),
                  ],
                ),
              Row(
                children: [
                  const Icon(Icons.send, size: 18, color: confirmAccent),
                  const SizedBox(width: 10),
                  Expanded(child: Text(autoAcceptLabel, style: t.textTheme.bodyMedium)),
                  Switch(
                    key: const ValueKey('auto-accept'),
                    value: autoAccept,
                    activeThumbColor: confirmAccent,
                    onChanged: onAutoAccept,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Tooltip(
                    message: 'Payment method: $payLabel. Change',
                    child: InkResponse(
                      key: const ValueKey('confirm-payment'),
                      onTap: onPayment,
                      child: Container(
                        width: 44,
                        height: 52,
                        alignment: Alignment.center,
                        child: Icon(
                          payment == 'Cash' ? Icons.payments_outlined : Icons.credit_card,
                          color: confirmAccent,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: BusyButton.filled(
                      key: const ValueKey('book'),
                      style: FilledButton.styleFrom(
                        backgroundColor: confirmAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      onPressed: onFind,
                      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Got promo code? Use it here" over the top of the sheet.
class PromoBanner extends StatelessWidget {
  const PromoBanner({super.key, required this.onTap});
  final VoidCallback onTap;

  /// How much of the bar shows above the sheet's top edge.
  static const visibleHeight = 40.0;

  /// How far the bar reaches under the sheet.
  static const tuck = 22.0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Material(
      key: const ValueKey('promo-banner'),
      color: t.colorScheme.surfaceContainerHigh,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: InkWell(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, tuck + 8),
          child: SizedBox(
            height: visibleHeight - 16,
            child: Row(
              children: [
                Icon(Icons.sell_outlined, size: 18, color: muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Got promo code? Use it here', style: t.textTheme.bodyMedium?.copyWith(color: muted)),
                ),
                Icon(Icons.chevron_right, color: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The promo-code sheet. No promotions are set up, so every code is
/// answered "not valid", as Expo's sheet answers any code it doesn't know.
Future<void> showPromoSheet(BuildContext context) =>
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => const _PromoSheet());

class _PromoSheet extends StatefulWidget {
  const _PromoSheet();

  @override
  State<_PromoSheet> createState() => _PromoSheetState();
}

class _PromoSheetState extends State<_PromoSheet> {
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Promo code', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('promo-code'),
          controller: _code,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(hintText: 'Enter promo code', errorText: _error),
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: _code,
          builder: (_, _) => FilledButton(
            key: const ValueKey('promo-apply'),
            style: FilledButton.styleFrom(backgroundColor: confirmAccent, padding: const EdgeInsets.all(14)),
            onPressed: _code.text.trim().isEmpty ? null : () => setState(() => _error = 'Promo code is not valid'),
            child: const Text('Apply'),
          ),
        ),
      ],
    ),
  );
}

/// "Earn 12 GC on this booking", or null for none.
String? coinEarnLabel(double coins) => coins > 0 ? 'Earn ${formatCoins(coins)} on this booking' : null;
