import 'package:flutter/material.dart';

import '../../widgets/page_style_host.dart';

/// The question a TEKSI driver gets right after signing in when the rate
/// card's "Meter at sign-in" is "Ask the driver": true for "Turn the meter
/// on", false for "Not now", null when the dialog went away unanswered.
Future<bool?> showMeterSignInPrompt(BuildContext context) => showAppDialog<bool>(
  id: 'meter.sign-in-choice',
  context: context,
  barrierDismissible: false,
  builder: (c) => const MeterSignInPrompt(),
);

class MeterSignInPrompt extends StatelessWidget {
  const MeterSignInPrompt({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('meter-sign-in-prompt'),
      icon: Icon(Icons.speed, color: t.colorScheme.primary),
      title: const Text('Turn the meter on?'),
      content: const Text(
        'With the meter on, the app opens on the meter console for this sign-in. '
        'Not now takes you to the app as usual, and you can turn the meter on later from the driver menu.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('meter-sign-in-not-now'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton.icon(
          key: const ValueKey('meter-sign-in-on'),
          icon: const Icon(Icons.speed),
          onPressed: () => Navigator.pop(context, true),
          label: const Text('Turn the meter on'),
        ),
      ],
    );
  }
}
