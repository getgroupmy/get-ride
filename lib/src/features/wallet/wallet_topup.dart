// GET.wallet top-up through the payment gateway account Admin → Payment
// Gateways chose for top-ups (0252): pick an amount, pay on the provider's
// page inside the app, and wait here for the provider's answer. The server
// credits the wallet once, on the provider's confirmation; this sheet only
// shows it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/payments_repository.dart';
import '../../widgets/in_app_page.dart';
import '../../widgets/page_style_host.dart';

/// Opens a checkout and returns when the payer is back (openPaymentPage; a fake in tests).
typedef PaymentPageOpener = Future<void> Function(BuildContext context, PaymentCheckout checkout);

Future<void> _openCheckout(BuildContext context, PaymentCheckout c) =>
    openPaymentPage(context, url: c.url, form: c.form, closeOn: c.closeOn, title: 'Top up GET.wallet');

/// The amounts offered with one tap (RM).
const walletTopUpPresets = <double>[20, 50, 100, 200];

/// Shows the top-up sheet. True when the wallet was credited.
Future<bool?> showWalletTopUp(BuildContext context, {PaymentPageOpener? open}) => showAppSheet<bool>(
      id: 'wallet.top-up',
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      fitContent: true,
      builder: (_) => WalletTopUpSheet(open: open ?? _openCheckout),
    );

class WalletTopUpSheet extends ConsumerStatefulWidget {
  const WalletTopUpSheet({
    super.key,
    required this.open,
    this.pollEvery = const Duration(seconds: 3),
    this.giveUpAfter = const Duration(minutes: 15),
  });

  final PaymentPageOpener open;
  final Duration pollEvery;
  final Duration giveUpAfter;

  @override
  ConsumerState<WalletTopUpSheet> createState() => _WalletTopUpSheetState();
}

class _WalletTopUpSheetState extends ConsumerState<WalletTopUpSheet> {
  final _amount = TextEditingController(text: '50');
  String _key = newPaymentKey();
  bool _starting = false;
  String? _error;
  PaymentCheckout? _checkout;
  PaymentIntentState? _intent;
  Timer? _poll;
  StreamSubscription<PaymentIntentState>? _live;
  DateTime? _since;

  @override
  void dispose() {
    _poll?.cancel();
    _live?.cancel();
    _amount.dispose();
    super.dispose();
  }

  double? get _value => double.tryParse(_amount.text.trim().replaceAll(',', ''));

  void _take(PaymentIntentState s) {
    if (!mounted) return;
    setState(() => _intent = s);
    if (!s.pending) {
      _poll?.cancel();
      _live?.cancel();
    }
  }

  Future<void> _refresh() async {
    final id = _intent?.id;
    if (id == null || !(_intent?.pending ?? false)) return;
    if (_since != null && DateTime.now().difference(_since!) > widget.giveUpAfter) {
      _poll?.cancel();
      return;
    }
    try {
      _take(await ref.read(paymentsRepositoryProvider).status(id));
    } catch (_) {
      // Polled again shortly.
    }
  }

  void _wait(PaymentIntentState s) {
    _since = DateTime.now();
    _poll?.cancel();
    _poll = Timer.periodic(widget.pollEvery, (_) => unawaited(_refresh()));
    _live?.cancel();
    try {
      _live = ref.read(paymentsRepositoryProvider).watch(s.id).listen(_take, onError: (_) {});
    } catch (_) {}
  }

  Future<void> _pay(PaymentPurposeInfo info) async {
    final v = _value;
    if (v == null || v < info.min || v > info.max || (v * 100).roundToDouble() != v * 100) {
      setState(() => _error = 'Enter an amount from ${formatMoney(info.min, info.currency)} to '
          '${formatMoney(info.max, info.currency)}.');
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final c = await ref.read(paymentsRepositoryProvider).checkout('wallet_topup', v, _key);
      if (!mounted) return;
      setState(() {
        _checkout = c;
        _intent = c.intent;
        _starting = false;
      });
      if (!c.intent.pending) return;
      _wait(c.intent);
      if (c.url != null || c.form != null) {
        await widget.open(context, c);
        await _refresh();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = paymentErrorMessage(e);
        });
      }
    }
  }

  void _again() {
    _poll?.cancel();
    _live?.cancel();
    setState(() {
      _checkout = null;
      _intent = null;
      _error = null;
      _key = newPaymentKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final info = ref.watch(walletTopUpInfoProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Top up GET.wallet', style: t.textTheme.titleLarge),
          const SizedBox(height: 12),
          info.when(
            loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            error: (_, _) => const _Note(
              icon: Icons.cloud_off,
              text: 'Top-up couldn\'t be loaded. Check your connection and try again.',
            ),
            data: (i) => _intent == null ? _choose(i) : _waiting(i),
          ),
        ],
      ),
    );
  }

  Widget _choose(PaymentPurposeInfo info) {
    final t = Theme.of(context);
    if (!info.available) {
      return const _Note(
        key: ValueKey('topup-unavailable'),
        icon: Icons.info_outline,
        text: 'Top-up isn\'t available yet: no payment provider is set up. Contact support if you need funds added.',
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in walletTopUpPresets)
            if (p >= info.min && p <= info.max)
              ChoiceChip(
                key: ValueKey('topup-preset-${p.toInt()}'),
                label: Text(formatMoney(p, info.currency, 0)),
                selected: _value == p,
                onSelected: (_) => setState(() {
                  _amount.text = p.toStringAsFixed(0);
                  _error = null;
                }),
              ),
        ]),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('topup-amount'),
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(
            labelText: 'Amount',
            prefixText: '${info.currency} ',
            helperText: 'From ${formatMoney(info.min, info.currency)} to ${formatMoney(info.max, info.currency)}',
            errorText: _error,
          ),
          onChanged: (_) => setState(() => _error = null),
        ),
        if (info.testMode) ...[
          const SizedBox(height: 8),
          const _Note(
            key: ValueKey('topup-test-mode'),
            icon: Icons.science_outlined,
            text: 'Test mode: the provider takes test payments only, and nothing is added to your wallet.',
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('topup-pay'),
          onPressed: _starting ? null : () => _pay(info),
          icon: _starting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.lock_outline),
          label: Text(info.providerName == null ? 'Continue to payment' : 'Pay with ${info.providerName}'),
        ),
        const SizedBox(height: 8),
        Text(
          'You pay on the provider\'s secure page. GET.wallet is topped up once they confirm the payment.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _waiting(PaymentPurposeInfo info) {
    final s = _intent!;
    final t = Theme.of(context);
    final amount = formatMoney(s.amount, s.currency);
    final Widget status = switch (s.status) {
      'paid' when s.applied == 'test_mode' || s.testMode => _Note(
          key: const ValueKey('topup-paid-test'),
          icon: Icons.science_outlined,
          text: 'Test payment of $amount received. Nothing was added to your wallet (test mode).',
        ),
      'paid' => _Note(
          key: const ValueKey('topup-paid'),
          icon: Icons.check_circle,
          color: t.colorScheme.primary,
          text: '$amount added to GET.wallet.',
        ),
      'pending' => Column(
          key: const ValueKey('topup-waiting'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
            Text('Waiting for the provider to confirm $amount…', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('Reference ${s.reference}', style: t.textTheme.bodySmall),
          ],
        ),
      'cancelled' => _Note(key: const ValueKey('topup-cancelled'), icon: Icons.cancel_outlined, text: 'The payment was cancelled. Nothing was charged.'),
      _ => _Note(
          key: const ValueKey('topup-failed'),
          icon: Icons.error_outline,
          color: t.colorScheme.error,
          text: 'The payment did not go through. Nothing was added to your wallet.',
        ),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        status,
        const SizedBox(height: 16),
        if (s.pending && _checkout != null && (_checkout!.url != null || _checkout!.form != null))
          OutlinedButton.icon(
            key: const ValueKey('topup-reopen'),
            onPressed: () async {
              await widget.open(context, _checkout!);
              await _refresh();
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open the payment page again'),
          ),
        if (!s.pending && s.status != 'paid')
          OutlinedButton(key: const ValueKey('topup-again'), onPressed: _again, child: const Text('Try again')),
        if (!s.pending)
          FilledButton(
            key: const ValueKey('topup-done'),
            onPressed: () => Navigator.of(context).pop(s.status == 'paid' && s.applied == 'wallet_credited'),
            child: const Text('Done'),
          ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: t.colorScheme.surfaceContainerHighest,
      child: ListTile(
        leading: Icon(icon, color: color ?? t.colorScheme.onSurfaceVariant),
        title: Text(text, style: t.textTheme.bodyMedium),
      ),
    );
  }
}
