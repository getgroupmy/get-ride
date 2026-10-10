import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth_utils.dart';
import '../../data/auth_repository.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';

/// Returning user: sign in with the 6-digit PIN.
class PinScreen extends ConsumerStatefulWidget {
  const PinScreen({super.key, required this.phone});
  final String phone;

  @override
  ConsumerState<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends ConsumerState<PinScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  /// The PIN can't be tried now: offer an SMS code instead.
  bool _locked = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit([String? _]) async {
    final pin = _pin.text;
    if (!isValidPin(pin) || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _locked = false;
    });
    final auth = ref.read(authRepositoryProvider);
    final result = await auth.signInWithPin(widget.phone, pin);
    if (!mounted) return;
    switch (result) {
      case PinSignInOk():
        break; // Router redirect takes over.
      case PinSignInNeedsOtp():
        // Right PIN, stale Auth password: confirm by SMS, then resync.
        try {
          await auth.sendOtp(widget.phone, createUser: false);
          if (!mounted) return;
          context.push(
            Uri(path: '/login/otp', queryParameters: {'phone': widget.phone, 'next': 'resync'}).toString(),
            extra: pin,
          );
        } catch (e) {
          if (mounted) showError(context, e);
        }
      case PinSignInError(:final message, :final locked):
        _pin.clear();
        setState(() {
          _error = message;
          _locked = locked;
        });
    }
    if (mounted) setState(() => _busy = false);
  }

  /// An SMS code, then a new PIN ([next] `set-pin`) or straight in past the
  /// lock with the PIN unchanged (`unlock`).
  Future<void> _smsCode(String next) async {
    setState(() => _busy = true);
    try {
      await ref.read(authRepositoryProvider).sendOtp(widget.phone, createUser: false);
      if (!mounted) return;
      context.push(Uri(path: '/login/otp', queryParameters: {'phone': widget.phone, 'next': next}).toString());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: SingleChildScrollView(
        child: ResponsiveCenter(
          maxWidth: 440,
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Welcome back', style: t.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text('Enter the 6-digit PIN for ${widget.phone}'),
            const SizedBox(height: 32),
            CodeField(controller: _pin, length: 6, obscure: true, onCompleted: _submit),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: t.colorScheme.error), textAlign: TextAlign.center),
            ],
            const SizedBox(height: 24),
            BusyButton.filled(onPressed: _busy ? null : _submit, child: const Text('Sign in')),
            const SizedBox(height: 8),
            if (_locked) ...[
              BusyButton.tonal(
                key: const ValueKey('pin-sms-unlock'),
                onPressed: _busy ? null : () => _smsCode('unlock'),
                child: const Text('Sign in with an SMS code instead'),
              ),
              const SizedBox(height: 8),
            ],
            BusyButton.text(
              onPressed: _busy ? null : () => _smsCode('set-pin'),
              child: const Text('Forgot PIN? Verify by SMS'),
            ),
          ]),
        ),
      ),
    );
  }
}
