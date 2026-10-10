import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:record/record.dart';

/// The microphone, as a call needs it: asked for (the system prompt the first
/// time), and the app's own Settings page when it has been turned off.
abstract class MicPermission {
  /// Whether the app may use the microphone now. Asks the first time; once
  /// refused, the system no longer asks and this answers false.
  Future<bool> ensure();

  /// The app's page in the phone's Settings, where Microphone is switched on.
  Future<bool> openSettings();
}

class _DeviceMic implements MicPermission {
  @override
  Future<bool> ensure() async {
    final rec = AudioRecorder();
    try {
      return await rec.hasPermission();
    } catch (_) {
      return false;
    } finally {
      unawaited(rec.dispose());
    }
  }

  @override
  Future<bool> openSettings() async {
    if (kIsWeb) return false;
    try {
      return await Geolocator.openAppSettings();
    } catch (_) {
      return false;
    }
  }
}

final micPermissionProvider = Provider<MicPermission>((ref) => _DeviceMic());

/// How long a trip to Settings may take before the call is given up.
const micSettingsWait = Duration(minutes: 2);

/// Gets the microphone before a call starts or is answered: true when the
/// call may go ahead. When the microphone is off, says so and offers the
/// app's Settings page; coming back with it switched on carries on with the
/// call, and anything else leaves it unplaced. A call is never started
/// without the microphone, so the other person never hears silence.
Future<bool> ensureMicForCall(BuildContext context, WidgetRef ref) async {
  final mic = ref.read(micPermissionProvider);
  if (await mic.ensure()) return true;
  if (!context.mounted) return false;
  final go = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      key: const ValueKey('mic-needed'),
      icon: const Icon(Icons.mic_off_outlined),
      title: const Text('Allow microphone'),
      content: Text(
        kIsWeb ? 'Calls need your microphone. Allow microphone for this site in your browser, then try again.' : 'Calls need your microphone. Turn on Microphone for GET.ride in Settings, and the call will start when you come back.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
        if (!kIsWeb)
          FilledButton(
            key: const ValueKey('mic-open-settings'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Open Settings'),
          ),
      ],
    ),
  );
  if (go != true) return false;
  // Back from Settings: check again, and carry on only if it is on now.
  final back = Completer<void>();
  final lifecycle = AppLifecycleListener(
    onResume: () {
      if (!back.isCompleted) back.complete();
    },
  );
  try {
    if (!await mic.openSettings()) return false;
    await back.future.timeout(micSettingsWait);
  } on TimeoutException {
    return false;
  } finally {
    lifecycle.dispose();
  }
  return mic.ensure();
}
