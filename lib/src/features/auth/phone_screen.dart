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
import 'passkey_sign_in_button.dart';

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _number = TextEditingController();
  DialCountry _country = dialCountryFor(AppConfig.defaultDialCode);
  bool _busy = false;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    signedOutElsewhere.value = false;
    final blocked = await ref.read(deviceBlockedProvider.future);
    if (!mounted) return;
    if (blocked) {
      showInfo(context, serviceNotAvailable);
      return;
    }
    final phone = composePhone(_country.dialCode, _number.text);
    if (phone.length < 9) {
      showInfo(context, 'Enter a valid phone number.');
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
        if (!mayContinueSignIn(hasAccount: false, display: display)) {
          context.push(Uri(path: '/login/closed', queryParameters: {'phone': phone}).toString());
          return;
        }
        // No SMS (and no account) until they say this is a new account.
        setState(() => _busy = false);
        if (!await _confirmNewAccount(phone) || !mounted) return;
        setState(() => _busy = true);
        await auth.sendOtp(phone, createUser: true);
        if (!mounted) return;
        context.push(
          Uri(path: '/login/otp', queryParameters: {'phone': phone, 'next': 'set-pin', 'new': '1'}).toString(),
        );
      } else if (lookup.hasPin) {
        context.push(Uri(path: '/login/pin', queryParameters: {'phone': phone}).toString());
      } else {
        await auth.sendOtp(phone, createUser: false);
        if (!mounted) return;
        context.push(Uri(path: '/login/otp', queryParameters: {'phone': phone, 'next': 'set-pin'}).toString());
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Expo's "Create a new account?" sheet: the number isn't known, so say so
  /// before texting it a code that would open an account.
  Future<bool> _confirmNewAccount(String phone) async {
    final ok = await showModalBottomSheet<bool>(
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
    final picked = await showDialCountryPicker(context);
    if (picked != null && mounted) setState(() => _country = picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final blocked = ref.watch(deviceBlockedProvider).value ?? false;
    final muted = t.colorScheme.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: ResponsiveCenter(
          maxWidth: 480,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              if (Navigator.of(context).canPop())
                IconButton.outlined(
                  key: const ValueKey('sign-in-back'),
                  tooltip: 'Back',
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              const Spacer(),
              IconButton(
                key: const ValueKey('phone-diagnostics'),
                tooltip: 'Connection diagnostics',
                icon: Icon(Icons.medical_services_outlined, color: muted),
                onPressed: () => context.push('/diagnostics'),
              ),
            ]),
            Expanded(
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const SizedBox(height: 12),
                  Text(
                    'Join us via phone number',
                    style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text('Sign in or create your account with your mobile number', style: t.textTheme.bodyLarge),
                  const SizedBox(height: 28),
                  const SignedOutElsewhereNote(),
                  _PhoneField(
                    country: _country,
                    controller: _number,
                    onPickCountry: _pickCountry,
                    onSubmitted: _continue,
                  ),
                  if (blocked) ...[
                    const SizedBox(height: 16),
                    Card(
                      key: const ValueKey('device-blocked'),
                      color: t.colorScheme.errorContainer,
                      child: const ListTile(leading: Icon(Icons.gpp_bad_outlined), title: Text(serviceNotAvailable)),
                    ),
                  ],
                ]),
              ),
            ),
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
        InkWell(
          key: const ValueKey('dial-country'),
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onPickCountry,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(widget.country.flag, style: const TextStyle(fontSize: 24)),
              const Icon(Icons.arrow_drop_down),
            ]),
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
              hintText: '12 345 6789',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
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
