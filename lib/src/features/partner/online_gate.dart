// Before a driver goes online: what Admin → App Settings → Permissions holds
// partners to (by default location switched on, allowed, "Always" on an
// iPhone, and notifications allowed; each can be bypassed). Otherwise a
// dialog says what to change and takes them there; they stay offline until
// it's done.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_permissions.dart';
import '../../data/permission_probe.dart';
import '../../data/permission_rules.dart';
import '../permissions/permission_actions.dart';
import '../../widgets/page_style_host.dart';

/// How long a trip to Settings may take before going online is given up.
const onlineSettingsWait = Duration(minutes: 2);

/// What holds a partner up now under [checks].
Future<List<PermissionBlock>> currentPermissionBlocks(PermissionProbe probe, PermissionChecks checks) async {
  if (!checks.any) return const [];
  final (on, location) = await probe.location();
  final notifications = checks.notifications ? await probe.notifications() : PermState.unknown;
  return permissionBlocks(
    checks: checks,
    serviceOn: on,
    location: location,
    notifications: notifications,
    platform: defaultTargetPlatform,
    web: kIsWeb,
  );
}

/// True when the driver may go online; shows the way to fix it when not.
Future<bool> ensureOnlineReady(BuildContext context, WidgetRef ref) async {
  final probe = ref.read(permissionProbeProvider);
  PermissionRules rules;
  try {
    rules = await ref.read(permissionRulesProvider.future).timeout(const Duration(seconds: 8));
  } catch (_) {
    rules = PermissionRules.defaults;
  }
  for (var round = 0; round < 6; round++) {
    final blocks = await currentPermissionBlocks(probe, rules.partner);
    if (blocks.isEmpty) return true;
    final block = blocks.first;
    if (!context.mounted) return false;
    final go = await showAppDialog<bool>(id: 'online-gate.ensure-online-ready',
      context: context,
      builder: (c) => OnlineBlockDialog(block: block),
    );
    if (go != true) return false;
    final back = Completer<void>();
    final lifecycle = AppLifecycleListener(
      onResume: () {
        if (!back.isCompleted) back.complete();
      },
    );
    try {
      switch (await resolvePermissionBlock(probe, block)) {
        case PermissionFix.failed:
          return false;
        case PermissionFix.settings:
          // Back from Settings: check again.
          await back.future.timeout(onlineSettingsWait);
        case PermissionFix.asked:
          break;
      }
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
  final PermissionBlock block;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final path = block.settingsPath;
    return AlertDialog(
      key: const ValueKey('online-block'),
      // Long reasons with large phone text scroll instead of running off.
      scrollable: true,
      icon: Icon(permissionBlockIcon(block), color: t.colorScheme.primary),
      title: Text(block.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('To go online: ${block.message}'),
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
          child: Text(permissionBlockAction(block)),
        ),
      ],
    );
  }
}
