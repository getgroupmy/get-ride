// myGiG part C (0331): reassign a ride or booking to another driver, like
// reassigning an in-app order. The first driver picks a reason and a nearby
// driver with myGiG (or types their code); the new driver sees the whole
// order and ticks "I accept this ride at the agreed price"; then the
// passenger confirms the new driver (in the app, on the trip link, or on the
// first driver's phone), keeps the first one, or cancels with no charge.
// Nothing changes until the passenger confirms.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/mygig.dart' show MygigWay, mygigMoney;
import '../../core/mygig_extras.dart';
import '../../data/models.dart' show RideRequest, RideStatus;
import '../../data/mygig_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import 'mygig_new_screen.dart' show openMygigWhatsApp;

const mygigReassignPath = '/drive/mygig/reassign';

/// The new driver's page for reassign [id].
String mygigReassignOfferPath(String id) => '/drive/mygig/reassign/${Uri.encodeComponent(id)}';

/// The passenger's page (in the app) for reassign [id].
String mygigReassignPassengerPath(String id) => '/mygig/reassign/${Uri.encodeComponent(id)}';

final mygigReassignOptionsProvider =
    FutureProvider.autoDispose.family<MygigReassignOptions, ({String? ride, String? booking})>(
  (ref, k) => ref.watch(mygigRepositoryProvider).reassignOptions(ride: k.ride, booking: k.booking),
);

/// "Reassign to another driver" / "Hand over to another driver" on the
/// driver's trip screen, where the admin's rule allows it now.
class MygigReassignButton extends ConsumerWidget {
  const MygigReassignButton({super.key, required this.ride});
  final RideRequest ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ride;
    final c = ref.watch(mygigConfigProvider(mygigAt(r.pickupLat, r.pickupLng))).value;
    if (c == null) return const SizedBox.shrink();
    final status = switch (r.status) {
      RideStatus.accepted => 'accepted',
      RideStatus.arrived => 'arrived',
      RideStatus.onTrip => 'on_trip',
      _ => '',
    };
    final rule = MygigReassignRule.of(c.settings.raw);
    if (!rule.allows(status: status, booked: r.raw['mygig'] is Map && (r.raw['mygig'] as Map)['bookingId'] != null)) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('mygig-reassign'),
        icon: const Icon(Icons.swap_horiz),
        label: Text(mygigReassignLabel(onTrip: r.status == RideStatus.onTrip)),
        onPressed: () => context.push('$mygigReassignPath?ride=${Uri.encodeComponent(r.id)}'),
      ),
    );
  }
}

/// The first driver: choose why and who, then follow the answers.
class MygigReassignScreen extends ConsumerStatefulWidget {
  const MygigReassignScreen({super.key, this.rideId, this.bookingId});
  final String? rideId;
  final String? bookingId;

  @override
  ConsumerState<MygigReassignScreen> createState() => _MygigReassignScreenState();
}

class _MygigReassignScreenState extends ConsumerState<MygigReassignScreen> {
  String? _reason;
  String? _to;
  String? _started;
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  ({String? ride, String? booking}) get _key => (ride: widget.rideId, booking: widget.bookingId);

  Future<void> _send() async {
    try {
      final code = _code.text.trim();
      final r = await ref.read(mygigRepositoryProvider).reassignStart(
            ride: widget.rideId,
            booking: widget.bookingId,
            to: code.isEmpty ? _to : null,
            code: code.isEmpty ? null : code,
            reason: _reason ?? 'Other',
          );
      if (mounted) setState(() => _started = r.id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// An open one already going for this ride or booking (the app restarted).
  String? _openId(List<MygigReassign> mine) => mine
      .where((r) => r.me == 'from' && r.open &&
          ((widget.rideId != null && r.rideId == widget.rideId) || (widget.bookingId != null && r.bookingId == widget.bookingId)))
      .map((r) => r.id)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final mine = ref.watch(mygigReassignsMineProvider).value ?? const <MygigReassign>[];
    final id = _started ?? _openId(mine);
    if (id != null) return MygigReassignFollow(id: id);
    final async = ref.watch(mygigReassignOptionsProvider(_key));
    return Scaffold(
      appBar: AppBar(title: Text(async.value?.during == true ? 'Hand over the ride' : 'Reassign the ride')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(mygigReassignOptionsProvider(_key)),
        data: (o) => _pick(context, o),
      ),
      bottomNavigationBar: async.value == null ? null : _foot(context, async.value!),
    );
  }

  Widget _pick(BuildContext context, MygigReassignOptions o) {
    final t = Theme.of(context);
    _reason ??= o.reasons.firstOrNull;
    return ResponsiveCenter(
      maxWidth: 760,
      child: ListView(
        key: const ValueKey('mygig-reassign-pick'),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'The price, the trip and the payment stay the same. The new driver accepts first, then the passenger must '
            'confirm the new driver before anything changes.',
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text('Why', style: t.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final r in o.reasons)
              ChoiceChip(
                key: ValueKey('mygig-reassign-reason-$r'),
                label: Text(r),
                selected: _reason == r,
                onSelected: (_) => setState(() => _reason = r),
              ),
          ]),
          const SizedBox(height: 16),
          Text('Nearby drivers with myGiG', style: t.textTheme.titleSmall),
          const SizedBox(height: 6),
          if (o.drivers.isEmpty)
            Text('No myGiG drivers within ${o.nearKm.toStringAsFixed(0)} km right now. Enter a driver’s code below.',
                style: t.textTheme.bodySmall)
          else
            Card(
              child: RadioGroup<String>(
                groupValue: _to,
                onChanged: (v) => setState(() {
                  _to = v;
                  _code.clear();
                }),
                child: Column(children: [
                  for (final d in o.drivers)
                    RadioListTile<String>(
                      key: ValueKey('mygig-reassign-driver-${d.id}'),
                      value: d.id,
                      enabled: d.eligible,
                      title: Text('${d.name} · ${d.ratingText}'),
                      subtitle: Text.rich(TextSpan(children: [
                        TextSpan(text: [d.carText, '${d.km.toStringAsFixed(1)} km away'].where((s) => s.isNotEmpty).join(' · ')),
                        if (!d.eligible)
                          TextSpan(text: ' · ${d.why}', style: TextStyle(color: t.colorScheme.error)),
                      ])),
                    ),
                ]),
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('mygig-reassign-code'),
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Or enter a driver’s code', hintText: 'My Ride code or GET.me QR'),
            onChanged: (_) => setState(() {
              if (_code.text.trim().isNotEmpty) _to = null;
            }),
          ),
          const SizedBox(height: 8),
          if (o.way == 'here')
            Text('This passenger gave no phone, so they confirm the new driver on your phone.', style: t.textTheme.bodySmall),
          Text(
            'They have ${o.answerMin} min to answer. With no answer, '
            '${mygigNoAnswerText(keep: o.keepOnNoAnswer, kept: 'you keep the ride')}.'
            '${o.sameOrBigger ? ' Only a vehicle as big as yours or bigger can be chosen.' : ''}',
            style: t.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _foot(BuildContext context, MygigReassignOptions o) {
    final chosen = o.drivers.where((d) => d.id == _to).firstOrNull;
    final ready = _reason != null && (chosen != null || _code.text.trim().isNotEmpty);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: BusyButton.filled(
          key: const ValueKey('mygig-reassign-send'),
          icon: const Icon(Icons.send),
          onPressed: ready ? _send : null,
          child: Text(chosen != null ? 'Send to ${chosen.name}' : 'Send to the new driver'),
        ),
      ),
    );
  }
}

/// The first driver follows a reassign: the new driver's answer, then the
/// passenger's; sends the link again or shows the passenger this phone.
class MygigReassignFollow extends ConsumerWidget {
  const MygigReassignFollow({super.key, required this.id});
  final String id;

  Future<void> _resend(BuildContext context, WidgetRef ref, MygigReassign r) async {
    try {
      final v = await ref.read(mygigRepositoryProvider).reassignResend(r.id);
      if (r.way == 'whatsapp') {
        await openMygigWhatsApp(MygigSent(offerId: r.id, way: MygigWay.whatsapp, link: v['link'] as String?,
            message: v['message'] as String?, phone: v['phone'] as String?));
      } else if (context.mounted) {
        await showAppNotice(id: 'notice.mygig', context: context, title: 'Sent again', message: 'The passenger was texted a new link.');
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _stop(BuildContext context, WidgetRef ref, MygigReassign r) async {
    try {
      await ref.read(mygigRepositoryProvider).reassignStop(r.id);
      ref.invalidate(mygigReassignProvider(id));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _showPassenger(BuildContext context, MygigReassign r) => Navigator.of(context).push(AppPageRoute<void>(
    id: 'mygig.reassign-here',
    fullscreenDialog: true,
    builder: (_) => MygigReassignPassengerScreen(id: r.id, here: true),
  ));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mygigReassignProvider(id));
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(async.value?.during == true ? 'Hand over the ride' : 'Reassign the ride')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(mygigReassignProvider(id)),
        data: (r) => ResponsiveCenter(
          maxWidth: 760,
          child: ListView(
            key: const ValueKey('mygig-reassign-follow'),
            padding: const EdgeInsets.all(20),
            children: [
              Icon(
                switch (r.stage) {
                  MygigReassignStage.driver => Icons.person_search,
                  MygigReassignStage.passenger => Icons.send_to_mobile,
                  MygigReassignStage.done => Icons.check_circle_outline,
                  _ => Icons.info_outline,
                },
                size: 48,
                color: t.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                switch (r.stage) {
                  MygigReassignStage.driver => 'Sent to ${r.to.name}',
                  MygigReassignStage.passenger => '${r.to.name} accepted. Waiting for the passenger',
                  MygigReassignStage.done => 'Handed over',
                  _ => 'The ride is still yours',
                },
                textAlign: TextAlign.center,
                style: t.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(mygigReassignStatusText(r), key: const ValueKey('mygig-reassign-status'), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              MygigReassignSummary(reassign: r),
              if (r.open && r.answerBy != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    r.stage == MygigReassignStage.passenger
                        ? 'No answer by ${TimeOfDay.fromDateTime(r.answerBy!).format(context)}: '
                            '${mygigNoAnswerText(keep: r.keepOnNoAnswer, kept: 'the ride stays with you')}. '
                            'Until then the ride is still yours.'
                        : '${r.to.name} has until ${TimeOfDay.fromDateTime(r.answerBy!).format(context)} to answer.',
                    style: t.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 16),
              if (r.stage == MygigReassignStage.passenger && r.way == 'here')
                FilledButton.icon(
                  key: const ValueKey('mygig-reassign-show'),
                  icon: const Icon(Icons.screen_rotation),
                  onPressed: () => _showPassenger(context, r),
                  label: const Text('Show the passenger'),
                ),
              if (r.stage == MygigReassignStage.passenger && (r.way == 'whatsapp' || r.way == 'sms'))
                BusyButton.tonal(
                  key: const ValueKey('mygig-reassign-resend'),
                  icon: Icon(r.way == 'whatsapp' ? Icons.chat_outlined : Icons.sms_outlined),
                  onPressed: () => _resend(context, ref, r),
                  child: Text(r.way == 'whatsapp' ? 'Send the link on WhatsApp' : 'Text the link again'),
                ),
              const SizedBox(height: 8),
              if (r.open)
                BusyButton.outlined(
                  key: const ValueKey('mygig-reassign-stop'),
                  onPressed: () => _stop(context, ref, r),
                  child: const Text('Stop reassigning'),
                )
              else
                FilledButton(
                  key: const ValueKey('mygig-reassign-done'),
                  onPressed: () => context.go(r.stage == MygigReassignStage.done || r.rideId == null
                      ? (r.bookingId != null ? '/drive/mygig/scheduled' : '/drive')
                      : '/drive/trip/${r.rideId}'),
                  child: const Text('OK'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The trip as both drivers and the passenger see it: route, when, who, price.
class MygigReassignSummary extends StatelessWidget {
  const MygigReassignSummary({super.key, required this.reassign});
  final MygigReassign reassign;

  @override
  Widget build(BuildContext context) {
    final r = reassign;
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('From ${r.pickupName}'),
          for (final s in r.stopNames) Text('Stop: $s'),
          Text('To ${r.dropName}'),
          const SizedBox(height: 6),
          Text([r.kindName, r.whenText, if (r.daysLeft != null && (r.days ?? 1) > 1) '${r.daysLeft} of ${r.days} days left']
              .join(' · '), style: t.textTheme.bodySmall),
          if (r.passenger != null || r.me != 'passenger')
            Text('${r.passenger ?? 'Passenger'} · ${r.registered ? 'registered' : 'not registered (trip link)'} · ${r.whoText}',
                style: t.textTheme.bodySmall),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Text(r.payName, style: t.textTheme.bodyMedium)),
            Text(mygigMoney(r.total), style: t.textTheme.titleMedium),
          ]),
        ]),
      ),
    );
  }
}

/// The new driver: the whole order, the agreed price, their plan, and the
/// tick before Accept works.
class MygigReassignOfferScreen extends ConsumerStatefulWidget {
  const MygigReassignOfferScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<MygigReassignOfferScreen> createState() => _MygigReassignOfferScreenState();
}

class _MygigReassignOfferScreenState extends ConsumerState<MygigReassignOfferScreen> {
  bool _ack = false;

  Future<void> _answer(bool accept) async {
    try {
      await ref.read(mygigRepositoryProvider).reassignDriverAnswer(widget.id, accept: accept, ack: _ack);
      ref.invalidate(mygigReassignProvider(widget.id));
      if (!accept && mounted) context.go('/drive');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(mygigReassignProvider(widget.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Take over this ride?')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(mygigReassignProvider(widget.id)),
        data: (r) => _body(context, r),
      ),
      bottomNavigationBar: async.value == null ? null : _foot(async.value!),
    );
  }

  Widget _body(BuildContext context, MygigReassign r) {
    final t = Theme.of(context);
    return ResponsiveCenter(
      maxWidth: 760,
      child: ListView(
        key: const ValueKey('mygig-reassign-offer'),
        padding: const EdgeInsets.all(16),
        children: [
          Text('From ${r.from.name}: ${r.reason.toLowerCase()}.', style: t.textTheme.bodyLarge),
          const SizedBox(height: 8),
          MygigReassignSummary(reassign: r),
          Card(
            child: ListTile(
              leading: const Icon(Icons.payments_outlined),
              title: Text('Agreed price ${mygigMoney(r.total)}${r.kind == 'trip' ? '' : ' · ${r.kindName}'}'),
              subtitle: Text('The passenger already agreed this price, so your own myGiG prices don’t apply. ${r.moneyLine}'),
            ),
          ),
          if (r.plan != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: Text('Your myGiG plan: ${r.plan!.text}'),
                subtitle: const Text('It applies to this ride like any of yours.'),
              ),
            ),
          if (r.stage == MygigReassignStage.driver)
            CheckboxListTile(
              key: const ValueKey('mygig-reassign-ack'),
              value: _ack,
              onChanged: (v) => setState(() => _ack = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('I accept this ride at the agreed price'),
              subtitle: Text('I’ll pick up ${r.passenger ?? 'the passenger'} at ${r.pickupName}'
                  '${r.when == 'now' || r.when == 'during' ? '' : ', ${r.when}'} in my ${[r.to.vehicle, r.to.plate].whereType<String>().join(', ')}. '
                  'The passenger confirms me before the ride is mine.'),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                switch (r.stage) {
                  MygigReassignStage.passenger => 'You accepted. Waiting for the passenger to confirm you.',
                  MygigReassignStage.done => 'The passenger confirmed you. The ride is yours.',
                  MygigReassignStage.declined => 'You declined.',
                  _ => 'This request has ended.',
                },
                key: const ValueKey('mygig-reassign-offer-state'),
                style: t.textTheme.titleMedium,
              ),
            ),
        ],
      ),
    );
  }

  Widget? _foot(MygigReassign r) {
    if (r.stage == MygigReassignStage.done) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            key: const ValueKey('mygig-reassign-open'),
            onPressed: () => context.go(r.rideId != null ? '/drive/trip/${r.rideId}' : '/drive/mygig/scheduled'),
            child: Text(r.rideId != null ? 'Open the ride' : 'Open Scheduled myGiG'),
          ),
        ),
      );
    }
    if (r.stage != MygigReassignStage.driver) return null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          BusyButton.filled(
            key: const ValueKey('mygig-reassign-accept'),
            icon: const Icon(Icons.check),
            onPressed: _ack ? () => _answer(true) : null,
            child: const Text('Accept the ride'),
          ),
          const SizedBox(height: 8),
          BusyButton.tonal(
            key: const ValueKey('mygig-reassign-decline'),
            onPressed: () => _answer(false),
            child: const Text('Decline'),
          ),
        ]),
      ),
    );
  }
}

/// The passenger confirms the new driver (with their tick), keeps the
/// first, or cancels with no charge. [onAnswer] sends it.
class MygigReassignConfirm extends StatefulWidget {
  const MygigReassignConfirm({super.key, required this.reassign, required this.onAnswer});
  final MygigReassign reassign;
  final Future<void> Function(String answer, bool ack) onAnswer;

  @override
  State<MygigReassignConfirm> createState() => _MygigReassignConfirmState();
}

class _MygigReassignConfirmState extends State<MygigReassignConfirm> {
  bool _ack = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.reassign;
    final t = Theme.of(context);
    final to = r.to;
    return Column(
      key: const ValueKey('mygig-reassign-confirm'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your driver is changing', style: t.textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text('${r.from.name} can’t take your ride: ${r.reason.toLowerCase()}. ${to.name} has accepted it at the same price.'),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text('${to.name} · ${to.ratingText}'),
            subtitle: Text.rich(TextSpan(children: [
              TextSpan(text: [to.vehicle, to.colour].whereType<String>().join(' · ')),
              if (to.plate != null) ...[
                const TextSpan(text: ' · '),
                TextSpan(text: to.plate, style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
              TextSpan(text: '\n${r.when == 'during' ? 'Meets you on the way to swap cars' : r.when == 'now' ? 'Coming to your pickup' : 'Picks you up ${r.when}'}'),
            ])),
            isThreeLine: true,
          ),
        ),
        MygigReassignSummary(reassign: r),
        Card(
          color: t.colorScheme.secondaryContainer,
          child: ListTile(
            leading: Icon(Icons.verified_outlined, color: t.colorScheme.onSecondaryContainer),
            title: Text('Same price ${mygigMoney(r.total)}, same payment',
                style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
            subtitle: Text(r.passengerMoneyLine(), style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
          ),
        ),
        CheckboxListTile(
          key: const ValueKey('mygig-reassign-pax-ack'),
          value: _ack,
          onChanged: (v) => setState(() => _ack = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text('I understand my driver is now ${to.name}'),
          subtitle: Text('${[to.vehicle, if (to.plate != null) 'plate ${to.plate}'].whereType<String>().join(', ')}. '
              'I’ll check the plate before I get in.'),
        ),
        if (r.answerBy != null)
          Text(
            'Please answer by ${TimeOfDay.fromDateTime(r.answerBy!).format(context)}. With no answer, '
            '${mygigNoAnswerText(keep: r.keepOnNoAnswer, kept: '${r.from.name} keeps your ride')}.',
            style: t.textTheme.bodySmall,
          ),
        const SizedBox(height: 12),
        BusyButton.filled(
          key: const ValueKey('mygig-reassign-pax-confirm'),
          onPressed: _ack ? () => widget.onAnswer('confirm', true) : null,
          child: Text('Confirm ${to.name} as my driver'),
        ),
        const SizedBox(height: 8),
        BusyButton.tonal(
          key: const ValueKey('mygig-reassign-pax-keep'),
          onPressed: () => widget.onAnswer('keep', false),
          child: Text('Keep ${r.from.name}'),
        ),
        BusyButton.text(
          key: const ValueKey('mygig-reassign-pax-cancel'),
          onPressed: () => widget.onAnswer('cancel', false),
          child: const Text('Cancel my ride (no charge)'),
        ),
      ],
    );
  }
}

/// The passenger's page in the app (from the push or the trip screen), or
/// on the first driver's phone ([here]) when the passenger gave no phone.
class MygigReassignPassengerScreen extends ConsumerWidget {
  const MygigReassignPassengerScreen({super.key, required this.id, this.here = false});
  final String id;
  final bool here;

  Future<void> _answer(BuildContext context, WidgetRef ref, String answer, bool ack) async {
    try {
      await ref.read(mygigRepositoryProvider).reassignAnswer(id: id, answer: answer, ack: ack);
      ref.invalidate(mygigReassignProvider(id));
      if (!context.mounted) return;
      await showAppNotice(
        id: 'notice.mygig',
        context: context,
        title: switch (answer) { 'confirm' => 'Driver changed', 'keep' => 'Driver kept', _ => 'Ride cancelled' },
        message: switch (answer) {
          'confirm' => 'Your new driver is on the way. Check the plate before you get in.',
          'keep' => 'Your first driver keeps your ride. Nothing has changed.',
          _ => 'Your ride is cancelled with no charge. Anything you paid is refunded.',
        },
      );
      if (context.mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mygigReassignProvider(id));
    return Scaffold(
      appBar: AppBar(title: Text(here ? 'For the passenger' : 'Your driver is changing')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(mygigReassignProvider(id)),
        data: (r) => ResponsiveCenter(
          maxWidth: 640,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (r.stage == MygigReassignStage.passenger)
                MygigReassignConfirm(reassign: r, onAnswer: (a, ack) => _answer(context, ref, a, ack))
              else
                Text(
                  switch (r.stage) {
                    MygigReassignStage.done => 'Your driver is now ${r.to.name}.',
                    MygigReassignStage.cancelled => 'Your ride was cancelled with no charge.',
                    _ => 'Your driver keeps your ride. Nothing has changed.',
                  },
                  key: const ValueKey('mygig-reassign-pax-ended'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// On the passenger's trip screen in the app: a change of driver to confirm.
class MygigReassignPrompt extends ConsumerWidget {
  const MygigReassignPrompt({super.key, this.rideId, this.bookingId});
  final String? rideId;
  final String? bookingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(mygigReassignsMineProvider).value ?? const <MygigReassign>[];
    final r = mine
        .where((x) => x.me == 'passenger' && x.stage == MygigReassignStage.passenger &&
            ((rideId != null && x.rideId == rideId) || (bookingId != null && x.bookingId == bookingId)))
        .firstOrNull;
    if (r == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('mygig-reassign-prompt'),
      color: t.colorScheme.tertiaryContainer,
      child: ListTile(
        leading: Icon(Icons.swap_horiz, color: t.colorScheme.onTertiaryContainer),
        title: Text('Your driver is changing to ${r.to.name}', style: TextStyle(color: t.colorScheme.onTertiaryContainer)),
        subtitle: Text('Confirm the new driver, keep ${r.from.name}, or cancel free.',
            style: TextStyle(color: t.colorScheme.onTertiaryContainer)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push(mygigReassignPassengerPath(r.id)),
      ),
    );
  }
}

/// On the driver's home and Scheduled myGiG: rides other drivers want to
/// hand to them.
class MygigReassignInbox extends ConsumerWidget {
  const MygigReassignInbox({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(mygigReassignsMineProvider).value ?? const <MygigReassign>[];
    final incoming = mine.where((r) => r.me == 'to' && r.stage == MygigReassignStage.driver).toList();
    if (incoming.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Column(children: [
      for (final r in incoming)
        Card(
          key: ValueKey('mygig-reassign-incoming-${r.id}'),
          color: t.colorScheme.primaryContainer,
          child: ListTile(
            leading: Icon(Icons.swap_horiz, color: t.colorScheme.onPrimaryContainer),
            title: Text('${r.from.name} asks you to take over a ${r.kindName.toLowerCase()}',
                style: TextStyle(color: t.colorScheme.onPrimaryContainer)),
            subtitle: Text('${r.pickupName} to ${r.dropName} · ${mygigMoney(r.total)}',
                style: TextStyle(color: t.colorScheme.onPrimaryContainer)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(mygigReassignOfferPath(r.id)),
          ),
        ),
    ]);
  }
}
