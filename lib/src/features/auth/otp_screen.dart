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
/// Whether the sign-in pages are short with the keyboard up (a phone on its
/// side): under 300 between the top and the keyboard.
bool otpShortScreen(MediaQueryData mq) => mq.size.height - mq.viewInsets.bottom < 300;

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
    // Read before signing in: the router may take it on the way.
    final landing = signInLanding();
    AuthRepository.pinSetupPending = next == OtpNext.setPin;
    try {
      await auth.verifyOtp(widget.phone, _code.text);
      switch (next) {
        case OtpNext.resync:
          // Confirmed by SMS: the PIN-derived password, if any, goes too.
          await auth.retireDerivedPassword();
          ResyncPin.value = null;
          if (mounted) context.go(landing);
        case OtpNext.unlock:
          // Signed in past the PIN lock: the code proved the number, so the
          // lock goes and the PIN stays as it was.
          await auth.clearPinLock();
          if (mounted) context.go(landing);
        case OtpNext.setPin:
          if (mounted) context.go(signInAddress('/login/set-pin'));
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
    // Short over the keyboard (a phone on its side): the title moves into a
    // slimmer back bar, so it is not scrolled away under it as the code
    // field comes into view.
    final mq = MediaQuery.of(context);
    final short = otpShortScreen(mq);
    const title = 'Verify your number';
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: short ? 44 : null,
        title: short ? Text(title, key: const ValueKey('otp-title'), style: t.textTheme.titleLarge) : null,
      ),
      body: SingleChildScrollView(
        child: ResponsiveCenter(
          maxWidth: 440,
          padding: short ? const EdgeInsets.fromLTRB(24, 4, 24, 16) : const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!short) ...[
              Text(title, key: const ValueKey('otp-title'), style: t.textTheme.headlineSmall),
              const SizedBox(height: 4),
            ],
            Text(
              widget.phone.isEmpty
                  ? 'Enter the 6-digit code sent by SMS to your number'
                  : 'Enter the 6-digit code sent by SMS to ${widget.phone}',
            ),
            SizedBox(height: short ? 12 : 32),
            CodeField(controller: _code, length: 6, onCompleted: _verify),
            const SizedBox(height: 24),
            // Usable once all six digits are in.
            ValueListenableBuilder(
              valueListenable: _code,
              builder: (_, v, _) => BusyButton.filled(
                key: const ValueKey('otp-verify'),
                onPressed: _busy || v.text.length != 6 ? null : _verify,
                child: _busy
                    ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Verify'),
              ),
            ),
            const SizedBox(height: 8),
            // A button, not a line of text: an icon and its own width.
            Center(
              child: BusyButton.text(
                key: const ValueKey('otp-resend'),
                onPressed: _cooldown > 0 ? null : _resend,
                icon: const Icon(Icons.refresh),
                child: Text(_cooldown > 0 ? 'Resend code in ${_cooldown}s' : 'Resend code'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
