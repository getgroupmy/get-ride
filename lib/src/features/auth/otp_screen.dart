import '../../widgets/busy.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth_utils.dart';
import '../../data/auth_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

/// SMS code verification.
///
/// [next] is `set-pin` (new user / forgot PIN → choose a PIN), `resync`
/// (PIN was right but the Auth password drifted → re-derive it from [pin]) or
/// `unlock` (the PIN is locked → sign in by SMS, keeping the PIN).
class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.phone, required this.next, this.pin, this.createUser = false});
  final String phone;
  final String next;
  final String? pin;

  /// Whether a resend may create the account (a confirmed new sign-up only).
  final bool createUser;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  int _cooldown = 60;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_cooldown <= 1) t.cancel();
      if (mounted) setState(() => _cooldown--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify([String? _]) async {
    if (_code.text.length != 6 || _busy) return;
    setState(() => _busy = true);
    final auth = ref.read(authRepositoryProvider);
    final next = otpNextFor(widget.next, pin: widget.pin);
    AuthRepository.pinSetupPending = next == OtpNext.setPin;
    try {
      await auth.verifyOtp(widget.phone, _code.text);
      switch (next) {
        case OtpNext.resync:
          await auth.syncPinPassword(widget.pin!);
          if (mounted) context.go('/');
        case OtpNext.unlock:
          // Signed in past the PIN lock: the code proved the number, so the
          // lock goes and the PIN stays as it was.
          await auth.clearPinLock();
          if (mounted) context.go('/');
        case OtpNext.setPin:
          if (mounted) context.go('/login/set-pin');
      }
    } catch (e) {
      AuthRepository.pinSetupPending = false;
      _code.clear();
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      await ref.read(authRepositoryProvider).sendOtp(widget.phone, createUser: widget.createUser);
      _startCooldown();
      if (mounted) showInfo(context, 'Code sent');
    } catch (e) {
      if (mounted) showError(context, e);
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
            Text('Verify your number', style: t.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text('Enter the 6-digit code sent by SMS to ${widget.phone}'),
            const SizedBox(height: 32),
            CodeField(controller: _code, length: 6, onCompleted: _verify),
            const SizedBox(height: 24),
            BusyButton.filled(
              onPressed: _busy ? null : _verify,
              child: _busy
                  ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Verify'),
            ),
            const SizedBox(height: 8),
            BusyButton.text(
              onPressed: _cooldown > 0 ? null : _resend,
              child: Text(_cooldown > 0 ? 'Resend code in ${_cooldown}s' : 'Resend code'),
            ),
          ]),
        ),
      ),
    );
  }
}
