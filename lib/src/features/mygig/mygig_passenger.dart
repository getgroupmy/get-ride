// myGiG on the passenger's side (migration 0329): the fare a driver sent
// to their get.ride app (a push opens it) with Accept and Decline, the
// Family row when their Family pays, cancelling after accepting (a fee
// only per what was agreed, and only paying in the app), and the trip
// link page for a passenger without the app (getride.my/gig/<token>, no
// sign-in): the trip and the price to accept, then the live ride on the
// shared ride page, and the receipt at the end.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/booking_modules.dart' show bookingModule;
import '../../core/format.dart';
import '../../core/mygig.dart';
import '../../data/family_repository.dart' show familyPayOptionProvider;
import '../../data/models.dart';
import '../../data/mygig_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import 'mygig_new_screen.dart' show MygigPriceLines;

/// The passenger's own offer, read for the accept screen.
final mygigOfferProvider = FutureProvider.autoDispose.family<MygigOffer, String>(
  (ref, id) => ref.watch(mygigRepositoryProvider).offer(id),
);

/// The fare a driver sent: Accept or Decline (in the app).
class MygigOfferScreen extends ConsumerWidget {
  const MygigOfferScreen({super.key, required this.offerId});
  final String offerId;

  Future<void> _answer(BuildContext context, WidgetRef ref, MygigOffer o, bool accept) async {
    try {
      final ride = await ref.read(mygigRepositoryProvider).answer(o.id, accept: accept);
      if (!context.mounted) return;
      if (accept && ride != null) {
        context.go('/ride/$ride');
        return;
      }
      await showAppNotice(
        id: 'notice.mygig',
        context: context,
        title: o.kind == 'change' ? 'Route not changed' : 'Declined',
        message: o.kind == 'change'
            ? 'Your driver carries on with the route you accepted.'
            : 'The ride wasn’t booked. Nothing was charged.',
      );
      if (context.mounted) context.go('/');
    } catch (e) {
      if (context.mounted) showError(context, e);
      ref.invalidate(mygigOfferProvider(offerId));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mygigOfferProvider(offerId));
    return Scaffold(
      appBar: AppBar(title: const Text('Accept your ride?')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(mygigOfferProvider(offerId)),
        data: (o) => _MygigOfferBody(offer: o, answer: (yes) => _answer(context, ref, o, yes)),
      ),
    );
  }
}

class _MygigOfferBody extends ConsumerWidget {
  const _MygigOfferBody({required this.offer, required this.answer});
  final MygigOffer offer;
  final Future<void> Function(bool accept) answer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final o = offer;
    final q = o.quote;
    final d = o.driver;
    final family = o.pay == MygigPay.family ? ref.watch(familyPayOptionProvider(familyModuleMygig)).value : null;
    if (!o.waiting) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            switch (o.status) {
              'accepted' => 'You accepted this ride.',
              'declined' => 'You declined this ride.',
              _ => 'This request has ended. Ask the driver to send it again.',
            },
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ResponsiveCenter(
      maxWidth: 640,
      child: ListView(
        key: const ValueKey('mygig-offer'),
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text('${d['name'] ?? 'Your driver'} · ★ ${d['rating'] ?? '5'}'),
              subtitle: Text([d['vehicle'], d['plate']].whereType<String>().join(' · ')),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('From ${o.trip['pickup']?['name'] ?? 'the pickup'}'),
                for (final s in (o.trip['stops'] is List ? o.trip['stops'] as List : const []))
                  Text('Stop: ${s is Map ? s['name'] : ''}'),
                Text('To ${o.trip['drop']?['name'] ?? 'the drop-off'}'),
              ]),
            ),
          ),
          MygigPriceLines(quote: q, what: 'myGiG', bags: o.bags),
          Row(children: [
            Expanded(child: Text(o.kind == 'change' ? 'New fixed price' : 'Fixed price', style: t.textTheme.titleMedium)),
            Text(mygigMoney(q.total), key: const ValueKey('mygig-offer-total'), style: t.textTheme.headlineSmall),
          ]),
          if (q.guard)
            Card(
              color: t.colorScheme.tertiaryContainer,
              child: ListTile(
                leading: Icon(Icons.info_outline, color: t.colorScheme.onTertiaryContainer),
                title: Text('Usual app price about ${mygigMoney(q.appPrice)}',
                    style: TextStyle(color: t.colorScheme.onTertiaryContainer)),
                subtitle: Text('This driver’s price is higher. You can decline and book in the app.',
                    style: TextStyle(color: t.colorScheme.onTertiaryContainer)),
              ),
            ),
          // Family (0317): the host's GET.wallet pays, within the member's limits.
          if (o.pay == MygigPay.family)
            ListTile(
              key: const ValueKey('mygig-offer-family'),
              leading: const Icon(Icons.family_restroom),
              title: Text(family?.label ?? '${bookingModule(familyModuleMygig)?.name ?? 'myGiG'} · Family'),
              subtitle: Text(family?.note((v) => formatMoney(v, 'MYR')) ?? 'Paid by your Family host'),
            ),
          Text(
            '${o.trip['pax'] ?? 1} passenger${(o.trip['pax'] ?? 1) == 1 ? '' : 's'} · ${mygigBagsText(o.bags)} · '
            'pay by ${mygigPayName(o.pay, familyHost: family?.hostName)}. Tolls and parking on the way are added.',
            style: t.textTheme.bodySmall,
          ),
          if (q.canCharge && (q.cancelFee > 0 || q.noShowFee > 0))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'If you cancel after accepting (after ${q.terms['cancelFreeMin'] ?? 2} min) or don’t come: '
                '${q.cancelFee > 0 ? '${mygigMoney(q.cancelFee)} cancellation fee' : 'no cancellation fee'}, '
                '${q.noShowFee > 0 ? '${mygigMoney(q.noShowFee)} no-show fee' : 'no no-show fee'}.',
                style: t.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          BusyButton.filled(
            key: const ValueKey('mygig-offer-accept'),
            onPressed: () => answer(true),
            child: Text('Accept fare ${mygigMoney(q.total)}'),
          ),
          const SizedBox(height: 8),
          BusyButton.tonal(
            key: const ValueKey('mygig-offer-decline'),
            onPressed: () => answer(false),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
  }
}

/// The passenger's Cancel ride on a myGiG ride (before the trip starts).
class MygigCancelButton extends StatelessWidget {
  const MygigCancelButton({super.key, required this.ride, required this.onPressed});
  final RideRequest ride;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final g = MygigRide.of(ride.raw);
    final fee = g == null ? 0.0 : mygigCancelFeeNow(g, ride.raw['accepted_at'], DateTime.now());
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: const ValueKey('mygig-cancel-ride'),
        icon: const Icon(Icons.close),
        onPressed: onPressed,
        label: Text(fee > 0 ? 'Cancel ride · ${mygigMoney(fee)} fee' : 'Cancel ride'),
      ),
    );
  }
}

/// The cancellation fee if the passenger cancelled at [now].
double mygigCancelFeeNow(MygigRide g, Object? acceptedAt, DateTime now) {
  if (!g.canCharge || g.cancelFee <= 0) return 0;
  final at = DateTime.tryParse('${acceptedAt ?? ''}');
  if (at == null) return 0;
  return now.difference(at.toLocal()).inMinutes >= g.cancelFreeMin ? g.cancelFee : 0;
}

/// The passenger cancels a myGiG ride: told the fee first.
Future<void> mygigRiderCancel(BuildContext context, WidgetRef ref, RideRequest r) async {
  final g = MygigRide.of(r.raw);
  if (g == null) return;
  final fee = mygigCancelFeeNow(g, r.raw['accepted_at'], DateTime.now());
  final ok = await showAppDialog<bool>(
    id: 'mygig.rider-cancel',
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Cancel this ride?'),
      content: Text(fee > 0
          ? 'You accepted more than ${g.cancelFreeMin} min ago and your driver is on the way, so a ${mygigMoney(fee)} '
              'cancellation fee is charged to ${mygigPayName(g.pay)}.'
          : 'There’s no charge to cancel.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep ride')),
        FilledButton(key: const ValueKey('mygig-rider-cancel-ok'), onPressed: () => Navigator.pop(c, true), child: const Text('Cancel ride')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await ref.read(mygigRepositoryProvider).cancelRide(rideId: r.id);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// getride.my/gig/`token`: the trip link (no app, no sign-in).
class MygigLinkScreen extends ConsumerStatefulWidget {
  const MygigLinkScreen({super.key, required this.token, this.poll = const Duration(seconds: 10)});
  final String token;
  final Duration poll;

  @override
  ConsumerState<MygigLinkScreen> createState() => _MygigLinkScreenState();
}

class _MygigLinkScreenState extends ConsumerState<MygigLinkScreen> {
  Map<String, dynamic>? _view;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _timer = Timer.periodic(widget.poll, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final v = await ref.read(mygigRepositoryProvider).linkView(widget.token);
      if (mounted) {
        setState(() {
          _view = v;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _answer(bool accept) async {
    try {
      await ref.read(mygigRepositoryProvider).linkAnswer(widget.token, accept: accept);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _cancel(double fee) async {
    final ok = await showAppDialog<bool>(
      id: 'mygig.link-cancel',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this ride?'),
        content: Text(fee > 0 ? 'A ${mygigMoney(fee)} cancellation fee applies.' : 'There’s no charge to cancel.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep ride')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel ride')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(mygigRepositoryProvider).cancelRide(token: widget.token);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final v = _view;
    return Scaffold(
      appBar: AppBar(title: const Text('Your trip'), automaticallyImplyLeading: false),
      body: v == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(errorText(_error!), textAlign: TextAlign.center),
                    ),
            )
          : ResponsiveCenter(maxWidth: 640, child: _body(t, v)),
    );
  }

  Widget _body(ThemeData t, Map<String, dynamic> v) {
    final status = '${v['status']}';
    final d = v['driver'] is Map ? Map<String, dynamic>.from(v['driver']) : const <String, dynamic>{};
    final trip = v['trip'] is Map ? Map<String, dynamic>.from(v['trip']) : const <String, dynamic>{};
    final q = MygigQuote(v['quote'] is Map ? Map<String, dynamic>.from(v['quote']) : const {});
    final ride = v['ride'] is Map ? Map<String, dynamic>.from(v['ride']) : null;
    final bags = {
      for (final s in const ['small', 'medium', 'large'])
        s: trip['bags'] is Map && (trip['bags'] as Map)[s] is num ? ((trip['bags'] as Map)[s] as num).toInt() : 0,
    };
    final name = '${v['name'] ?? ''}'.trim();
    return ListView(
      key: const ValueKey('mygig-link'),
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          ride != null
              ? switch ('${ride['status']}') {
                  'completed' => 'Your trip is done',
                  'cancelled' => 'This ride was cancelled',
                  'on_trip' => 'On the way',
                  'arrived' => '${d['name'] ?? 'Your driver'} has arrived',
                  _ => '${d['name'] ?? 'Your driver'} is coming to the pickup',
                }
              : name.isEmpty ? 'Here is your trip' : 'Hi $name, here is your trip',
          style: t.textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text('${d['name'] ?? 'Your driver'} · ★ ${d['rating'] ?? '5'}'),
            subtitle: Text([d['vehicle'], d['plate']].whereType<String>().join(' · ')),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('From ${trip['pickup']?['name'] ?? 'the pickup'}'),
              for (final s in (trip['stops'] is List ? trip['stops'] as List : const []))
                Text('Stop: ${s is Map ? s['name'] : ''}'),
              Text('To ${trip['drop']?['name'] ?? 'the drop-off'}'),
            ]),
          ),
        ),
        MygigPriceLines(quote: q, what: 'myGiG', bags: bags),
        Row(children: [
          Expanded(child: Text(ride != null && '${ride['status']}' == 'completed' ? 'Total' : 'Fixed price',
              style: t.textTheme.titleMedium)),
          Text(mygigMoney(ride != null && ride['total'] is num ? (ride['total'] as num).toDouble() : q.total),
              key: const ValueKey('mygig-link-total'), style: t.textTheme.headlineSmall),
        ]),
        if (q.guard && q.appPrice > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Usual app price about ${mygigMoney(q.appPrice)}. This driver’s price is higher. You can decline '
                'and book in the get.ride app.'),
          ),
        const SizedBox(height: 8),
        Text(
          'Pay by ${mygigPayName(mygigPayFrom(trip['pay']))}. Tolls and parking on the way are added. '
          'This price stays the same unless you change where you’re going or the stops.',
          style: t.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (status == 'waiting') ...[
          BusyButton.filled(
            key: const ValueKey('mygig-link-accept'),
            onPressed: () => _answer(true),
            child: Text(v['kind'] == 'change' ? 'Accept new price ${mygigMoney(q.total)}' : 'Accept fare ${mygigMoney(q.total)}'),
          ),
          const SizedBox(height: 8),
          BusyButton.tonal(
            key: const ValueKey('mygig-link-decline'),
            onPressed: () => _answer(false),
            child: const Text('Decline'),
          ),
        ] else if (ride == null)
          Text(
            switch (status) {
              'declined' => 'You declined this trip. Nothing was booked.',
              'cancelled' => 'The driver cancelled this request.',
              _ => 'This request has ended. Ask the driver to send it again.',
            },
            textAlign: TextAlign.center,
          )
        else ...[
          if (ride['shareToken'] != null && '${ride['status']}' != 'cancelled')
            FilledButton.icon(
              key: const ValueKey('mygig-link-follow'),
              icon: const Icon(Icons.map_outlined),
              onPressed: () => context.go('/share/${ride['shareToken']}'),
              label: Text('${ride['status']}' == 'completed' ? 'See the trip' : 'Follow the ride live'),
            ),
          // No losses (owner's rule): pay by link before the trip (and what
          // is added before it ends).
          if (ride['owed'] is num && (ride['owed'] as num) > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ride['payUrl'] is String
                  ? FilledButton.icon(
                      key: const ValueKey('mygig-link-pay'),
                      icon: const Icon(Icons.payments_outlined),
                      onPressed: () => launchUrl(Uri.parse('${ride['payUrl']}'), mode: LaunchMode.externalApplication),
                      label: Text('Pay ${mygigMoney((ride['owed'] as num).toDouble())} by card, FPX or DuitNow'),
                    )
                  : Text('Your driver sends you a link to pay ${mygigMoney((ride['owed'] as num).toDouble())} '
                      'before the trip. Or pay them in cash.', textAlign: TextAlign.center),
            ),
          if (ride['canCancel'] == true)
            TextButton.icon(
              key: const ValueKey('mygig-link-cancel'),
              style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
              icon: const Icon(Icons.cancel_outlined),
              onPressed: () => _cancel(ride['cancelFee'] is num ? (ride['cancelFee'] as num).toDouble() : 0),
              label: const Text('Cancel ride'),
            ),
          const SizedBox(height: 8),
          Text('This link shows the ride live until it ends, then the receipt.', textAlign: TextAlign.center,
              style: t.textTheme.bodySmall),
        ],
      ],
    );
  }
}
