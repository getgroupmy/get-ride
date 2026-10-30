// myGiG: the driver waits for the passenger to accept the fare (in their
// app, on the trip link), with Resend, Use another way, Show on this phone
// and Cancel. Shown on this phone, it is the passenger's agree page. Once
// accepted the ride is a normal ride: the driver's trip screen opens.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/mygig.dart';
import '../../core/mygig_hire.dart';
import '../../data/mygig_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import 'mygig_new_screen.dart' show MygigPriceLines, openMygigWhatsApp;
import 'mygig_scheduled_screen.dart' show mygigScheduledPath;
import 'mygig_when.dart' show MygigBookingTerms;

/// "Ends in 1:40".
String mygigCountdown(Duration left) {
  final s = left.isNegative ? 0 : left.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class MygigWaitingScreen extends ConsumerStatefulWidget {
  const MygigWaitingScreen({super.key, required this.sent, this.change = false, this.poll = const Duration(seconds: 3)});
  final MygigSent sent;

  /// A change of route on a ride already going (its offer is a 'change').
  final bool change;
  final Duration poll;

  @override
  ConsumerState<MygigWaitingScreen> createState() => _MygigWaitingScreenState();
}

class _MygigWaitingScreenState extends ConsumerState<MygigWaitingScreen> {
  late MygigSent _sent = widget.sent;
  MygigOffer? _offer;
  Timer? _timer;
  DateTime _now = DateTime.now();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      if (t.tick % widget.poll.inSeconds.clamp(1, 60) == 0) unawaited(_check());
    });
    unawaited(_check());
    // Shown on this phone: the agree page opens at once, turned to the passenger.
    if (widget.sent.way == MygigWay.here) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showHere());
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_done) return;
    MygigOffer o;
    try {
      o = await ref.read(mygigRepositoryProvider).offer(_sent.offerId);
    } catch (_) {
      return;
    }
    if (!mounted || _done) return;
    setState(() => _offer = o);
    switch (o.status) {
      case 'accepted' when o.raw['bookingId'] is String:
        _done = true;
        await _booked(o);
      case 'accepted':
        _done = true;
        _goToTrip(o.rideId);
      case 'declined':
        _done = true;
        await showAppNotice(
          id: 'notice.mygig',
          context: context,
          title: widget.change ? 'Route not changed' : 'Trip not started',
          message: widget.change
              ? 'The passenger didn’t accept the new price. Carry on with the route they accepted.'
              : 'The passenger didn’t accept the fare. Nothing was saved or charged.',
        );
        if (mounted) Navigator.of(context).pop();
      default:
        break;
    }
  }

  void _goToTrip(String? ride) {
    if (widget.change) {
      Navigator.of(context).pop();
      return;
    }
    if (ride == null) return;
    // No losses (owner's rule): a pay-by-link price is paid before the
    // trip; the link goes to the passenger at once.
    if (_offer?.pay == MygigPay.link) unawaited(ref.read(mygigRepositoryProvider).sendPayLink(ride).catchError((_) {}));
    context.go('/drive/trip/$ride');
  }

  /// A booking for later or a hire (0330): it is in Scheduled myGiG; a
  /// passenger paying by link gets the link at once (confirmed once paid).
  Future<void> _booked(MygigOffer o) async {
    final id = o.raw['bookingId'] as String;
    final booking = o.raw['booking'] is Map ? Map<String, dynamic>.from(o.raw['booking'] as Map) : <String, dynamic>{};
    if (o.raw['bookingStatus'] == 'awaiting_payment') {
      unawaited(ref.read(mygigRepositoryProvider).sendPayLink(id).catchError((_) {}));
    }
    await showAppNotice(
      id: 'notice.mygig',
      context: context,
      kind: NoticeKind.success,
      title: 'myGiG booked',
      message: mygigBookedText(name: o.name ?? 'The passenger', booking: booking, total: o.total, now: DateTime.now(),
          status: o.raw['bookingStatus'] as String?),
    );
    if (mounted) context.go(mygigScheduledPath);
  }

  Future<void> _resend([MygigWay? way]) async {
    final s = await ref.read(mygigRepositoryProvider).resend(_sent.offerId, way: way);
    if (!mounted) return;
    setState(() => _sent = s);
    if (s.way == MygigWay.whatsapp) await openMygigWhatsApp(s);
    if (!mounted) return;
    if (s.way == MygigWay.here) return _showHere();
    unawaited(showAppNotice(
      id: 'notice.mygig',
      context: context,
      kind: NoticeKind.success,
      title: 'Sent again',
      message: 'The ${s.way == MygigWay.app ? 'notification' : 'link'} was sent again.',
    ));
  }

  Future<void> _otherWay() async {
    final o = _offer;
    final ways = MygigWay.values.where((w) => w != _sent.way && _wayFits(w, o)).toList();
    final w = await showAppSheet<MygigWay>(
      id: 'mygig.other-way',
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Use another way')),
          for (final w in ways)
            ListTile(
              key: ValueKey('mygig-other-${w.name}'),
              title: Text(w.label),
              subtitle: Text(w.sub),
              onTap: () => Navigator.pop(c, w),
            ),
        ]),
      ),
    );
    if (w == null || !mounted) return;
    try {
      await _resend(w);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  bool _wayFits(MygigWay w, MygigOffer? o) {
    if (o == null) return w == MygigWay.here;
    final hasPhone = o.phone != null;
    return switch (w) {
      MygigWay.app => o.raw['registered'] == true && o.raw['lookup'] == 'latest',
      MygigWay.sms || MygigWay.whatsapp => hasPhone && o.pay != MygigPay.family,
      MygigWay.here => o.pay != MygigPay.family,
    };
  }

  Future<void> _showHere() async {
    if (_sent.way != MygigWay.here) {
      try {
        final s = await ref.read(mygigRepositoryProvider).resend(_sent.offerId, way: MygigWay.here);
        if (!mounted) return;
        setState(() => _sent = s);
      } catch (e) {
        if (mounted) showError(context, e);
        return;
      }
    }
    final o = _offer ?? await ref.read(mygigRepositoryProvider).offer(_sent.offerId);
    if (!mounted) return;
    final ride = await Navigator.of(context).push<String>(AppPageRoute<String>(
      id: 'mygig.agree',
      fullscreenDialog: true,
      builder: (_) => MygigAgreeScreen(offer: o),
    ));
    if (!mounted) return;
    if (ride != null) {
      _done = true;
      _goToTrip(ride);
    } else {
      unawaited(_check());
    }
  }

  Future<void> _cancel() async {
    try {
      await ref.read(mygigRepositoryProvider).cancelOffer(_sent.offerId);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final o = _offer;
    final expires = o?.expiresAt ?? _sent.expiresAt;
    final left = expires == null ? Duration.zero : expires.difference(_now);
    final expired = o?.status == 'expired' || (expires != null && left.isNegative);
    final via = switch (_sent.way) {
      MygigWay.app => '${o?.name ?? 'the passenger'}’s get.ride app',
      MygigWay.whatsapp => 'WhatsApp ${o?.phone ?? ''}'.trim(),
      MygigWay.sms => 'SMS ${o?.phone ?? ''}'.trim(),
      MygigWay.here => 'this phone',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Waiting for the passenger')),
      body: ResponsiveCenter(
        maxWidth: 640,
        child: ListView(
          key: const ValueKey('mygig-waiting'),
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              switch (_sent.way) {
                MygigWay.app => Icons.send_to_mobile,
                MygigWay.whatsapp => Icons.chat_outlined,
                MygigWay.sms => Icons.sms_outlined,
                MygigWay.here => Icons.screen_rotation,
              },
              size: 48,
              color: t.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text('Sent to $via', textAlign: TextAlign.center, style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              _sent.way == MygigWay.app
                  ? 'They get a notification and accept the fare in the app.'
                  : 'They open the link, see the trip and accept the fare.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (o != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('${o.trip['pickup']?['name'] ?? 'Pickup'}  ·  ${o.trip['drop']?['name'] ?? 'Drop-off'}'),
                    const Divider(),
                    Row(children: [
                      Expanded(
                        child: Text('Fixed price\n${mygigBagsText(o.bags)} · ${o.trip['pax'] ?? 1} passenger'
                            '${(o.trip['pax'] ?? 1) == 1 ? '' : 's'} · ${mygigPayName(o.pay)}'),
                      ),
                      Text(mygigMoney(o.total), style: t.textTheme.titleLarge),
                    ]),
                  ]),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              expired ? 'Not accepted in time: it ended, nothing was saved. Send it again or cancel.' : 'Ends in ${mygigCountdown(left)} if not accepted',
              key: const ValueKey('mygig-countdown'),
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(alignment: WrapAlignment.center, spacing: 4, children: [
              BusyButton.text(
                key: const ValueKey('mygig-resend'),
                icon: const Icon(Icons.refresh),
                onPressed: () async {
                  try {
                    await _resend();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('Resend'),
              ),
              TextButton.icon(
                key: const ValueKey('mygig-other-way'),
                onPressed: _otherWay,
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Use another way'),
              ),
              if (_wayFits(MygigWay.here, o))
                TextButton.icon(
                  key: const ValueKey('mygig-show-here'),
                  onPressed: _showHere,
                  icon: const Icon(Icons.screen_rotation),
                  label: const Text('Show on this phone'),
                ),
            ]),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: BusyButton.tonal(
            key: const ValueKey('mygig-cancel'),
            onPressed: _cancel,
            child: Text(widget.change ? 'Keep the accepted route' : 'Cancel myGiG'),
          ),
        ),
      ),
    );
  }
}

/// The full-screen agree page, turned to the passenger. Pops the ride's id
/// when they agree, null when they don't.
class MygigAgreeScreen extends ConsumerWidget {
  const MygigAgreeScreen({super.key, required this.offer});
  final MygigOffer offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final q = offer.quote;
    final d = offer.driver;
    final change = offer.kind == 'change';
    return Scaffold(
      appBar: AppBar(title: Text(change ? 'New price' : 'Your trip')),
      body: ResponsiveCenter(
        maxWidth: 640,
        child: ListView(
          key: const ValueKey('mygig-agree'),
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
                  Text('From ${offer.trip['pickup']?['name'] ?? 'the pickup'}'),
                  for (final s in (offer.trip['stops'] is List ? offer.trip['stops'] as List : const []))
                    Text('Stop: ${s is Map ? s['name'] : ''}'),
                  Text('To ${offer.trip['drop']?['name'] ?? 'the drop-off'}'),
                  const SizedBox(height: 4),
                  Text('${q.km.toStringAsFixed(1)} km · about ${q.minutes} min · ${mygigBagsText(offer.bags)}',
                      style: t.textTheme.bodySmall),
                ]),
              ),
            ),
            MygigPriceLines(quote: q, what: 'myGiG', bags: offer.bags),
            // 0330: a booking for later or a hire: when, the package, what is paid now.
            if (offer.raw['booking'] is Map)
              MygigBookingTerms(
                booking: Map<String, dynamic>.from(offer.raw['booking'] as Map),
                total: q.total,
                now: DateTime.now(),
                kmIncluded: (q.raw['kmIncluded'] as num?)?.toDouble(),
              ),
            const SizedBox(height: 8),
            Text('Fixed price', textAlign: TextAlign.center, style: t.textTheme.bodyMedium),
            Text(mygigMoney(q.total), key: const ValueKey('mygig-agree-total'), textAlign: TextAlign.center,
                style: t.textTheme.displaySmall),
            if (q.guard)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Usual app price about ${mygigMoney(q.appPrice)}. This driver’s price is higher. '
                    'You can decline and book in the app.', textAlign: TextAlign.center),
              ),
            const SizedBox(height: 8),
            Text(
              'This price stays the same unless you change where you’re going or the stops. Tolls and parking on the way '
              'are added. You pay by ${mygigPayName(offer.pay)}.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: double.infinity,
              child: BusyButton.filled(
                key: const ValueKey('mygig-agree-yes'),
                onPressed: () async {
                  try {
                    final ride = await ref.read(mygigRepositoryProvider).answerHere(offer.id, accept: true);
                    if (context.mounted) Navigator.of(context).pop(ride ?? offer.rideId);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: Text(change
                    ? 'I agree to the new price'
                    : offer.raw['booking'] is Map && (offer.raw['booking'] as Map)['when'] == 'later'
                    ? 'I agree, book it'
                    : 'I agree, start the trip'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: BusyButton.tonal(
                key: const ValueKey('mygig-agree-no'),
                onPressed: () async {
                  try {
                    await ref.read(mygigRepositoryProvider).answerHere(offer.id, accept: false);
                  } catch (_) {}
                  if (context.mounted) Navigator.of(context).pop();
                },
                child: const Text('Not now'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
