// Settings › Safety: "Share my last location with GET.ride safety when the
// app is closed" (migration 0333). Shown to passengers only while the admin
// has passenger check-ins on; off until they turn it on, after the full
// background-location disclosure (Continue / Not now) and the phone's own
// question. Turning it off stops the check-ins at once; the server ignores
// any that still come.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_permissions.dart';
import '../../data/background_location.dart';
import '../../data/permission_probe.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../permissions/permission_actions.dart';

/// The admin's switch: passengers may opt in to closed-app check-ins.
final locationCheckinsConfigProvider = FutureProvider<bool>((ref) async {
  try {
    final r = await ref.watch(supabaseProvider).rpc('location_checkins_config');
    return r is Map && r['passengers'] == true;
  } catch (_) {
    return false;
  }
});

/// The disclosure before the phone is asked: true for Continue.
Future<bool> showLocationCheckinsDisclosure(BuildContext context) async =>
    await showAppDialog<bool>(
      id: 'settings.location-checkins',
      context: context,
      builder: (c) => const LocationCheckinsDisclosure(),
    ) ==
    true;

class LocationCheckinsDisclosure extends StatelessWidget {
  const LocationCheckinsDisclosure({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('location-checkins-disclosure'),
    scrollable: true,
    icon: const Icon(Icons.share_location_outlined),
    title: const Text('Location all the time'),
    content: const Text(backgroundLocationDisclosure),
    actions: [
      TextButton(
        key: const ValueKey('location-checkins-not-now'),
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Not now'),
      ),
      FilledButton(
        key: const ValueKey('location-checkins-continue'),
        style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Continue'),
      ),
    ],
  );
}

class LocationCheckinsCard extends ConsumerStatefulWidget {
  const LocationCheckinsCard({super.key, this.save, this.askPhone, this.stopNow});

  /// Saves the opt-in (set_location_checkins); stand-ins in tests.
  final Future<void> Function(bool on)? save;

  /// Asks the phone for location all the time, after the disclosure.
  final Future<void> Function(BuildContext context)? askPhone;

  /// Stops the closed-app reporter at once.
  final Future<void> Function()? stopNow;

  @override
  ConsumerState<LocationCheckinsCard> createState() => _LocationCheckinsCardState();
}

class _LocationCheckinsCardState extends ConsumerState<LocationCheckinsCard> {
  bool? _on;
  bool _busy = false;

  Future<void> _askPhone(BuildContext context) async {
    final block = defaultTargetPlatform == TargetPlatform.iOS ? PermissionBlock.notAlways : PermissionBlock.notAllTheTime;
    await resolvePermissionBlock(context, ref.read(permissionProbeProvider), block);
  }

  Future<void> _set(bool on) async {
    if (on) {
      if (!await showLocationCheckinsDisclosure(context) || !mounted) return;
      await (widget.askPhone ?? _askPhone)(context);
      if (!mounted) return;
    }
    setState(() => _busy = true);
    try {
      await (widget.save ?? (v) => ref.read(supabaseProvider).rpc('set_location_checkins', params: {'p_on': v}))(on);
      if (!on) await (widget.stopNow ?? () => BackgroundLocation().disarm())();
      setState(() => _on = on);
      ref.invalidate(profileProvider);
      if (mounted) {
        showInfo(context, on ? 'Your last location will be shared with GET.ride safety.' : 'Stopped. Nothing is shared when the app is closed.');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offered = ref.watch(locationCheckinsConfigProvider).value ?? false;
    // Drivers keep their own rules (going online); this is the passenger's.
    final driver = ref.watch(partnerProvider).value != null;
    if (!offered || driver || kIsWeb) return const SizedBox.shrink();
    final on = _on ?? (ref.watch(profileProvider).value?.raw['location_checkins'] == true);
    return Card(
      key: const ValueKey('location-checkins-card'),
      child: SwitchListTile(
        key: const ValueKey('location-checkins-switch'),
        value: on,
        onChanged: _busy ? null : (v) => unawaited(_set(v)),
        secondary: const Icon(Icons.share_location_outlined),
        title: const Text('Share my last location with GET.ride safety when the app is closed'),
        subtitle: const Text('Off unless you turn it on. Your approximate location about every 15 minutes, so our '
            'safety team can see where you last were if you need help. Turn it off any time.'),
      ),
    );
  }
}
