// Pair this phone (migration 0190): a code from Admin → SMS / WhatsApp →
// "Pair a gateway phone", typed once. The phone keeps the device key it
// gets back and never needs a sign-in.
import 'package:flutter/material.dart';

import 'core.dart';

/// Pairs with [code]; null when paired, else what to show.
typedef PairGateway = Future<String?> Function(String code);

class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.pair});

  final PairGateway pair;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  bool get _ready => isPairCode(_code.text);

  Future<void> _pair() async {
    if (!_ready || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final error = await widget.pair(_code.text);
      if (error != null && mounted) setState(() => _error = error);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.sim_card_outlined, size: 56, color: t.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'GET.ride Gateway',
                    textAlign: TextAlign.center,
                    style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This phone sends and receives GET.ride\'s SMS from its SIM. Pair it once: in the GET.ride app, '
                    'open Admin → SMS / WhatsApp → Pair a gateway phone, and type the code here. No sign-in is needed '
                    'after that.',
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    key: const ValueKey('pair-code'),
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 9,
                    textAlign: TextAlign.center,
                    style: t.textTheme.headlineSmall?.copyWith(letterSpacing: 4, fontWeight: FontWeight.w600),
                    decoration: const InputDecoration(
                      labelText: 'Pairing code',
                      hintText: 'XXXX-XXXX',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _pair(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      key: const ValueKey('pair-error'),
                      style: TextStyle(color: t.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const ValueKey('pair-submit'),
                    onPressed: _ready && !_busy ? _pair : null,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: _busy
                        ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Text('Pair this phone'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
