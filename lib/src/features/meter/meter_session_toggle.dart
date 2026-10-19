import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/meter_sign_in.dart';
import 'meter_auto_launch.dart';

/// "Meter on/off" in the driver menu: the driver's meter for this sign-in,
/// shown only where the rate card's "Meter at sign-in" is "Ask the driver"
/// or "Always on". Turning it on calls [onTurnedOn] (which opens the meter);
/// turning it off keeps the meter from opening on a reopen until the next
/// sign-in or until the driver turns it on again.
class MeterSessionToggle extends ConsumerWidget {
  const MeterSessionToggle({super.key, this.onTurnedOn});

  final VoidCallback? onTurnedOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(meterAtSignInProvider).value ?? 'off';
    if (!showMeterSessionToggle(mode)) return const SizedBox.shrink();
    final on = ref.watch(meterSessionChoiceProvider).value ?? false;
    return SwitchListTile(
      key: const ValueKey('meter-session-toggle'),
      secondary: const Icon(Icons.speed),
      title: const Text('Meter on/off'),
      subtitle: Text(on ? 'On for this sign-in' : 'Off for this sign-in'),
      value: on,
      onChanged: (v) async {
        await ref.read(meterSessionChoiceProvider.notifier).set(v);
        if (v) onTurnedOn?.call();
      },
    );
  }
}
