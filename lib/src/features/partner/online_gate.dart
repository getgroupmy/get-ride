// Before a driver goes online: location switched on and, on an iPhone,
// allowed "Always", and notifications allowed (onlineBlock). Otherwise a
// dialog says what to change and takes them there; they stay offline until
// it's done.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_permissions.dart';
import '../../data/permission_probe.dart';

/// How long a trip to Settings may take before going online is given up.
const onlineSettingsWait = Duration(minutes: 2);

/// True when the driver may go online; shows the way to fix it when not.
Future<bool> ensureOnlineReady(BuildContext context, WidgetRef ref) async {
  final probe = ref.read(permissionProbeProvider);
  Future<OnlineBlock?> check() async {
    final (on, location) = await probe.location();
    final notifications = await probe.notifications();
    return onlineBlock(
      serviceOn: on,
      location: location,
      notifications: notifications,
      platform: defaultTargetPlatform,
      web: kIsWeb,
    );
  }

  for (var round = 0; round < 4; round++) {
    final block = await check();
    if (block == null) return true;
    if (!context.mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => OnlineBlockDialog(block: block),
    );
    if (go != true) return false;
    // Asking may settle it here (iOS offers Always once; Android asks for
    // notifications until refused twice); otherwise it's the phone's Settings.
    if (block != OnlineBlock.serviceOff && block != OnlineBlock.locationOff) {
      if (block.isLocation) {
        await probe.requestLocation();
      } else {
        await probe.request(AppPermission.notifications);
      }
      final after = await check();
      if (after == null) return true;
      if (after != block || block == OnlineBlock.locationNotAsked || block == OnlineBlock.notificationsNotAsked) {
        continue;
      }
    }
    final back = Completer<void>();
    final lifecycle = AppLifecycleListener(
      onResume: () {
        if (!back.isCompleted) back.complete();
      },
    );
    try {
      final opened = block == OnlineBlock.serviceOff
          ? await probe.openLocationSettings()
          : await probe.openAppSettings();
      if (!opened) return false;
      await back.future.timeout(onlineSettingsWait);
    } on TimeoutException {
      return false;
    } finally {
      lifecycle.dispose();
    }
  }
  return false;
}

/// What the driver must change before going online, and the button that
/// takes them there.
class OnlineBlockDialog extends StatelessWidget {
  const OnlineBlockDialog({super.key, required this.block});
  final OnlineBlock block;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final action = switch (block) {
      OnlineBlock.serviceOff => 'Open Location settings',
      OnlineBlock.locationNotAsked => 'Allow location',
      OnlineBlock.notAlways => 'Allow Always',
      OnlineBlock.notificationsNotAsked => 'Allow notifications',
      OnlineBlock.locationOff || OnlineBlock.notificationsOff => 'Open Settings',
    };
    final path = block.settingsPath;
    return AlertDialog(
      key: const ValueKey('online-block'),
      icon: Icon(
        block.isLocation ? Icons.location_on_outlined : Icons.notifications_active_outlined,
        color: t.colorScheme.primary,
      ),
      title: Text(block.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(block.message),
          if (path != null) ...[
            const SizedBox(height: 12),
            Text(path, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 12),
          Text(
            'You stay offline until this is done.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        FilledButton(
          key: const ValueKey('online-block-fix'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    );
  }
}
