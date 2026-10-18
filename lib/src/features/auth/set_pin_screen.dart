import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth_utils.dart';
import '../../core/referral.dart';
import '../../data/auth_repository.dart';
import '../../data/referral_repository.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../admin/screens/commerce/get_coin.dart' show formatCoins;
import '../../data/coin_trade_repository.dart';
import 'signup_photo_screen.dart' show signupLanding;

/// Choose the 6-digit sign-in PIN after an SMS sign-in (a new account, or
/// a forgotten PIN). Requires an active session. Changing it from Settings
/// is its own page (`ChangePinScreen`).
class SetPinScreen extends ConsumerStatefulWidget {
  const SetPinScreen({super.key});

  @override
  ConsumerState<SetPinScreen> createState() => _SetPinScreenState();
}

class _SetPinScreenState extends ConsumerState<SetPinScreen> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  late final _referral = TextEditingController(text: PendingReferral.code ?? '');
  bool _busy = false;
  String? _pinError;
  String? _confirmError;

  /// Expo `role-selection`: where a brand-new account lands. Either mode
  /// stays a tap away later.
  String _role = 'passenger';

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    _name.dispose();
    _referral.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // Checked in the order the fields stand: the name, the PINs, the code.
    final before = ref.read(profileProvider).value;
    final isNew = before?.name?.trim().isNotEmpty != true;
    final hasPhoto = before?.avatarUrl != null;
    if (isNew) {
      final problem = signupNameProblem(_name.text);
      if (problem != null) return showInfo(context, problem);
    }
    // The PIN problems sit under their own field.
    final pinError = isValidPin(_pin.text) ? null : 'PIN must be 6 digits';
    final confirmError = pinError == null && _pin.text != _confirm.text ? "PINs don't match" : null;
    setState(() {
      _pinError = pinError;
      _confirmError = confirmError;
    });
    if (pinError != null || confirmError != null) return;
    final referral = normalizeReferralCode(_referral.text);
    if (referral.isNotEmpty && !isPlausibleReferralCode(referral)) {
      return showInfo(context, "That referral code wasn't found.");
    }
    setState(() => _busy = true);
    try {
      if (isNew) {
        // The admin's device guard, asked before the account is made so the
        // reason can be told apart (emulator or too many accounts).
        final problem = (await ref.read(authRepositoryProvider).deviceRegistration()).problem;
        if (problem != null) {
          if (mounted) showInfo(context, problem);
          return;
        }
      }
      await ref.read(authRepositoryProvider).setPin(_pin.text);
      final name = capitaliseName(_name.text);
      if (name.isNotEmpty) await ref.read(accountRepositoryProvider).updateProfile(name: name);
      AuthRepository.pinSetupPending = false;
      ref.invalidate(profileProvider);
      final referralNotice = referral.isEmpty ? null : await _applyReferral(referral);
      if (mounted) context.go(_nextRoute(isNew: isNew, hasPhoto: hasPhoto));
      if (referralNotice != null && mounted) showInfo(context, referralNotice);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A new account gets the optional photo step (unless it already has
  /// one) and then its chosen mode.
  String _nextRoute({required bool isNew, required bool hasPhoto}) {
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
    await ref.read(authRepositoryProvider).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final needsName = ref.watch(profileProvider).value?.name?.trim().isNotEmpty != true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set your PIN'),
        leading: BusyIconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: _busy ? null : _cancel),
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
                key: const ValueKey('signup-name'),
                controller: _name,
                // The first field, so the keyboard is up for it.
                autofocus: true,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.words,
                maxLength: signupNameMaxLength,
                // The limit still holds; a "0/50" under a name says nothing.
                decoration: const InputDecoration(labelText: 'Your name', counterText: ''),
              ),
              const SizedBox(height: 16),
            ],
            // Next goes down the form: PIN, confirm, referral code.
            CodeField(
              controller: _pin,
              length: 6,
              obscure: true,
              autofocus: !needsName,
              label: 'New PIN',
              textInputAction: TextInputAction.next,
              errorText: _pinError,
              onChanged: (_) {
                if (_pinError != null) setState(() => _pinError = null);
              },
            ),
            const SizedBox(height: 16),
            CodeField(
              controller: _confirm,
              length: 6,
              obscure: true,
              autofocus: false,
              label: 'Confirm PIN',
              textInputAction: TextInputAction.next,
              errorText: _confirmError,
              onChanged: (_) {
                if (_confirmError != null) setState(() => _confirmError = null);
              },
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('signup-referral'),
              controller: _referral,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _busy ? null : _save(),
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
            const SizedBox(height: 24),
            BusyButton.filled(onPressed: _busy ? null : _save, child: const Text('Save PIN')),
          ]),
        ),
      ),
    );
  }
}
