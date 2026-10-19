import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_display.dart';
import '../../widgets/common.dart';

/// What a phone number with no account sees while Admin → Display Settings →
/// Sign-in Screen → Allow new registrations is off: a page of its own rather
/// than a passing message, with the way back to try another number. The
/// number lives only in memory (`SignInPhone`): reloaded, the page still
/// says what closed means, without it.
class RegistrationClosedScreen extends StatelessWidget {
  const RegistrationClosedScreen({super.key, required this.phone});

  final String phone;

  /// Back to the number: the page before when there was one; reloaded (no
  /// number), straight to the number page.
  void _back(BuildContext context) => phone.isEmpty
      ? context.go('/login/phone')
      : context.canPop()
      ? context.pop()
      : context.go('/login');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: () => _back(context))),
      body: SafeArea(
        child: SingleChildScrollView(
          child: ResponsiveCenter(
            maxWidth: 440,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                Center(
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: t.colorScheme.secondaryContainer,
                    child: Icon(Icons.person_off_outlined, size: 40, color: t.colorScheme.onSecondaryContainer),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  registrationClosedTitle,
                  key: const ValueKey('registration-closed'),
                  textAlign: TextAlign.center,
                  style: t.textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  phone.isEmpty ? registrationClosedNoNumberMessage : registrationClosedMessage,
                  key: const ValueKey('registration-closed-message'),
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyLarge,
                ),
                if (phone.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    phone,
                    textAlign: TextAlign.center,
                    style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: () => _back(context),
                  child: Text(phone.isEmpty ? 'Sign in with your number' : 'Use a different number'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
