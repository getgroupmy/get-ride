// Rider promo codes in the app (migration 0242): the home "promo zone" bar,
// the confirm step's promo bar and sheet, the driver's "Promo applied" mark,
// and the promo lines on the driver's trip, receipts and history.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/format.dart' show formatMoney;
import '../../core/promo_codes.dart';
import '../../data/models.dart';
import '../../widgets/page_style_host.dart';
import 'confirm_parts.dart' show SheetTopBar;

/// How far the rider must move before the home bar asks the server again.
const promoZoneRecheckMetres = 250.0;

/// Whether the home bar should ask again: the first fix, a move of
/// [promoZoneRecheckMetres] or more, or [force] (the app came back).
bool promoZoneRecheckDue(LatLng? lastAsked, LatLng now, {bool force = false}) =>
    force || lastAsked == null || const Distance()(lastAsked, now) >= promoZoneRecheckMetres;

/// The trip the confirm step's offers were read for: they are read again
/// when any of it changes.
String promoTripKey({
  required LatLng pickup,
  required LatLng drop,
  required String service,
  required double fare,
}) =>
    '${pickup.latitude.toStringAsFixed(5)},${pickup.longitude.toStringAsFixed(5)}'
    '|${drop.latitude.toStringAsFixed(5)},${drop.longitude.toStringAsFixed(5)}'
    '|${service.toLowerCase()}|${fare.toStringAsFixed(2)}';

/// What the confirm step applies after the offers are read again: the
/// rider's own pick while it still applies, else the auto-applied one
/// (unless the rider took it off).
({PromoOffer? promo, bool auto}) promoAfterOffers(
  List<PromoOffer> offers, {
  PromoOffer? current,
  bool currentAuto = false,
  bool removed = false,
}) {
  if (current != null) {
    final kept = offers.where((o) => o.codeId == current.codeId).firstOrNull;
    if (kept != null) return (promo: kept, auto: currentAuto);
  }
  if (removed) return (promo: null, auto: false);
  final auto = offers.where((o) => o.autoApply).firstOrNull;
  return (promo: auto, auto: auto != null);
}

/// The bar's colours: the theme's tertiary container, in light and dark.
({Color bg, Color fg}) _promoColours(ThemeData t) =>
    (bg: t.colorScheme.tertiaryContainer, fg: t.colorScheme.onTertiaryContainer);

/// Home: "You are within promo zone", over the top of the sheet.
class PromoZoneBar extends StatelessWidget {
  const PromoZoneBar({super.key, this.onTap});
  final VoidCallback? onTap;

  static const visibleHeight = SheetTopBar.visibleHeight;
  static const tuck = SheetTopBar.tuck;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = _promoColours(t);
    return Semantics(
      container: true,
      label: 'You are within promo zone',
      child: Material(
        key: const ValueKey('promo-zone-bar'),
        color: c.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: InkWell(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, tuck + 8),
            child: SizedBox(
              height: visibleHeight - 16,
              child: ExcludeSemantics(
                child: Row(children: [
                  Icon(Icons.local_offer, size: 18, color: c.fg),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'You are within promo zone',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodyMedium?.copyWith(color: c.fg, fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The confirm step's promo bar, over the top of the sheet: the code
/// applied (by itself or by the rider) and what the rider pays after it, or
/// the codes that apply to the trip, to pick from.
class ConfirmPromoBar extends StatelessWidget {
  const ConfirmPromoBar({
    super.key,
    required this.offers,
    required this.applied,
    required this.auto,
    required this.fare,
    required this.onTap,
    this.currency = 'MYR',
  });

  final List<PromoOffer> offers;
  final PromoOffer? applied;
  final bool auto;
  final double fare;
  final String currency;
  final VoidCallback onTap;

  static const visibleHeight = SheetTopBar.visibleHeight;
  static const tuck = SheetTopBar.tuck;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = _promoColours(t);
    final muted = t.colorScheme.onSurfaceVariant;
    final p = applied;
    final pay = p == null ? null : fare - p.estimatedDiscount;
    final title = p == null
        ? (offers.length == 1 ? 'Promo ${offers.first.code} available' : '${offers.length} promos available')
        : '${p.code}${auto ? ' applied automatically' : ' applied'}';
    final sub = p == null
        ? 'Tap to apply'
        : 'You pay about ${formatMoney(pay! < 0 ? 0 : pay, currency)} after promo';
    return Material(
      key: const ValueKey('confirm-promo-bar'),
      color: p == null ? t.colorScheme.surfaceContainerHigh : c.bg,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: InkWell(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, tuck + 4),
          child: SizedBox(
            height: visibleHeight - 8,
            child: Row(children: [
              Icon(p == null ? Icons.sell_outlined : Icons.local_offer, size: 18, color: p == null ? muted : c.fg),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      key: const ValueKey('confirm-promo-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodyMedium?.copyWith(
                          color: p == null ? t.colorScheme.onSurface : c.fg, fontWeight: FontWeight.w600, height: 1.1),
                    ),
                    Text(
                      sub,
                      key: const ValueKey('confirm-promo-pay'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: p == null ? muted : c.fg, height: 1.1),
                    ),
                  ],
                ),
              ),
              Text(p == null ? 'Apply' : 'Change',
                  style: t.textTheme.labelLarge?.copyWith(color: p == null ? t.colorScheme.primary : c.fg)),
              Icon(Icons.chevron_right, color: p == null ? muted : c.fg),
            ]),
          ),
        ),
      ),
    );
  }
}

/// What the rider chose on the promo sheet: a code, or none.
@immutable
class PromoChoice {
  const PromoChoice(this.offer);
  const PromoChoice.none() : offer = null;
  final PromoOffer? offer;
}

/// The promo sheet: the codes that apply to the trip, taking the applied
/// one off, or typing another (checked by the server, with its reason when
/// it doesn't apply). Null: closed without a change.
Future<PromoChoice?> showPromoCodeSheet(
  BuildContext context, {
  required List<PromoOffer> offers,
  required PromoOffer? applied,
  required double fare,
  required Future<PromoCheckResult> Function(String code) onCheck,
  String currency = 'MYR',
}) =>
    showAppSheet<PromoChoice>(
      id: 'confirm.show-promo-sheet',
      context: context,
      isScrollControlled: true,
      builder: (_) => PromoCodeSheet(offers: offers, applied: applied, fare: fare, onCheck: onCheck, currency: currency),
    );

class PromoCodeSheet extends StatefulWidget {
  const PromoCodeSheet({
    super.key,
    required this.offers,
    required this.applied,
    required this.fare,
    required this.onCheck,
    this.currency = 'MYR',
  });

  final List<PromoOffer> offers;
  final PromoOffer? applied;
  final double fare;
  final String currency;
  final Future<PromoCheckResult> Function(String code) onCheck;

  @override
  State<PromoCodeSheet> createState() => _PromoCodeSheetState();
}

class _PromoCodeSheetState extends State<PromoCodeSheet> {
  final _code = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final code = normalizePromoCode(_code.text);
    if (code.isEmpty) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    PromoCheckResult r;
    try {
      r = await widget.onCheck(code);
    } catch (_) {
      r = const PromoCheckResult.refused('error', "Couldn't check the code. Please try again.");
    }
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, PromoChoice(r.offer));
      return;
    }
    setState(() {
      _checking = false;
      _error = r.message ?? promoReasonText(r.reason);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final pad = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      // Above the keyboard when it is up, else above the home indicator.
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + (inset > pad ? inset : pad)),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Promo code', style: t.textTheme.titleMedium),
            if (widget.offers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('For this trip', style: t.textTheme.labelLarge?.copyWith(color: muted)),
              for (final o in widget.offers)
                ListTile(
                  key: ValueKey('promo-offer-${o.code}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    o.codeId == widget.applied?.codeId ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: o.codeId == widget.applied?.codeId ? t.colorScheme.primary : muted,
                  ),
                  title: Text('${o.code} · ${o.discountLabel}'),
                  subtitle: Text(
                    [
                      if (o.description.trim().isNotEmpty) o.description.trim(),
                      'You pay about ${formatMoney((widget.fare - o.estimatedDiscount).clamp(0, double.infinity), widget.currency)}',
                      if (o.autoApply) 'Applies by itself',
                    ].join('\n'),
                  ),
                  selected: o.codeId == widget.applied?.codeId,
                  onTap: () => Navigator.pop(context, PromoChoice(o)),
                ),
            ],
            if (widget.applied != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('promo-remove'),
                  onPressed: () => Navigator.pop(context, const PromoChoice.none()),
                  icon: const Icon(Icons.close),
                  label: Text('Remove ${widget.applied!.code}'),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('promo-code'),
              controller: _code,
              autofocus: widget.offers.isEmpty,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _apply(),
              decoration: InputDecoration(
                hintText: widget.offers.isEmpty ? 'Enter promo code' : 'Or enter another code',
                errorText: _error,
                errorMaxLines: 3,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: _code,
              builder: (_, _) => FilledButton(
                key: const ValueKey('promo-apply'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.all(14)),
                onPressed: _checking || _code.text.trim().isEmpty ? null : _apply,
                child: _checking
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The driver's mark on a request with a promo: the fare shown is the full
/// fare; the promo is paid to them by the platform.
class PromoAppliedIcon extends StatelessWidget {
  const PromoAppliedIcon({super.key, this.size = 18});
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = _promoColours(t);
    return Tooltip(
      message: 'Promo applied',
      child: Semantics(
        label: 'Promo applied',
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: c.bg, shape: BoxShape.circle),
          child: Icon(Icons.local_offer, size: size, color: c.fg),
        ),
      ),
    );
  }
}

/// Whether a request carries a promo the server kept.
bool rideHasPromo(RideRequest r) => r.promo != null;

/// The driver's trip: what to collect in cash after the promo, and that the
/// promo is paid to their GET.wallet. Before completion it is the estimate;
/// once completed, the server's figures.
class DriverPromoLine extends StatelessWidget {
  const DriverPromoLine({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context) {
    final p = ride.promo;
    if (p == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final c = _promoColours(t);
    final cash = ride.paymentMode.toLowerCase() == 'cash';
    final fare = ride.effectiveFare ?? 0;
    final String title;
    final String sub;
    if (p.settled && !p.applied) {
      title = 'Promo ${p.code} not applied';
      sub = p.error == 'ended_early'
          ? 'The trip ended early. Collect the full amount.'
          : 'Collect the full amount.';
    } else if (p.settled) {
      title = 'Promo ${p.code}: ${formatMoney(p.discount, ride.currency)} to your GET.wallet';
      sub = cash ? 'Collect ${formatMoney(ride.cashDue, ride.currency)} in cash' : 'The passenger pays the rest in the app';
    } else {
      final left = fare - (p.estimate ?? 0);
      title = 'Promo ${p.code} applied';
      sub = cash
          ? 'Collect about ${formatMoney(left < 0 ? 0 : left, ride.currency)} in cash. '
              'The promo amount (about ${formatMoney(p.estimate, ride.currency)}) goes to your GET.wallet.'
          : 'The promo amount (about ${formatMoney(p.estimate, ride.currency)}) goes to your GET.wallet.';
    }
    return Card(
      key: const ValueKey('trip-promo'),
      color: c.bg,
      child: ListTile(
        leading: Icon(Icons.local_offer, color: c.fg),
        title: Text(title, style: TextStyle(color: c.fg, fontWeight: FontWeight.w700)),
        subtitle: Text(sub, key: const ValueKey('trip-promo-collect'), style: TextStyle(color: c.fg)),
      ),
    );
  }
}

/// The promo line on a receipt or in ride history: "Promo RIDE5 −RM5.00",
/// or null when the ride had none that gave money off.
String? ridePromoLine(RideRequest r) {
  final p = r.promo;
  if (p == null) return null;
  if (p.settled) {
    return p.applied ? 'Promo ${p.code} −${formatMoney(p.discount, r.currency)}' : null;
  }
  return (p.estimate ?? 0) > 0 ? 'Promo ${p.code} (about −${formatMoney(p.estimate, r.currency)})' : null;
}
