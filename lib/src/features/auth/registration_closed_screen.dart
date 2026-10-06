import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_display.dart';
import '../../widgets/common.dart';

/// What a phone number with no account sees while Admin → Display Settings →
/// Sign-in Screen → Allow new registrations is off: a page of its own rather
/// than a passing message, with the way back to try another number.
class RegistrationClosedScreen extends StatelessWidget {
  const RegistrationClosedScreen({super.key, required this.phone});

  final String phone;

  void _back(BuildContext context) => context.canPop() ? context.pop() : context.go('/login');

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
                Text(registrationClosedMessage, textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
                if (phone.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    phone,
                    textAlign: TextAlign.center,
                    style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 32),
                FilledButton(onPressed: () => _back(context), child: const Text('Use a different number')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
