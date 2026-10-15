import 'package:flutter/material.dart';

/// What the banner says when notifications are off for the app.
const notificationsOffText = "Notifications are off. You won't hear calls or new rides while GET.ride is closed.";

/// The warning shown at the top of the rider's and driver's screens when
/// notifications are off for the app (PushService.notificationsOff), with
/// the way to Settings to switch them on.
MaterialBanner notificationsOffBanner({required VoidCallback onSettings, required VoidCallback onDismiss}) =>
    MaterialBanner(
      key: const ValueKey('notifications-off-banner'),
      leading: Builder(
        builder: (context) => Icon(Icons.notifications_off_outlined, color: Theme.of(context).colorScheme.error),
      ),
      content: const Text(notificationsOffText),
      actions: [
        TextButton(key: const ValueKey('notifications-off-later'), onPressed: onDismiss, child: const Text('Not now')),
        FilledButton(
          key: const ValueKey('notifications-off-settings'),
          onPressed: onSettings,
          child: const Text('Open Settings'),
        ),
      ],
    );
