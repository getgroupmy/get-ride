import 'dart:math' as math;
// The confirm-ride screen's parts, drawn as Expo's `app/ride-confirm.tsx`:
// the address card floating over the map, the vehicle cards with the fare
// inside the chosen one, the fixed bar with "Find a driver", and the
// entrance, route-stops and payment sheets (the promo bar and sheet are in
// promo_parts.dart).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../core/fare.dart';
import '../../core/fare_info.dart';
import '../../core/fare_offer.dart';
import '../../core/format.dart';
import '../../core/payment_types.dart';
import '../../core/route_estimate.dart' show FareTrend, FareTrendDirection;
import '../../widgets/fare_trend_arrows.dart';
import '../../core/ride_confirm.dart' show RideOptions;
import '../../core/ride_assistance.dart' show AssistanceCatalogue, assistanceSummary;
import '../../core/ride_option_settings.dart';
import '../../core/ride_pets.dart' show PetConfig, petSummary;
import '../../data/geo_service.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show mutedTextColor;
import '../../widgets/media_image.dart' show MediaIcon, MediaImage;
import '../../widgets/map_sheet_layout.dart' show MapSheetReveal;
import '../../widgets/shake.dart';
import 'fare_offer_controls.dart';
import 'home_parts.dart' show uriImage;
import 'assistance_parts.dart' show showRideAssistanceSheet;
import 'pet_parts.dart' show showRidePetsSheet;
import '../../core/page_styles.dart' show fareInfoSurface, homeSurface;
import '../../widgets/page_style_host.dart';

/// Expo's accent: the "Find a driver" bar, the add-stop button, the
/// payment icon and the auto-accept switch.
const confirmAccent = Color(0xFF2DABE2);

/// The confirm blue darkened for a filled button with white words on it
/// (4.5:1 and more); [confirmAccent] stays for icons, tints and highlights.
const accentFill = Color(0xFF0C7AB8);


/// The address card's marks, as inDrive's: a hailing figure for the pickup
/// and a flag for the drop-off, black on a light card and white on a dark.
class _Mark extends StatelessWidget {
  const _Mark(this.icon, this.id);
  final IconData icon;
  final String id;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 12),
    child: Icon(
      icon,
      key: ValueKey('confirm-mark-$id'),
      size: 24,
      color: Theme.of(context).colorScheme.onSurface,
      semanticLabel: id == 'pickup' ? 'Pickup' : 'Drop-off',
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
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const _Mark(Icons.emoji_people, 'pickup'),
                Expanded(
                  // Read as "From: <place>", a button, not the bare name.
                  child: Semantics(
                    container: true,
                    button: true,
                    label: 'From: ${pickup?.name ?? 'Set pickup'}',
                    onTap: onPickup,
                    excludeSemantics: true,
                    child: InkWell(
                      key: const ValueKey('confirm-pickup'),
                      onTap: onPickup,
                      // 44 tall at least: a finger-sized target.
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            pickup?.name ?? 'Set pickup',
                            style: text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // A button of its own for screen readers, its tap included.
                Semantics(
                  container: true,
                  button: true,
                  label: entrance.isEmpty ? 'Set entrance' : 'Entrance $entrance, change',
                  onTap: onEntrance,
                  excludeSemantics: true,
                  child: InkWell(
                  key: const ValueKey('confirm-entrance'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: onEntrance,
                  // The chip stays small; the target around it is 44 high.
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                    child: Center(
                      widthFactor: 1,
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
                  ),
                ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const _Mark(Icons.flag, 'drop'),
                Expanded(
                  child: Semantics(
                    container: true,
                    button: true,
                    label: stops.isEmpty
                        ? 'To: ${drop.name}${duration.isEmpty ? '' : ', $duration'}'
                        : 'Route: ${stops.length + 1} stops${duration.isEmpty ? '' : ', $duration'}',
                    onTap: stops.isEmpty ? onDrop : onStops,
                    excludeSemantics: true,
                    child: InkWell(
                      key: const ValueKey('confirm-drop'),
                      onTap: stops.isEmpty ? onDrop : onStops,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          // The name ellipsised before the time, which stays
                          // whole on its right ("~14 min" never broken).
                          child: LayoutBuilder(builder: (context, row) {
                            final rowWidth = row.maxWidth;
                            return Row(children: [
                            Expanded(
                              child: Text(
                                stops.isEmpty ? drop.name : '${stops.length + 1} route stops',
                                key: const ValueKey('confirm-drop-name'),
                                style: text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (duration.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              // Whole wherever there is room for it; in a
                              // sliver of a row (on its side, large text) it
                              // fades rather than overflows.
                              ConstrainedBox(
                                  // Some of the name always shows beside it.
                                  constraints: BoxConstraints(maxWidth: math.max(0, rowWidth - 8 - 48)),
                                  child: Text(
                                    duration,
                                    key: const ValueKey('confirm-duration'),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.fade,
                                    style: text?.copyWith(color: t.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w400),
                                  ),
                              ),
                            ],
                          ]);
                          }),
                        ),
                      ),
                    ),
                  ),
                ),
                if (onAddStop != null) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Add another stop',
                    excludeFromSemantics: true,
                    child: Semantics(
                      container: true,
                      button: true,
                      label: 'Add stop',
                      onTap: onAddStop,
                      excludeSemantics: true,
                      child: InkResponse(
                        key: const ValueKey('confirm-add-stop'),
                        onTap: onAddStop,
                        child: SizedBox.square(
                          dimension: 44,
                          child: Center(
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: const BoxDecoration(color: confirmAccent, shape: BoxShape.circle),
                              child: const Icon(Icons.add, color: Colors.white, size: 20),
                            ),
                          ),
                        ),
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

/// What the empty entrance field asks for.
const entranceHint = 'Gate or door number, e.g. 3';

/// Expo's "Set entrance" keypad: the entrance (a door or gate number) the
/// driver should come to. Pops the new value, or null when closed.
Future<String?> showEntranceSheet(BuildContext context, String current) => showAppSheet<String>(id: 'confirm.confirm-address-card',
  context: context,
  // On its side the sheet sits beside its keypad and scrolls if need be.
  fitContent: true,
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

  void _type(String digit) => setState(() => _value = (_value + digit).substring(0, (_value.length + 1).clamp(0, 6)));

  void _back() => setState(() => _value = _value.isEmpty ? '' : _value.substring(0, _value.length - 1));

  /// One key of the keypad: its digit alone (only digits can be typed), on
  /// a white (or, dark, charcoal) rounded key.
  Widget _key(BuildContext context, String digit, {double height = 50}) {
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
              height: height,
              // Large phone text shrinks to the key instead of spilling out.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(digit, style: TextStyle(fontSize: 24, height: 1.1, color: ink)),
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
    // A phone on its side (393 high): the number and Done beside smaller
    // keys, so it all fits above the home bar.
    final size = MediaQuery.sizeOf(context);
    final side = size.height < 500 && size.width > size.height;
    final keyHeight = side ? 38.0 : 50.0;
    final entry = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
                    child: SizedBox.square(dimension: 48, child: Icon(Icons.close, size: 22, color: ink)),
                  ),
                ),
              ),
            ],
          ),
          // The number, large and centred over a hairline, with a caret.
          Container(
            key: const ValueKey('entrance-value'),
            height: side ? 56 : 76,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.colorScheme.outlineVariant)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_value.isEmpty)
                  // What to type, until something is.
                  Flexible(
                    child: Text(
                      entranceHint,
                      key: const ValueKey('entrance-hint'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  )
                else
                  Text(_value, style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
                Container(width: 2, height: 40, margin: const EdgeInsets.only(left: 2), color: ink),
              ],
            ),
          ),
          SizedBox(height: side ? 12 : 24),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton(
              key: const ValueKey('entrance-done'),
              style: FilledButton.styleFrom(
                backgroundColor: accentFill,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              onPressed: () => Navigator.pop(context, _value),
              child: const Text('Done'),
            ),
          ),
          // An entrance set before can be taken off in one go.
          if (widget.current.isNotEmpty)
            SizedBox(
              height: 48,
              child: TextButton(
                key: const ValueKey('entrance-clear'),
                style: TextButton.styleFrom(foregroundColor: ink),
                onPressed: () => Navigator.pop(context, ''),
                child: const Text('Clear entrance'),
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
    // The phone-style keypad, edge to edge on its grey panel.
    final keypad = Container(
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
              Row(children: [for (final k in row) _key(context, k, height: keyHeight)]),
            Row(
              children: [
                const Expanded(child: SizedBox()),
                _key(context, '0', height: keyHeight),
                Expanded(
                  child: InkResponse(
                    key: const ValueKey('entrance-key-back'),
                    onTap: _back,
                    child: SizedBox(
                      height: keyHeight + 8,
                      child: Icon(
                        Icons.backspace_outlined,
                        size: 26,
                        color: dark ? Colors.white : Colors.black,
                        semanticLabel: 'Delete',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (side) {
      return SafeArea(
        top: false,
        bottom: false,
        child: Row(
          key: const ValueKey('entrance-sheet'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: entry),
            Expanded(child: keypad),
          ],
        ),
      );
    }
    return Column(
      key: const ValueKey('entrance-sheet'),
      mainAxisSize: MainAxisSize.min,
      children: [entry, keypad],
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
}) => showAppSheet<void>(id: 'confirm.show-route-stops-sheet',
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
/// and description, and the price. Where bidding is on the chosen one is a
/// white card raised in a grey tray, with a pencil in place of the price and
/// the fare below it; a [fixed] fare is inDrive's outlined row keeping its
/// price, the arrows after the name and what it is priced on behind the (i).
/// The chosen vehicle's picture on the confirm page: [sizePct] of the
/// usual 72 × 45, with [hiddenPct] of its width (the back) cut off by the
/// card's left edge. [shown] is the width it takes in the row.
({double width, double height, double shown}) chosenPictureBox(double sizePct, double hiddenPct) {
  final scale = sizePct.clamp(100, 220) / 100;
  final hidden = hiddenPct.clamp(0, 50) / 100;
  final w = 72 * scale;
  return (width: w, height: 45 * scale, shown: w * (1 - hidden));
}

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
    this.trend,
    this.fixed = false,
    this.onInfo,
    this.uplift,
    this.was,
    this.note,
  });

  /// The price before a GET.Plus member's discount, struck through under
  /// [price] (migration 0316); null when there is none.
  final String? was;

  /// A line under the description: a Premium service's rules ("Cars 5
  /// years or newer, listed models, drivers rated 4.8+").
  final String? note;

  /// [price] with the struck-through price before the member's discount.
  Widget _withWas(BuildContext context, Widget price) {
    final w = was;
    if (w == null) return price;
    final t = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        price,
        Semantics(
          label: 'Was $w',
          excludeSemantics: true,
          child: Text(
            w,
            key: ValueKey('service-was-${service.name}'),
            style: t.textTheme.bodySmall?.copyWith(
              color: mutedTextColor(t, background: ConfirmCardColors.of(context).card),
              decoration: TextDecoration.lineThrough,
            ),
          ),
        ),
      ],
    );
  }

  /// What high demand adds to this fare ("+RM1", [demandUpliftLabel]),
  /// shown under the price; null when it adds nothing.
  final String? uplift;

  /// The price, with the demand uplift under it.
  Widget _withUplift(BuildContext context, Widget price) {
    final u = uplift;
    if (u == null) return price;
    final t = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        price,
        Semantics(
          label: 'High demand, $u',
          excludeSemantics: true,
          child: Text(
            u,
            key: ValueKey('uplift-${service.name}'),
            style: t.textTheme.labelSmall?.copyWith(color: mutedTextColor(t, background: ConfirmCardColors.of(context).card), fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  /// The (i) on a chosen fixed fare: what it is priced on ([FareInfoSheet]).
  final VoidCallback? onInfo;

  final RideService service;
  final String price;

  /// A fixed fare (bidding off): chosen, it is an outlined row keeping its
  /// price, and [fare] opens from the (i) instead of sitting in the card.
  final bool fixed;

  /// The arrows before the price (fare trend); null for none.
  final FareTrend? trend;

  Widget _price(String text, TextStyle? style) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (trend != null) ...[FareTrendArrows(trend: trend!), const SizedBox(width: 4)],
      Text(text, style: style),
    ],
  );

  /// Minutes for the nearest driver to reach the pickup ("4 • 4 min");
  /// null when none is near.
  final int? etaMinutes;
  final bool selected;
  final VoidCallback onTap;

  /// The fare section shown inside the chosen card.
  final Widget? fare;

  /// The pencil: the rider's own fare (only where bidding is on).
  final VoidCallback? onEdit;

  Widget _row(
    BuildContext context, {
    required Widget trailing,
    bool info = false,
    VoidCallback? onInfo,
    bool nameArrows = false,
    ({double width, double height, double shown})? chosen,
  }) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final ink = t.colorScheme.onSurface;
    final fallback = Icon(service.name == 'Teksi' ? Icons.local_taxi : Icons.directions_car, size: 36, color: muted);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chosen == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: 72,
              height: 45,
              child: uriImage(service.image, width: 72, height: 45, fallback: fallback),
            ),
          )
        else
          // Larger, its back past the row's start: the card's edge cuts it.
          Padding(
            padding: EdgeInsets.only(top: math.max(0, 6 - (chosen.height - 45) / 2)),
            child: SizedBox(
              key: ValueKey('service-picture-chosen-${service.name}'),
              width: chosen.shown,
              height: chosen.height,
              child: OverflowBox(
                alignment: Alignment.centerRight,
                minWidth: chosen.width,
                maxWidth: chosen.width,
                child: uriImage(service.image, width: chosen.width, height: chosen.height, fallback: fallback),
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
                  // inDrive's fixed fare: the arrows stand after the name.
                  if (nameArrows && trend != null) ...[
                    const SizedBox(width: 6),
                    FareTrendArrows(trend: trend!, size: 16),
                  ],
                  if (info) ...[
                    const SizedBox(width: 2),
                    onInfo == null
                        ? Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(Icons.info_outline, size: 16, color: muted),
                          )
                        : Tooltip(
                            message: 'Fare details',
                            excludeFromSemantics: true,
                            child: Semantics(
                              container: true,
                              button: true,
                              label: 'Fare details',
                              excludeSemantics: true,
                              child: InkResponse(
                                key: const ValueKey('fare-details'),
                                radius: 22,
                                onTap: onInfo,
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(Icons.info_outline, size: 16, color: muted),
                                ),
                              ),
                            ),
                          ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.person, size: 17, color: ink),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      etaMinutes == null ? '${service.seats}' : '${service.seats} • $etaMinutes min',
                      key: ValueKey('service-eta-${service.name}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodyMedium?.copyWith(color: ink, fontSize: 15),
                    ),
                  ),
                ],
              ),
              if (service.description.isNotEmpty)
                // Two lines before it is cut ("Comfortable c…" at large text).
                Text(
                  service.description,
                  key: ValueKey('service-description-${service.name}'),
                  style: t.textTheme.bodyMedium?.copyWith(color: muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              if (note != null)
                Text(
                  note!,
                  key: ValueKey('service-rules-${service.name}'),
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                  maxLines: 2,
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
            nameArrows: fixed,
            trailing: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _withUplift(
                context,
                _withWas(
                  context,
                  fixed
                      ? Text(price, style: t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600))
                      : _price(price, t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final c = ConfirmCardColors.of(context);
    final priceStyle = t.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600);
    final look = SurfaceStyle.of(context, homeSurface);
    final pic = chosenPictureBox(look.number('chosenPictureSize'), look.number('chosenPictureHidden'));
    // Cut by the edge, the picture starts at it; whole, it keeps the gap.
    final cut = pic.shown < pic.width;
    // A fixed fare (no bidding): inDrive's outlined row with its price, and
    // nothing to raise or lower; the fare's details are behind the (i).
    if (fixed) {
      return MapSheetReveal(
        child: Material(
          key: ValueKey('service-${service.name}'),
          color: c.card,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: t.colorScheme.outlineVariant, width: 2),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onInfo,
            child: Padding(
              padding: EdgeInsets.fromLTRB(cut ? 0 : 16, 12, 16, 12),
              child: _row(
                context,
                info: true,
                nameArrows: true,
                onInfo: onInfo,
                chosen: pic,
                trailing: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _withUplift(context, _withWas(context, Text(price, style: priceStyle))),
                ),
              ),
            ),
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
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: c.tray,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: c.trayBorder),
          ),
          child: Column(
            children: [
              // Shaken, the card swings against the tray, inside its padding.
              ShakeCounter(
                travel: 4,
                child: Material(
                key: const ValueKey('service-card-top'),
                color: c.card,
                elevation: 1.5,
                shadowColor: Colors.black26,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: onEdit,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(cut ? 0 : 12, 12, 8, 14),
                    child: _row(
                      context,
                      info: true,
                      chosen: pic,
                      trailing: onEdit == null
                          ? Padding(
                              padding: const EdgeInsets.only(top: 4, right: 6),
                              child: _withUplift(context, _withWas(context, _price(price, priceStyle))),
                            )
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
    this.tax,
    this.onEdit,
    this.trend,
  });

  /// The arrows before the recommended amount (fare trend); not shown once
  /// the rider raises or lowers it.
  final FareTrend? trend;

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

  /// The region's tax on the fare, as a line ("+ SST 6%: RM 1.08").
  final String? tax;

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
        // A long fare in large text shrinks rather than running off the sheet.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (trend != null && adjust == 0) ...[
                FareTrendArrows(trend: trend!, size: 24),
                const SizedBox(width: 6),
              ],
              Text(
                money(recommended + adjust),
                key: const ValueKey('confirm-fare'),
                style: t.textTheme.headlineSmall?.copyWith(fontSize: 28, fontWeight: FontWeight.w600),
              ),
            ],
          ),
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
        if (tax != null)
          Padding(
            key: const ValueKey('fare-tax'),
            padding: const EdgeInsets.only(top: 2),
            child: Text(tax!, style: t.textTheme.bodySmall?.copyWith(color: muted)),
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

/// A payment method's icon and colour.
(IconData, Color) paymentLook(PaymentKind kind) => switch (kind) {
  PaymentKind.cash => (Icons.payments_outlined, const Color(0xFF6BBF2A)),
  PaymentKind.wallet => (Icons.account_balance_wallet_outlined, confirmAccent),
  PaymentKind.card => (Icons.credit_card, confirmAccent),
  PaymentKind.other => (Icons.account_balance_outlined, confirmAccent),
  PaymentKind.business => (Icons.business_center_outlined, confirmAccent),
};

/// Expo's payment sheet, opened from the card icon beside "Find a driver".
/// [payments] are the methods offered (Admin → Payment Type).
Future<String?> showPaymentSheet(
  BuildContext context,
  String current, {
  List<PaymentChoice> payments = builtInPayments,
}) => showAppSheet<String>(id: 'confirm.show-payment-sheet',
  context: context,
  fitContent: true,
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
                    // 48 across, and named for screen readers and on hover.
                    child: const Tooltip(
                      message: 'Close',
                      child: SizedBox.square(dimension: 48, child: Icon(Icons.close, size: 22)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final PaymentChoice(:value, :label, :kind, :icon) in payments.isEmpty ? builtInPayments : payments)
            Material(
              // The chosen one on a pale blue band with a tick.
              color: value == current
                  ? (dark ? const Color(0xFF16384A) : const Color(0xFFD3EEFB))
                  : Colors.transparent,
              child: ListTile(
                key: ValueKey('payment-$value'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: MediaIcon(icon, fallback: paymentLook(kind).$1, color: paymentLook(kind).$2),
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
    this.autoAcceptLabel,
    required this.autoAccept,
    required this.onAutoAccept,
    required this.label,
    required this.onFind,
    this.coinTitle,
    this.coinSubtitle,
    this.useCoins = false,
    this.onUseCoins,
    this.pickLater,
    this.onLater,
    this.owedNote,
    this.chargesNote,
    this.whoRiding,
    this.myRide,
    this.audioProtection,
    this.onOptions,
    this.optionsOn = false,
    this.payments = builtInPayments,
  });

  final String payment;

  /// The methods offered (Admin → Payment Type), for [payment]'s label.
  final List<PaymentChoice> payments;
  final VoidCallback onPayment;
  /// "Auto-accept offer of RM x"; null hides the row (the service is not
  /// open to offers, so there is nothing to accept).
  final String? autoAcceptLabel;
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

  /// "Later" (0189): the pickup time asked for ([pickLater]), then the
  /// booking for it ([onLater]); with them the button splits into Now and
  /// Later. Null while scheduled rides are off.
  final Future<DateTime?> Function()? pickLater;
  final Future<void> Function(DateTime at)? onLater;

  /// Late-cancel fees from earlier bookings, added to this ride.
  final String? owedNote;

  /// What the rider's options add to the fare ("Pet charge RM10 ·
  /// Assistance charge RM5"); the fares above already include it.
  final String? chargesNote;

  /// A row under the GET.coin one: who's riding (a toggle for someone else).
  final Widget? whoRiding;

  /// The "My Ride" switch (favourite drivers first), under who's riding;
  /// none when the rider has no favourite to offer it to.
  final Widget? myRide;

  /// The rider's "Audio protection" switch (migration 0315), under My Ride.
  final Widget? audioProtection;

  /// The options button right of "Find a driver"; none without it.
  final VoidCallback? onOptions;

  /// An option is on: a dot on the button.
  final bool optionsOn;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final payLabel = paymentChoiceFor(payment, payments).label;
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
              if (owedNote != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    key: const ValueKey('owed-note'),
                    children: [
                      Icon(Icons.info_outline, size: 18, color: t.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          owedNote!,
                          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              if (chargesNote != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    key: const ValueKey('option-charges-note'),
                    children: [
                      Icon(Icons.info_outline, size: 18, color: t.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          chargesNote!,
                          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ?whoRiding,
              ?myRide,
              ?audioProtection,
              if (autoAcceptLabel != null)
                Row(
                  children: [
                    const AutoAcceptIcon(),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(autoAcceptLabel!, style: t.textTheme.bodyLarge?.copyWith(fontSize: 16)),
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
                          paymentChoiceFor(payment, payments).kind == PaymentKind.cash
                              ? Icons.payments_outlined
                              : Icons.credit_card,
                          color: confirmAccent,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: pickLater != null && onLater != null
                        ? NowLaterButton(
                            label: label,
                            onNow: onFind,
                            pickLater: onFind == null ? null : pickLater,
                            onLater: onLater!,
                          )
                        : BusyButton.filled(
                            key: const ValueKey('book'),
                            style: FilledButton.styleFrom(
                              backgroundColor: accentFill,
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
/// safety seat (a number of them when the admin allows more than one), more
/// than four passengers, a pet (its own Your pets sheet, [petConfig]),
/// assistance (its own sheet, [assistance]) and comments for the driver.
/// [config] (Admin → Display Settings → Ride Options) decides which show,
/// in what order and under what name. Changes apply as they are made
/// ([onChanged], and [note] is the confirm screen's own note), so Close and
/// a swipe down both keep them.
Future<void> showRideOptionsSheet(
  BuildContext context, {
  required RideOptions options,
  required ValueChanged<RideOptions> onChanged,
  required TextEditingController note,
  PetConfig petConfig = const PetConfig(),
  RideOptionsConfig config = const RideOptionsConfig(),
  AssistanceCatalogue assistance = const AssistanceCatalogue(),
}) => showAppSheet<void>(id: 'confirm.show-ride-options-sheet',
  context: context,
  isScrollControlled: true,
  // On a phone on its side (393 high) the three switches, Comments and
  // Close did not fit: the sheet scrolls instead of cutting Close off.
  fitContent: true,
  showDragHandle: false,
  builder: (_) => _RideOptionsSheet(
    options: options,
    onChanged: onChanged,
    note: note,
    petConfig: petConfig,
    config: config,
    assistance: assistance,
  ),
);

class _RideOptionsSheet extends StatefulWidget {
  const _RideOptionsSheet({
    required this.options,
    required this.onChanged,
    required this.note,
    required this.petConfig,
    required this.config,
    required this.assistance,
  });
  final RideOptions options;
  final ValueChanged<RideOptions> onChanged;
  final TextEditingController note;
  final PetConfig petConfig;
  final RideOptionsConfig config;
  final AssistanceCatalogue assistance;

  @override
  State<_RideOptionsSheet> createState() => _RideOptionsSheetState();
}

class _RideOptionsSheetState extends State<_RideOptionsSheet> {
  late RideOptions _options = widget.options;

  void _set(RideOptions o) {
    setState(() => _options = o);
    widget.onChanged(o);
  }

  /// "Pet with me": on opens Your pets, and stays off unless it is done;
  /// off clears the pets. Edit reopens it; cancelled keeps what was saved.
  Future<void> _pets({bool? on}) async {
    if (on == false) return _set(_options.copyWith(pet: false, pets: const []));
    final pets = await showRidePetsSheet(context, initial: _options.pets, config: widget.petConfig);
    if (pets == null || pets.isEmpty || !mounted) return;
    _set(_options.copyWith(pet: true, pets: pets));
  }

  /// "Assistance required": as "Pet with me", with its own sheet.
  Future<void> _assistance({bool? on}) async {
    if (on == false) return _set(_options.copyWith(clearAssistance: true));
    final help = await showRideAssistanceSheet(context, initial: _options.assistance, catalogue: widget.assistance);
    if (help == null || help.isEmpty || !mounted) return;
    _set(_options.copyWith(assistance: help));
  }

  /// A summary under an option's name, with Edit.
  Widget _summary(String text, String key, VoidCallback onEdit) => Row(children: [
    Expanded(child: Text(text, key: ValueKey('$key-summary'))),
    TextButton(
      key: ValueKey('$key-edit'),
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      onPressed: onEdit,
      child: const Text('Edit'),
    ),
  ]);

  Widget _option(BuildContext context, RideOptionKind k) {
    final c = widget.config;
    final image = c.images[k];
    // The admin's picture beside it (Display Settings → Ride Options).
    final title = image == null
        ? Text(c.labelOf(k))
        : Row(children: [
            SizedBox.square(
              key: ValueKey('option-image-${k.id}'),
              dimension: 32,
              child: MediaImage(image, width: 32, height: 32),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(c.labelOf(k))),
          ]);
    switch (k) {
      case RideOptionKind.childSeat:
        if (c.childSeatMax <= 1) {
          return SwitchListTile(
            key: const ValueKey('option-child-seat'),
            contentPadding: EdgeInsets.zero,
            title: title,
            value: _options.childSeat,
            onChanged: (v) => _set(_options.copyWith(childSeat: v, childSeats: 1)),
          );
        }
        // More than one allowed: how many, 0 for none.
        final n = _options.childSeat ? _options.childSeats.clamp(1, c.childSeatMax) : 0;
        void count(int v) => _set(_options.copyWith(childSeat: v > 0, childSeats: v < 1 ? 1 : v));
        return ListTile(
          key: const ValueKey('option-child-seat'),
          contentPadding: EdgeInsets.zero,
          title: title,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              key: const ValueKey('option-child-seat-minus'),
              tooltip: 'One less',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: n > 0 ? () => count(n - 1) : null,
            ),
            SizedBox(
              width: 24,
              child: Text(
                '$n',
                key: const ValueKey('option-child-seat-count'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              key: const ValueKey('option-child-seat-plus'),
              tooltip: 'One more',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: n < c.childSeatMax ? () => count(n + 1) : null,
            ),
          ]),
        );
      case RideOptionKind.morePassengers:
        return SwitchListTile(
          key: const ValueKey('option-more-passengers'),
          contentPadding: EdgeInsets.zero,
          title: title,
          value: _options.morePassengers,
          onChanged: (v) => _set(_options.copyWith(morePassengers: v)),
        );
      case RideOptionKind.pet:
        // As the other options, with the pets' summary and Edit under it
        // once they are in.
        return SwitchListTile(
          key: const ValueKey('option-pet'),
          contentPadding: EdgeInsets.zero,
          title: title,
          subtitle: _options.pet && _options.pets.isNotEmpty
              ? _summary(petSummary(_options.pets), 'option-pet', _pets)
              : null,
          value: _options.pet,
          onChanged: (v) => _pets(on: v),
        );
      case RideOptionKind.assistance:
        final help = _options.assistance;
        return SwitchListTile(
          key: const ValueKey('option-assistance'),
          contentPadding: EdgeInsets.zero,
          title: title,
          subtitle: help != null && !help.isEmpty
              ? _summary(assistanceSummary(help.items), 'option-assistance', _assistance)
              : null,
          value: help != null,
          onChanged: (v) => _assistance(on: v),
        );
      // The Freight page's; never on a ride's sheet (RideOptionsConfig.shown).
      case RideOptionKind.helperOne || RideOptionKind.helperTwo || RideOptionKind.closedBody || RideOptionKind.rideAlong:
        return const SizedBox.shrink();
    }
  }

  Future<void> _comments() async {
    final r = await showAppSheet<_Comments>(id: 'confirm.comments',
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
            for (final k in widget.config.shown(catalogue: widget.assistance)) _option(context, k),
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

/// The bars over the top of the confirm sheet (the promo bar, the demand
/// band): how much shows above the sheet's edge and how far it tucks under.
abstract final class SheetTopBar {
  /// How much of the bar shows above the sheet's top edge.
  static const visibleHeight = 40.0;

  /// How far the bar reaches under the sheet.
  static const tuck = 22.0;

  /// How far a bar runs on behind the bar stacked under it: past that
  /// bar's rounded top corners, so no map shows between the two.
  static const underlap = 20.0;

  /// How far a bar's foot runs behind the sheet: [tuck], or past the
  /// sheet's own rounded top corners where the admin made them deeper
  /// (App Page Settings, Map sheet top curve), so no map shows in them.
  static double footUnder(double sheetRadius) => math.max(tuck, sheetRadius + 2);
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
  const ConfirmSwitch({super.key, required this.value, required this.onChanged, this.semanticLabel});
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// What the switch turns on, for screen readers (the words beside it are
  /// a separate node).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final toggle = Switch(
      value: value,
      onChanged: onChanged,
      activeThumbColor: Colors.white,
      activeTrackColor: confirmAccent,
      inactiveThumbColor: dark ? const Color(0xFF1E1E1E) : Colors.white,
      inactiveTrackColor: dark ? const Color(0xFF5A5A5A) : const Color(0xFFE6E5E2),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(null),
    );
    return semanticLabel == null ? toggle : Semantics(label: semanticLabel, child: toggle);
  }
}

/// Expo's "Calculating fare" overlay: over the whole confirm screen while
/// the route and the AI's traffic-aware estimate are fetched, so no fare is
/// read or booked before it is settled.
class CalculatingFareOverlay extends StatelessWidget {
  const CalculatingFareOverlay({
    super.key,
    this.title = 'Calculating fare',
    this.message = 'Checking live traffic and distance for the best estimate…',
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Stack(
      key: const ValueKey('calculating-fare'),
      children: [
        const ModalBarrier(dismissible: false, color: Color(0x8C000000)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Material(
                color: t.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox.square(dimension: 40, child: CircularProgressIndicator(color: confirmAccent)),
                      const SizedBox(height: 18),
                      Text(
                        title,
                        key: const ValueKey('calculating-title'),
                        textAlign: TextAlign.center,
                        style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 18),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.45),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// What adding a stop is doing, step by step, in the "Calculating fare"
/// box; one step after another.
const addStopSteps = ['Calculating additional distance', 'Calculating additional fare', 'Updating route'];

/// The "Calculating fare" box over whatever screen is open, its title the
/// [step] adding a stop is on. Closed with `Navigator.pop`.
Future<void> showAddStopProgress(BuildContext context, ValueListenable<String> step) => showAppGeneralDialog<void>(id: 'ride.add-stop-progress',
  context: context,
  barrierDismissible: false,
  barrierColor: Colors.transparent,
  pageBuilder: (_, _, _) => PopScope(
    canPop: false,
    child: ValueListenableBuilder<String>(
      valueListenable: step,
      builder: (_, title, _) => CalculatingFareOverlay(
        key: const ValueKey('add-stop-progress'),
        title: title,
        message: 'Working out what the stop adds to the trip…',
      ),
    ),
  ),
);

/// What a new stop adds: [extraFare] (already formatted) and [extraMinutes],
/// to Add or Cancel. True to add it.
Future<bool> confirmAddStop(
  BuildContext context, {
  required String stopName,
  required String extraFare,
  required double extraMinutes,
}) async {
  final t = Theme.of(context);
  Widget line(String label, String value, Key key) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: Text(label, style: t.textTheme.bodyLarge)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            key: key,
            textAlign: TextAlign.end,
            style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
  final minutes = extraMinutes.round();
  final ok = await showAppDialog<bool>(id: 'ride.add-stop-confirm',
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      key: const ValueKey('add-stop-confirm'),
      scrollable: true,
      title: const Text('Add this stop?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(stopName, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          line('Additional cost', extraFare, const ValueKey('add-stop-cost')),
          line(
            'Additional time',
            minutes <= 0 ? 'No extra time' : '+${formatDuration(minutes)}',
            const ValueKey('add-stop-time'),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('add-stop-cancel'),
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('add-stop-add'),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Add'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// inDrive's band over the vehicle list while the fare is off the usual
/// (a fixed fare or an offer): in the discount bar's place, tucked under
/// the sheet's top edge, opening [showDemandSheet].
class DemandBanner extends StatelessWidget {
  const DemandBanner({super.key, required this.trend, required this.onTap, this.foot = SheetTopBar.tuck, this.color});

  final FareTrend trend;
  final VoidCallback onTap;

  /// How far it runs on below its visible part, behind what stands under
  /// it: the sheet (alone), or the promo bar ([DemandPromoBars]).
  final double foot;

  /// Its fill; null for [demandBandColor].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final up = trend.direction == FareTrendDirection.up;
    // One button to a screen reader, named by what it says and does.
    return Semantics(
      container: true,
      button: true,
      label: '${demandHeadline(trend.direction).replaceAll(' — ', ', ')}. Fare details',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
      key: ValueKey(up ? 'high-demand' : 'low-demand'),
      color: color ?? demandBandColor(t),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: InkWell(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 12, foot + 8),
          child: SizedBox(
            height: SheetTopBar.visibleHeight - 16,
            child: Row(
              children: [
                FareTrendArrows(trend: trend, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    demandHeadline(trend.direction),
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurface),
                  ),
                ),
                Icon(Icons.chevron_right, color: t.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// The demand band alone, over the sheet.
Color demandBandColor(ThemeData t) => t.colorScheme.surfaceContainerHigh;

/// The demand band and the promo bar together, the band on top: while the
/// fare is off the usual the promo code stays within reach. The band runs
/// on behind the promo bar, so only the bars' top corners show rounded and
/// no map shows between them; it is a shade deeper than the promo bar so
/// the promo bar's top still reads.
class DemandPromoBars extends StatelessWidget {
  const DemandPromoBars({super.key, required this.trend, required this.onDemand, required this.promo});

  final FareTrend trend;
  final VoidCallback onDemand;

  /// The promo bar under the band (promo_parts.dart's ConfirmPromoBar).
  final Widget promo;

  /// How much taller the pair stands than the promo bar alone.
  static const extraHeight = SheetTopBar.visibleHeight;

  @override
  Widget build(BuildContext context) => Stack(
    key: const ValueKey('demand-promo-bars'),
    children: [
      // Drawn first: its foot is behind the promo bar's top.
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: DemandBanner(
          trend: trend,
          onTap: onDemand,
          foot: SheetTopBar.underlap,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
      ),
      // The pair's size: the promo bar, under the band's visible part.
      Padding(padding: const EdgeInsets.only(top: extraHeight), child: promo),
    ],
  );
}

/// The trend as inDrive's details put it: the arrows, the headline and why.
class DemandNote extends StatelessWidget {
  const DemandNote({super.key, required this.trend});

  final FareTrend trend;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      key: const ValueKey('demand-note'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: FareTrendArrows(trend: trend, size: 22)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(demandDetail(trend.direction), style: t.textTheme.titleMedium),
              if (trend.explanation.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    trend.explanation,
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _okButton(BuildContext context) => SizedBox(
  width: double.infinity,
  child: FilledButton.tonal(
    key: const ValueKey('fare-info-ok'),
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(56),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    onPressed: () => Navigator.of(context).pop(),
    child: const Text('OK', style: TextStyle(fontSize: 18)),
  ),
);

/// The demand band's "Fare details" (inDrive's): why the fare is off the
/// usual, and OK.
Future<void> showDemandSheet(BuildContext context, FareTrend trend, {double? factor}) => showAppSheet<void>(id: 'ride.demand-details',
  context: context,
  isScrollControlled: true,
  builder: (ctx) => SafeArea(
    child: Padding(
      key: const ValueKey('demand-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Fare details', style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          if (trend.direction == FareTrendDirection.up) ...[
            const SizedBox(height: 12),
            // How much higher, from the fare with and without the trend.
            Text(
              demandHigherLine(factor),
              key: const ValueKey('demand-higher'),
              style: Theme.of(ctx).textTheme.bodyLarge,
            ),
          ],
          const SizedBox(height: 20),
          DemandNote(trend: trend),
          const SizedBox(height: 28),
          _okButton(ctx),
        ],
      ),
    ),
  ),
);

/// A fixed-fare vehicle's (i) (inDrive's): its picture, name and
/// description; for a metered taxi, that the meter decides, else the rates
/// the fare is priced on and what an in-app fare covers; then the coins,
/// tolls and taxes on this trip, the demand note, and OK.
class FareInfoSheet extends StatelessWidget {
  const FareInfoSheet({
    super.key,
    required this.service,
    required this.rates,
    this.tollCharges,
    this.tax,
    this.earn,
    this.trend,
  });

  final RideService service;

  /// [fareRateLines] for it at the pickup.
  final List<String> rates;

  /// This trip's estimated tolls, formatted; null for none.
  final String? tollCharges;

  /// The region's surcharges and taxes on the fare, one per line.
  final String? tax;

  /// "Earn 12 GC on this booking"; null for none.
  final String? earn;
  final FareTrend? trend;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // App Page Settings → Fare info.
    final style = SurfaceStyle.of(context, fareInfoSurface);
    final body = t.textTheme.bodyLarge?.copyWith(fontSize: style.number('bodySize'));
    final metered = isMeteredService(service);
    final imageWidth = style.number('imageWidth'), imageHeight = style.number('imageHeight');
    return SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('fare-details-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: imageWidth,
              height: imageHeight,
              child: uriImage(
                service.image,
                width: imageWidth,
                height: imageHeight,
                fallback: Icon(
                  metered ? Icons.local_taxi : Icons.directions_car,
                  size: 64,
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              service.name,
              style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: style.number('titleSize')),
            ),
            if (service.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(service.description, style: body),
            ],
            if (metered) ...[const SizedBox(height: 12), Text(meteredFareNote, key: const ValueKey('metered-note'), style: body)],
            if (rates.isNotEmpty) ...[
              const SizedBox(height: 20),
              for (final r in rates) Text(r, style: body),
            ],
            if (!metered) ...[
              const SizedBox(height: 20),
              Text(appFareNotesTitle, style: body),
              for (final n in appFareNotes) Text('• $n', style: body),
            ],
            if (earn != null || tollCharges != null || tax != null) ...[
              const SizedBox(height: 20),
              if (earn != null)
                Text(
                  earn!,
                  key: const ValueKey('booking-coin-earn'),
                  style: body?.copyWith(color: t.brightness == Brightness.dark ? const Color(0xFFFCD34D) : const Color(0xFFB45309)),
                ),
              if (tollCharges != null)
                Text(
                  'Est. Toll Charges $tollCharges',
                  key: const ValueKey('route-tolls'),
                  style: body?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              if (tax != null)
                Text(tax!, key: const ValueKey('fare-tax'), style: body?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
            if (trend != null) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: t.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: DemandNote(trend: trend!),
              ),
            ],
            const SizedBox(height: 20),
            _okButton(context),
          ],
        ),
      ),
    );
  }
}

Future<void> showFareInfo(BuildContext context, FareInfoSheet sheet) =>
    showAppSheet<void>(id: 'fare-info', context: context, fitContent: true, builder: (_) => sheet);

/// The booking button when rides can be scheduled: Now books at once,
/// Later asks for the pickup time first and books on Confirm. The side
/// tapped wears the raised pill, and spins while its booking runs.
class NowLaterButton extends StatefulWidget {
  const NowLaterButton({
    super.key,
    required this.onNow,
    required this.pickLater,
    required this.onLater,
    this.label = 'Find a driver',
  });

  /// The book-now button's words (the footer's label).
  final String label;

  /// Null while the booking can't go.
  final Future<void> Function()? onNow;
  final Future<DateTime?> Function()? pickLater;
  final Future<void> Function(DateTime at) onLater;

  @override
  State<NowLaterButton> createState() => _NowLaterButtonState();
}

class _NowLaterButtonState extends State<NowLaterButton> {
  bool _later = false;
  bool _busy = false;

  Future<void> _run(bool later) async {
    if (_busy || (later ? widget.pickLater : widget.onNow) == null) return;
    setState(() {
      _later = later;
      _busy = !later;
    });
    try {
      if (later) {
        final at = await widget.pickLater!();
        if (at == null || !mounted) return;
        setState(() => _busy = true);
        await widget.onLater(at);
      } else {
        await widget.onNow!();
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _later = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // One plain primary action, Find a driver, books now; Later, beside it,
    // is the secondary one (a Now|Later switch read as a toggle, not a go).
    final nowBusy = _busy && !_later;
    final laterBusy = _busy && _later;
    // Narrow (a 360 phone with the payment and options buttons beside it):
    // Later shrinks to its icon so "Find a driver" is read whole.
    return LayoutBuilder(builder: (context, box) {
      final compact = box.maxWidth < MediaQuery.textScalerOf(context).scale(nowLaterCompactWidth);
      final laterOnPressed = widget.pickLater == null || _busy ? null : () => _run(true);
      return SizedBox(
        key: const ValueKey('book-now-later'),
        height: 56,
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('book-now'),
                style: FilledButton.styleFrom(
                  backgroundColor: accentFill,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 56),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                onPressed: widget.onNow == null || _busy ? null : () => _run(false),
                icon: nowBusy ? const BusySpinner(size: 20, color: Colors.white) : const Icon(Icons.bolt),
                label: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            const SizedBox(width: 8),
            if (compact)
              Tooltip(
                message: 'Later',
                child: OutlinedButton(
                  key: const ValueKey('book-later'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(56, 56),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: laterOnPressed,
                  child: laterBusy
                      ? const BusySpinner(size: 20)
                      : const Icon(Icons.event, semanticLabel: 'Later'),
                ),
              )
            else
              OutlinedButton.icon(
                key: const ValueKey('book-later'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 56),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: laterOnPressed,
                icon: laterBusy ? const BusySpinner(size: 20) : const Icon(Icons.event),
                label: const Text('Later'),
              ),
          ],
        ),
      );
    });
  }
}

/// Below this width (at text scale 1) the book-now row shows Later as its
/// icon alone.
const nowLaterCompactWidth = 300.0;
