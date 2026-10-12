import '../../widgets/busy.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../admin/screens/commerce/get_coin.dart';
import '../../core/format.dart';
import '../../core/wallet_qr.dart';
import '../../data/coin_trade_repository.dart';
import '../../data/wallet_pay_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/image_share.dart';
import 'wallet_screen.dart';

/// The account's own code (Expo `wallet-receive.tsx`, and `wallet-coin-qr.tsx`
/// when [coin] is set). Whoever scans it in GET.ride sends GET.coin to this
/// account. A fixed amount can be added; that code is shown for
/// [walletAmountQrTtl] and then has to be regenerated.
class ReceiveQrScreen extends ConsumerStatefulWidget {
  const ReceiveQrScreen({super.key, this.coin = false});

  final bool coin;

  @override
  ConsumerState<ReceiveQrScreen> createState() => _ReceiveQrScreenState();
}

class _ReceiveQrScreenState extends ConsumerState<ReceiveQrScreen> {
  double? _amount;
  Timer? _timer;
  var _left = walletAmountQrTtl;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _setAmount(double? amount) {
    _timer?.cancel();
    setState(() {
      _amount = amount;
      _left = walletAmountQrTtl;
    });
    if (amount == null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _left -= const Duration(seconds: 1));
      if (_left <= Duration.zero) t.cancel();
    });
  }

  Future<void> _askAmount() async {
    final v = await showDialog<double>(
      context: context,
      builder: (_) => _AmountDialog(initial: _amount),
    );
    if (v != null) _setAmount(v);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final userId = ref.watch(currentUserIdProvider);
    final name = ref.watch(profileProvider).value?.name;
    if (userId == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.coin ? 'GET.coin QR' : 'Receive')),
        body: const EmptyState(icon: Icons.lock_outline, title: 'Sign in to show your code'),
      );
    }
    final expired = _amount != null && _left <= Duration.zero;
    final payload = walletQrPayload(userId, amount: _amount);
    final quote = widget.coin ? ref.watch(coinTradeQuoteProvider).value : null;
    final qrColor = widget.coin ? Colors.black : const Color(0xFFED2E67);

    return Scaffold(
      appBar: AppBar(title: Text(widget.coin ? 'GET.coin QR' : 'Receive')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.coin
                      ? 'Scan to send GET.coin to ${(name ?? 'me').toUpperCase()}'
                      : (name ?? 'My code').toUpperCase(),
                  textAlign: TextAlign.center,
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      // QR codes stay dark-on-white in both themes so every scanner reads them.
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: widget.coin ? const Color(0xFFF5B301) : const Color(0xFFED2E67),
                        width: 4,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        QrImageView(
                          key: const ValueKey('wallet-qr'),
                          data: payload,
                          size: 240,
                          backgroundColor: Colors.white,
                          errorCorrectionLevel: QrErrorCorrectLevel.M,
                          eyeStyle: QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: qrColor,
                          ),
                          dataModuleStyle: QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: qrColor,
                          ),
                        ),
                        if (expired)
                          Container(
                            width: 240,
                            height: 240,
                            color: Colors.white.withValues(alpha: 0.92),
                            alignment: Alignment.center,
                            child: const Text(
                              'QR code expired',
                              style: TextStyle(color: Colors.black, fontWeight: FontWeight.w700),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_amount != null) ...[
                  Text(formatMoney(_amount), textAlign: TextAlign.center, style: t.textTheme.headlineSmall),
                  Text(
                    expired ? 'This code has expired.' : 'Valid for ${_left.inSeconds}s',
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodySmall,
                  ),
                ],
                if (widget.coin && quote != null)
                  Text(
                    'GET.coin ${formatCoins(quote.coinBalance)}'
                    '${quote.settings.coinsPerCurrency > 0 ? ' ≈ ${formatMoney(quote.coinBalance / quote.settings.coinsPerCurrency)}' : ''}',
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    title: Text(widget.coin ? 'Wallet ID' : 'Account no.'),
                    subtitle: SelectableText(widget.coin ? userId : walletAccountNumber(userId)),
                    trailing: IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: widget.coin ? userId : walletAccountNumber(userId)),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Anyone who scans this in GET.ride sends you GET.coin. You accept each transfer before it arrives.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                if (!widget.coin) ...[
                  FilledButton.icon(
                    key: const ValueKey('qr-amount'),
                    onPressed: _askAmount,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(_amount == null ? 'Enter specific amount' : 'Enter new amount'),
                  ),
                  if (_amount != null) ...[
                    const SizedBox(height: 8),
                    if (expired) OutlinedButton(onPressed: () => _setAmount(_amount), child: const Text('Regenerate')),
                    TextButton(onPressed: () => _setAmount(null), child: const Text('Cancel amount')),
                  ],
                ],
                const SizedBox(height: 8),
                // The code as a picture on white, so it scans from a chat in dark mode too.
                ShareSaveImageButtons(
                  keyPrefix: 'wallet-qr',
                  enabled: !expired,
                  image: (origin) async => ShareableImage(
                    png: await ref.read(qrPngRendererProvider)(
                      payload,
                      color: qrColor,
                      caption: walletQrCaption(coin: widget.coin, userId: userId, name: name),
                    ),
                    fileName: walletQrFileName(coin: widget.coin, amount: _amount),
                    text: walletQrShareText(
                      coin: widget.coin,
                      userId: userId,
                      name: name,
                      amountLabel: _amount == null ? null : formatMoney(_amount),
                    ),
                    subject: widget.coin ? 'My GET.coin code' : 'My GET.ride pay code',
                    origin: origin,
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

class _AmountDialog extends StatefulWidget {
  const _AmountDialog({this.initial});
  final double? initial;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final _c = TextEditingController(text: widget.initial?.toStringAsFixed(2) ?? '');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter specific amount'),
      content: TextField(
        controller: _c,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: const InputDecoration(prefixText: 'RM ', labelText: 'Amount'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
          onPressed: () {
            final v = double.tryParse(_c.text.trim());
            if (v != null && v > 0 && v <= 100000) Navigator.pop(context, (v * 100).roundToDouble() / 100);
          },
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

/// Turns the scanner's flashlight on or off. Overridden in tests.
final scannerTorchProvider = Provider<Future<void> Function(MobileScannerController controller)>(
  (ref) => (controller) => controller.toggleTorch(),
);

/// Whether a torch button can do anything: not once a running camera has
/// said it has no flashlight (a laptop, most browsers).
bool scannerTorchAvailable(MobileScannerState s) =>
    !(s.isInitialized && s.isRunning && s.torchState == TorchState.unavailable);

/// The Scan & Pay help: what to point at and what happens next.
Future<void> showScanPayHelp(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (c) {
    final t = Theme.of(c);
    return SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('scan-help-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('How to pay', style: t.textTheme.titleLarge),
            const SizedBox(height: 12),
            for (final (i, step) in scanPayHowToSteps.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: t.colorScheme.primaryContainer,
                      foregroundColor: t.colorScheme.onPrimaryContainer,
                      child: Text('${i + 1}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(step, style: t.textTheme.bodyMedium)),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Got it')),
          ],
        ),
      ),
    );
  },
);

/// Scan & Pay (Expo `wallet-scan.tsx`). A GET account's code opens the
/// GET.coin send flow addressed to that account; any other code is paid out
/// of GET.wallet through `wallet_pay`, optionally part-paid with GET.coin.
class ScanPayScreen extends ConsumerStatefulWidget {
  const ScanPayScreen({super.key});

  @override
  ConsumerState<ScanPayScreen> createState() => _ScanPayScreenState();
}

class _ScanPayScreenState extends ConsumerState<ScanPayScreen> {
  final _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final _manual = TextEditingController();
  var _handled = false;
  MerchantQr? _merchant;

  @override
  void dispose() {
    _scanner.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _handle(String raw) async {
    if (_handled) return;
    final qr = parseWalletQr(raw);
    if (qr == null) return;
    _handled = true;
    HapticFeedback.mediumImpact();
    switch (qr) {
      case GetAccountQr(:final userId, :final amount):
        if (userId == ref.read(currentUserIdProvider)) {
          _handled = false;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That is your own code.')));
          return;
        }
        await _scanner.stop();
        if (!mounted) return;
        final q = {'to': userId, if (amount != null) 'amt': amount.toStringAsFixed(2)};
        context.pushReplacement(Uri(path: '/wallet/trade', queryParameters: q).toString());
      case MerchantQr():
        await _scanner.stop();
        if (mounted) setState(() => _merchant = qr);
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await ref.read(scannerTorchProvider)(_scanner);
    } catch (_) {
      if (mounted) showInfo(context, "The flashlight isn't available right now.");
    }
  }

  Future<void> _scanAgain() async {
    setState(() => _merchant = null);
    _manual.clear();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _handled = false;
    await _scanner.start();
  }

  @override
  Widget build(BuildContext context) {
    final merchant = _merchant;
    if (merchant != null) {
      return MerchantPayView(qr: merchant, onScanAgain: _scanAgain);
    }
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan & Pay'),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _scanner,
            builder: (_, state, _) {
              final on = state.torchState == TorchState.on;
              final available = scannerTorchAvailable(state);
              return IconButton(
                key: const ValueKey('scan-torch'),
                tooltip: !available
                    ? 'No flashlight on this device'
                    : on
                    ? 'Turn flashlight off'
                    : 'Turn flashlight on',
                isSelected: on,
                icon: const Icon(Icons.flashlight_off_outlined),
                selectedIcon: const Icon(Icons.flashlight_on),
                onPressed: available ? _toggleTorch : null,
              );
            },
          ),
          IconButton(
            key: const ValueKey('scan-help'),
            tooltip: 'How to pay',
            icon: const Icon(Icons.help_outline),
            onPressed: () => showScanPayHelp(context),
          ),
          TextButton.icon(
            onPressed: () => context.push('/wallet/receive'),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('My code'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: MobileScanner(
                      controller: _scanner,
                      onDetect: (c) {
                        for (final b in c.barcodes) {
                          final v = b.rawValue;
                          if (v != null && v.trim().isNotEmpty) {
                            _handle(v);
                            break;
                          }
                        }
                      },
                      errorBuilder: (_, e) => ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              e.errorCode == MobileScannerErrorCode.permissionDenied
                                  ? 'Camera access is off. Allow it in your settings to scan, or enter the code below.'
                                  : 'The camera is not available here. Enter the code below instead.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Point the camera at a GET.ride or merchant QR code.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('scan-manual'),
                  controller: _manual,
                  decoration: InputDecoration(
                    labelText: 'Or paste a code',
                    prefixIcon: const Icon(Icons.keyboard_outlined),
                    suffixIcon: BusyIconButton(
                      tooltip: 'Continue',
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: () => _handle(_manual.text),
                    ),
                  ),
                  onSubmitted: _handle,
                ),
                const SizedBox(height: 16),
                AsyncView(
                  value: ref.watch(walletBalancesProvider),
                  onRetry: () => ref.invalidate(walletBalancesProvider),
                  data: (bs) {
                    final w = bs.where((b) => b.walletType == 'get_wallet').firstOrNull;
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.account_balance_wallet_outlined),
                        title: const Text('GET.wallet'),
                        trailing: Text(formatMoney(w?.balance ?? 0), style: t.textTheme.titleMedium),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The pay page for a merchant code: amount, optional GET.coin, confirm,
/// receipt.
class MerchantPayView extends ConsumerStatefulWidget {
  const MerchantPayView({super.key, required this.qr, required this.onScanAgain});

  final MerchantQr qr;
  final VoidCallback onScanAgain;

  @override
  ConsumerState<MerchantPayView> createState() => _MerchantPayViewState();
}

class _MerchantPayViewState extends ConsumerState<MerchantPayView> {
  final _amount = TextEditingController();
  var _useCoins = false;
  var _busy = false;
  String? _error;
  WalletPayResult? _paid;
  double _paidAmount = 0;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double get _value => ((double.tryParse(_amount.text.trim()) ?? 0) * 100).roundToDouble() / 100;

  Future<void> _pay(CoinSplit? split) async {
    final amount = _value;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Pay ${formatMoney(amount)}?'),
        content: Text(
          [
            'To ${widget.qr.label}',
            if (split != null && split.coinsUsed > 0)
              '${formatCoins(split.coinsUsed)} from GET.coin, ${formatMoney(split.walletShare)} from GET.wallet.'
            else
              'From GET.wallet.',
          ].join('\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Pay'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(walletPayRepositoryProvider)
          .pay(amount, note: 'QR payment — ${widget.qr.label}', redeemCoins: split != null && split.coinsUsed > 0);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _paid = r;
        _paidAmount = amount;
      });
      ref.invalidate(walletBalancesProvider);
      ref.invalidate(walletTxProvider);
      ref.invalidate(coinTradeQuoteProvider);
    } catch (e) {
      if (mounted) setState(() => _error = walletPayErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paid = _paid;
    return Scaffold(
      appBar: AppBar(
        title: Text(paid == null ? 'Pay' : 'Payment successful'),
        leading: paid == null ? BackButton(onPressed: _busy ? null : widget.onScanAgain) : null,
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 480,
            child: paid == null
                ? AsyncView(
                    value: ref.watch(coinTradeQuoteProvider),
                    onRetry: () => ref.invalidate(coinTradeQuoteProvider),
                    data: _form,
                  )
                : _receipt(paid),
          ),
        ],
      ),
    );
  }

  Widget _form(CoinTradeQuote q) {
    final t = Theme.of(context);
    final rate = q.settings.coinsPerCurrency;
    final canCoins = q.coinBalance > 0 && rate > 0;
    final amount = _value;
    final split = canCoins && _useCoins ? computeCoinSplit(amount, q.coinBalance, rate) : null;
    final problem = walletPayProblem(amount: amount, walletBalance: q.walletBalance, split: split);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.storefront_outlined),
            title: const Text('Paying'),
            subtitle: Text(widget.qr.label),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('pay-amount'),
          controller: _amount,
          enabled: !_busy,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(
            labelText: 'Amount',
            prefixText: 'RM ',
            helperText: 'GET.wallet ${formatMoney(q.walletBalance)}',
            errorText: amount > 0 ? problem : null,
          ),
          style: t.textTheme.headlineSmall,
          onChanged: (_) => setState(() => _error = null),
        ),
        if (canCoins) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('pay-coins'),
            contentPadding: EdgeInsets.zero,
            value: _useCoins,
            onChanged: _busy ? null : (v) => setState(() => _useCoins = v),
            title: const Text('Use GET.coin'),
            subtitle: Text(
              split != null && amount > 0
                  ? '${formatCoins(split.coinsUsed)} covers ${formatMoney(split.coinValue)}; '
                        '${formatMoney(split.walletShare)} from GET.wallet'
                  : 'You have ${formatCoins(q.coinBalance)}',
            ),
          ),
        ],
        if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: TextStyle(color: t.colorScheme.error))],
        const SizedBox(height: 16),
        BusyButton.filled(
          key: const ValueKey('pay-confirm'),
          onPressed: _busy || problem != null ? null : () => _pay(split),
          child: Text(amount > 0 ? 'Pay ${formatMoney(amount)}' : 'Pay'),
        ),
      ],
    );
  }

  Widget _receipt(WalletPayResult r) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.check_circle, color: Colors.green, size: 72),
        const SizedBox(height: 12),
        Text('Payment Successful', textAlign: TextAlign.center, style: t.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(formatMoney(_paidAmount), textAlign: TextAlign.center, style: t.textTheme.headlineMedium),
        Text(widget.qr.label, textAlign: TextAlign.center, style: t.textTheme.bodySmall),
        if (r.coinsUsed > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${formatCoins(r.coinsUsed)} (${formatMoney(r.coinValue)}) paid with GET.coin',
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(onPressed: () => context.pop(), child: const Text('Done')),
      ],
    );
  }
}
