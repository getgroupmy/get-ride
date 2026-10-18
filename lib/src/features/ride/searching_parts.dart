import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/payment_types.dart' show paymentModeLabel;
import '../../core/request_viewers.dart';
import '../../core/ride_cancel.dart';
import '../../core/search_stage.dart';
import '../../widgets/ride_stop_tiles.dart';
import '../../data/models.dart';
import 'confirm_parts.dart';
import '../../widgets/net_image.dart';
import '../../widgets/page_style_host.dart';

// The rider's search for a driver, drawn as inDrive draws it: the sheet
// (stage headline and countdown, fare stepper, auto-accept, payment, route,
// Cancel request), the "Choose a driver" overlay its offers arrive on, and
// the two-step cancel sheet.

/// The Accept key's colour, and the darker one its timer drains to.
Color get offerAcceptColor => accentFill;
Color get offerAcceptSpent => Color.lerp(accentFill, Colors.black, 0.28)!;

/// The grey of inDrive's secondary keys (Decline, Cancel request).
Color searchGreyKey(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF3A3A3A) : const Color(0xFFEDECE9);

/// A white (or charcoal) rounded block of the search sheet.
class SearchBlock extends StatelessWidget {
  const SearchBlock({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 8),
    padding: padding,
    decoration: BoxDecoration(
      color: color ?? ConfirmCardColors.of(context).tray,
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

/// "All drivers verified", with the blue shield.
class DriversVerified extends StatelessWidget {
  const DriversVerified({super.key, this.color});
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.verified_user, size: 20, color: Color(0xFF3B6CF6)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'All drivers verified',
            style: t.textTheme.titleMedium?.copyWith(color: color ?? t.colorScheme.onSurface),
          ),
        ),
      ],
    );
  }
}

/// The headline: the stage the search is at, the time left on the request
/// and its bar.
class SearchHeader extends StatelessWidget {
  const SearchHeader({
    super.key,
    required this.elapsed,
    required this.left,
    required this.progress,
    this.bidding = true,
    this.waitHint,
    this.offers = 0,
  });

  /// Offers waiting for the rider: the headline says so instead of
  /// cycling through the search's stages.
  final int offers;
  final Duration elapsed;
  final String left;
  final double progress;

  /// How near the drivers are ("Nearest driver about 3 min away", "Few
  /// drivers nearby"), beside the countdown; null shows nothing.
  final String? waitHint;

  /// Whether the request is open to offers; a fixed-fare one says nothing
  /// about prices or offers.
  final bool bidding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stage = offers > 0
        ? (
            id: 'offers',
            title: offers == 1 ? '1 offer — choose a driver' : '$offers offers — choose a driver',
            subtitle: 'Accept the one that suits you',
          )
        : searchStageAt(elapsed, bidding: bidding);
    final ink = t.colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                child: Column(
                  key: ValueKey('search-stage-${stage.id}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(stage.title, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    if (stage.id == 'searching')
                      const DriversVerified()
                    else
                      Text(stage.subtitle, style: t.textTheme.titleMedium),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  left,
                  key: const ValueKey('search-time-left'),
                  style: t.textTheme.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                if (waitHint case final hint?)
                  ConstrainedBox(
                    // Narrow enough to leave the headline its room on a
                    // small phone at large text; it wraps instead.
                    constraints: BoxConstraints(maxWidth: math.min(140, MediaQuery.sizeOf(context).width * 0.34)),
                    child: Text(
                      hint,
                      key: const ValueKey('search-wait-hint'),
                      textAlign: TextAlign.end,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            key: const ValueKey('search-progress'),
            value: progress,
            minHeight: 4,
            color: ink,
            backgroundColor: ink.withValues(alpha: 0.12),
          ),
        ),
      ],
    );
  }
}

/// No offer yet on a request open to offers: the fare as it stands, a
/// one-tap raise by the usual step, and Keep waiting.
class SearchRaiseCard extends StatelessWidget {
  const SearchRaiseCard({
    super.key,
    required this.fare,
    required this.raisedTo,
    required this.onRaise,
    required this.onKeepWaiting,
  });

  /// The fare offered now ("RM 20.00").
  final String fare;

  /// What one raise would make it, or null when it can go no higher.
  final String? raisedTo;

  /// Null while busy.
  final VoidCallback? onRaise;
  final VoidCallback onKeepWaiting;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = ConfirmCardColors.of(context);
    final to = raisedTo;
    return Container(
      key: const ValueKey('search-raise-card'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: c.tray,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accentFill, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              to == null ? 'No offers yet' : 'Raise your fare and search again',
              style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            to == null
                ? 'Your fare of $fare is as high as it can go. Drivers nearby can still take it.'
                : 'No driver has answered at $fare yet. A higher fare often gets one sooner.',
            key: const ValueKey('search-raise-body'),
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          if (to != null) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: FilledButton(
                key: const ValueKey('search-raise-now'),
                onPressed: onRaise,
                style: FilledButton.styleFrom(
                  backgroundColor: accentFill,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text('Raise to $to', textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(height: 4),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: TextButton(
              key: const ValueKey('search-keep-waiting'),
              onPressed: onKeepWaiting,
              style: TextButton.styleFrom(foregroundColor: t.colorScheme.onSurface),
              child: const Text('Keep waiting'),
            ),
          ),
        ],
      ),
    );
  }
}

/// inDrive's −/+ fare tray with Confirm under it: the keys move a target,
/// and nothing is sent until Confirm.
class SearchFareStepper extends StatelessWidget {
  const SearchFareStepper({
    super.key,
    required this.amount,
    required this.canLower,
    required this.canRaise,
    required this.onLower,
    required this.onRaise,
    required this.onConfirm,
    required this.confirmLabel,
  });

  final String amount;
  final bool canLower, canRaise;
  final VoidCallback onLower, onRaise;

  /// Null while there is nothing to confirm.
  final VoidCallback? onConfirm;
  final String confirmLabel;

  Widget _round(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tip,
    VoidCallback? onTap,
  }) {
    final c = ConfirmCardColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: tip,
      child: Material(
        color: onTap == null ? c.tray : c.round,
        shape: const CircleBorder(),
        elevation: onTap == null ? 0 : 1,
        shadowColor: Colors.black26,
        child: InkWell(
          key: key,
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 56,
            child: Icon(icon, size: 26, color: onTap == null ? ink.withValues(alpha: 0.3) : ink),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = ConfirmCardColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.tray,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.trayBorder),
          ),
          child: Row(
            children: [
              _round(
                context,
                key: const ValueKey('search-fare-lower'),
                icon: Icons.remove,
                tip: 'Lower',
                onTap: canLower ? onLower : null,
              ),
              Expanded(
                child: Text(
                  amount,
                  key: const ValueKey('search-fare'),
                  textAlign: TextAlign.center,
                  style: t.textTheme.headlineSmall?.copyWith(fontSize: 28, fontWeight: FontWeight.w500),
                ),
              ),
              _round(
                context,
                key: const ValueKey('search-fare-raise'),
                icon: Icons.add,
                tip: 'Raise',
                onTap: canRaise ? onRaise : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 56,
          child: FilledButton(
            key: const ValueKey('search-fare-confirm'),
            onPressed: onConfirm,
            style: FilledButton.styleFrom(
              backgroundColor: accentFill,
              foregroundColor: Colors.white,
              disabledBackgroundColor: c.tray,
              disabledForegroundColor: t.colorScheme.onSurface.withValues(alpha: 0.35),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            child: Text(confirmLabel),
          ),
        ),
      ],
    );
  }
}

/// The payment the driver will be paid in: "RM 12.00 Cash".
class SearchPaymentRow extends StatelessWidget {
  const SearchPaymentRow({super.key, required this.amount, required this.mode});
  final String amount;
  final String mode;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cash = mode.toLowerCase() == 'cash';
    return Row(
      key: const ValueKey('search-payment'),
      children: [
        Icon(cash ? Icons.payments : Icons.credit_card, color: cash ? const Color(0xFF6BBF2A) : confirmAccent),
        const SizedBox(width: 16),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '$amount '),
                TextSpan(
                  text: paymentModeLabel(mode),
                  style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            style: t.textTheme.titleMedium,
          ),
        ),
      ],
    );
  }
}

/// Pickup (the rider), the stops, and the destination flag, joined by a line.
class SearchRouteCard extends StatelessWidget {
  const SearchRouteCard({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    String line(String label, String? address) =>
        address == null || address.isEmpty || address == label ? label : '$label ($address)';
    return Column(
      key: const ValueKey('search-route'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.emoji_people),
            const SizedBox(width: 12),
            Expanded(child: Text(line(ride.pickupLabel, ride.pickupAddress), style: t.textTheme.titleMedium)),
          ],
        ),
        if (ride.stops.isNotEmpty) RideStopTiles(stops: ride.stops),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.flag),
            const SizedBox(width: 12),
            Expanded(child: Text(line(ride.dropLabel, ride.dropAddress), style: t.textTheme.titleMedium)),
          ],
        ),
      ],
    );
  }
}

/// A grey full-width key, as inDrive's Cancel request / Decline / Skip.
class SearchGreyButton extends StatelessWidget {
  const SearchGreyButton({super.key, required this.label, required this.onPressed, this.height = 56});
  final String label;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: searchGreyKey(context),
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
      ),
      child: Text(label),
    ),
  );
}

/// One driver's offer as the overlay shows it.
class SearchOfferView {
  const SearchOfferView({
    required this.key,
    required this.price,
    required this.yourFare,
    required this.progress,
    required this.onAccept,
    required this.onDecline,
    this.name,
    this.rating,
    this.rides,
    this.vehicle,
    this.photo,
    this.etaMin,
    this.demo = false,
    this.cardKey,
    this.acceptKey,
    this.declineKey,
    this.amount,
    this.difference,
    this.secondsLeft,
  });

  final String key;
  final String price;

  /// The offer's amount, for ordering the cards by price.
  final double? amount;

  /// How far it is from the rider's fare ("+RM1.00"); null when it is the
  /// rider's own fare ([yourFare]) or unknown.
  final String? difference;

  /// Whole seconds left on the offer, read out with Accept.
  final int? secondsLeft;

  /// The offer is the rider's own fare.
  final bool yourFare;

  /// What is left of the offer's window, 1 → 0.
  final double progress;
  final VoidCallback? onAccept, onDecline;
  final String? name, vehicle, photo;
  final double? rating;
  final int? rides, etaMin;
  final bool demo;
  final Key? cardKey, acceptKey, declineKey;
}

/// The cards in the order the rider compares them: cheapest first, then
/// the nearer driver; offers that tie keep the order they came in.
List<SearchOfferView> sortOffers(List<SearchOfferView> offers) {
  final indexed = offers.indexed.toList();
  indexed.sort((a, b) {
    final pa = a.$2.amount ?? double.infinity, pb = b.$2.amount ?? double.infinity;
    if (pa != pb) return pa.compareTo(pb);
    final ea = a.$2.etaMin ?? 1 << 20, eb = b.$2.etaMin ?? 1 << 20;
    if (ea != eb) return ea.compareTo(eb);
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, o) in indexed) o];
}

/// What Accept is read out as: "Accept RM11.00 from Mellier, 8 seconds left".
String offerAcceptLabel(SearchOfferView o) {
  final from = o.name == null ? '' : ' from ${o.name}';
  final left = switch (o.secondsLeft) {
    null => '',
    1 => ', 1 second left',
    final n => ', $n seconds left',
  };
  return 'Accept ${o.price}$from$left';
}

/// The Accept key with the offer's time running out across it: the bright
/// part shrinks toward the left as the window drains.
class OfferAcceptButton extends StatelessWidget {
  const OfferAcceptButton({
    super.key,
    required this.progress,
    required this.onPressed,
    this.timerKey,
    this.semanticLabel,
  });
  final double progress;
  final VoidCallback? onPressed;
  final Key? timerKey;

  /// Read out instead of a bare "Accept" (the price, driver and time left).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    // A button node of its own, named in full: not merged with the card.
    return Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      label: semanticLabel ?? 'Accept',
      onTap: onPressed,
      excludeSemantics: true,
      child: Material(
      color: offerAcceptSpent,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          height: 52,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  key: timerKey,
                  widthFactor: progress.clamp(0.0, 1.0),
                  heightFactor: 1,
                  child: ColoredBox(color: offerAcceptColor),
                ),
              ),
              const Center(
                child: Text(
                  'Accept',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}

/// inDrive's offer card: price and how far away, "Your fare", the driver,
/// Decline and the timed Accept.
class SearchOfferCard extends StatelessWidget {
  const SearchOfferCard({super.key, required this.offer});
  final SearchOfferView offer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final o = offer;
    return Material(
      key: o.cardKey,
      color: ConfirmCardColors.of(context).card,
      borderRadius: BorderRadius.circular(24),
      elevation: 6,
      shadowColor: Colors.black45,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                // Price and time shrink together rather than pushing off the card.
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(o.price, style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                        if (o.difference case final d?) ...[
                          const SizedBox(width: 8),
                          Text(
                            d,
                            key: ValueKey('offer-difference-${o.key}'),
                            style: t.textTheme.titleMedium?.copyWith(color: muted, fontWeight: FontWeight.w600),
                          ),
                        ],
                        if (o.etaMin != null) ...[
                          const SizedBox(width: 12),
                          Text(
                            '${o.etaMin} min',
                            style: t.textTheme.headlineMedium?.copyWith(color: muted, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (o.demo) const _DemoTag(),
              ],
            ),
            if (o.yourFare)
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: confirmAccent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.thumb_up, size: 16, color: t.colorScheme.onSurface),
                      const SizedBox(width: 6),
                      Text('Your fare', style: t.textTheme.titleSmall),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  child: o.photo == null
                      ? Text((o.name ?? '?').characters.first)
                      : ClipOval(
                          child: Image.network(
                            o.photo!,
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            frameBuilder: boneUntilPainted(width: 44, height: 44, circle: true),
                            errorBuilder: (_, _, _) => const Icon(Icons.person),
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: o.name ?? 'A driver'),
                            if (o.rating != null) ...[
                              const TextSpan(text: ' '),
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Icon(Icons.star, size: 18, color: t.colorScheme.onSurface),
                              ),
                              TextSpan(text: o.rating!.toStringAsFixed(o.rating! * 10 % 1 == 0 ? 1 : 2)),
                            ],
                            if (o.rides != null)
                              TextSpan(
                                text: ' ${o.rides} rides',
                                style: TextStyle(color: muted),
                              ),
                          ],
                        ),
                        style: t.textTheme.titleMedium,
                      ),
                      if (o.vehicle != null) Text(o.vehicle!, style: t.textTheme.titleMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: SearchGreyButton(key: o.declineKey, label: 'Decline', height: 52, onPressed: o.onDecline),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OfferAcceptButton(
                    key: o.acceptKey,
                    progress: o.progress,
                    onPressed: o.onAccept,
                    semanticLabel: offerAcceptLabel(o),
                    timerKey: ValueKey('offer-countdown-${o.key}'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoTag extends StatelessWidget {
  const _DemoTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: const Color(0xFF7C3AED), borderRadius: BorderRadius.circular(6)),
    child: const Text(
      'DEMO',
      style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
    ),
  );
}

/// Offer cards as inDrive deals them: each flies in from the right, tilted,
/// and straightens as it lands; an answered, replaced or lapsed one tilts
/// and flies off to the left. The rider can also throw a card away by
/// swiping it left, which declines it.
class OfferStack extends StatefulWidget {
  const OfferStack({super.key, required this.offers, this.gap = 12});
  final List<SearchOfferView> offers;
  final double gap;

  @override
  State<OfferStack> createState() => _OfferStackState();
}

class _OfferEntry {
  _OfferEntry(this.view, this.controller);
  SearchOfferView view;
  final AnimationController controller;
  bool leaving = false;

  /// How far the rider has dragged the card, in pixels (negative is left).
  double drag = 0;

  /// Where the card was, as a share of its width, when it began to leave:
  /// a swiped card flies on from where the finger let go.
  double leaveFrom = 0;
}

/// How long a card takes to come in, and to go.
const offerInDuration = Duration(milliseconds: 460);
const offerOutDuration = Duration(milliseconds: 340);

/// The tilt a card comes in and goes out with: 15°, as Expo's
/// (`ride-confirm.tsx`), in radians.
const offerTilt = 0.2618;

/// A left swipe past this share of the card's width (or a quick flick)
/// declines it; anything less springs back.
const offerSwipeDecline = 0.32;
const offerFlickVelocity = 700.0;

class _OfferStackState extends State<OfferStack> with TickerProviderStateMixin {
  final _entries = <_OfferEntry>[];

  @override
  void initState() {
    super.initState();
    for (final o in widget.offers) {
      _entries.add(_enter(o));
    }
  }

  _OfferEntry _enter(SearchOfferView o) {
    final c = AnimationController(vsync: this, duration: offerInDuration, reverseDuration: offerOutDuration);
    final e = _OfferEntry(o, c);
    c.forward();
    return e;
  }

  /// Sends [e] off to the left, from wherever it is now.
  void _leave(_OfferEntry e, double width) {
    if (e.leaving) return;
    e.leaving = true;
    e.leaveFrom = width > 0 ? e.drag / width : 0;
    e.drag = 0;
    e.controller.reverse(from: 1).whenComplete(() {
      if (!mounted || !e.leaving) return;
      setState(() => _entries.remove(e));
      e.controller.dispose();
    });
  }

  double _width = 0;

  @override
  void didUpdateWidget(covariant OfferStack old) {
    super.didUpdateWidget(old);
    final now = {for (final o in widget.offers) o.key: o};
    for (final e in _entries) {
      final fresh = now[e.view.key];
      if (fresh != null) {
        e.view = fresh;
        if (e.leaving && !e.controller.isAnimating) {
          // Still offered after all (a decline that didn't go through).
          e.leaving = false;
          e.leaveFrom = 0;
          e.controller.forward();
        }
      } else if (!e.leaving) {
        _leave(e, _width);
      }
    }
    // A new card goes in where it belongs in the order it was given (by
    // price, [sortOffers]); the cards already on screen keep their places,
    // so nothing jumps while the rider reads.
    final known = {for (final e in _entries) e.view.key};
    final order = {for (final (i, o) in widget.offers.indexed) o.key: i};
    for (final o in widget.offers) {
      if (known.contains(o.key)) continue;
      final at = _entries.indexWhere((e) => !e.leaving && (order[e.view.key] ?? -1) > order[o.key]!);
      final entry = _enter(o);
      at < 0 ? _entries.add(entry) : _entries.insert(at, entry);
      known.add(o.key);
    }
  }

  @override
  void dispose() {
    for (final e in _entries) {
      e.controller.dispose();
    }
    super.dispose();
  }

  void _dragUpdate(_OfferEntry e, DragUpdateDetails d) {
    if (e.leaving) return;
    // Left only, as Expo's: there is nothing to the right.
    setState(() => e.drag = math.min(0, e.drag + d.delta.dx));
  }

  void _dragEnd(_OfferEntry e, DragEndDetails d) {
    if (e.leaving) return;
    final v = d.primaryVelocity ?? 0;
    final decline = e.view.onDecline;
    if (decline != null && _width > 0 && (e.drag < -_width * offerSwipeDecline || v < -offerFlickVelocity)) {
      _leave(e, _width);
      setState(() {});
      decline();
      return;
    }
    // Not far enough: back into place.
    final from = e.drag;
    final back = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    final curve = CurvedAnimation(parent: back, curve: Curves.easeOutBack);
    back.addListener(() {
      if (mounted && !e.leaving) setState(() => e.drag = from * (1 - curve.value));
    });
    back.forward().whenComplete(back.dispose);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth.isFinite ? constraints.maxWidth : MediaQuery.sizeOf(context).width;
      final w = _width;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in _entries)
            AnimatedBuilder(
              key: ValueKey('offer-entry-${e.view.key}'),
              animation: e.controller,
              builder: (context, child) {
                final v = e.controller.value;
                final double dx; // share of the card's width
                final double angle;
                final double opacity;
                if (e.leaving) {
                  // 1 → 0 as it goes: tilt and fly off to the left.
                  final p = Curves.easeInCubic.transform(1 - v);
                  dx = e.leaveFrom + p * (-1.5 - e.leaveFrom);
                  // The swipe's tilt carries on to the full 15° as it goes.
                  final from = math.max(-offerTilt, e.leaveFrom * offerTilt);
                  angle = from + p * (-offerTilt - from);
                  opacity = (1 - p * 0.9).clamp(0.0, 1.0);
                } else {
                  // 0 → 1 as it comes: in from the right, tilted, then level.
                  final p = Curves.easeOutCubic.transform(v);
                  final drag = w > 0 ? e.drag / w : 0.0;
                  dx = (1 - p) * 1.2 + drag;
                  // Dragging tilts it with the finger, up to 15° at a full
                  // width (Expo's).
                  angle = (1 - p) * offerTilt + math.max(-offerTilt, drag * offerTilt);
                  opacity = Curves.easeOut.transform(v).clamp(0.0, 1.0);
                }
                // The slot opens before the card lands, and closes once it
                // has gone.
                final height = Curves.easeInOut.transform((v / 0.5).clamp(0.0, 1.0));
                final card = FractionalTranslation(
                  translation: Offset(dx, 0),
                  child: Transform.rotate(
                    angle: angle,
                    alignment: Alignment.bottomCenter,
                    child: Opacity(opacity: opacity, child: child),
                  ),
                );
                final slot = Align(alignment: Alignment.topCenter, heightFactor: height, child: card);
                return height >= 0.999 ? slot : ClipRect(clipper: const _SideOpenClip(), child: slot);
              },
              child: Padding(
                padding: EdgeInsets.only(bottom: widget.gap),
                child: IgnorePointer(
                  ignoring: e.leaving,
                  child: GestureDetector(
                    key: ValueKey('offer-swipe-${e.view.key}'),
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (d) => _dragUpdate(e, d),
                    onHorizontalDragEnd: (d) => _dragEnd(e, d),
                    child: SearchOfferCard(offer: e.view),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Clips a card's slot top and bottom only, so a card flying in or out
/// sideways is not cut off at the column's edge.
class _SideOpenClip extends CustomClipper<Rect> {
  const _SideOpenClip();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-size.width * 3, 0, size.width * 4, size.height);

  @override
  bool shouldReclip(covariant _SideOpenClip old) => false;
}

/// inDrive's "Choose a driver": the screen over the sheet's foot dims, and
/// the offers stack under the title. Cancel request stays the sheet's own,
/// pinned under the dim (one way to cancel, not two).
class ChooseDriverOverlay extends StatelessWidget {
  const ChooseDriverOverlay({super.key, required this.offers});
  final List<SearchOfferView> offers;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final showing = offers.isNotEmpty;
    return IgnorePointer(
      ignoring: !showing,
      child: AnimatedOpacity(
        key: const ValueKey('choose-driver'),
        opacity: showing ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.62),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Choose a driver',
                    style: t.textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  const DriversVerified(color: Colors.white),
                  const SizedBox(height: 16),
                  OfferStack(offers: offers),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the cancel sheets came back with.
typedef SearchCancelChoice = ({bool cancel, String? reason});

/// inDrive's cancel: "Why do you want to cancel?" (a reason, or Skip), then
/// "Cancel your request?" with Keep searching first. Null keeps searching.
Future<SearchCancelChoice?> showSearchCancelSheet(BuildContext context) async {
  final reason = await showAppSheet<String>(id: 'searching.show-search-cancel-sheet',
    context: context,
    fitContent: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (c) => const _WhyCancelSheet(),
  );
  if (reason == null || !context.mounted) return null;
  final sure = await showAppSheet<bool>(id: 'searching.show-search-cancel-sheet-2',
    context: context,
    fitContent: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (c) => const _SureCancelSheet(),
  );
  if (sure != true) return null;
  return (cancel: true, reason: reason == _skip ? null : reason);
}

const _skip = '_skip';

const _reasonIcons = <String, IconData>{
  'drivers_too_far': Icons.route,
  'high_fares': Icons.local_atm,
  'accidental_request': Icons.warning_amber_rounded,
  'wrong_points': Icons.location_off_outlined,
  'no_offers': Icons.feed_outlined,
  'better_alternative': Icons.directions_bus_outlined,
};

class _WhyCancelSheet extends StatelessWidget {
  const _WhyCancelSheet();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Why do you want to cancel?',
                    style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('cancel-sheet-close'),
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final r in searchCancelReasons)
              ListTile(
                key: ValueKey('cancel-reason-${r.id}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(_reasonIcons[r.id] ?? Icons.help_outline, color: t.colorScheme.onSurface),
                title: Text(r.label, style: t.textTheme.titleMedium),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, r.id),
              ),
            const SizedBox(height: 12),
            SearchGreyButton(
              key: const ValueKey('cancel-skip'),
              label: 'Skip',
              onPressed: () => Navigator.pop(context, _skip),
            ),
          ],
        ),
      ),
    );
  }
}

class _SureCancelSheet extends StatelessWidget {
  const _SureCancelSheet();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back',
                onPressed: () => Navigator.pop(context, false),
                icon: const Icon(Icons.arrow_back),
              ),
            ),
            const SizedBox(height: 8),
            Text('Cancel your request?', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 24),
            SizedBox(
              height: 56,
              child: FilledButton(
                key: const ValueKey('cancel-keep-searching'),
                onPressed: () => Navigator.pop(context, false),
                style: FilledButton.styleFrom(
                  backgroundColor: accentFill,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                child: const Text('Keep searching'),
              ),
            ),
            const SizedBox(height: 12),
            SearchGreyButton(
              key: const ValueKey('cancel-confirm'),
              label: 'Cancel request',
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
  }
}

/// inDrive's bar over the search sheet: "3 drivers are viewing your
/// request", with their faces overlapping on the right and "+9".
class DriversViewingBar extends StatelessWidget {
  const DriversViewingBar({super.key, required this.viewers, this.demo = false, this.demoNames = const []});
  final RequestViewers viewers;

  /// Admin → Demo: initials stand in for faces, and the DEMO mark shows.
  final bool demo;
  final List<String> demoNames;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final label = viewers.label;
    if (label == null) return const SizedBox.shrink();
    final (:faces, :more) = viewers.faces();
    // As many faces as the number says, at most four: initials stand in
    // for the demo's, never more than it counts.
    final count = viewers.viewing > 0 ? viewers.viewing : viewers.viewed;
    final initials = demo ? math.max(0, math.min(math.min(4, count), demoNames.length + faces.length) - faces.length) : 0;
    final ring = ConfirmCardColors.of(context).tray;
    Widget face(Widget child) => Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 2)),
      child: ClipOval(child: child),
    );
    final circles = <Widget>[
      for (final url in faces)
        face(Image.network(url, fit: BoxFit.cover, frameBuilder: boneUntilPainted(), errorBuilder: (_, _, _) => const ColoredBox(color: Colors.grey))),
      for (final n in demoNames.take(initials))
        face(CircleAvatar(child: Text(n[0], style: const TextStyle(fontSize: 11)))),
    ];
    final extra = math.max(0, more - initials);
    return Container(
      key: const ValueKey('drivers-viewing'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(color: ring, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(label, key: ValueKey(label), style: t.textTheme.titleSmall?.copyWith(fontSize: 15)),
            ),
          ),
          if (demo) ...[const SizedBox(width: 6), const _DemoTag(), const SizedBox(width: 6)],
          if (circles.isNotEmpty || extra > 0)
            SizedBox(
              height: 30,
              width: 20.0 * (circles.length + (extra > 0 ? 1 : 0) - 1) + (extra > 0 ? 44 : 30),
              child: Stack(
                children: [
                  for (var i = 0; i < circles.length; i++) Positioned(left: 20.0 * i, child: circles[i]),
                  if (extra > 0)
                    Positioned(
                      left: 20.0 * circles.length,
                      child: Container(
                        key: const ValueKey('drivers-viewing-more'),
                        height: 30,
                        constraints: const BoxConstraints(minWidth: 30),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: ConfirmCardColors.of(context).card,
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(color: ring, width: 2),
                        ),
                        child: Text('+$extra', style: t.textTheme.labelLarge),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
