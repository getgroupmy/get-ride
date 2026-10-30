// myGiG Delivery (migration 0332), the sender's and recipients' side. The
// sender accepts on their link (getride.my/gig/d/<token>, no sign-in), in
// their app, or on the driver's phone: the parcel, the drop-offs, the price,
// who pays, COD, cover, what happens if it comes back, and the tick "No
// prohibited items, and the details are right" (MygigDeliveryAgree, with
// the Family row when their Family pays). Then they follow it: pay by link
// when that was agreed, the proof per drop-off, and acknowledging a return
// with their return code. A recipient's link: tracking, their delivery
// code, paying at the door when they pay, the proof afterwards, and
// "Something wrong? Send it back".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/booking_modules.dart' show bookingModule;
import '../../core/format.dart';
import '../../core/mygig.dart';
import '../../core/mygig_delivery.dart';
import '../../data/family_repository.dart' show familyPayOptionProvider;
import '../../data/mygig_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import 'mygig_delivery_new.dart' show MygigDeliveryLines, openMygigDeliveryPay;
import 'mygig_delivery_trip.dart' show MygigSendBackScreen;
import 'mygig_when.dart' show MygigNote;

/// The sender's own delivery in the app.
String mygigDeliveryMinePath(String ride) => '/mygig/delivery/$ride';

/// What the sender accepts: an offer as mygig_offer_json (or the link's
/// offer) gives it.
class MygigDeliveryAgree extends ConsumerStatefulWidget {
  const MygigDeliveryAgree({super.key, required this.offer, required this.onAnswer, this.banner});
  final Map<String, dynamic> offer;

  /// Accept ([accept] true, with the tick) or decline.
  final Future<void> Function(bool accept) onAnswer;

  /// "Shown to the sender on your phone".
  final String? banner;

  @override
  ConsumerState<MygigDeliveryAgree> createState() => _MygigDeliveryAgreeState();
}

class _MygigDeliveryAgreeState extends ConsumerState<MygigDeliveryAgree> {
  bool _ack = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final o = widget.offer;
    final dl = o['delivery'] is Map ? Map<String, dynamic>.from(o['delivery'] as Map) : <String, dynamic>{};
    final parcel = dl['parcel'] is Map ? Map<String, dynamic>.from(dl['parcel'] as Map) : <String, dynamic>{};
    final q = MygigDeliveryQuote(o['quote'] is Map ? Map<String, dynamic>.from(o['quote'] as Map) : const {});
    final driver = o['driver'] is Map ? Map<String, dynamic>.from(o['driver'] as Map) : <String, dynamic>{};
    final drops = [for (final x in (dl['drops'] is List ? dl['drops'] as List : const [])) if (x is Map) Map<String, dynamic>.from(x)];
    final pay = mygigPayFrom(dl['pay'] ?? (o['trip'] is Map ? (o['trip'] as Map)['pay'] : null));
    final recipientPays = dl['payer'] == 'recipient';
    final inApp = dl['inApp'] == true;
    final cod = (dl['cod'] as num?)?.toDouble() ?? 0;
    final family = pay == MygigPay.family ? ref.watch(familyPayOptionProvider(familyModuleMygig)).value : null;
    final payNow = mygigDeliveryPayNow(q: q, senderPays: !recipientPays, pay: pay);
    final value = (parcel['value'] as num?)?.toDouble() ?? 0;
    final kg = (parcel['kg'] as num?)?.toDouble() ?? 1;
    final size = '${parcel['size'] ?? 'small'}';
    final waiting = o['status'] == null || o['status'] == 'waiting';
    if (!waiting) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(switch (o['status']) {
            'accepted' => 'You accepted this delivery.',
            'declined' => 'You declined this delivery. Nothing was charged.',
            _ => 'This request has ended. Ask the driver to send it again.',
          }, textAlign: TextAlign.center),
        ),
      );
    }
    return ResponsiveCenter(
      maxWidth: 640,
      child: ListView(
        key: const ValueKey('mygig-delivery-agree'),
        padding: const EdgeInsets.all(20),
        children: [
          if (widget.banner != null) MygigNote(icon: Icons.smartphone, title: widget.banner!, body: 'Read it and choose.'),
          Text('Your delivery with ${driver['name'] ?? 'your driver'}', style: t.textTheme.titleLarge),
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text('${driver['name'] ?? 'Your driver'} · ★ ${driver['rating'] ?? '5'}'),
              subtitle: Text([driver['vehicle'], driver['plate']].whereType<String>().join(' · ')),
            ),
          ),
          Card(
            child: Column(children: [
              for (final x in drops)
                ListTile(
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text('${(x['place'] is Map ? (x['place'] as Map)['name'] : null) ?? 'Drop-off'}'),
                  subtitle: Text('To ${x['name'] ?? 'the recipient'} · gets a tracking link and a delivery code'),
                ),
            ]),
          ),
          MygigDeliveryLines(quote: q, size: size, kg: kg, freeKg: MygigDeliveryCard(q.raw['card'] is Map ? Map<String, dynamic>.from(q.raw['card'] as Map) : const {}).freeKg),
          Row(children: [
            Expanded(child: Text(recipientPays ? 'Recipient pays on delivery' : 'You pay', style: t.textTheme.titleMedium)),
            Text(mygigMoney(q.total), key: const ValueKey('mygig-delivery-agree-total'), style: t.textTheme.headlineSmall),
          ]),
          if (pay == MygigPay.family)
            ListTile(
              key: const ValueKey('mygig-delivery-family'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.family_restroom),
              title: Text(family?.label ?? '${bookingModule(familyModuleMygig)?.name ?? 'myGiG'} · Family'),
              subtitle: Text(family?.note((v) => formatMoney(v, 'MYR')) ?? 'Paid by your Family host'),
            ),
          if (cod > 0)
            MygigNote(icon: Icons.point_of_sale, title: 'Cash on delivery ${mygigMoney(cod)}',
                body: 'Collected from the recipient and paid to your GET.wallet less ${mygigMoney(q.codFee)}.'),
          MygigNote(icon: Icons.shield_outlined, title: 'Covered up to ${mygigMoney(q.coverUpTo)}',
              body: 'If the item is lost or damaged in the driver’s care. Declared value ${mygigMoney(value)}.'),
          MygigNote(
            key: const ValueKey('mygig-delivery-agree-back'),
            icon: Icons.keyboard_return,
            title: 'If it comes back',
            body: mygigComesBackText(q: q, inApp: inApp, payName: mygigPayName(pay, familyHost: family?.hostName),
                recipientPaysAsked: dl['retPayer'] != 'sender', drops: drops.length),
          ),
          if (q.deposit != null) Text(mygigDepositText(q.deposit!), style: t.textTheme.bodySmall),
          CheckboxListTile(
            key: const ValueKey('mygig-delivery-agree-ack'),
            contentPadding: EdgeInsets.zero,
            value: _ack,
            title: const Text('No prohibited items, and the details are right'),
            subtitle: Text('${parcel['type'] ?? 'Parcel'}, ${mygigDeliverySizeName(size).toLowerCase()}, '
                '${kg.toStringAsFixed(kg == kg.roundToDouble() ? 0 : 1)} kg, worth ${mygigMoney(value)}.'),
            onChanged: (v) => setState(() => _ack = v ?? false),
          ),
          const SizedBox(height: 8),
          BusyButton.filled(
            key: const ValueKey('mygig-delivery-agree-yes'),
            onPressed: _ack ? () => widget.onAnswer(true) : null,
            child: Text(mygigDeliveryAcceptLabel(payNow: payNow, total: q.total)),
          ),
          const SizedBox(height: 8),
          BusyButton.tonal(
            key: const ValueKey('mygig-delivery-agree-no'),
            onPressed: () => widget.onAnswer(false),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
  }
}

/// On the driver's phone, turned to the sender: pops the ride's id when they accept.
class MygigDeliveryAgreeScreen extends ConsumerWidget {
  const MygigDeliveryAgreeScreen({super.key, required this.offer});
  final MygigOffer offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Your delivery')),
    body: MygigDeliveryAgree(
      offer: offer.raw,
      banner: 'Shown to the sender on the driver’s phone',
      onAnswer: (accept) async {
        try {
          final r = await ref.read(mygigRepositoryProvider).deliveryAnswer(offer: offer.id, accept: accept, ack: accept);
          if (!context.mounted) return;
          final req = r['payRequest'] as String?;
          if (accept && req != null && ((r['payNow'] as num?) ?? 0) > 0) await openMygigDeliveryPay(context, ref, req);
          if (context.mounted) Navigator.of(context).pop(accept ? r['rideId'] as String? : null);
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      },
    ),
  );
}

/// The link page: `getride.my/gig/d/<token>`.
class MygigDeliveryLinkScreen extends ConsumerStatefulWidget {
  const MygigDeliveryLinkScreen({super.key, required this.token});
  final String token;

  @override
  ConsumerState<MygigDeliveryLinkScreen> createState() => _MygigDeliveryLinkScreenState();
}

class _MygigDeliveryLinkScreenState extends ConsumerState<MygigDeliveryLinkScreen> {
  late Future<Map<String, dynamic>> _view = _load();

  Future<Map<String, dynamic>> _load() => ref.read(mygigRepositoryProvider).deliveryLinkView(widget.token);

  void _reload() => setState(() => _view = _load());

  Future<void> _answer(bool accept) async {
    try {
      final r = await ref.read(mygigRepositoryProvider).deliveryAnswer(token: widget.token, accept: accept, ack: accept);
      if (!mounted) return;
      final req = r['payRequest'] as String?;
      if (accept && req != null && ((r['payNow'] as num?) ?? 0) > 0) {
        await openMygigDeliveryPay(context, ref, req, token: widget.token);
      } else if (!accept) {
        await showAppNotice(id: 'notice.mygig', context: context, title: 'Declined',
            message: 'The delivery wasn’t booked. Nothing was charged.');
      }
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Your delivery'), actions: [
      IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _reload),
    ]),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _view,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', textAlign: TextAlign.center)));
        }
        final v = snap.data;
        if (v == null) return const Center(child: CircularProgressIndicator());
        if (v['stage'] == 'offer') {
          return MygigDeliveryAgree(offer: Map<String, dynamic>.from(v['offer'] as Map), onAnswer: _answer);
        }
        final d = MygigDelivery(Map<String, dynamic>.from(v['delivery'] as Map));
        final repo = ref.read(mygigRepositoryProvider);
        return MygigDeliveryFollow(
          delivery: d,
          recipient: v['role'] == 'recipient',
          onPay: (what) async {
            try {
              final r = await repo.deliveryPayRequest(widget.token, what: what);
              if (context.mounted) await openMygigDeliveryPay(context, ref, '${r['requestId']}', token: widget.token);
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          onAck: (ret) => repo.deliveryReturnAck(token: widget.token, tick: true),
          onCancel: () => repo.deliveryCancel(token: widget.token),
          onSendBack: (reason, method) =>
              repo.deliveryReturnAsk(token: widget.token, reason: reason, method: method, ack: true),
          token: widget.token,
          onCashAck: () => repo.deliveryReturnCashAck(widget.token),
          onChanged: _reload,
        );
      },
    ),
  );
}

/// The sender (or a registered recipient) in the app.
class MygigDeliveryMineScreen extends ConsumerStatefulWidget {
  const MygigDeliveryMineScreen({super.key, required this.ride});
  final String ride;

  @override
  ConsumerState<MygigDeliveryMineScreen> createState() => _MygigDeliveryMineScreenState();
}

class _MygigDeliveryMineScreenState extends ConsumerState<MygigDeliveryMineScreen> {
  late Future<MygigDelivery> _view = ref.read(mygigRepositoryProvider).deliveryMine(widget.ride);

  void _reload() => setState(() => _view = ref.read(mygigRepositoryProvider).deliveryMine(widget.ride));

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(mygigRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Your delivery'), actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _reload),
      ]),
      body: FutureBuilder<MygigDelivery>(
        future: _view,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', textAlign: TextAlign.center)));
          }
          final d = snap.data;
          if (d == null) return const Center(child: CircularProgressIndicator());
          return MygigDeliveryFollow(
            delivery: d,
            recipient: d.raw['role'] == 'recipient',
            onPay: (what) async {
              final part = d.payParts.where((p) => p['paidAt'] == null && (what == null || p['purpose'] == what)).firstOrNull;
              if (part != null) await openMygigDeliveryPay(context, ref, '${part['id']}');
            },
            onAck: (ret) => repo.deliveryReturnAck(ret: ret.id, tick: true),
            onCancel: () => repo.deliveryCancel(ride: widget.ride),
            onChanged: _reload,
          );
        },
      ),
    );
  }
}

/// Following a delivery: the sender's or a recipient's view.
class MygigDeliveryFollow extends StatefulWidget {
  const MygigDeliveryFollow({
    super.key,
    required this.delivery,
    required this.recipient,
    required this.onPay,
    required this.onAck,
    required this.onCancel,
    required this.onChanged,
    this.onSendBack,
    this.token,
    this.onCashAck,
  });
  final MygigDelivery delivery;
  final bool recipient;
  final Future<void> Function(String? what) onPay;
  final Future<Object?> Function(MygigDeliveryReturn ret) onAck;
  final Future<Object?> Function() onCancel;
  final VoidCallback onChanged;

  /// The recipient's link: send it back ([token] is the link's).
  final Future<Map<String, dynamic>> Function(String reason, String method)? onSendBack;
  final String? token;
  final Future<void> Function()? onCashAck;

  @override
  State<MygigDeliveryFollow> createState() => _MygigDeliveryFollowState();
}

class _MygigDeliveryFollowState extends State<MygigDeliveryFollow> {
  final _ticked = <String>{};

  Future<void> _do(Future<Object?> Function() f, {String? done}) async {
    try {
      await f();
      if (!mounted) return;
      if (done != null) await showAppNotice(id: 'notice.mygig', context: context, kind: NoticeKind.success, message: done);
      widget.onChanged();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = widget.delivery;
    final mine = widget.recipient ? d.drops.firstOrNull : null;
    final part = d.acceptPart;
    return ResponsiveCenter(
      maxWidth: 640,
      child: ListView(
        key: ValueKey(widget.recipient ? 'mygig-delivery-recipient' : 'mygig-delivery-sender'),
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            switch (d.status) {
              'done' => widget.recipient ? 'Delivered' : 'Delivery done',
              'refused' => 'The driver didn’t take the item',
              'cancelled' => 'Delivery cancelled',
              'pickup' => widget.recipient ? 'Your parcel is being picked up' : 'Waiting for the pickup',
              _ => mine?.delivered == true ? 'Delivered' : 'Your parcel is on the way',
            },
            style: t.textTheme.titleLarge,
          ),
          Text('${widget.recipient ? 'From ${d.senderName} · ' : ''}${d.type.toLowerCase()}, '
              '${mygigDeliverySizeName(d.size).toLowerCase()} · seal code ${d.sealCode}', style: t.textTheme.bodyMedium),
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text('${d.driver['name'] ?? 'Your driver'} · ★ ${d.driver['rating'] ?? '5'}'),
              subtitle: Text([d.driver['vehicle'], d.driver['plate']].whereType<String>().join(' · ')),
              trailing: d.shareToken == null || d.ended
                  ? null
                  : TextButton(
                      key: const ValueKey('mygig-delivery-track'),
                      onPressed: () => context.push('/share/${d.shareToken}'),
                      child: const Text('Track live'),
                    ),
            ),
          ),
          // The sender's link payment before the pickup.
          if (!widget.recipient && part != null && d.atPickup)
            MygigNote(
              key: const ValueKey('mygig-delivery-pay-first'),
              icon: Icons.link,
              title: 'Pay ${mygigMoney((part['amount'] as num).toDouble())} before the pickup',
              body: 'By card, FPX or DuitNow. The deposit part is refunded once it isn’t needed (but the guarantee fee).',
              warn: true,
            ),
          if (!widget.recipient && part != null && d.atPickup)
            BusyButton.filled(
              key: const ValueKey('mygig-delivery-pay'),
              onPressed: () => widget.onPay('accept'),
              child: Text('Pay ${mygigMoney((part['amount'] as num).toDouble())}'),
            ),
          // The recipient: their code, and paying at the door.
          if (mine != null && !mine.ended && mine.code != null)
            Card(
              key: const ValueKey('mygig-delivery-my-code'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Text('Your delivery code. Give it to the driver only when you have the parcel.',
                      textAlign: TextAlign.center, style: t.textTheme.bodySmall),
                  Text(mine.code!, style: t.textTheme.displaySmall?.copyWith(letterSpacing: 8)),
                ]),
              ),
            ),
          if (mine != null && mine.due > 0 && mine.paidHow == null) ...[
            MygigNote(
              icon: Icons.payments_outlined,
              title: 'Pay ${mygigMoney(mine.due)} on delivery',
              body: '${[
                if (mine.dueFare > 0) 'Delivery ${mygigMoney(mine.dueFare)}',
                if (mine.dueWait > 0) 'waiting ${mygigMoney(mine.dueWait)}',
                if (mine.dueCod > 0) 'item ${mygigMoney(mine.dueCod)}',
              ].join(' + ')}. Cash to the driver, or pay here when they are at your door.',
              warn: true,
            ),
            BusyButton.filled(
              key: const ValueKey('mygig-delivery-pay-door'),
              onPressed: mine.status == 'arrived' ? () => widget.onPay('door') : null,
              child: Text('Pay ${mygigMoney(mine.due)}'),
            ),
          ],
          // Every drop-off, with its proof.
          for (final x in d.drops)
            ListTile(
              key: ValueKey('mygig-delivery-follow-drop-${x.n}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(x.delivered ? Icons.task_alt : x.status == 'returned' ? Icons.keyboard_return : Icons.location_on_outlined,
                  color: x.delivered ? t.colorScheme.primary : null),
              title: Text('${x.placeName}${widget.recipient ? '' : ' · ${x.name}'}'),
              subtitle: Text(x.delivered
                  ? 'Delivered${x.deliveredAt == null ? '' : ' at ${TimeOfDay.fromDateTime(x.deliveredAt!).format(context)}'}. '
                      '${x.proofText}${x.proof['photo'] == true ? '. A photo is saved with the delivery.' : '.'}'
                  : switch (x.status) {
                      'arrived' => 'The driver is at the door',
                      'returning' => 'Coming back to the sender',
                      'returned' => 'Back with the sender',
                      _ => 'On the way',
                    }),
            ),
          // Returns: the sender acknowledges (and pays when agreed); the recipient's cash.
          for (final r in d.returns.where((r) => !r.done)) _return(t, d, r),
          if (mine != null && d.delivering && d.returnOf(mine.n) == null && widget.token != null && widget.onSendBack != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('mygig-delivery-send-back'),
                onPressed: () async {
                  final ok = await Navigator.of(context).push<bool>(AppPageRoute<bool>(
                    id: 'mygig.delivery-send-back-link',
                    fullscreenDialog: true,
                    builder: (_) => MygigSendBackScreen(delivery: d, drop: mine, onSend: (reason, method) async {
                      final res = await widget.onSendBack!(reason, method);
                      if (res['payRequest'] != null) await widget.onPay('return');
                    }),
                  ));
                  if (ok == true) widget.onChanged();
                },
                icon: const Icon(Icons.keyboard_return),
                label: const Text('Something wrong? Send it back'),
              ),
            ),
          if (!widget.recipient && d.atPickup)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('mygig-delivery-cancel'),
                onPressed: () => _do(widget.onCancel, done: 'Cancelled. Nothing was charged; anything paid by link is refunded.'),
                child: const Text('Cancel the delivery'),
              ),
            ),
          if (!widget.recipient && d.done && ((d.money['refundDue'] as num?) ?? 0) > 0)
            MygigNote(icon: Icons.undo, title: 'Deposit refund ${mygigMoney((d.money['refundDue'] as num).toDouble())}',
                body: 'Back to the card or account you paid with.', ok: true),
        ],
      ),
    );
  }

  Widget _return(ThemeData t, MygigDelivery d, MygigDeliveryReturn r) {
    final x = d.drops.where((y) => y.n == r.n).firstOrNull;
    if (widget.recipient) {
      if (r.method != 'cash' || r.payer != 'recipient') {
        return MygigNote(icon: Icons.keyboard_return, title: 'It’s going back to ${d.senderName}',
            body: r.payer == 'recipient' && !r.paid ? 'Pay the return fare, ${mygigMoney(r.amount)}, first.' : r.reason);
      }
      return r.recipientCashAck
          ? MygigNote(icon: Icons.check_circle_outline, title: 'You confirmed paying ${mygigMoney(r.amount)} in cash',
              body: r.driverCash ? 'The driver confirmed it too.' : 'Waiting for the driver to confirm it.', ok: true)
          : BusyButton.filled(
              key: const ValueKey('mygig-delivery-cash-ack'),
              onPressed: widget.onCashAck == null ? null : () => _do(() async => widget.onCashAck!()),
              child: Text('I paid ${mygigMoney(r.amount)} in cash to the driver'),
            );
    }
    final payNow = !r.failed && r.payer == 'sender' && !r.paid;
    return Card(
      key: ValueKey('mygig-delivery-ack-${r.n}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Your parcel is coming back', style: t.textTheme.titleMedium),
          Text(r.failed
              ? 'It couldn’t be delivered to ${x?.name ?? 'the recipient'}: ${r.reason.toLowerCase()}.'
              : '${x?.name ?? 'The recipient'} is sending it back: ${r.reason.toLowerCase()}.'),
          MygigNote(
            icon: Icons.payments_outlined,
            title: 'Return fee',
            body: r.failed
                ? '${mygigMoney(r.amount)} ${r.method == 'app' ? 'from ${mygigPayName(d.pay)}' : 'from your return deposit'}, as agreed.'
                : r.payer == 'recipient'
                ? '${x?.name ?? 'The recipient'} pays the return.'
                : 'You agreed to pay returns the recipient asks for: ${mygigMoney(r.amount)}.',
            warn: payNow,
          ),
          if (d.returnCode != null)
            Column(children: [
              Text('Your return code. Give it to the driver only when you have the parcel back.',
                  textAlign: TextAlign.center, style: t.textTheme.bodySmall),
              Text(d.returnCode!, key: const ValueKey('mygig-delivery-return-code'),
                  style: t.textTheme.displaySmall?.copyWith(letterSpacing: 8)),
            ]),
          if (!r.senderAck) ...[
            CheckboxListTile(
              key: ValueKey('mygig-delivery-ack-tick-${r.n}'),
              contentPadding: EdgeInsets.zero,
              value: _ticked.contains(r.id),
              title: Text('I’ll be at ${d.pickupName} to take it back'),
              subtitle: const Text('The driver brings it straight back. I’ll check it against the pickup photos.'),
              onChanged: (v) => setState(() => v == true ? _ticked.add(r.id) : _ticked.remove(r.id)),
            ),
            BusyButton.filled(
              key: ValueKey('mygig-delivery-ack-go-${r.n}'),
              onPressed: _ticked.contains(r.id)
                  ? () => _do(() async {
                        final res = await widget.onAck(r);
                        if (res is Map && res['payRequest'] != null) await widget.onPay('return');
                        return res;
                      })
                  : null,
              child: Text(payNow && !d.inApp ? 'Acknowledge and pay ${mygigMoney(r.amount)}' : 'Acknowledge'),
            ),
            Text('Can’t be there? Contact get.ride support.', style: t.textTheme.bodySmall),
          ] else if (payNow)
            BusyButton.filled(onPressed: () => widget.onPay('return'), child: Text('Pay ${mygigMoney(r.amount)}'))
          else
            const MygigNote(icon: Icons.check_circle_outline, title: 'Acknowledged', body: 'The driver brings it back to you.', ok: true),
        ]),
      ),
    );
  }
}
