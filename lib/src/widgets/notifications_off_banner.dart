import 'package:flutter/material.dart';

import 'app_notice.dart';

/// What the popup says when notifications are off for the app.
const notificationsOffTitle = 'Notifications are off';
const notificationsOffText = "Notifications are off. You won't hear calls or new rides while GET.ride is closed.";

/// The warning shown over the rider's and driver's screens when
/// notifications are off for the app (PushService.notificationsOff): a popup
/// with an (x) and the way to Settings to switch them on. Completes when it
/// is closed, by the (x), Close, Open Settings or by itself (Admin →
/// Display → Popups).
Future<void> showNotificationsOffNotice({required BuildContext context, required VoidCallback onSettings}) =>
    showAppNotice(
      id: 'notice.notifications-off',
      context: context,
      key: const ValueKey('notifications-off'),
      title: notificationsOffTitle,
      message: notificationsOffText,
      kind: NoticeKind.error,
      actionLabel: 'Open Settings',
      onAction: onSettings,
    );
