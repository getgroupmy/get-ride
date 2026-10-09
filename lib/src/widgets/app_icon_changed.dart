// The one-time "App icon updated" popup (Expo `AppIconChangeModal`): shown
// once on each device after the admin publishes a new app icon (Admin → App
// Settings → App Icon), with the new icon in it.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_branding.dart';
import 'net_image.dart';

const _seenKey = 'app_icon_seen_at';

/// Whether [b]'s icon change is one this device has yet to be told about;
/// records it as seen either way, so it is asked once. A device seeing the
/// row for the first time only records it: a fresh install never saw the
/// old icon.
Future<bool> takeIconChange(AppBranding b) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final firstLook = !prefs.containsKey(_seenKey);
    final seen = DateTime.tryParse(prefs.getString(_seenKey) ?? '');
    final changed = b.iconChangedAt;
    final show = iconChangeUnseen(changed, seen, firstLook: firstLook);
    if (firstLook || show) await prefs.setString(_seenKey, changed?.toUtc().toIso8601String() ?? '');
    return show;
  } catch (_) {
    return false;
  }
}

Future<void> showAppIconChanged(BuildContext context, String? iconUrl) => showDialog<void>(
  context: context,
  builder: (c) {
    final t = Theme.of(c);
    final fallback = Icon(Icons.apps, size: 40, color: t.colorScheme.primary);
    return AlertDialog(
      key: const ValueKey('app-icon-changed'),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 88,
            height: 88,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: t.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: t.colorScheme.outlineVariant),
            ),
            child: iconUrl == null
                ? fallback
                : Image.network(iconUrl, fit: BoxFit.cover, frameBuilder: boneUntilPainted(), errorBuilder: (_, _, _) => fallback),
          ),
          Positioned(
            right: -6,
            bottom: -6,
            child: CircleAvatar(
              radius: 14,
              backgroundColor: const Color(0xFF10B981),
              child: const Icon(Icons.check, size: 16, color: Colors.white),
            ),
          ),
        ],
      ),
      title: const Text('App icon updated'),
      content: const Text(
        'The app icon has been refreshed by the team. Enjoy the new look!',
        textAlign: TextAlign.center,
      ),
      actions: [
        FilledButton(
          key: const ValueKey('app-icon-changed-ok'),
          onPressed: () => Navigator.pop(c),
          child: const Text('Continue'),
        ),
      ],
    );
  },
);
