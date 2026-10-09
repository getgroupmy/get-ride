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
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/in_app_page.dart';

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
    final picked = await showModalBottomSheet<DialCountry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CountrySheet(),
    );
    if (picked != null && mounted) setState(() => _country = picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final blocked = ref.watch(deviceBlockedProvider).value ?? false;
    final showLogo = ref.watch(appDisplayProvider).value?.showSignInLogo ?? true;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: ResponsiveCenter(
            maxWidth: 440,
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  key: const ValueKey('phone-diagnostics'),
                  tooltip: 'Connection diagnostics',
                  icon: const Icon(Icons.medical_services_outlined),
                  onPressed: () => context.push('/diagnostics'),
                ),
              ),
              if (showLogo) ...[
                const Center(key: ValueKey('sign-in-logo'), child: BrandMark(size: 40)),
                const SizedBox(height: 8),
              ],
              Text('Your ride, your way.', textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
              const SizedBox(height: 48),
              Text('Enter your mobile number', style: t.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('We\'ll sign you in, or create your account.', style: t.textTheme.bodyMedium),
              const SizedBox(height: 20),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                OutlinedButton(
                  key: const ValueKey('dial-country'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 52),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: _pickCountry,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_country.flag, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 6),
                    Text(_country.dialCode),
                    const Icon(Icons.arrow_drop_down),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _number,
                    autofocus: true,
                    keyboardType: TextInputType.phone,
                    autofillHints: const [AutofillHints.telephoneNumberNational],
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\s-]')), const NoTrunkZeroFormatter()],
                    decoration: const InputDecoration(hintText: '12 345 6789'),
                    onSubmitted: (_) => _continue(),
                  ),
                ),
              ]),
              const SizedBox(height: 24),
              if (blocked) ...[
                Card(
                  key: const ValueKey('device-blocked'),
                  color: t.colorScheme.errorContainer,
                  child: const ListTile(leading: Icon(Icons.gpp_bad_outlined), title: Text(serviceNotAvailable)),
                ),
                const SizedBox(height: 12),
              ],
              BusyButton.filled(
                onPressed: _busy || blocked ? null : _continue,
                child: _busy
                    ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Continue'),
              ),
              const SizedBox(height: 16),
              Text(
                'By continuing you agree to the GET.ride Terms of Service and Privacy Policy.',
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall,
              ),
              Wrap(alignment: WrapAlignment.center, children: [
                TextButton(
                  key: const ValueKey('phone-terms'),
                  onPressed: () => openInApp(context, AppConfig.termsUrl, title: 'Terms of Service'),
                  child: const Text('Terms of Service'),
                ),
                TextButton(
                  key: const ValueKey('phone-privacy'),
                  onPressed: () => openInApp(context, AppConfig.privacyUrl, title: 'Privacy Policy'),
                  child: const Text('Privacy Policy'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Pick a country by name, code or dial code (Expo's country picker).
class _CountrySheet extends StatefulWidget {
  const _CountrySheet();

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final list = searchDialCountries(_query);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const ValueKey('country-search'),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search country or code'),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('No country found'))
                : ListView.builder(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: list.length,
                    itemBuilder: (c, i) => ListTile(
                      leading: Text(list[i].flag, style: const TextStyle(fontSize: 24)),
                      title: Text(list[i].name),
                      trailing: Text(list[i].dialCode),
                      onTap: () => Navigator.pop(c, list[i]),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}
