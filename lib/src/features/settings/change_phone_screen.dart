import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../core/auth_utils.dart';
import '../../core/dial_countries.dart';
import '../../core/phone_input.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/dial_country_picker.dart';

/// Whether [local] (after [dialCode]) is a number Send code can go with:
/// at least 9 characters composed, as the sign-in page checks.
bool changePhoneNumberReady(String dialCode, String local) =>
    local.trim().isNotEmpty && composePhone(dialCode, local).length >= 9;

/// Moves the signed-in account to a new phone number (Expo
/// `app/change-number.tsx`): the number is checked against other accounts,
/// Supabase Auth texts a code to it, and the change only takes effect once
/// that code is entered. The sign-in PIN is unchanged.
class ChangePhoneScreen extends ConsumerStatefulWidget {
  const ChangePhoneScreen({super.key});

  @override
  ConsumerState<ChangePhoneScreen> createState() => _ChangePhoneScreenState();
}

class _ChangePhoneScreenState extends ConsumerState<ChangePhoneScreen> {
  final _number = TextEditingController();
  final _code = TextEditingController();
  DialCountry _country = dialCountryFor(AppConfig.defaultDialCode);
  String? _sentTo;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _number.dispose();
    _code.dispose();
    super.dispose();
  }

  /// A whole number is typed (as the sign-in page asks: 9 or more
  /// characters with its dial code), so Send code can go.
  bool get _numberReady => changePhoneNumberReady(_country.dialCode, _number.text);

  Future<void> _send() async {
    if (!_numberReady) return;
    final phone = composePhone(_country.dialCode, _number.text);
    final auth = ref.read(authRepositoryProvider);
    final current = ref.read(profileProvider).value?.phone;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var problem = phoneChangeProblem(phone, current, takenByAnother: false);
      if (problem == null) {
        final lookup = await auth.lookupPhone(phone);
        problem = phoneChangeProblem(phone, current, takenByAnother: lookup.hasProfile && !lookup.isDeleted);
      }
      if (problem != null) {
        setState(() => _error = problem);
        return;
      }
      await auth.requestPhoneChange(phone);
      if (mounted) setState(() => _sentTo = phone);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final phone = _sentTo;
    if (phone == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).confirmPhoneChange(phone, _code.text.trim());
      ref.invalidate(profileProvider);
      if (!mounted) return;
      showInfo(context, 'Your phone number is now $phone.');
      await Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final current = ref.watch(profileProvider).value?.phone;
    final sent = _sentTo;
    return Scaffold(
      appBar: AppBar(title: const Text('Change phone number')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (current != null && current.isNotEmpty)
                  Text('Current number: ${normalizeE164(current)}', style: t.textTheme.bodyMedium),
                const SizedBox(height: 16),
                if (sent == null) ...[
                  Text('Enter your new number. We will text a code to it to confirm.', style: t.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The sign-in page's picker: flag, name and code, searchable.
                      DialCountryButton(
                        key: const ValueKey('new-phone-country'),
                        country: _country,
                        height: 56,
                        onPressed: _busy
                            ? null
                            : () async {
                                final picked = await showDialCountryPicker(context, selected: _country);
                                if (picked != null && mounted) setState(() => _country = picked);
                              },
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('new-phone'),
                          controller: _number,
                          enabled: !_busy,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly, const NoTrunkZeroFormatter()],
                          decoration: const InputDecoration(labelText: 'New phone number'),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  Text('Enter the 6-digit code sent to $sent.', style: t.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('change-code'),
                    controller: _code,
                    enabled: !_busy,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Code'),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _confirm(),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _sentTo = null;
                            _code.clear();
                          }),
                    child: const Text('Use a different number'),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: t.colorScheme.error)),
                ],
                const SizedBox(height: 16),
                BusyButton.filled(
                  key: const ValueKey('change-phone-go'),
                  onPressed: _busy || (sent != null && _code.text.trim().length != 6) || (sent == null && !_numberReady)
                      ? null
                      : (sent == null ? _send : _confirm),
                  child: _busy
                      ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(sent == null ? 'Send code' : 'Confirm new number'),
                ),
                const SizedBox(height: 12),
                Text('Your sign-in PIN stays the same.', style: t.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
