import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth_utils.dart';
import '../../core/referral.dart';
import '../../data/auth_repository.dart';
import '../../data/referral_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

/// Choose (or change) the 6-digit sign-in PIN. Requires an active session.
class SetPinScreen extends ConsumerStatefulWidget {
  const SetPinScreen({super.key, this.changing = false});

  /// True when an already signed-in user is changing their PIN (closing
  /// returns to settings instead of abandoning the sign-in).
  final bool changing;

  @override
  ConsumerState<SetPinScreen> createState() => _SetPinScreenState();
}

class _SetPinScreenState extends ConsumerState<SetPinScreen> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  late final _referral = TextEditingController(text: PendingReferral.code ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    _name.dispose();
    _referral.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!isValidPin(_pin.text)) return showInfo(context, 'PIN must be 6 digits.');
    if (_pin.text != _confirm.text) return showInfo(context, 'PINs do not match.');
    final referral = widget.changing ? '' : normalizeReferralCode(_referral.text);
    if (referral.isNotEmpty && !isPlausibleReferralCode(referral)) {
      return showInfo(context, "That referral code wasn't found.");
    }
    setState(() => _busy = true);
    try {
      await ref.read(authRepositoryProvider).setPin(_pin.text);
      final name = _name.text.trim();
      if (name.isNotEmpty) await ref.read(accountRepositoryProvider).updateProfile(name: name);
      AuthRepository.pinSetupPending = false;
      ref.invalidate(profileProvider);
      final referralNotice = referral.isEmpty ? null : await _applyReferral(referral);
      if (mounted) context.go(widget.changing ? '/account/settings' : '/');
      if (widget.changing && mounted) showInfo(context, 'PIN updated');
      if (referralNotice != null && mounted) showInfo(context, referralNotice);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Applies the referral code after sign-up. Never blocks it: a refusal or
  /// a network failure only changes the notice shown.
  Future<String?> _applyReferral(String code) async {
    try {
      final r = await ref.read(referralRepositoryProvider).apply(code);
      PendingReferral.code = null;
      return applyReferralMessage(r);
    } catch (_) {
      return "The referral code couldn't be applied.";
    }
  }

  Future<void> _cancel() async {
    AuthRepository.pinSetupPending = false;
    if (widget.changing) {
      context.go('/account/settings');
    } else {
      await ref.read(authRepositoryProvider).signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final needsName = ref.watch(profileProvider).value?.name?.trim().isNotEmpty != true;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.changing ? 'Change PIN' : 'Set your PIN'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: _busy ? null : _cancel),
      ),
      body: SingleChildScrollView(
        child: ResponsiveCenter(
          maxWidth: 440,
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Use this 6-digit PIN to sign in on any device — no SMS needed.',
                style: t.textTheme.bodyLarge),
            const SizedBox(height: 24),
            if (needsName) ...[
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
              const SizedBox(height: 16),
            ],
            CodeField(controller: _pin, length: 6, obscure: true, label: 'New PIN'),
            const SizedBox(height: 16),
            CodeField(controller: _confirm, length: 6, obscure: true, autofocus: false, label: 'Confirm PIN'),
            if (!widget.changing) ...[
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('signup-referral'),
                controller: _referral,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Referral code (optional)',
                  helperText: 'Invited by a friend? You both earn bonus GET.coin.',
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _save, child: const Text('Save PIN')),
          ]),
        ),
      ),
    );
  }
}
