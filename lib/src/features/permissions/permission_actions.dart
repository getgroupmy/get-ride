// What fixes each [PermissionBlock]: the phone's own question where it can
// still be shown, its Settings where only they can change it. Shared by the
// rider's permissions page, the partner's go-online check, the map's locate
// button and Settings → Permissions.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_permissions.dart';
import '../../core/permission_ask.dart';
import '../../data/permission_probe.dart';
import '../../widgets/page_style_host.dart';

/// The button that fixes [block].
String permissionBlockAction(PermissionBlock block) => switch (block) {
  PermissionBlock.serviceOff => 'Open Location settings',
  PermissionBlock.locationNotAsked => 'Allow location',
  PermissionBlock.notAlways => 'Allow Always',
  PermissionBlock.notAllTheTime => 'Allow all the time',
  PermissionBlock.notificationsNotAsked => 'Allow notifications',
  PermissionBlock.locationOff || PermissionBlock.notificationsOff => kIsWeb ? 'How to allow' : 'Open settings',
};

/// The one-line hint under the button, where only Settings can help.
String? permissionBlockHint(PermissionBlock block, {bool web = kIsWeb}) => switch (block) {
  PermissionBlock.locationOff => askBlockedHint(AskKind.location, web: web),
  PermissionBlock.notificationsOff => askBlockedHint(AskKind.notifications, web: web),
  _ => null,
};

IconData permissionBlockIcon(PermissionBlock block) =>
    block.isLocation ? Icons.location_on_outlined : Icons.notifications_active_outlined;

/// How a fix went: asked here ([asked]), sent to the phone's Settings
/// ([settings], the answer comes when the app is in front again), Settings
/// could not be opened ([failed]), or the explanation was put away
/// ([declined]).
enum PermissionFix { asked, settings, failed, declined }

/// Asks for [kind] again where the phone still shows its question. Where it
/// won't (refused for good, which it answers at once, without a question),
/// says so and offers the app's Settings; with [explain] off the button
/// already said "Open settings", so they open at once. The phone's Location
/// switched off offers the Location settings. The browser's own switches
/// can't be opened from the page: it says where they are.
Future<PermissionFix> askPermission(
  BuildContext context,
  PermissionProbe probe,
  AskKind kind, {
  bool explain = true,
  bool web = kIsWeb,
}) async {
  final r = await probe.ask(kind);
  final serviceOff = r.answer == AskAnswer.serviceOff;
  switch (r.answer) {
    case AskAnswer.granted || AskAnswer.denied || AskAnswer.unsupported:
      return PermissionFix.asked;
    case AskAnswer.blocked when r.prompted:
      // Refused just now in the phone's own question: no more questions.
      return PermissionFix.asked;
    case AskAnswer.blocked || AskAnswer.serviceOff:
      break;
  }
  if (explain || web) {
    if (!context.mounted) return PermissionFix.declined;
    final go = await showPermissionSettingsDialog(context, kind, serviceOff: serviceOff, web: web);
    if (!go) return PermissionFix.declined;
  }
  final opening = serviceOff
      ? probe.openLocationSettings()
      : kind == AskKind.notifications
      ? probe.openNotificationSettings()
      : probe.openAppSettings();
  return await opening ? PermissionFix.settings : PermissionFix.failed;
}

/// Why the phone won't ask, and the way to its Settings: true when "Open
/// settings" was tapped. The browser gets where to allow it, and no button.
Future<bool> showPermissionSettingsDialog(
  BuildContext context,
  AskKind kind, {
  bool serviceOff = false,
  bool web = kIsWeb,
}) async {
  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  final go = await showAppDialog<bool>(id: 'permissions.open_settings',
    context: context,
    builder: (c) => PermissionSettingsDialog(kind: kind, serviceOff: serviceOff, web: web, ios: ios),
  );
  return go == true;
}

/// The explanation itself.
class PermissionSettingsDialog extends StatelessWidget {
  const PermissionSettingsDialog({
    super.key,
    required this.kind,
    this.serviceOff = false,
    this.web = false,
    this.ios = false,
  });

  final AskKind kind;
  final bool serviceOff;
  final bool web;
  final bool ios;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final location = kind == AskKind.location;
    return AlertDialog(
      key: const ValueKey('permission-settings'),
      scrollable: true,
      icon: Icon(
        location ? Icons.location_off_outlined : Icons.notifications_off_outlined,
        color: t.colorScheme.primary,
      ),
      title: Text(askBlockedTitle(kind, serviceOff: serviceOff)),
      content: Text(askBlockedMessage(kind, serviceOff: serviceOff, web: web, ios: ios)),
      actions: [
        if (web)
          FilledButton(
            key: const ValueKey('permission-settings-ok'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('OK'),
          )
        else ...[
          TextButton(
            key: const ValueKey('permission-settings-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const ValueKey('permission-settings-open'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(serviceOff ? 'Open Location settings' : 'Open settings'),
          ),
        ],
      ],
    );
  }
}

/// Tries to fix [block]: asks again where the phone still can, and where it
/// can't, explains (in [context]) and opens its Settings.
Future<PermissionFix> resolvePermissionBlock(BuildContext context, PermissionProbe probe, PermissionBlock block) async {
  Future<PermissionFix> open(Future<bool> opening) async =>
      await opening ? PermissionFix.settings : PermissionFix.failed;
  switch (block) {
    case PermissionBlock.serviceOff:
      return open(probe.openLocationSettings());
    case PermissionBlock.locationNotAsked:
      return askPermission(context, probe, AskKind.location);
    case PermissionBlock.notAlways:
      // iOS offers "Change to Always Allow" once; after that only Settings can.
      if (await probe.requestLocation() == PermState.granted) return PermissionFix.asked;
      return open(probe.openAppSettings());
    case PermissionBlock.notAllTheTime:
      // Android 11+ answers with the app's Location page, where "Allow all
      // the time" is picked; refused before, only the app's Settings can.
      if (await probe.requestLocationAlways() == PermState.granted) return PermissionFix.asked;
      return open(probe.openAppSettings());
    case PermissionBlock.locationOff:
      // The button said "Open settings": asked first all the same (Settings
      // may have put it back to "Ask every time"), else straight there.
      return askPermission(context, probe, AskKind.location, explain: false);
    case PermissionBlock.notificationsNotAsked:
      return askPermission(context, probe, AskKind.notifications);
    case PermissionBlock.notificationsOff:
      return askPermission(context, probe, AskKind.notifications, explain: false);
  }
}
