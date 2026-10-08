import 'package:flutter/material.dart';

import '../../core/ride_cancel.dart';
import '../../core/search_stage.dart';
import '../../widgets/ride_stop_tiles.dart';
import '../../data/models.dart';
import 'confirm_parts.dart';

// The rider's search for a driver, drawn as inDrive draws it: the sheet
// (stage headline and countdown, fare stepper, auto-accept, payment, route,
// Cancel request), the "Choose a driver" overlay its offers arrive on, and
// the two-step cancel sheet.

/// The Accept key's colour, and the darker one its timer drains to.
Color get offerAcceptColor => confirmAccent;
Color get offerAcceptSpent => Color.lerp(confirmAccent, Colors.black, 0.28)!;

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
  const SearchHeader({super.key, required this.elapsed, required this.left, required this.progress});
  final Duration elapsed;
  final String left;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stage = searchStageAt(elapsed);
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
            Text(
              left,
              key: const ValueKey('search-time-left'),
              style: t.textTheme.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
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
              backgroundColor: confirmAccent,
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
                  text: mode,
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
  });

  final String key;
  final String price;

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

/// The Accept key with the offer's time running out across it: the bright
/// part shrinks toward the left as the window drains.
class OfferAcceptButton extends StatelessWidget {
  const OfferAcceptButton({super.key, required this.progress, required this.onPressed, this.timerKey});
  final double progress;
  final VoidCallback? onPressed;
  final Key? timerKey;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return Material(
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
                Text(o.price, style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                if (o.etaMin != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    '${o.etaMin} min',
                    style: t.textTheme.headlineMedium?.copyWith(color: muted, fontWeight: FontWeight.w600),
                  ),
                ],
                const Spacer(),
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

/// Offer cards that rise into place from below as they arrive and slide
/// away to the left as they are answered, replaced or lapse (inDrive's).
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
}

/// How long a card takes to come in, and to go.
const offerInDuration = Duration(milliseconds: 420);
const offerOutDuration = Duration(milliseconds: 320);

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

  @override
  void didUpdateWidget(covariant OfferStack old) {
    super.didUpdateWidget(old);
    final now = {for (final o in widget.offers) o.key: o};
    for (final e in _entries) {
      final fresh = now[e.view.key];
      if (fresh != null) {
        e.view = fresh;
        if (e.leaving) {
          e.leaving = false;
          e.controller.forward();
        }
      } else if (!e.leaving) {
        e.leaving = true;
        e.controller.reverse().whenComplete(() {
          if (!mounted || !e.leaving) return;
          setState(() => _entries.remove(e));
          e.controller.dispose();
        });
      }
    }
    final known = {for (final e in _entries) e.view.key};
    for (final o in widget.offers) {
      if (!known.contains(o.key)) _entries.add(_enter(o));
    }
  }

  @override
  void dispose() {
    for (final e in _entries) {
      e.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final e in _entries)
        AnimatedBuilder(
          key: ValueKey('offer-entry-${e.view.key}'),
          animation: e.controller,
          builder: (context, child) {
            final v = e.controller.value;
            final curved = (e.leaving ? Curves.easeInCubic : Curves.easeOutCubic).transform(v);
            // In: up from below. Out: away to the left.
            final slide = e.leaving ? Offset(-(1 - curved) * 1.1, 0) : Offset(0, (1 - curved) * 0.6);
            return ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: Curves.easeInOut.transform(v),
                child: FractionalTranslation(
                  translation: slide,
                  child: Opacity(opacity: curved.clamp(0.0, 1.0), child: child),
                ),
              ),
            );
          },
          child: Padding(
            padding: EdgeInsets.only(bottom: widget.gap),
            child: IgnorePointer(
              ignoring: e.leaving,
              child: SearchOfferCard(offer: e.view),
            ),
          ),
        ),
    ],
  );
}

/// inDrive's "Choose a driver": the screen dims, and the offers stack under
/// a Cancel request pill and the title.
class ChooseDriverOverlay extends StatelessWidget {
  const ChooseDriverOverlay({super.key, required this.offers, required this.onCancel});
  final List<SearchOfferView> offers;
  final VoidCallback? onCancel;

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
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Material(
                      color: const Color(0xFFFCE4E6),
                      shape: const StadiumBorder(),
                      child: InkWell(
                        key: const ValueKey('overlay-cancel-request'),
                        customBorder: const StadiumBorder(),
                        onTap: onCancel,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.close, color: Colors.black87),
                              SizedBox(width: 10),
                              Text(
                                'Cancel request',
                                style: TextStyle(color: Colors.black87, fontSize: 17, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
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
  final reason = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (c) => const _WhyCancelSheet(),
  );
  if (reason == null || !context.mounted) return null;
  final sure = await showModalBottomSheet<bool>(
    context: context,
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
                  backgroundColor: confirmAccent,
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
