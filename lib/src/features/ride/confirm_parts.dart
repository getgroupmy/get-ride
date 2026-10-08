// The confirm-ride screen's parts, drawn as Expo's `app/ride-confirm.tsx`:
// the address card floating over the map, the vehicle cards with the fare
// inside the chosen one, the fixed bar with "Find a driver", and the
// entrance, route-stops, payment and promo-code sheets.
import 'package:flutter/material.dart';

import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../core/fare.dart';
import '../../core/fare_offer.dart';
import '../../core/ride_confirm.dart' show RideOptions;
import '../../data/geo_service.dart';
import '../../widgets/busy.dart';
import '../../widgets/map_sheet_layout.dart' show MapSheetReveal;
import '../../widgets/shake.dart';
import 'fare_offer_controls.dart';
import 'home_parts.dart' show uriImage;

/// Expo's accent: the "Find a driver" bar, the add-stop button, the
/// payment icon and the auto-accept switch.
const confirmAccent = Color(0xFF2DABE2);


/// The address card's marks, as inDrive's: a hailing figure for the pickup
/// and a flag for the drop-off, black on a light card and white on a dark.
class _Mark extends StatelessWidget {
  const _Mark(this.icon, this.id);
  final IconData icon;
  final String id;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 12),
    child: Icon(icon, key: ValueKey('confirm-mark-$id'), size: 24, color: Theme.of(context).colorScheme.onSurface),
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
                const _Mark(Icons.emoji_people, 'pickup'),
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
                const _Mark(Icons.flag, 'drop'),
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
  showDragHandle: true,
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

  static const _letters = {
    '2': 'ABC',
    '3': 'DEF',
    '4': 'GHI',
    '5': 'JKL',
    '6': 'MNO',
    '7': 'PQRS',
    '8': 'TUV',
    '9': 'WXYZ',
  };

  void _type(String digit) => setState(() => _value = (_value + digit).substring(0, (_value.length + 1).clamp(0, 6)));

  void _back() => setState(() => _value = _value.isEmpty ? '' : _value.substring(0, _value.length - 1));

  /// One key of the phone-style keypad: the digit over its letters, on a
  /// white (or, dark, charcoal) rounded key.
  Widget _key(BuildContext context, String digit) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? Colors.white : Colors.black;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          color: dark ? const Color(0xFF4A4A4C) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          elevation: dark ? 0 : 0.5,
          shadowColor: Colors.black38,
          child: InkWell(
            key: ValueKey('entrance-key-$digit'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => _type(digit),
            child: SizedBox(
              height: 50,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(digit, style: TextStyle(fontSize: 24, height: 1.1, color: ink)),
                  if (_letters[digit] != null)
                    Text(
                      _letters[digit]!,
                      style: TextStyle(fontSize: 9, letterSpacing: 2, fontWeight: FontWeight.w600, color: ink),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final ink = t.colorScheme.onSurface;
    return Column(
      key: const ValueKey('entrance-sheet'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Column(
            children: [
              // "Set entrance", bold and centred, with a round close button.
              Row(
                children: [
                  const SizedBox(width: 40),
                  Expanded(
                    child: Text(
                      'Set entrance',
                      textAlign: TextAlign.center,
                      style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Material(
                    color: t.colorScheme.surfaceContainerHighest,
                    shape: const CircleBorder(),
                    child: InkWell(
                      key: const ValueKey('entrance-close'),
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.pop(context),
                      child: Tooltip(
                        message: 'Close',
                        child: SizedBox.square(dimension: 40, child: Icon(Icons.close, size: 22, color: ink)),
                      ),
                    ),
                  ),
                ],
              ),
              // The number, large and centred over a hairline, with a caret.
              Container(
                key: const ValueKey('entrance-value'),
                height: 76,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t.colorScheme.outlineVariant)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_value, style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Container(width: 2, height: 40, margin: const EdgeInsets.only(left: 2), color: ink),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  key: const ValueKey('entrance-done'),
                  style: FilledButton.styleFrom(
                    backgroundColor: confirmAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  onPressed: () => Navigator.pop(context, _value),
                  child: const Text('Done'),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
        // The phone-style keypad, edge to edge on its grey panel.
        Container(
          key: const ValueKey('entrance-keypad'),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF2B2B2D) : const Color(0xFFD7D9DE),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                ])
                  Row(children: [for (final k in row) _key(context, k)]),
                Row(
                  children: [
                    const Expanded(child: SizedBox()),
                    _key(context, '0'),
                    Expanded(
                      child: InkResponse(
                        key: const ValueKey('entrance-key-back'),
                        onTap: _back,
                        child: SizedBox(
                          height: 58,
                          child: Icon(Icons.backspace_outlined, size: 26, color: dark ? Colors.white : Colors.black),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ],
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

/// The chosen vehicle card's colours, as inDrive's: a warm grey tray with a
/// white card raised in it and white round −/+ on a light sheet; charcoal
/// shades of the same on a dark one.
class ConfirmCardColors {
  const ConfirmCardColors({
    required this.tray,
    required this.trayBorder,
    required this.card,
    required this.round,
    required this.chip,
  });

  /// The tray the card and the fare sit in.
  final Color tray, trayBorder;

  /// The raised card with the vehicle, and the round −/+ buttons.
  final Color card, round;

  /// The pencil's pill.
  final Color chip;

  static const light = ConfirmCardColors(
    tray: Color(0xFFF3F2EF),
    trayBorder: Color(0xFFE4E2DD),
    card: Colors.white,
    round: Colors.white,
    chip: Color(0xFFF0EFEC),
  );
  static const dark = ConfirmCardColors(
    tray: Color(0xFF262626),
    trayBorder: Color(0xFF3A3A3A),
    card: Color(0xFF333333),
    round: Color(0xFF333333),
    chip: Color(0xFF3D3D3D),
  );

  static ConfirmCardColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// One vehicle on the confirm sheet (inDrive's): the car, its name, seats
/// and description, and the price. The chosen one is a white card raised in
/// a grey tray, with a pencil in place of the price and the fare below it.
class ConfirmServiceCard extends StatelessWidget {
  const ConfirmServiceCard({
    super.key,
    required this.service,
    required this.price,
    required this.selected,
    required this.onTap,
    this.fare,
    this.onEdit,
    this.etaMinutes,
  });

  final RideService service;
  final String price;

  /// Minutes for the nearest driver to reach the pickup ("4 • 4 min");
  /// null when none is near.
  final int? etaMinutes;
  final bool selected;
  final VoidCallback onTap;

  /// The fare section shown inside the chosen card.
  final Widget? fare;

  /// The pencil: the rider's own fare (only where bidding is on).
  final VoidCallback? onEdit;

  Widget _row(BuildContext context, {required Widget trailing, bool info = false}) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final ink = t.colorScheme.onSurface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: SizedBox(
            width: 72,
            height: 45,
            child: uriImage(
              service.image,
              width: 72,
              height: 45,
              fallback: Icon(service.name == 'Teksi' ? Icons.local_taxi : Icons.directions_car, size: 36, color: muted),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      service.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w500, color: ink),
                    ),
                  ),
                  if (info) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.info_outline, size: 16, color: muted),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.person, size: 17, color: ink),
                  const SizedBox(width: 2),
                  Text(
                    etaMinutes == null ? '${service.seats}' : '${service.seats} • $etaMinutes min',
                    key: ValueKey('service-eta-${service.name}'),
                    style: t.textTheme.bodyMedium?.copyWith(color: ink, fontSize: 15),
                  ),
                ],
              ),
              if (service.description.isNotEmpty)
                Text(
                  service.description,
                  style: t.textTheme.bodyMedium?.copyWith(color: muted),
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: _row(
            context,
            trailing: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(price, style: t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );
    }
    // Shaken by the fare's −/+ when a step would leave the range, and kept
    // whole above the pinned footer, as Expo scrolls the chosen one.
    final c = ConfirmCardColors.of(context);
    final priceStyle = t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600);
    return Shake(
      child: MapSheetReveal(
        child: Container(
          key: ValueKey('service-${service.name}'),
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: c.tray,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: c.trayBorder),
          ),
          child: Column(
            children: [
              Material(
                key: const ValueKey('service-card-top'),
                color: c.card,
                elevation: 1.5,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: onEdit,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 8, 14),
                    child: _row(
                      context,
                      info: true,
                      trailing: onEdit == null
                          ? Padding(padding: const EdgeInsets.only(top: 4, right: 6), child: Text(price, style: priceStyle))
                          : Material(
                              color: c.chip,
                              shape: const CircleBorder(),
                              child: InkWell(
                                key: const ValueKey('fare-edit'),
                                customBorder: const CircleBorder(),
                                onTap: onEdit,
                                child: Tooltip(
                                  message: 'Edit fare',
                                  child: SizedBox.square(
                                    dimension: 34,
                                    child: Icon(Icons.edit, size: 16, color: t.colorScheme.onSurface),
                                  ),
                                ),
                              ),
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
    this.onEdit,
  });

  /// A tap on the amount: the full "Offer your fare" page where there is
  /// one, else the typing sheet.
  final VoidCallback? onEdit;

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
      color: ConfirmCardColors.of(context).round,
      shape: const CircleBorder(),
      elevation: 1,
      shadowColor: Colors.black26,
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
          style: t.textTheme.headlineSmall?.copyWith(fontSize: 28, fontWeight: FontWeight.w600),
        ),
        Text(
          adjust == 0 ? 'Recommended fare' : 'Recommended fare: ${money(recommended)}',
          style: t.textTheme.bodyMedium?.copyWith(color: muted, fontSize: 15),
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
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 8),
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
                    key: const ValueKey('confirm-fare-edit'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: onEdit ??
                        () => editFareOffer(
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
  builder: (c) {
    final t = Theme.of(c);
    final dark = t.brightness == Brightness.dark;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // "Payment method", bold and centred, with a round close (inDrive's).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                const SizedBox(width: 40),
                Expanded(
                  child: Text(
                    'Payment method',
                    textAlign: TextAlign.center,
                    style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Material(
                  color: t.colorScheme.surfaceContainerHighest,
                  shape: const CircleBorder(),
                  child: InkWell(
                    key: const ValueKey('payment-close'),
                    customBorder: const CircleBorder(),
                    onTap: () => Navigator.pop(c),
                    child: const SizedBox.square(dimension: 40, child: Icon(Icons.close, size: 22)),
                  ),
                ),
              ],
            ),
          ),
          for (final (value, label, icon) in confirmPayments)
            Material(
              // The chosen one on a pale blue band with a tick.
              color: value == current
                  ? (dark ? const Color(0xFF16384A) : const Color(0xFFD3EEFB))
                  : Colors.transparent,
              child: ListTile(
                key: ValueKey('payment-$value'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: Icon(icon, color: value == 'Cash' ? const Color(0xFF6BBF2A) : confirmAccent),
                title: Text(label, style: t.textTheme.bodyLarge?.copyWith(fontSize: 17)),
                trailing: value == current ? const Icon(Icons.check, color: Color(0xFF3B6CF6)) : null,
                onTap: () => Navigator.pop(c, value),
              ),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  },
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
    this.onOptions,
    this.optionsOn = false,
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

  /// The options button right of "Find a driver"; none without it.
  final VoidCallback? onOptions;

  /// An option is on: a dot on the button.
  final bool optionsOn;

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
                    ConfirmSwitch(
                      key: const ValueKey('use-coins-switch'),
                      value: useCoins,
                      onChanged: onUseCoins,
                    ),
                  ],
                ),
              Row(
                children: [
                  const AutoAcceptIcon(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(autoAcceptLabel, style: t.textTheme.bodyLarge?.copyWith(fontSize: 16)),
                  ),
                  ConfirmSwitch(
                    key: const ValueKey('auto-accept'),
                    value: autoAccept,
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
                  if (onOptions != null) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      key: const ValueKey('confirm-options'),
                      tooltip: 'Options',
                      iconSize: 26,
                      icon: Badge(isLabelVisible: optionsOn, smallSize: 8, child: const Icon(Icons.tune)),
                      onPressed: onOptions,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Options sheet from the button beside "Find a driver": a child
/// safety seat, more than four passengers, and comments for the driver.
/// Changes apply as they are made ([onChanged], and [note] is the confirm
/// screen's own note), so Close and a swipe down both keep them.
Future<void> showRideOptionsSheet(
  BuildContext context, {
  required RideOptions options,
  required ValueChanged<RideOptions> onChanged,
  required TextEditingController note,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: false,
  builder: (_) => _RideOptionsSheet(options: options, onChanged: onChanged, note: note),
);

class _RideOptionsSheet extends StatefulWidget {
  const _RideOptionsSheet({required this.options, required this.onChanged, required this.note});
  final RideOptions options;
  final ValueChanged<RideOptions> onChanged;
  final TextEditingController note;

  @override
  State<_RideOptionsSheet> createState() => _RideOptionsSheetState();
}

class _RideOptionsSheetState extends State<_RideOptionsSheet> {
  late RideOptions _options = widget.options;

  void _set(RideOptions o) {
    setState(() => _options = o);
    widget.onChanged(o);
  }

  Future<void> _comments() async {
    final r = await showModalBottomSheet<_Comments>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) => _CommentsSheet(initial: widget.note.text),
    );
    if (r == null || !mounted) return;
    if (r.text != null) setState(() => widget.note.text = r.text!);
    // Its ✕ closes Options too.
    if (r.closeAll) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final comment = widget.note.text.trim();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          key: const ValueKey('ride-options'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Text('Options', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton.filledTonal(
                    key: const ValueKey('ride-options-x'),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('option-child-seat'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Child safety seat'),
              value: _options.childSeat,
              onChanged: (v) => _set(_options.copyWith(childSeat: v)),
            ),
            SwitchListTile(
              key: const ValueKey('option-more-passengers'),
              contentPadding: EdgeInsets.zero,
              title: const Text('More than ${RideOptions.standardSeats} passengers'),
              value: _options.morePassengers,
              onChanged: (v) => _set(_options.copyWith(morePassengers: v)),
            ),
            SwitchListTile(
              key: const ValueKey('option-pet'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Pet with me'),
              value: _options.pet,
              onChanged: (v) => _set(_options.copyWith(pet: v)),
            ),
            const SizedBox(height: 12),
            Material(
              color: t.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              child: ListTile(
                key: const ValueKey('option-comments'),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                title: Text(
                  comment.isEmpty ? 'Comments' : comment,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: comment.isEmpty ? TextStyle(color: t.colorScheme.onSurfaceVariant) : null,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _comments,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const ValueKey('ride-options-close'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the Comments sheet hands back: the text when saved, and whether
/// its ✕ closes Options as well.
typedef _Comments = ({String? text, bool closeAll});

/// Comments for the driver, typed on their own sheet: ← back to Options,
/// ✕ out of both, Save keeps them.
class _CommentsSheet extends StatefulWidget {
  const _CommentsSheet({required this.initial});
  final String initial;

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final edge = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: t.colorScheme.onSurface, width: 1.5),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            key: const ValueKey('option-comments-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      key: const ValueKey('option-comments-back'),
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  Text('Comments', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton.filledTonal(
                      key: const ValueKey('option-comments-x'),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop<_Comments>(context, (text: null, closeAll: true)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('option-comments-field'),
                controller: _text,
                autofocus: true,
                minLines: 4,
                maxLines: 6,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'What your driver should know?',
                  counterText: '',
                  filled: true,
                  fillColor: t.colorScheme.surfaceContainerHigh,
                  border: edge,
                  enabledBorder: edge,
                  focusedBorder: edge,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('option-comments-done'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                onPressed: () => Navigator.pop<_Comments>(context, (text: _text.text.trim(), closeAll: false)),
                child: const Text('Save'),
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

/// inDrive's auto-accept mark: a paper plane taking off, with speed lines
/// behind it, black on light and white on dark.
class AutoAcceptIcon extends StatelessWidget {
  const AutoAcceptIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(
      key: const ValueKey('auto-accept-icon'),
      dimension: 30,
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: 0,
            child: Transform.rotate(angle: -0.6, child: Icon(Icons.send, size: 22, color: ink)),
          ),
          Positioned(left: 0, bottom: 2, child: CustomPaint(size: const Size(14, 14), painter: _SpeedLines(ink))),
        ],
      ),
    );
  }
}

class _SpeedLines extends CustomPainter {
  _SpeedLines(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    // Three short dashes trailing down and left from the plane's tail.
    canvas.drawLine(Offset(size.width * 0.55, size.height * 0.2), Offset(size.width * 0.25, size.height * 0.5), p);
    canvas.drawLine(Offset(size.width * 0.8, size.height * 0.45), Offset(size.width * 0.4, size.height * 0.85), p);
    canvas.drawLine(Offset(size.width * 0.3, size.height * 0.65), Offset(size.width * 0.05, size.height * 0.9), p);
  }

  @override
  bool shouldRepaint(_SpeedLines old) => old.color != color;
}

/// inDrive's switch: a pill track with no outline, light grey (or charcoal
/// on dark) when off with a white knob, the brand blue when on.
class ConfirmSwitch extends StatelessWidget {
  const ConfirmSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Switch(
      value: value,
      onChanged: onChanged,
      activeThumbColor: Colors.white,
      activeTrackColor: confirmAccent,
      inactiveThumbColor: dark ? const Color(0xFF1E1E1E) : Colors.white,
      inactiveTrackColor: dark ? const Color(0xFF5A5A5A) : const Color(0xFFE6E5E2),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(null),
    );
  }
}
