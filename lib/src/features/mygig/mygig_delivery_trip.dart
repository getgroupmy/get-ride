// myGiG Delivery on the driver's trip screen (migration 0332): the pickup
// (photos, the item matches, the seal code written on it, the sender's
// cash or link first, refuse the item), Start delivery, each drop-off (I've
// arrived, what the recipient pays first, the proof the admin asks for,
// "Nobody here / refused", "<name> wants to send it back"), and returns:
// every line done before Start the return (payment, the payer's
// acknowledgement, a photo now, the sender's acknowledgement), finished
// with the sender's return code. The server checks each step again.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mygig.dart';
import '../../core/mygig_delivery.dart';
import '../../data/freight_repository.dart' show freightCargoPhotoUploadProvider;
import '../../data/models.dart';
import '../../data/mygig_repository.dart';
import '../../data/photo_picker.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import 'mygig_delivery_new.dart' show openMygigDeliveryPay;
import 'mygig_when.dart' show MygigNote;

/// Whether [r] is a myGiG delivery.
bool isMygigDelivery(RideRequest r) => r.raw['mygig'] is Map && (r.raw['mygig'] as Map)['kind'] == 'delivery';

/// The delivery behind a ride; [stamp] changes when the server touches it.
final mygigDeliveryViewProvider = FutureProvider.autoDispose.family<MygigDelivery, (String, String)>(
  (ref, k) => ref.watch(mygigRepositoryProvider).deliveryView(k.$1),
);

class MygigDeliveryTripPanel extends ConsumerStatefulWidget {
  const MygigDeliveryTripPanel({super.key, required this.ride, this.onEnded});
  final RideRequest ride;
  final VoidCallback? onEnded;

  @override
  ConsumerState<MygigDeliveryTripPanel> createState() => _MygigDeliveryTripPanelState();
}

class _MygigDeliveryTripPanelState extends ConsumerState<MygigDeliveryTripPanel> {
  final _code = TextEditingController();
  final _otherName = TextEditingController();
  final _returnCode = TextEditingController();
  bool _handOther = false;
  String? _handPhoto;
  Timer? _tick;

  (String, String) get _key =>
      (widget.ride.id, '${(widget.ride.raw['mygig'] as Map?)?['deliveryAt'] ?? ''}${widget.ride.status.db}');

  @override
  void initState() {
    super.initState();
    // The proof shows as it is typed.
    _code.addListener(_typed);
    _otherName.addListener(_typed);
    // The waiting clock and the sender's answer show without a tap.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) ref.invalidate(mygigDeliveryViewProvider(_key));
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _code.dispose();
    _otherName.dispose();
    _returnCode.dispose();
    super.dispose();
  }

  void _typed() {
    if (mounted) setState(() {});
  }

  MygigRepository get _repo => ref.read(mygigRepositoryProvider);

  Future<void> _run(Future<void> Function() f, {String? done}) async {
    try {
      await f();
      if (!mounted) return;
      ref.invalidate(mygigDeliveryViewProvider(_key));
      if (done != null) await showAppNotice(id: 'notice.mygig', context: context, kind: NoticeKind.success, message: done);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<String?> _photo() async {
    final picked = await ref.read(photoPickerProvider)(
        ref.read(photoCameraAvailableProvider) ? PhotoSource.camera : PhotoSource.gallery);
    if (picked == null) return null;
    return ref.read(freightCargoPhotoUploadProvider)(picked.bytes, picked.name);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(mygigDeliveryViewProvider(_key));
    final d = async.value;
    if (d == null) {
      return async.hasError
          ? MygigNote(icon: Icons.error_outline, title: 'Couldn’t load the delivery', body: '${async.error}', bad: true)
          : const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
    }
    return MygigDeliveryDriverView(
      delivery: d,
      arrivedAtPickup: widget.ride.status != RideStatus.accepted,
      code: _code,
      otherName: _otherName,
      returnCode: _returnCode,
      handOther: _handOther,
      handPhoto: _handPhoto != null,
      onHandOther: (v) => setState(() => _handOther = v),
      onAction: (a, {drop, ret}) => _act(d, a, drop: drop, ret: ret),
    );
  }

  Future<void> _act(MygigDelivery d, String a, {MygigDeliveryDrop? drop, MygigDeliveryReturn? ret}) async {
    final ride = d.rideId;
    switch (a) {
      case 'arrivedPickup':
        await _run(() => _repo.deliveryArrivedPickup(ride));
      case 'pickupPhoto':
        await _run(() async {
          final p = await _photo();
          if (p != null) await _repo.deliveryPickup(ride, photos: [...d.pickupPhotoPaths, p]);
        });
      case 'matches':
        await _run(() => _repo.deliveryPickup(ride, matches: !d.itemMatches));
      case 'sealed':
        await _run(() => _repo.deliveryPickup(ride, sealed: !d.sealed));
      case 'senderCash':
        await _run(() => _repo.deliverySenderCash(ride));
      case 'senderPay':
        final part = d.acceptPart;
        if (part != null) await openMygigDeliveryPay(context, ref, '${part['id']}');
      case 'refuse':
        final ok = await showAppDialog<bool>(
          id: 'mygig.delivery-refuse',
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Refuse this item?'),
            content: const Text('Nothing is charged and nothing is saved. Anything the sender paid by link is refunded '
                '(but the small guarantee fee). Give back any cash they handed you.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
              FilledButton(key: const ValueKey('mygig-delivery-refuse-yes'), onPressed: () => Navigator.pop(c, true),
                  child: const Text('Refuse')),
            ],
          ),
        );
        if (ok == true) {
          await _run(() => _repo.deliveryRefuse(ride), done: 'Item refused. Nothing was charged. You’re online for the next request.');
          widget.onEnded?.call();
        }
      case 'start':
        await _run(() => _repo.deliveryStart(ride),
            done: 'Each recipient got the tracking link and their delivery code (in the app, or by SMS).');
      case 'arrived':
        _code.clear();
        _otherName.clear();
        setState(() {
          _handOther = false;
          _handPhoto = null;
        });
        await _run(() => _repo.deliveryArrived(ride, drop!.n));
      case 'doorCash':
        await _run(() => _repo.deliveryDoorCash(ride, drop!.n));
      case 'doorLink':
        try {
          final req = await _repo.deliveryDoorLink(ride, drop!.n);
          if (req != null && mounted) await openMygigDeliveryPay(context, ref, req);
        } catch (e) {
          if (mounted) showError(context, e);
        }
      case 'handPhoto':
        try {
          final p = await _photo();
          if (p != null && mounted) setState(() => _handPhoto = p);
        } catch (e) {
          if (mounted) showError(context, e);
        }
      case 'delivered':
        final res = <String, dynamic>{};
        await _run(() async {
          res.addAll(await _repo.deliveryHandover(ride, drop!.n,
              code: _code.text.trim().isEmpty ? null : _code.text.trim(),
              name: _otherName.text.trim().isEmpty ? null : _otherName.text.trim(),
              photo: _handPhoto));
        });
        if (res['finished'] == true && mounted) {
          await showAppNotice(id: 'notice.mygig', context: context, kind: NoticeKind.success, title: 'Delivery done',
              message: '${d.drops.length} drop-off${d.drops.length > 1 ? 's' : ''} done. Proof sent to ${d.senderName}. '
                  'You’re online for the next request.');
          widget.onEnded?.call();
        }
      case 'notHere':
        final go = await showAppDialog<bool>(
          id: 'mygig.delivery-not-here',
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Nobody here, or refused?'),
            content: Text('Waiting counts after ${d.quote.waitFree.round()} min. If you can’t deliver, start a return to '
                '${d.senderName}. The return fee is ${mygigMoney(drop!.failFee)}: '
                '${d.inApp ? 'charged to ${mygigPayName(d.pay)} when it’s back' : 'paid from the sender’s return deposit'}. '
                '${d.senderName} must acknowledge before you go.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep waiting')),
              FilledButton(key: const ValueKey('mygig-delivery-start-failed'), onPressed: () => Navigator.pop(c, true),
                  child: const Text('Start a return')),
            ],
          ),
        );
        if (go == true) await _run(() => _repo.deliveryReturnFailed(ride, drop!.n));
      case 'asked':
        final ok = await Navigator.of(context).push<bool>(AppPageRoute<bool>(
          id: 'mygig.delivery-send-back',
          fullscreenDialog: true,
          builder: (_) => MygigSendBackScreen(delivery: d, drop: drop!, onSend: (reason, method) async {
            await _repo.deliveryReturnAsk(ride: ride, n: drop.n, reason: reason, method: method, ack: true);
          }),
        ));
        if (ok == true && mounted) ref.invalidate(mygigDeliveryViewProvider(_key));
      case 'retCash':
        await _run(() => _repo.deliveryReturnCash(ride, ret!.id));
      case 'retPhoto':
        await _run(() async {
          final p = await _photo();
          if (p != null) await _repo.deliveryReturnPhoto(ride, ret!.id, p);
        });
      case 'retStart':
        await _run(() => _repo.deliveryReturnStart(ride, ret!.id));
      case 'retDone':
        final res = <String, dynamic>{};
        await _run(() async => res.addAll(await _repo.deliveryReturnDone(ride, ret!.id, _returnCode.text.trim())));
        _returnCode.clear();
        if (res['finished'] == true && mounted) {
          await showAppNotice(id: 'notice.mygig', context: context, kind: NoticeKind.success, title: 'Back with the sender',
              message: '${d.senderName} gave the return code and has the parcel back. The return is in the delivery’s '
                  'history with both acknowledgements.');
          widget.onEnded?.call();
        }
    }
  }
}

typedef MygigDeliveryAction = void Function(String action, {MygigDeliveryDrop? drop, MygigDeliveryReturn? ret});

/// What the driver sees (no server calls: tested on its own).
class MygigDeliveryDriverView extends StatelessWidget {
  const MygigDeliveryDriverView({
    super.key,
    required this.delivery,
    required this.arrivedAtPickup,
    required this.code,
    required this.otherName,
    required this.returnCode,
    required this.handOther,
    required this.handPhoto,
    required this.onHandOther,
    required this.onAction,
  });
  final MygigDelivery delivery;
  final bool arrivedAtPickup;
  final TextEditingController code;
  final TextEditingController otherName;
  final TextEditingController returnCode;
  final bool handOther;
  final bool handPhoto;
  final ValueChanged<bool> onHandOther;
  final MygigDeliveryAction onAction;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = delivery;
    final open = d.returns.where((r) => !r.done).toList();
    return Column(
      key: const ValueKey('mygig-delivery-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.inventory_2_outlined)),
            title: Text('${d.type} · ${mygigDeliverySizeName(d.size).toLowerCase()} · ${d.kg.toStringAsFixed(d.kg == d.kg.roundToDouble() ? 0 : 1)} kg'
                '${d.fragile ? ' · fragile' : ''}'),
            subtitle: Text('From ${d.senderName} · seal code ${d.sealCode}'),
          ),
        ),
        if (d.atPickup) ..._pickup(t, d),
        if (d.delivering) ...[
          for (final r in open) _return(t, d, r),
          ..._drops(t, d),
        ],
        if (d.done)
          MygigNote(
            icon: Icons.task_alt,
            title: 'Delivery done',
            body: 'Proof sent to ${d.senderName}. Earned ${mygigMoney((d.money['earned'] as num?)?.toDouble() ?? d.total)}.',
            ok: true,
          ),
      ],
    );
  }

  Widget _check(String key, bool on, String title, String sub, VoidCallback tap) => CheckboxListTile(
    key: ValueKey(key),
    contentPadding: EdgeInsets.zero,
    value: on,
    title: Text(title),
    subtitle: Text(sub),
    onChanged: (_) => tap(),
  );

  List<Widget> _pickup(ThemeData t, MygigDelivery d) {
    final part = d.acceptPart;
    final why = d.startProblem;
    return [
      Text('Pick up the parcel', style: t.textTheme.titleMedium),
      if (!arrivedAtPickup)
        BusyButton.tonal(onPressed: () async => onAction('arrivedPickup'), child: const Text('I’ve arrived at the pickup')),
      Row(children: [
        Expanded(child: Text('Photos at pickup · ${d.pickupPhotos} of ${d.needPhotos}', style: t.textTheme.bodyMedium)),
        OutlinedButton.icon(
          key: const ValueKey('mygig-delivery-pickup-photo'),
          onPressed: () => onAction('pickupPhoto'),
          icon: const Icon(Icons.add_a_photo_outlined),
          label: const Text('Take a photo'),
        ),
      ]),
      _check('mygig-delivery-matches', d.itemMatches, 'The item matches the description',
          'Size, weight, nothing that looks prohibited', () => onAction('matches')),
      _check('mygig-delivery-sealed', d.sealed, 'Seal code written on the parcel: ${d.sealCode}',
          'The recipient can check it at the door', () => onAction('sealed')),
      if (d.senderCashDue)
        BusyButton.filled(
          key: const ValueKey('mygig-delivery-sender-cash'),
          icon: const Icon(Icons.payments_outlined),
          onPressed: () async => onAction('senderCash'),
          child: Text('Confirm cash ${mygigMoney(d.total)} received'),
        )
      else if (part != null)
        MygigNote(
          key: const ValueKey('mygig-delivery-sender-link'),
          icon: Icons.link,
          title: 'Waiting for ${d.senderName} to pay ${mygigMoney((part['amount'] as num).toDouble())} by link',
          body: (part['split'] is Map && ((part['split'] as Map)['fare'] as num? ?? 0) > 0)
              ? 'The delivery and the refundable deposit, before you pick up.'
              : 'The refundable deposit, before you pick up.',
          warn: true,
        )
      else
        MygigNote(
          icon: Icons.check_circle_outline,
          title: d.recipientPays
              ? 'Recipient pays on delivery'
              : switch (d.pay) {
                  MygigPay.link => 'Paid by link',
                  MygigPay.business => 'Charged to the business account',
                  MygigPay.family => 'Paid by Family',
                  MygigPay.wallet => 'Paid with GET.wallet',
                  MygigPay.cash => 'Cash received',
                },
          body: d.depositPaid > 0 ? 'The sender’s deposit is paid.' : 'Nothing more to collect here.',
          ok: true,
        ),
      if (part != null)
        TextButton.icon(
          onPressed: () => onAction('senderPay'),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Pay on this phone'),
        ),
      if (d.pickupWaitOver > 0)
        Text('Waiting ${d.pickupWaitOver} min over the free time: ${mygigMoney(d.pickupWaitCharge)}, '
            '${d.inApp ? 'charged to ${mygigPayName(d.pay)}' : 'from the sender’s deposit'}.', style: t.textTheme.bodySmall),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('mygig-delivery-refuse'),
          style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
          onPressed: () => onAction('refuse'),
          icon: const Icon(Icons.do_not_disturb_on_outlined),
          label: const Text('Refuse this item'),
        ),
      ),
      if (why != null) Text(why, key: const ValueKey('mygig-delivery-start-why'), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
      BusyButton.filled(
        key: const ValueKey('mygig-delivery-start'),
        icon: const Icon(Icons.local_shipping_outlined),
        onPressed: why == null ? () async => onAction('start') : null,
        child: const Text('Start delivery'),
      ),
    ];
  }

  List<Widget> _drops(ThemeData t, MygigDelivery d) {
    final next = d.nextDrop;
    return [
      Card(
        child: Column(children: [
          for (final x in d.drops)
            ListTile(
              key: ValueKey('mygig-delivery-drop-${x.n}'),
              leading: x.delivered
                  ? Icon(Icons.check_circle, color: t.colorScheme.primary)
                  : x.status == 'returning' || x.status == 'returned'
                  ? const Icon(Icons.keyboard_return)
                  : CircleAvatar(radius: 12, child: Text('${x.n}', style: const TextStyle(fontSize: 12))),
              title: Text(x.placeName),
              subtitle: Text('${x.name}${x.delivered ? ' · delivered' : x.status == 'returning' ? ' · coming back' : x.status == 'returned' ? ' · back with the sender' : ''}'),
            ),
        ]),
      ),
      Text('The sender and every recipient follow it live. Seal code ${d.sealCode}.', style: t.textTheme.bodySmall),
      if (next != null && next.status == 'waiting')
        BusyButton.filled(
          key: const ValueKey('mygig-delivery-arrived'),
          icon: const Icon(Icons.where_to_vote_outlined),
          onPressed: () async => onAction('arrived', drop: next),
          child: Text('I’ve arrived · ${next.name}'),
        ),
      if (next != null && next.status == 'arrived') ..._door(t, d, next),
    ];
  }

  List<Widget> _door(ThemeData t, MygigDelivery d, MygigDeliveryDrop x) {
    final rule = d.proofRule;
    final proofOk = mygigProofOk(rule: rule, code: code.text, handOther: handOther, name: otherName.text, photo: handPhoto);
    final why = mygigHandoverProblem(d: x, rule: rule, proofOk: proofOk);
    return [
      Text('At the drop-off${d.drops.length > 1 ? ' ${x.n}' : ''} · ${x.name}', style: t.textTheme.titleMedium),
      if (x.due > 0)
        Card(
          key: const ValueKey('mygig-delivery-due'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (x.dueFare > 0) _row(t, 'Delivery fare', x.dueFare),
              if (x.dueWait > 0) _row(t, 'Waiting', x.dueWait),
              if (x.dueCod > 0) _row(t, 'Cash on delivery for ${d.senderName}', x.dueCod),
              _row(t, 'Collect from ${x.name}', x.due, bold: true),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: BusyButton.filled(
                    key: const ValueKey('mygig-delivery-door-cash'),
                    onPressed: () async => onAction('doorCash', drop: x),
                    child: const Text('Cash received'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: BusyButton.tonal(
                    key: const ValueKey('mygig-delivery-door-link'),
                    onPressed: () async => onAction('doorLink', drop: x),
                    child: const Text('Pay by link'),
                  ),
                ),
              ]),
              if (x.dueCod > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Cash COD comes off your GET.credit at once. If it can’t cover it, the recipient pays by link.',
                      style: t.textTheme.bodySmall),
                ),
            ]),
          ),
        ),
      Text(d.waitLine(x, d.quote.waitFree), key: const ValueKey('mygig-delivery-wait-line'), style: t.textTheme.bodySmall),
      if (x.waitOver > 0) Text('Waiting ${x.waitOver} min over the free time: ${mygigMoney(x.waitCharge)}.', style: t.textTheme.bodySmall),
      if (d.waitUsedUp)
        const MygigNote(icon: Icons.hourglass_bottom, title: 'The deposit’s waiting allowance is used up',
            body: 'Start a return now: you’re never left waiting unpaid.', warn: true),
      Text('Proof of delivery', style: t.textTheme.titleSmall),
      if (rule != 'photo')
        TextField(
          key: const ValueKey('mygig-delivery-code'),
          controller: code,
          keyboardType: TextInputType.number,
          maxLength: 4,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: 'Delivery code from ${x.name}', hintText: '4 digits', counterText: ''),
        ),
      if (rule == 'codeOrPhoto')
        CheckboxListTile(
          key: const ValueKey('mygig-delivery-hand-other'),
          contentPadding: EdgeInsets.zero,
          value: handOther,
          title: const Text('Recipient not here: hand it to someone else'),
          subtitle: const Text('A guard, a neighbour, reception. Their name and a photo'),
          onChanged: (v) => onHandOther(v ?? false),
        ),
      if (rule == 'codeOrPhoto' && handOther)
        TextField(
          key: const ValueKey('mygig-delivery-other-name'),
          controller: otherName,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Handed to (name)'),
        ),
      if (rule == 'photo' || handOther)
        OutlinedButton.icon(
          key: const ValueKey('mygig-delivery-hand-photo'),
          onPressed: () => onAction('handPhoto', drop: x),
          icon: Icon(handPhoto ? Icons.check : Icons.add_a_photo_outlined),
          label: Text(handPhoto ? 'Photo taken' : rule == 'photo' ? 'Photo of the hand-over' : 'Take a photo'),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('mygig-delivery-not-here'),
          style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
          onPressed: () => onAction('notHere', drop: x),
          icon: const Icon(Icons.person_off_outlined),
          label: const Text('Nobody here / refused'),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('mygig-delivery-asked'),
          onPressed: () => onAction('asked', drop: x),
          icon: const Icon(Icons.keyboard_return),
          label: Text('${x.name} wants to send it back'),
        ),
      ),
      if (why != null) Text(why, textAlign: TextAlign.center, style: t.textTheme.bodySmall),
      BusyButton.filled(
        key: const ValueKey('mygig-delivery-delivered'),
        icon: const Icon(Icons.task_alt),
        onPressed: why == null ? () async => onAction('delivered', drop: x) : null,
        child: Text(d.drops.where((y) => !y.ended).length <= 1 ? 'Delivered · finish' : 'Delivered · next drop-off'),
      ),
    ];
  }

  Widget _row(ThemeData t, String label, double v, {bool bold = false}) {
    final style = bold ? t.textTheme.titleMedium : t.textTheme.bodyMedium;
    return Row(children: [Expanded(child: Text(label, style: style)), Text(mygigMoney(v), style: style)]);
  }

  Widget _return(ThemeData t, MygigDelivery d, MygigDeliveryReturn r) {
    final x = d.drops.where((y) => y.n == r.n).firstOrNull;
    final rec = x?.name ?? 'The recipient';
    final lines = mygigReturnLines(r, sender: d.senderName, recipient: rec, payName: mygigPayName(d.pay), senderInApp: d.inApp);
    return Card(
      key: ValueKey('mygig-delivery-return-${r.n}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          MygigNote(
            icon: Icons.keyboard_return,
            title: r.failed ? 'Couldn’t deliver to $rec' : '$rec is sending it back',
            body: '${r.reason}. It goes back to ${d.senderName} at ${d.pickupName}.',
            warn: r.failed,
          ),
          if (r.started) ...[
            Text('Taking it back to ${d.senderName}', style: t.textTheme.titleSmall),
            TextField(
              key: ValueKey('mygig-delivery-return-code-${r.n}'),
              controller: returnCode,
              keyboardType: TextInputType.number,
              maxLength: 4,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: 'Return code from ${d.senderName}', hintText: '4 digits', counterText: ''),
            ),
            BusyButton.filled(
              key: ValueKey('mygig-delivery-return-done-${r.n}'),
              icon: const Icon(Icons.task_alt),
              onPressed: () async => onAction('retDone', ret: r),
              child: const Text('Back with the sender'),
            ),
          ] else ...[
            Text('Every line must be done before you start. Nothing is charged later to anyone without the app.',
                style: t.textTheme.bodySmall),
            for (final (i, l) in lines.indexed)
              ListTile(
                key: ValueKey('mygig-delivery-return-line-${r.n}-$i'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(l.ok ? Icons.check_circle : Icons.hourglass_top, color: l.ok ? t.colorScheme.primary : null),
                title: Text(l.title),
                subtitle: Text(l.sub),
                trailing: i == 0 && r.method == 'cash' && !r.driverCash
                    ? TextButton(onPressed: () => onAction('retCash', ret: r), child: const Text('Cash received'))
                    : i == 1 && !l.ok
                    ? IconButton(tooltip: 'Take a photo', icon: const Icon(Icons.add_a_photo_outlined),
                        onPressed: () => onAction('retPhoto', ret: r))
                    : null,
              ),
            if (r.support)
              const MygigNote(icon: Icons.support_agent, title: 'get.ride support is deciding',
                  body: 'The sender didn’t answer in time. Support calls you; don’t keep the parcel.', warn: true)
            else
              Text('No answer from ${d.senderName} in ${d.ackMin.round()} min: get.ride support is told and decides. '
                  'You don’t keep the parcel.', style: t.textTheme.bodySmall),
            BusyButton.filled(
              key: ValueKey('mygig-delivery-return-start-${r.n}'),
              icon: const Icon(Icons.keyboard_return),
              onPressed: r.checks.all && !r.support ? () async => onAction('retStart', ret: r) : null,
              child: const Text('Start the return'),
            ),
          ],
        ]),
      ),
    );
  }
}

/// "Send it back": the recipient's page (on their link, or on the driver's
/// phone at the door). The payer was fixed at the start.
class MygigSendBackScreen extends StatefulWidget {
  const MygigSendBackScreen({super.key, required this.delivery, required this.drop, required this.onSend});
  final MygigDelivery delivery;
  final MygigDeliveryDrop drop;
  final Future<void> Function(String reason, String method) onSend;

  @override
  State<MygigSendBackScreen> createState() => _MygigSendBackScreenState();
}

class _MygigSendBackScreenState extends State<MygigSendBackScreen> {
  String _reason = 'Wrong item';
  String _method = 'link';
  bool _ack = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = widget.delivery;
    final recPays = d.retPayer == 'recipient';
    final amount = widget.drop.returnFare;
    return Scaffold(
      appBar: AppBar(title: Text('Send it back to ${d.senderName}')),
      body: ListView(
        key: const ValueKey('mygig-send-back'),
        padding: const EdgeInsets.all(16),
        children: [
          Text('Why?', style: t.textTheme.titleSmall),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final r in const ['Wrong item', 'Damaged', 'Don’t want it', 'Other'])
              ChoiceChip(label: Text(r), selected: _reason == r, onSelected: (_) => setState(() => _reason = r)),
          ]),
          MygigNote(
            icon: Icons.payments_outlined,
            title: recPays ? 'You pay the return: ${mygigMoney(amount)}' : '${d.senderName} pays the return: ${mygigMoney(amount)}',
            body: recPays
                ? 'As agreed when the parcel was sent. Paid before it leaves.'
                : 'As agreed when the parcel was sent. ${d.senderName} confirms and pays before it leaves.',
            warn: recPays,
          ),
          if (recPays) ...[
            Text('How you pay', style: t.textTheme.titleSmall),
            Wrap(spacing: 8, children: [
              ChoiceChip(label: const Text('Pay now by link'), selected: _method == 'link', onSelected: (_) => setState(() => _method = 'link')),
              ChoiceChip(
                key: const ValueKey('mygig-send-back-cash'),
                label: const Text('Cash to the driver'),
                selected: _method == 'cash',
                onSelected: (_) => setState(() => _method = 'cash'),
              ),
            ]),
            if (_method == 'cash')
              Text('Hand the cash to the driver. The driver confirms it in the app and you confirm it on your link, '
                  'so there’s a record on both sides.', style: t.textTheme.bodySmall),
          ],
          CheckboxListTile(
            key: const ValueKey('mygig-send-back-ack'),
            contentPadding: EdgeInsets.zero,
            value: _ack,
            title: Text('I’m sending it back to ${d.senderName}'),
            subtitle: Text('To ${d.pickupName}, in the same condition I received it${recPays ? '. I pay ${mygigMoney(amount)} before it leaves' : ''}.'),
            onChanged: (v) => setState(() => _ack = v ?? false),
          ),
          const SizedBox(height: 12),
          BusyButton.filled(
            key: const ValueKey('mygig-send-back-go'),
            onPressed: _ack
                ? () async {
                    try {
                      await widget.onSend(_reason, recPays ? _method : 'link');
                      if (context.mounted) Navigator.of(context).pop(true);
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  }
                : null,
            child: Text(recPays && _method == 'link' ? 'Send it back and pay ${mygigMoney(amount)}' : 'Send it back'),
          ),
        ],
      ),
    );
  }
}
