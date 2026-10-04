import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../../core/auth_utils.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

const _dialCodes = ['+60', '+65', '+62', '+66', '+63', '+84', '+673', '+91', '+44', '+1'];

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _number = TextEditingController();
  String _dial = AppConfig.defaultDialCode;
  bool _busy = false;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final phone = composePhone(_dial, _number.text);
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
      if (lookup.hasPin) {
        context.push(Uri(path: '/login/pin', queryParameters: {'phone': phone}).toString());
      } else {
        await auth.sendOtp(phone);
        if (!mounted) return;
        context.push(Uri(path: '/login/otp', queryParameters: {'phone': phone, 'next': 'set-pin'}).toString());
      }
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
      body: SafeArea(
        child: SingleChildScrollView(
          child: ResponsiveCenter(
            maxWidth: 440,
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SizedBox(height: 48),
              const Center(child: BrandMark(size: 40)),
              const SizedBox(height: 8),
              Text('Your ride, your way.', textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
              const SizedBox(height: 48),
              Text('Enter your mobile number', style: t.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('We\'ll sign you in, or create your account.', style: t.textTheme.bodyMedium),
              const SizedBox(height: 20),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 110,
                  child: DropdownButtonFormField<String>(
                    initialValue: _dial,
                    items: [
                      for (final c in {..._dialCodes, _dial}) DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: (v) => setState(() => _dial = v ?? _dial),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _number,
                    autofocus: true,
                    keyboardType: TextInputType.phone,
                    autofillHints: const [AutofillHints.telephoneNumberNational],
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\s-]'))],
                    decoration: const InputDecoration(hintText: '12 345 6789'),
                    onSubmitted: (_) => _continue(),
                  ),
                ),
              ]),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _continue,
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
            ]),
          ),
        ),
      ),
    );
  }
}
