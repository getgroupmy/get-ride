// Sign in with a GET.ride admin account: the same phone number and 6-digit
// PIN as the GET.ride app.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.auth});

  final GoTrueClient auth;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _dial = TextEditingController(text: '+60');
  final _phone = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _dial.dispose();
    _phone.dispose();
    _pin.dispose();
    super.dispose();
  }

  String get _composed => composeSignInPhone(_dial.text, _phone.text);
  bool get _ready => _composed.length >= 8 && isValidPin(_pin.text);

  Future<void> _signIn() async {
    if (!_ready || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.signInWithPassword(phone: _composed, password: pinPassword(_pin.text));
    } on AuthException catch (e) {
      setState(
        () => _error = RegExp('invalid login credentials', caseSensitive: false).hasMatch(e.message)
            ? 'Wrong phone number or PIN. If you set your PIN on another phone, sign in to the GET.ride app '
                  'once first, then try again here.'
            : e.message,
      );
    } catch (e) {
      setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.sim_card_outlined, size: 56, color: t.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'GET.ride Gateway',
                    textAlign: TextAlign.center,
                    style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This phone sends and receives GET.ride\'s SMS from its SIM. Sign in with an admin account — '
                    'the same phone number and PIN as the GET.ride app.',
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      SizedBox(
                        width: 84,
                        child: TextField(
                          key: const ValueKey('sign-in-dial'),
                          controller: _dial,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Code', border: OutlineInputBorder()),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('sign-in-phone'),
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          autofillHints: const [AutofillHints.telephoneNumberNational],
                          decoration: const InputDecoration(labelText: 'Phone number', border: OutlineInputBorder()),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('sign-in-pin'),
                    controller: _pin,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      labelText: '6-digit PIN',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _signIn(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      key: const ValueKey('sign-in-error'),
                      style: TextStyle(color: t.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const ValueKey('sign-in-submit'),
                    onPressed: _ready && !_busy ? _signIn : null,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: _busy
                        ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Text('Sign in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
