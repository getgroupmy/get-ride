// myGiG part C (0331): the passenger after the trip, in the app or on the
// trip link: the receipt, rating the driver (the link; the app has its own
// rating card), a tip (GET.wallet in the app; by link or noted as cash on
// the link), splitting the fare between 2 or 3 people while something is
// still to pay, asking for an e-Invoice (kept for get.ride's team: there is
// no e-Invoice connection to LHDN MyInvois yet, and the passenger is told
// so), "Book <driver> again" (a favourite driver in My Ride when
// registered), and for link passengers the app with the driver's code.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/mygig.dart' show mygigMoney;
import '../../core/mygig_extras.dart';
import '../../data/mygig_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

typedef MygigAfterKey = ({String? ride, String? token});

final mygigAfterProvider = FutureProvider.autoDispose.family<MygigAfter, MygigAfterKey>(
  (ref, k) => ref.watch(mygigRepositoryProvider).afterView(ride: k.ride, token: k.token),
);

/// The after-trip card: in the app ([rideId]) or on the trip link ([token]).
class MygigAfterTrip extends ConsumerWidget {
  const MygigAfterTrip({super.key, this.rideId, this.token}) : assert(rideId != null || token != null);
  final String? rideId;
  final String? token;

  MygigAfterKey get _key => (ride: token == null ? rideId : null, token: token);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(mygigAfterProvider(_key)).value;
    if (a == null) return const SizedBox.shrink();
    return MygigAfterBody(after: a, token: token, onChanged: () => ref.invalidate(mygigAfterProvider(_key)));
  }
}

class MygigAfterBody extends ConsumerStatefulWidget {
  const MygigAfterBody({super.key, required this.after, this.token, required this.onChanged});
  final MygigAfter after;
  final String? token;
  final VoidCallback onChanged;

  @override
  ConsumerState<MygigAfterBody> createState() => _MygigAfterBodyState();
}

class _MygigAfterBodyState extends ConsumerState<MygigAfterBody> {
  double _tip = 0;
  bool _otherTip = false;
  final _tipText = TextEditingController();
  int _split = 1;
  final _phones = [TextEditingController(), TextEditingController()];

  @override
  void dispose() {
    _tipText.dispose();
    for (final c in _phones) {
      c.dispose();
    }
    super.dispose();
  }

  MygigAfter get a => widget.after;
  bool get _link => widget.token != null;

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      widget.onChanged();
    }
  }

  Future<void> _openPay(String request) async {
    final url = await ref.read(mygigRepositoryProvider).payLinkUrl(request, token: widget.token);
    if (url != null) await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  double? get _tipAmount => _otherTip ? double.tryParse(_tipText.text.trim()) : _tip;

  Future<void> _sendTip(String how) => _run(() async {
    final amount = _tipAmount;
    final problem = mygigTipProblem(amount, a.tipMax);
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    final repo = ref.read(mygigRepositoryProvider);
    final v = await repo.afterTip(ride: _link ? null : a.rideId, token: widget.token, amount: amount!, how: how);
    if (how == 'link' && _link && v['partId'] is String) {
      await _openPay(v['partId'] as String);
    } else if (mounted) {
      await showAppNotice(
        id: 'notice.mygig',
        context: context,
        title: 'Thank you',
        message: how == 'cash'
            ? '${a.driver.name} is told you’ll tip ${mygigMoney(amount)} in cash.'
            : '${mygigMoney(amount)} went to ${a.driver.name} from your GET.wallet.',
      );
    }
  });

  Future<void> _sendSplit() => _run(() async {
    final phones = [for (var i = 0; i < _split - 1; i++) _phones[i].text.trim()];
    if (phones.any((p) => p.replaceAll(RegExp(r'\D'), '').length < 9)) {
      showInfo(context, 'Enter a phone number for each other person.');
      return;
    }
    final v = await ref.read(mygigRepositoryProvider)
        .split(ride: _link ? null : a.rideId, token: widget.token, parts: _split, phones: [for (final p in phones) '+60${p.replaceFirst(RegExp(r'^0+'), '')}']);
    final first = (v['parts'] is List && (v['parts'] as List).isNotEmpty) ? (v['parts'] as List).first : null;
    if (first is Map && first['id'] is String) await _openPay(first['id'] as String);
  });

  Future<void> _einvoice() async {
    final details = await showAppDialog<Map<String, dynamic>>(
      id: 'mygig.einvoice',
      context: context,
      builder: (_) => const MygigEinvoiceDialog(),
    );
    if (details == null || !mounted) return;
    await _run(() async {
      final v = await ref.read(mygigRepositoryProvider)
          .einvoice(ride: _link ? null : a.rideId, token: widget.token, details: details);
      if (mounted) {
        await showAppNotice(id: 'notice.mygig', context: context, title: 'e-Invoice requested',
            message: '${v['message'] ?? mygigEinvoiceSavedText}');
      }
    });
  }

  Future<void> _bookAgain() => _run(() async {
    final v = await ref.read(mygigRepositoryProvider).bookAgain(ride: _link ? null : a.rideId, token: widget.token);
    if (!mounted) return;
    if (v['saved'] == true) {
      await showAppNotice(
        id: 'notice.mygig',
        context: context,
        title: '${a.driver.name} saved',
        message: '${a.driver.name} is in your favourite drivers. Book them again from My Ride.',
      );
    } else {
      final offer = a.appOffer;
      await showAppNotice(
        id: 'notice.mygig',
        context: context,
        title: 'Book ${a.driver.name} in the app',
        message: offer?.body ?? 'Get the get.ride app to book ${a.driver.name} again.',
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tipped = a.tip;
    return Column(
      key: const ValueKey('mygig-after'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (a.completed) ...[
          Text('Thanks for riding with ${a.driver.name}', style: t.textTheme.titleLarge),
          const SizedBox(height: 8),
          Card(
            key: const ValueKey('mygig-receipt'),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                if (a.tolls > 0) _line('Tolls', a.tolls),
                if (a.other > 0) _line('Other charges', a.other),
                if (a.waiting > 0) _line('Waiting', a.waiting),
                _line('Total', a.total, bold: true),
                const SizedBox(height: 4),
                Text(
                  a.paid
                      ? 'Paid.'
                      : switch (a.pay) {
                          'cash' => 'Pay ${a.driver.name} in cash.',
                          'family' => 'Paid from your Family’s GET.wallet.',
                          'business' => 'Charged to the business account.',
                          _ => a.owed > 0 ? '${mygigMoney(a.owed)} still to pay.' : 'Paid.',
                        },
                  style: t.textTheme.bodySmall,
                ),
              ]),
            ),
          ),
        ],
        // Pay what is owed by link, split or not.
        if (_link && a.owed > 0 && a.parts.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: BusyButton.filled(
              key: const ValueKey('mygig-after-pay'),
              icon: const Icon(Icons.payments_outlined),
              onPressed: () => _run(() => _openPay(a.rideId)),
              child: Text('Pay ${mygigMoney(a.owed)} by card, FPX or DuitNow'),
            ),
          ),
        if (a.canSplit) ...[
          const SizedBox(height: 12),
          Text('Split the fare', style: t.textTheme.titleSmall),
          Wrap(spacing: 8, children: [
            for (var n = 1; n <= a.splitMax; n++)
              ChoiceChip(
                key: ValueKey('mygig-split-$n'),
                label: Text(n == 1 ? 'Just me' : '$n people'),
                selected: _split == n,
                onSelected: (_) => setState(() => _split = n),
              ),
          ]),
          if (_split > 1) ...[
            Text('Each pays about ${mygigMoney(mygigSplitShares(a.owed, _split).last)}. The others get a pay link by SMS.',
                style: t.textTheme.bodySmall),
            for (var i = 0; i < _split - 1; i++)
              TextField(
                key: ValueKey('mygig-split-phone-$i'),
                controller: _phones[i],
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(prefixText: '+60 ', labelText: 'Person ${i + 2}’s phone'),
              ),
            const SizedBox(height: 6),
            BusyButton.tonal(
              key: const ValueKey('mygig-split-send'),
              onPressed: _sendSplit,
              child: Text('Send links and pay my ${mygigMoney(mygigSplitShares(a.owed, _split).first)}'),
            ),
          ],
        ],
        if (a.parts.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final p in a.parts)
            ListTile(
              key: ValueKey('mygig-part-${p['no']}'),
              dense: true,
              leading: Icon(p['paid'] == true ? Icons.check_circle : Icons.schedule),
              title: Text('Share ${p['no']} of ${p['of']}: ${mygigMoney((p['amount'] as num).toDouble())}'),
              subtitle: Text(p['paid'] == true ? 'Paid' : p['phone'] != null ? 'Link sent to ${p['phone']}' : 'Yours'),
              trailing: p['paid'] != true && p['no'] == 1 && _link
                  ? TextButton(onPressed: () => _run(() => _openPay('${p['id']}')), child: const Text('Pay'))
                  : null,
            ),
        ],
        if (a.completed && a.canRate) ...[
          const SizedBox(height: 12),
          Text('Rate ${a.driver.name}', style: t.textTheme.titleSmall, textAlign: TextAlign.center),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                key: ValueKey('mygig-star-$i'),
                tooltip: '$i star${i == 1 ? '' : 's'}',
                icon: Icon(i <= (a.stars ?? 0) ? Icons.star : Icons.star_border, color: t.colorScheme.primary),
                onPressed: () => _run(() => ref.read(mygigRepositoryProvider).afterRate(widget.token!, i)),
              ),
          ]),
        ],
        if (a.completed && tipped != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tipped['method'] == 'cash'
                  ? 'You’ll tip ${mygigMoney((tipped['amount'] as num).toDouble())} in cash. Thank you!'
                  : 'You tipped ${mygigMoney((tipped['amount'] as num).toDouble())}. Thank you!',
              key: const ValueKey('mygig-tipped'),
              textAlign: TextAlign.center,
            ),
          )
        else if (a.completed && a.canTip) ...[
          const SizedBox(height: 12),
          Text('Add a tip', style: t.textTheme.titleSmall, textAlign: TextAlign.center),
          Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
            ChoiceChip(
              key: const ValueKey('mygig-tip-0'),
              label: const Text('No tip'),
              selected: !_otherTip && _tip == 0,
              onSelected: (_) => setState(() {
                _tip = 0;
                _otherTip = false;
              }),
            ),
            for (final p in a.tipPresets)
              ChoiceChip(
                key: ValueKey('mygig-tip-${p.toStringAsFixed(0)}'),
                label: Text(mygigMoney(p).replaceAll('.00', '')),
                selected: !_otherTip && _tip == p,
                onSelected: (_) => setState(() {
                  _tip = p;
                  _otherTip = false;
                }),
              ),
            ChoiceChip(
              key: const ValueKey('mygig-tip-other'),
              label: const Text('Other'),
              selected: _otherTip,
              onSelected: (_) => setState(() => _otherTip = true),
            ),
          ]),
          if (_otherTip)
            TextField(
              key: const ValueKey('mygig-tip-amount'),
              controller: _tipText,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: InputDecoration(prefixText: 'RM ', labelText: 'Tip (up to ${mygigMoney(a.tipMax)})'),
              onChanged: (_) => setState(() {}),
            ),
          if ((_tipAmount ?? 0) > 0) ...[
            const SizedBox(height: 6),
            if (_link) ...[
              BusyButton.tonal(
                key: const ValueKey('mygig-tip-link'),
                onPressed: () => _sendTip('link'),
                child: Text('Tip ${mygigMoney(_tipAmount!)} by card, FPX or DuitNow'),
              ),
              BusyButton.text(
                key: const ValueKey('mygig-tip-cash'),
                onPressed: () => _sendTip('cash'),
                child: const Text('I’ll tip in cash'),
              ),
            ] else
              BusyButton.tonal(
                key: const ValueKey('mygig-tip-wallet'),
                onPressed: () => _sendTip('wallet'),
                child: Text('Tip ${mygigMoney(_tipAmount!)} from GET.wallet'),
              ),
          ],
        ],
        if (a.completed) ...[
          const SizedBox(height: 12),
          if (a.einvoice != null)
            ListTile(
              key: const ValueKey('mygig-einvoice-done'),
              leading: const Icon(Icons.receipt_long),
              title: Text(a.einvoice!['state'] == 'sent' ? 'e-Invoice sent' : 'e-Invoice requested'),
              subtitle: Text(a.einvoice!['state'] == 'sent'
                  ? 'Emailed to ${a.einvoice!['email']}.'
                  : 'get.ride sends it to LHDN MyInvois and emails it to ${a.einvoice!['email']} once validated.'),
            )
          else if (a.canEinvoice)
            OutlinedButton.icon(
              key: const ValueKey('mygig-einvoice'),
              icon: const Icon(Icons.receipt_long),
              onPressed: _einvoice,
              label: const Text('Request e-Invoice'),
            ),
          if (a.canBookAgain)
            BusyButton.outlined(
              key: const ValueKey('mygig-book-again'),
              icon: const Icon(Icons.event_repeat),
              onPressed: _bookAgain,
              child: Text(a.bookedAgain && a.registered ? '${a.driver.name} is in My Ride' : 'Book ${a.driver.name} again'),
            ),
          if (a.appOffer case final offer? when offer.enabled)
            Card(
              key: const ValueKey('mygig-app-offer'),
              color: t.colorScheme.secondaryContainer,
              child: ListTile(
                leading: Icon(Icons.redeem, color: t.colorScheme.onSecondaryContainer),
                title: Text(offer.title, style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
                subtitle: Text(offer.body, style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
              ),
            ),
        ],
      ],
    );
  }

  Widget _line(String label, double v, {bool bold = false}) {
    final style = bold ? Theme.of(context).textTheme.titleMedium : null;
    return Row(children: [
      Expanded(child: Text(label, style: style)),
      Text(mygigMoney(v), style: style),
    ]);
  }
}

/// The e-Invoice details: the name, an email, and a TIN or an ID.
class MygigEinvoiceDialog extends StatefulWidget {
  const MygigEinvoiceDialog({super.key});

  @override
  State<MygigEinvoiceDialog> createState() => _MygigEinvoiceDialogState();
}

class _MygigEinvoiceDialogState extends State<MygigEinvoiceDialog> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _tin = TextEditingController();
  final _idNo = TextEditingController();
  String _idType = 'nric';
  String? _problem;

  @override
  void dispose() {
    for (final c in [_name, _email, _tin, _idNo]) {
      c.dispose();
    }
    super.dispose();
  }

  void _send() {
    final problem = mygigEinvoiceProblem(name: _name.text, email: _email.text, tin: _tin.text,
        idType: _idNo.text.trim().isEmpty ? null : _idType, idNo: _idNo.text);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.pop(context, {
      'name': _name.text.trim(),
      'email': _email.text.trim(),
      if (_tin.text.trim().isNotEmpty) 'tin': _tin.text.trim(),
      if (_idNo.text.trim().isNotEmpty) ...{'idType': _idType, 'idNo': _idNo.text.trim()},
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      title: const Text('Request e-Invoice'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(key: const ValueKey('mygig-einvoice-name'), controller: _name,
              decoration: const InputDecoration(labelText: 'Name on the invoice')),
          TextField(key: const ValueKey('mygig-einvoice-email'), controller: _email, keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email')),
          TextField(key: const ValueKey('mygig-einvoice-tin'), controller: _tin, textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'TIN (tax number)', helperText: 'Or give your ID below')),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (k, l) in mygigEinvoiceIdTypes)
              ChoiceChip(label: Text(l), selected: _idType == k, onSelected: (_) => setState(() => _idType = k)),
          ]),
          TextField(key: const ValueKey('mygig-einvoice-id'), controller: _idNo,
              decoration: const InputDecoration(labelText: 'ID or passport number')),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_problem!, style: TextStyle(color: t.colorScheme.error)),
            ),
          const SizedBox(height: 8),
          Text('get.ride sends it to LHDN MyInvois and emails you the e-Invoice once it is validated.',
              style: t.textTheme.bodySmall),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('mygig-einvoice-send'), onPressed: _send, child: const Text('Request')),
      ],
    );
  }
}

/// A share of a fare, on the link texted to another person (no sign-in).
class MygigPayPartScreen extends ConsumerStatefulWidget {
  const MygigPayPartScreen({super.key, required this.token});
  final String token;

  @override
  ConsumerState<MygigPayPartScreen> createState() => _MygigPayPartScreenState();
}

class _MygigPayPartScreenState extends ConsumerState<MygigPayPartScreen> {
  late Future<Map<String, dynamic>> _view = ref.read(mygigRepositoryProvider).payPartView(widget.token);

  Future<void> _pay(String id) async {
    try {
      final url = await ref.read(mygigRepositoryProvider).payLinkUrl(id, token: widget.token);
      if (url != null) await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      setState(() => _view = ref.read(mygigRepositoryProvider).payPartView(widget.token));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Your share'), automaticallyImplyLeading: false),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _view,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(errorText(snap.error!))));
          }
          final v = snap.data;
          if (v == null) return const Center(child: CircularProgressIndicator());
          final driver = MygigDriverCard(v['driver'] is Map ? Map<String, dynamic>.from(v['driver'] as Map) : const {});
          final amount = v['amount'] is num ? (v['amount'] as num).toDouble() : 0.0;
          final offer = v['appOffer'] is Map ? MygigAppOffer(Map<String, dynamic>.from(v['appOffer'] as Map)) : null;
          return ResponsiveCenter(
            maxWidth: 560,
            child: ListView(
              key: const ValueKey('mygig-pay-part'),
              padding: const EdgeInsets.all(20),
              children: [
                Text('Your share of a ride with ${driver.name}', style: t.textTheme.titleLarge),
                const SizedBox(height: 6),
                Text('${v['pickup'] ?? ''} to ${v['drop'] ?? ''}'),
                const SizedBox(height: 12),
                Text(mygigMoney(amount), style: t.textTheme.headlineMedium, key: const ValueKey('mygig-pay-part-amount')),
                const SizedBox(height: 12),
                if (v['paid'] == true)
                  const Text('Paid. Thank you!')
                else if (v['cancelled'] == true)
                  const Text('This share isn’t needed any more: the fare is paid.')
                else
                  BusyButton.filled(
                    key: const ValueKey('mygig-pay-part-pay'),
                    icon: const Icon(Icons.payments_outlined),
                    onPressed: () => _pay('${v['id']}'),
                    child: Text('Pay ${mygigMoney(amount)} by card, FPX or DuitNow'),
                  ),
                if (offer != null && offer.enabled) ...[
                  const SizedBox(height: 20),
                  Card(
                    color: t.colorScheme.secondaryContainer,
                    child: ListTile(
                      leading: Icon(Icons.redeem, color: t.colorScheme.onSecondaryContainer),
                      title: Text(offer.title, style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
                      subtitle: Text(offer.body, style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
