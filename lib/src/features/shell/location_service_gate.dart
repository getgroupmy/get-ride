// After signing in (PIN, SMS code or passkey), the phone's location must be
// switched on before the home page: pickups, nearby drivers and requests all
// start from it. Until it is, a modal over the app says so and opens the
// phone's Location settings; coming back with it on lets them through.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/auth_repository.dart';
import '../../data/permission_probe.dart';
import '../../providers.dart';

class LocationServiceGate extends ConsumerStatefulWidget {
  const LocationServiceGate({super.key, required this.child, this.signIns});

  final Widget child;

  /// Fresh sign-ins; null is Supabase's (a restored session at launch is not
  /// one). For tests.
  final Stream<void>? signIns;

  @override
  ConsumerState<LocationServiceGate> createState() => _LocationServiceGateState();
}

class _LocationServiceGateState extends ConsumerState<LocationServiceGate> {
  StreamSubscription<void>? _sub;
  AppLifecycleListener? _lifecycle;
  bool _blocked = false;
  bool _watching = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;
    final signIns =
        widget.signIns ??
        ref
            .read(supabaseProvider)
            .auth
            .onAuthStateChange
            .where((s) => s.event == AuthChangeEvent.signedIn && s.session != null)
            // A new account sets its PIN first; this is for registered users.
            .where((_) => !AuthRepository.pinSetupPending);
    _sub = signIns.listen((_) {
      _watching = true;
      unawaited(_check());
    }, onError: (Object _) {});
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (_watching) unawaited(_check());
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final (on, _) = await ref.read(permissionProbeProvider).location();
    if (!mounted) return;
    // Once on, this sign-in is done with; the next sign-in checks again.
    if (on) _watching = false;
    if (_blocked != !on) setState(() => _blocked = !on);
  }

  @override
  Widget build(BuildContext context) {
    if (!_blocked) return widget.child;
    return Stack(
      children: [
        widget.child,
        const Positioned.fill(child: ModalBarrier(dismissible: false, color: Colors.black54)),
        Center(child: LocationServiceOffCard(onOpen: () => ref.read(permissionProbeProvider).openLocationSettings())),
      ],
    );
  }
}

/// The modal itself: location is off, and the button to the phone's settings.
class LocationServiceOffCard extends StatelessWidget {
  const LocationServiceOffCard({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Material(
          key: const ValueKey('location-service-off'),
          color: t.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.location_off_outlined, size: 40, color: t.colorScheme.primary),
                const SizedBox(height: 16),
                Text('Turn on Location', style: t.textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(
                  "Location is switched off on this phone. GET.ride needs it to find your pickup and the drivers "
                  'near you. Turn it on to continue.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('location-service-open'),
                    onPressed: onOpen,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Open Location settings'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
