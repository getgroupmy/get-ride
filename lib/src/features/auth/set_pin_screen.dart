import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth_utils.dart';
import '../../core/referral.dart';
import '../../data/auth_repository.dart';
import '../../data/referral_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../data/coin_trade_repository.dart';
import 'signup_photo_screen.dart' show signupLanding;

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
  final _current = TextEditingController();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  late final _referral = TextEditingController(text: PendingReferral.code ?? '');
  bool _busy = false;

  /// Expo `role-selection`: where a brand-new account lands. Either mode
  /// stays a tap away later.
  String _role = 'passenger';

  @override
  void dispose() {
    _current.dispose();
    _pin.dispose();
    _confirm.dispose();
    _name.dispose();
    _referral.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (widget.changing && !isValidPin(_current.text)) return showInfo(context, 'Enter your current 6-digit PIN.');
    if (!isValidPin(_pin.text)) return showInfo(context, 'PIN must be 6 digits.');
    if (_pin.text != _confirm.text) return showInfo(context, 'PINs do not match.');
    if (widget.changing && _pin.text == _current.text) {
      return showInfo(context, 'New PIN must be different from current PIN.');
    }
    final referral = widget.changing ? '' : normalizeReferralCode(_referral.text);
    if (referral.isNotEmpty && !isPlausibleReferralCode(referral)) {
      return showInfo(context, "That referral code wasn't found.");
    }
    final before = ref.read(profileProvider).value;
    final isNew = !widget.changing && before?.name?.trim().isNotEmpty != true;
    final hasPhoto = before?.avatarUrl != null;
    setState(() => _busy = true);
    try {
      if (widget.changing) {
        // Someone holding an unlocked phone must not be able to take the
        // account's PIN without knowing it.
        final problem = await ref.read(authRepositoryProvider).checkCurrentPin(_current.text);
        if (problem != null) {
          _current.clear();
          if (mounted) showInfo(context, problem);
          return;
        }
      }
      await ref.read(authRepositoryProvider).setPin(_pin.text);
      final name = _name.text.trim();
      if (name.isNotEmpty) await ref.read(accountRepositoryProvider).updateProfile(name: name);
      AuthRepository.pinSetupPending = false;
      ref.invalidate(profileProvider);
      final referralNotice = referral.isEmpty ? null : await _applyReferral(referral);
      if (mounted) context.go(_nextRoute(isNew: isNew, hasPhoto: hasPhoto));
      if (widget.changing && mounted) showInfo(context, 'PIN updated');
      if (referralNotice != null && mounted) showInfo(context, referralNotice);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Settings when changing; a new account gets the optional photo step
  /// (unless it already has one) and then its chosen mode.
  String _nextRoute({required bool isNew, required bool hasPhoto}) {
    if (widget.changing) return '/account/settings';
    if (!isNew) return '/';
    final landing = signupLanding(_role);
    return hasPhoto ? landing : Uri(path: '/signup/photo', queryParameters: {'next': landing}).toString();
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
            if (needsName && !widget.changing) ...[
              Text('Are you a passenger or a driver?', style: t.textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                key: const ValueKey('signup-role'),
                segments: const [
                  ButtonSegment(value: 'passenger', icon: Icon(Icons.person_outline), label: Text('Passenger')),
                  ButtonSegment(value: 'driver', icon: Icon(Icons.local_taxi_outlined), label: Text('Driver')),
                ],
                selected: {_role},
                onSelectionChanged: (v) => setState(() => _role = v.first),
              ),
              const SizedBox(height: 4),
              Text('You can change the mode later', style: t.textTheme.bodySmall),
              const SizedBox(height: 16),
            ],
            if (needsName) ...[
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
              const SizedBox(height: 16),
            ],
            if (widget.changing) ...[
              CodeField(
                key: const ValueKey('current-pin'),
                controller: _current,
                length: 6,
                obscure: true,
                label: 'Current PIN',
              ),
              const SizedBox(height: 16),
            ],
            CodeField(controller: _pin, length: 6, obscure: true, autofocus: !widget.changing, label: 'New PIN'),
            const SizedBox(height: 16),
            CodeField(controller: _confirm, length: 6, obscure: true, autofocus: false, label: 'Confirm PIN'),
            if (!widget.changing) ...[
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('signup-referral'),
                controller: _referral,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'Referral code (optional)',
                  helperText: () {
                    final coin = ref.watch(coinSettingsProvider).value;
                    return coin == null
                        ? null
                        : referralSignupHint(
                            enabled: coin.referralEnabled,
                            referred: coin.referralReferredCoins,
                            coins: formatCoins,
                          );
                  }(),
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
