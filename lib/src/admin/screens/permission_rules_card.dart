// Admin → App Settings → Permissions (migration 0196): what riders are held
// to before the home map and partners before going online, each check
// enforced or bypassed, and whether the app's Settings shows the
// Permissions card.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_permissions.dart';
import '../../data/permission_rules.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

class PermissionRulesCard extends ConsumerWidget {
  const PermissionRulesCard({super.key, required this.canEdit});

  final bool canEdit;

  Future<void> _save(BuildContext context, WidgetRef ref, PermissionRules rules) async {
    final ok = await runAdminAction(
      context,
      () => savePermissionRules(ref.read(supabaseProvider), rules),
      success: 'Saved',
    );
    if (ok) ref.invalidate(permissionRulesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('permission-rules-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(permissionRulesProvider),
          onRetry: () => ref.invalidate(permissionRulesProvider),
          data: (rules) {
            Widget rule(String key, String title, String subtitle, bool value, PermissionRules Function(bool) next) =>
                SwitchListTile(
                  key: ValueKey('permission-rule-$key'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(title),
                  subtitle: Text('$subtitle\n${value ? 'Enforced' : 'Bypassed'}'),
                  isThreeLine: true,
                  value: value,
                  onChanged: canEdit ? (v) => _save(context, ref, next(v)) : null,
                );
            Widget section(String title, String detail) => Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text(detail, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ],
              ),
            );
            PermissionRules user(PermissionChecks c) =>
                PermissionRules(user: c, partner: rules.partner, showPermissionsCard: rules.showPermissionsCard);
            PermissionRules partner(PermissionChecks c) =>
                PermissionRules(user: rules.user, partner: c, showPermissionsCard: rules.showPermissionsCard);
            final u = rules.user, p = rules.partner;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Permissions', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'What the app waits for before letting people on. Enforced: a page says what to switch on and '
                  'they can\'t go further until it\'s done. Bypassed: not checked.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                section('Users', 'After signing in, before the home map.'),
                rule(
                  'user-location-service',
                  'Location switched on',
                  'The phone\'s Location setting.',
                  u.locationService,
                  (v) => user(u.copyWith(locationService: v)),
                ),
                rule(
                  'user-location',
                  'Location allowed',
                  'GET.ride allowed to use the location.',
                  u.location,
                  (v) => user(u.copyWith(location: v)),
                ),
                rule(
                  'user-notifications',
                  'Notifications allowed',
                  'Apple may reject an app that requires notifications to use it (App Store guideline 4.5.4).',
                  u.notifications,
                  (v) => user(u.copyWith(notifications: v)),
                ),
                section('Partners', 'Before going online.'),
                rule(
                  'partner-location-service',
                  'Location switched on',
                  'The phone\'s Location setting.',
                  p.locationService,
                  (v) => partner(p.copyWith(locationService: v)),
                ),
                rule(
                  'partner-location',
                  'Location allowed',
                  'GET.ride allowed to use the location.',
                  p.location,
                  (v) => partner(p.copyWith(location: v)),
                ),
                rule(
                  'partner-location-always',
                  'Location set to Always',
                  'iPhone only. Android keeps an online partner\'s location with "While using the app".',
                  p.locationAlways,
                  (v) => partner(p.copyWith(locationAlways: v)),
                ),
                rule(
                  'partner-notifications',
                  'Notifications allowed',
                  'So partners hear ride requests and calls.',
                  p.notifications,
                  (v) => partner(p.copyWith(notifications: v)),
                ),
                section('App Settings page', 'The app\'s Settings → Permissions card.'),
                SwitchListTile(
                  key: const ValueKey('permission-rule-show-card'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show the Permissions card'),
                  subtitle: Text(rules.showPermissionsCard ? 'Shown' : 'Hidden'),
                  value: rules.showPermissionsCard,
                  onChanged: canEdit
                      ? (v) => _save(
                          context,
                          ref,
                          PermissionRules(user: rules.user, partner: rules.partner, showPermissionsCard: v),
                        )
                      : null,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
