// What the app asks the phone for, and why (migration 0333): shown after
// sign-in (the store review account every time, everyone else once and
// again after an update adds a permission). OK only explains: the phone's
// own questions still come where the app asks them, after its own page
// where one is due (background location's prominent disclosure).
import 'package:flutter/material.dart';

import '../core/store_review.dart';
import 'page_style_host.dart';

IconData permissionNoticeIcon(String id) => switch (id) {
  'location' => Icons.location_on_outlined,
  'location-background' => Icons.share_location_outlined,
  'notifications' => Icons.notifications_active_outlined,
  'camera' => Icons.photo_camera_outlined,
  'photos' => Icons.photo_library_outlined,
  'microphone' => Icons.mic_none_outlined,
  'calls' => Icons.call_outlined,
  'bluetooth' => Icons.bluetooth,
  'local-network' => Icons.wifi_outlined,
  _ => Icons.verified_user_outlined,
};

/// Shows the notice over [context]'s navigator; returns once OK is tapped,
/// with whether "Send me news and offers" was ticked (unticked by default).
Future<bool> showPermissionsNotice(BuildContext context, {NoticePlatform? platform}) async =>
    await showAppDialog<bool>(
      id: 'notice.permissions',
      context: context,
      barrierDismissible: false,
      builder: (_) => PermissionsNoticeDialog(items: permissionNoticeFor(platform)),
    ) ==
    true;

class PermissionsNoticeDialog extends StatefulWidget {
  const PermissionsNoticeDialog({super.key, required this.items});

  final List<PermissionNoticeItem> items;

  @override
  State<PermissionsNoticeDialog> createState() => _PermissionsNoticeDialogState();
}

class _PermissionsNoticeDialogState extends State<PermissionsNoticeDialog> {
  bool _news = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return AlertDialog(
      key: const ValueKey('permissions-notice'),
      scrollable: true,
      icon: Icon(Icons.verified_user_outlined, color: t.colorScheme.primary),
      title: const Text('What GET.ride asks your phone for'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your phone asks you about each of these when the app first needs it. You can change them any time in '
            'your phone\'s Settings. Tap one to read what it is for, who sees it and when it runs.',
            style: t.textTheme.bodyMedium?.copyWith(color: muted),
          ),
          const SizedBox(height: 8),
          for (final i in widget.items)
            Theme(
              data: t.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: ValueKey('permissions-notice-${i.id}'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(left: 40, bottom: 8),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                initiallyExpanded: i.id == 'location-background',
                leading: Icon(permissionNoticeIcon(i.id), color: t.colorScheme.primary),
                title: Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(i.title, style: t.textTheme.titleSmall),
                    if (i.driverOnly)
                      Container(
                        key: ValueKey('permissions-notice-driver-${i.id}'),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: t.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Driver mode',
                          style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSecondaryContainer),
                        ),
                      ),
                  ],
                ),
                children: [Text(i.why, style: t.textTheme.bodySmall?.copyWith(color: muted))],
              ),
            ),
          const Divider(),
          CheckboxListTile(
            key: const ValueKey('permissions-notice-news'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _news,
            onChanged: (v) => setState(() => _news = v ?? false),
            title: const Text(newsOffersChoice),
            subtitle: const Text('Occasional announcements and promotions, by notification and by SMS. Change it '
                'any time in Settings > Notifications > News and offers, or reply STOP to a promotion SMS.'),
          ),
        ],
      ),
      actions: [
        FilledButton(
          key: const ValueKey('permissions-notice-ok'),
          onPressed: () => Navigator.pop(context, _news),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
