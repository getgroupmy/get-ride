import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:record/record.dart';
import '../../../widgets/page_style_host.dart';

/// Where the microphone stands. iOS tells "never asked" ([undetermined])
/// apart from "refused" ([denied]); it only lists Microphone in the app's
/// Settings page once it has been asked, so a phone that was never asked
/// must be asked, not sent to Settings. [unknown] is a platform that can't
/// say (asking is then the only way to find out).
enum MicStatus { granted, denied, undetermined, unknown }

/// The microphone, as a call needs it: asked for (the system prompt the first
/// time), and the app's own Settings page when it has been turned off.
abstract class MicPermission {
  /// Whether the app may use the microphone now. Asks the first time; once
  /// refused, the system no longer asks and this answers false.
  Future<bool> ensure();

  /// Where it stands, without asking.
  Future<MicStatus> status();

  /// The app's page in the phone's Settings, where Microphone is switched on.
  Future<bool> openSettings();
}

/// iOS's own answer (AppDelegate.swift, `MicStatusPlugin`).
const micChannel = MethodChannel('get_ride/mic');

bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Resolves once the app is in the foreground and active: iOS only shows its
/// permission prompt then, and quietly answers "no" (leaving it never asked)
/// to a request made from behind its own call screen.
Future<void> _whenActive() async {
  final binding = WidgetsBinding.instance;
  if (binding.lifecycleState == null || binding.lifecycleState == AppLifecycleState.resumed) return;
  final back = Completer<void>();
  final listener = AppLifecycleListener(
    onResume: () {
      if (!back.isCompleted) back.complete();
    },
  );
  try {
    await back.future.timeout(const Duration(seconds: 20));
  } catch (_) {
  } finally {
    listener.dispose();
  }
}

class _DeviceMic implements MicPermission {
  @override
  Future<MicStatus> status() async {
    if (!_isIos) return MicStatus.unknown;
    try {
      return switch (await micChannel.invokeMethod<String>('status')) {
        'granted' => MicStatus.granted,
        'denied' => MicStatus.denied,
        'undetermined' => MicStatus.undetermined,
        _ => MicStatus.unknown,
      };
    } catch (_) {
      // A build from before the native half: say nothing.
      return MicStatus.unknown;
    }
  }

  @override
  Future<bool> ensure() async {
    if (_isIos) {
      final s = await status();
      if (s == MicStatus.granted) return true;
      if (s == MicStatus.denied) return false;
      if (s == MicStatus.undetermined) {
        await _whenActive();
        try {
          return await micChannel.invokeMethod<bool>('request') ?? false;
        } catch (_) {}
      }
    }
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

/// What the microphone is wanted for, which is what the ask says.
enum MicUse { call, voiceNote }

/// Gets the microphone before a call starts or is answered: true when the
/// call may go ahead. When the microphone is off, says so and offers the
/// app's Settings page; coming back with it switched on carries on with the
/// call, and anything else leaves it unplaced. A call is never started
/// without the microphone, so the other person never hears silence.
Future<bool> ensureMicForCall(BuildContext context, WidgetRef ref) => ensureMic(context, ref, MicUse.call);

/// Gets the microphone for [use]; see [ensureMicForCall].
Future<bool> ensureMic(BuildContext context, WidgetRef ref, MicUse use) async {
  final mic = ref.read(micPermissionProvider);
  if (await mic.ensure()) return true;
  if (!context.mounted) return false;
  final what = use == MicUse.call ? 'Calls need' : 'Voice notes need';
  // Never asked (the ask was made behind the phone's own call screen, where
  // iOS can't show it): there is nothing in Settings yet, so ask here, from
  // a tap, where the system's question can appear.
  if (await mic.status() == MicStatus.undetermined) {
    if (!context.mounted) return false;
    final allow = await showAppDialog<bool>(id: 'mic-gate.ensure-mic',
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('mic-ask'),
        icon: const Icon(Icons.mic_none),
        title: const Text('Allow microphone'),
        content: Text('$what your microphone. Tap Allow, then choose Allow when your phone asks.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(
            key: const ValueKey('mic-allow'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (allow != true) return false;
    if (await mic.ensure()) return true;
    if (!context.mounted || await mic.status() == MicStatus.undetermined) return false;
  }
  if (!context.mounted) return false;
  final then = use == MicUse.call ? 'the call will start when you come back' : 'you can record when you come back';
  final go = await showAppDialog<bool>(id: 'mic-gate.ensure-mic-2',
    context: context,
    builder: (c) => AlertDialog(
      key: const ValueKey('mic-needed'),
      icon: const Icon(Icons.mic_off_outlined),
      title: const Text('Allow microphone'),
      content: Text(
        kIsWeb
            ? '$what your microphone. Allow microphone for this site in your browser, then try again.'
            : '$what your microphone. Turn on Microphone for GET.ride in Settings, and $then.',
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

/// Asks for the microphone ahead of any call, while the app is on screen,
/// if it has never been asked: a call answered from the phone's own call
/// screen can't show the question. Silent otherwise.
Future<void> primeMicForCalls(WidgetRef ref) async {
  final mic = ref.read(micPermissionProvider);
  if (await mic.status() != MicStatus.undetermined) return;
  await mic.ensure();
}
