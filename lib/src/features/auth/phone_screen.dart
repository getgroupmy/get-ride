import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../../core/app_display.dart';
import '../../core/auth_utils.dart';
import '../../core/dial_countries.dart';
import '../../core/phone_input.dart';
import '../../data/app_display_repository.dart';
import '../../data/device_access.dart';
import '../../data/session_guard.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/dial_country_picker.dart';
import 'otp_screen.dart' show otpShortScreen;
import 'passkey_sign_in_button.dart';
import '../../widgets/page_style_host.dart';

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _number = TextEditingController();
  DialCountry _country = dialCountryFor(AppConfig.defaultDialCode);
  bool _busy = false;

  /// Said under the field, not in a snackbar that would cover Next.
  String? _numberError;

  @override
  void initState() {
    super.initState();
    _number.addListener(_clearError);
  }

  void _clearError() {
    if (_numberError != null) setState(() => _numberError = null);
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    signedOutElsewhere.value = false;
    // Started when this screen opened (build watches it), so usually done.
    final blocked = await deviceBlockedWithin(ref.read(deviceBlockedProvider.future));
    if (!mounted) return;
    if (blocked) {
      showInfo(context, serviceNotAvailable);
      return;
    }
    final phone = composePhone(_country.dialCode, _number.text);
    if (phone.length < 9) {
      setState(() => _numberError = 'Enter a valid phone number.');
      return;
    }
    setState(() => _busy = true);
    final auth = ref.read(authRepositoryProvider);
    try {
      final lookup = await auth.lookupPhone(phone);
      if (!mounted) return;
      if (lookup.isDeleted) {
        showInfo(context, 'This account has been deleted. Contact support to restore it.');
        return;
      }
      if (!lookup.hasProfile) {
        final display = await ref.read(appDisplayProvider.future);
        if (!mounted) return;
        // Passenger and driver sign-up both closed: no SMS code at all
        // (the server's sign-up hook refuses one too, migration 0287).
        if (!mayContinueSignIn(hasAccount: false, display: display)) {
          setState(() => _busy = false);
          // Not awaited: Next stops spinning while the modal is up.
          unawaited(_noAccount(phone));
          return;
        }
        // No SMS (and no account) until they say this is a new account.
        setState(() => _busy = false);
        if (!await _confirmNewAccount(phone) || !mounted) return;
        setState(() => _busy = true);
        try {
          await auth.sendOtp(phone, createUser: true);
        } catch (e) {
          // Closed since this page read the settings: the server said so.
          if (!isRegistrationClosed('$e')) rethrow;
          if (mounted) setState(() => _busy = false);
          if (mounted) unawaited(_noAccount(phone));
          return;
        }
        if (!mounted) return;
        // The number stays in memory, not in the address (signInStepPath).
        context.push(signInStepPath('/login/otp', phone, {'next': 'set-pin', 'new': '1'}));
      } else if (lookup.hasPin) {
        context.push(signInStepPath('/login/pin', phone));
      } else {
        await auth.sendOtp(phone, createUser: false);
        if (!mounted) return;
        context.push(signInStepPath('/login/otp', phone, {'next': 'set-pin'}));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A number with no account while new sign-ups are closed: a modal
  /// instead of an SMS code, back to the number to try another.
  Future<void> _noAccount(String phone) async {
    await showAppDialog<void>(
      id: 'phone.no-account',
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('no-account'),
        icon: const Icon(Icons.person_off_outlined),
        title: const Text(noAccountTitle),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(phone, key: const ValueKey('no-account-phone'), style: Theme.of(c).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(noAccountMessage, textAlign: TextAlign.center),
        ]),
        actions: [
          FilledButton(
            key: const ValueKey('no-account-try-another'),
            onPressed: () => Navigator.pop(c),
            child: const Text('Try another number'),
          ),
        ],
      ),
    );
    if (mounted) _number.clear();
  }

  /// Expo's "Create a new account?" sheet: the number isn't known, so say so
  /// before texting it a code that would open an account.
  Future<bool> _confirmNewAccount(String phone) async {
    final ok = await showAppSheet<bool>(id: 'phone.confirm-new-account',
      context: context,
      showDragHandle: true,
      builder: (c) {
        final t = Theme.of(c);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: t.colorScheme.surfaceContainerHighest,
                child: Icon(Icons.person_add_alt_1_outlined, color: t.colorScheme.onSurface),
              ),
              const SizedBox(height: 16),
              Text('Create a new account?', textAlign: TextAlign.center, style: t.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                "We don't recognise this number. We'll text a 6-digit code to:",
                textAlign: TextAlign.center,
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(phone, key: const ValueKey('signup-phone'), textAlign: TextAlign.center, style: t.textTheme.titleMedium),
              const SizedBox(height: 24),
              FilledButton(
                key: const ValueKey('signup-send-code'),
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Sign up & send code'),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Use a different number')),
            ]),
          ),
        );
      },
    );
    return ok == true;
  }

  Future<void> _pickCountry() async {
    final picked = await showDialCountryPicker(context, selected: _country);
    if (picked != null && mounted) setState(() => _country = picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final blocked = ref.watch(deviceBlockedProvider).value ?? false;
    final muted = t.colorScheme.onSurfaceVariant;
    final short = otpShortScreen(MediaQuery.of(context));
    Widget title(TextStyle? style) => Text(
      'Join us via phone number',
      key: const ValueKey('phone-title'),
      style: style?.copyWith(fontWeight: FontWeight.w800),
    );
    return Scaffold(
      body: SafeArea(
        child: ResponsiveCenter(
          maxWidth: 480,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          // One scroll for the whole page, Next at the foot of the screen
          // when there is room and under the form when there is not (on its
          // side with the keyboard up).
          child: CustomScrollView(
            key: const ValueKey('phone-scroll'),
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // Short over the keyboard (a phone on its side): the title
                  // beside Back, in one row, rather than a row of its own.
                  Row(children: [
                    if (Navigator.of(context).canPop())
                      IconButton.outlined(
                        key: const ValueKey('sign-in-back'),
                        tooltip: 'Back',
                        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    if (short) ...[
                      const SizedBox(width: 12),
                      Expanded(child: title(t.textTheme.titleLarge)),
                    ] else
                      const Spacer(),
                    IconButton(
                      key: const ValueKey('phone-diagnostics'),
                      tooltip: 'Connection diagnostics',
                      icon: Icon(Icons.network_check, color: muted),
                      onPressed: () => context.push('/diagnostics'),
                    ),
                  ]),
                  // Short, the line under the title goes: the title and the
                  // number field stay in view together.
                  if (short)
                    const SizedBox(height: 12)
                  else ...[
                    const SizedBox(height: 12),
                    title(t.textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text('Sign in or create your account with your mobile number', style: t.textTheme.bodyLarge),
                    const SizedBox(height: 28),
                  ],
                  const SignedOutElsewhereNote(),
                  _PhoneField(
                    country: _country,
                    controller: _number,
                    onPickCountry: _pickCountry,
                    onSubmitted: _continue,
                  ),
                  if (_numberError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Text(
                        _numberError!,
                        key: const ValueKey('phone-error'),
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
                      ),
                    ),
                  if (blocked) ...[
                    const SizedBox(height: 16),
                    Card(
                      key: const ValueKey('device-blocked'),
                      color: t.colorScheme.errorContainer,
                      child: const ListTile(leading: Icon(Icons.gpp_bad_outlined), title: Text(serviceNotAvailable)),
                    ),
                  ],
                  const Spacer(),
                  const SizedBox(height: 12),
                  BusyButton.filled(
                    key: const ValueKey('phone-next'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(58),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      textStyle: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    onPressed: _busy || blocked ? null : _continue,
                    child: _busy
                        ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Next'),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The number in one rounded box, as inDrive: flag and dial code (tap to
/// change the country), the number, and a clear button.
class _PhoneField extends StatefulWidget {
  const _PhoneField({
    required this.country,
    required this.controller,
    required this.onPickCountry,
    required this.onSubmitted,
  });

  final DialCountry country;
  final TextEditingController controller;
  final VoidCallback onPickCountry;
  final VoidCallback onSubmitted;

  @override
  State<_PhoneField> createState() => _PhoneFieldState();
}

class _PhoneFieldState extends State<_PhoneField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 6, right: 4),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.colorScheme.onSurface, width: 2),
      ),
      child: Row(children: [
        // Read out as "Country code +60, Malaysia", not as the flag.
        Semantics(
          button: true,
          label: DialCountryButton.semanticsLabelFor(widget.country),
          excludeSemantics: true,
          onTap: widget.onPickCountry,
          child: InkWell(
            key: const ValueKey('dial-country'),
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onPickCountry,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                DialCountryFlag(widget.country),
                const Icon(Icons.arrow_drop_down),
              ]),
            ),
          ),
        ),
        Text(widget.country.dialCode, style: t.textTheme.titleLarge),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            key: const ValueKey('phone-number'),
            controller: widget.controller,
            autofocus: true,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\s-]')), const NoTrunkZeroFormatter()],
            style: t.textTheme.titleLarge,
            decoration: const InputDecoration(
              hintText: '123456789',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              // A 48-high tap target, not the dense field's 36.
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
            onSubmitted: (_) => widget.onSubmitted(),
          ),
        ),
        if (widget.controller.text.isNotEmpty)
          IconButton(
            key: const ValueKey('phone-clear'),
            tooltip: 'Clear',
            icon: Icon(Icons.cancel, color: t.colorScheme.onSurfaceVariant),
            onPressed: widget.controller.clear,
          ),
      ]),
    );
  }
}
