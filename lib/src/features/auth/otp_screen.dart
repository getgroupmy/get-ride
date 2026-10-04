import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/auth_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

/// SMS code verification.
///
/// [next] is `set-pin` (new user / forgot PIN → choose a PIN) or `resync`
/// (PIN was right but the Auth password drifted → re-derive it from [pin]).
class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.phone, required this.next, this.pin});
  final String phone;
  final String next;
  final String? pin;

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
    final setPin = widget.next != 'resync' || widget.pin == null;
    AuthRepository.pinSetupPending = setPin;
    try {
      await auth.verifyOtp(widget.phone, _code.text);
      if (!setPin) {
        await auth.syncPinPassword(widget.pin!);
        if (mounted) context.go('/');
      } else if (mounted) {
        context.go('/login/set-pin');
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
      await ref.read(authRepositoryProvider).sendOtp(widget.phone);
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
            FilledButton(
              onPressed: _busy ? null : _verify,
              child: _busy
                  ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Verify'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _cooldown > 0 ? null : _resend,
              child: Text(_cooldown > 0 ? 'Resend code in ${_cooldown}s' : 'Resend code'),
            ),
          ]),
        ),
      ),
    );
  }
}
