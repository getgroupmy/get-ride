// Settings → Permissions: everything GET.ride asks the phone for, why, and
// where each stands, with the way to change it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_permissions.dart';
import '../../data/permission_probe.dart';

final permissionStatusesProvider = FutureProvider.autoDispose<Map<AppPermission, PermState>>(
  (ref) => ref.watch(permissionProbeProvider).statuses(),
);

IconData permissionIcon(AppPermission p) => switch (p) {
  AppPermission.notifications => Icons.notifications_outlined,
  AppPermission.location => Icons.location_on_outlined,
  AppPermission.microphone => Icons.mic_none,
  AppPermission.camera => Icons.photo_camera_outlined,
  AppPermission.bluetooth => Icons.bluetooth,
  AppPermission.fullScreenCalls => Icons.phone_in_talk_outlined,
};

class PermissionsCard extends ConsumerStatefulWidget {
  const PermissionsCard({super.key});

  @override
  ConsumerState<PermissionsCard> createState() => _PermissionsCardState();
}

class _PermissionsCardState extends ConsumerState<PermissionsCard> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from the phone's Settings: show what changed there.
    _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(permissionStatusesProvider));
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _change(AppPermission p, PermState s) async {
    final probe = ref.read(permissionProbeProvider);
    if (s == PermState.notAsked) {
      await probe.request(p);
    } else {
      await probe.openAppSettings();
    }
    if (mounted) ref.invalidate(permissionStatusesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final statuses = ref.watch(permissionStatusesProvider);
    return Card(
      key: const ValueKey('permissions-card'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Permissions', style: t.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                'What GET.ride needs to work fully. Tap one to change it.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
            switch (statuses) {
              AsyncData(:final value) => Column(
                children: [
                  for (final e in value.entries)
                    ListTile(
                      key: ValueKey('permission-${e.key.name}'),
                      leading: Icon(permissionIcon(e.key)),
                      title: Text(e.key.title),
                      subtitle: Text(e.key.why),
                      trailing: PermissionStatusChip(permission: e.key, state: e.value),
                      onTap: e.value == PermState.granted || e.value == PermState.unknown
                          ? null
                          : () => unawaited(_change(e.key, e.value)),
                    ),
                ],
              ),
              AsyncError() => ListTile(
                title: const Text("Couldn't read the permissions"),
                trailing: TextButton(
                  onPressed: () => ref.invalidate(permissionStatusesProvider),
                  child: const Text('Try again'),
                ),
              ),
              _ => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))),
              ),
            },
            if (statuses.value?.entries.any((e) => e.value != PermState.granted && e.value != PermState.unknown) ??
                false)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: OutlinedButton.icon(
                  key: const ValueKey('permissions-open-settings'),
                  onPressed: () => unawaited(ref.read(permissionProbeProvider).openAppSettings()),
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Open Settings'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Where one permission stands, coloured from the theme (light and dark).
class PermissionStatusChip extends StatelessWidget {
  const PermissionStatusChip({super.key, required this.permission, required this.state});
  final AppPermission permission;
  final PermState state;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (bg, fg) = switch (state) {
      PermState.granted => (c.primaryContainer, c.onPrimaryContainer),
      PermState.limited => (c.tertiaryContainer, c.onTertiaryContainer),
      PermState.denied => (c.errorContainer, c.onErrorContainer),
      PermState.notAsked || PermState.unknown => (c.surfaceContainerHighest, c.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Text(
        permStateLabel(permission, state),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
      ),
    );
  }
}
