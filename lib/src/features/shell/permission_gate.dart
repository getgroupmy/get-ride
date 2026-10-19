// Before the rider's home map: what Admin → App Settings → Permissions holds
// riders to (by default the phone's location switched on, GET.ride allowed to
// use it, and notifications allowed; each can be bypassed). Until it's all
// done, a page over the app lists what to switch on, each with the button
// that does it; coming back from Settings checks again. Checked after every
// sign-in and launch, and whenever the app comes back to the front.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_permissions.dart';
import '../../core/push_logic.dart';
import '../../data/permission_probe.dart';
import '../../data/permission_rules.dart';
import '../../providers.dart';
import '../partner/online_gate.dart' show currentPermissionBlocks;
import '../permissions/permission_actions.dart';

class PermissionGate extends ConsumerStatefulWidget {
  const PermissionGate({super.key, required this.child, required this.location, this.listenable, this.enabled});

  final Widget child;

  /// Where the app is now; the page shows on the rider's screens only.
  final String Function() location;

  /// Fires when [location] may have changed (the router).
  final Listenable? listenable;

  /// Null is every phone app (not the web).
  final bool? enabled;

  @override
  ConsumerState<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends ConsumerState<PermissionGate> {
  AppLifecycleListener? _lifecycle;
  List<PermissionBlock> _blocks = const [];
  bool _inRiderArea = false;
  bool _checking = false;
  bool _again = false;

  bool get _enabled => widget.enabled ?? !kIsWeb;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    widget.listenable?.addListener(_routeChanged);
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_check()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _routeChanged());
  }

  @override
  void dispose() {
    widget.listenable?.removeListener(_routeChanged);
    _lifecycle?.dispose();
    super.dispose();
  }

  void _routeChanged() {
    if (!mounted) return;
    final rider = pushModeAt(widget.location(), null) == 'rider';
    if (rider == _inRiderArea) return;
    _inRiderArea = rider;
    unawaited(_check());
  }

  Future<void> _check() async {
    if (!mounted) return;
    if (_checking) {
      _again = true;
      return;
    }
    _checking = true;
    try {
      do {
        _again = false;
        var blocks = const <PermissionBlock>[];
        if (_inRiderArea && ref.read(currentUserIdProvider) != null) {
          PermissionRules rules;
          try {
            rules = await ref.read(permissionRulesProvider.future).timeout(const Duration(seconds: 8));
          } catch (_) {
            rules = PermissionRules.defaults;
          }
          blocks = await currentPermissionBlocks(ref.read(permissionProbeProvider), rules.user);
        }
        if (!mounted) return;
        if (!listEquals(blocks, _blocks)) setState(() => _blocks = blocks);
      } while (_again);
    } finally {
      _checking = false;
    }
  }

  /// Under the page's own navigator, so an explanation shows over the page
  /// (the gate sits above the app's navigator).
  final _page = GlobalKey<NavigatorState>();

  Future<void> _fix(PermissionBlock block) async {
    final context = _page.currentContext ?? this.context;
    await resolvePermissionBlock(context, ref.read(permissionProbeProvider), block);
    // Back from a question the app asked: check now. From Settings, the
    // resume does it.
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled) {
      // Signing in or out, and the admin's rules changing, check again.
      ref.listen(currentUserIdProvider, (_, _) => unawaited(_check()));
      ref.listen(permissionRulesProvider, (_, _) => unawaited(_check()));
    }
    if (_blocks.isEmpty) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: HeroControllerScope.none(
            child: Navigator(
              key: _page,
              pages: [
                MaterialPage<void>(
                  key: const ValueKey('permissions-required-page'),
                  child: PermissionsRequiredPage(
                    blocks: _blocks,
                    onFix: (b) => unawaited(_fix(b)),
                    onCheckAgain: () => unawaited(_check()),
                    onSignOut: () => unawaited(ref.read(authRepositoryProvider).signOut()),
                  ),
                ),
              ],
              onDidRemovePage: (_) {},
            ),
          ),
        ),
      ],
    );
  }
}

/// The page itself: what is still needed, each with the button that does it.
class PermissionsRequiredPage extends StatelessWidget {
  const PermissionsRequiredPage({
    super.key,
    required this.blocks,
    required this.onFix,
    required this.onCheckAgain,
    required this.onSignOut,
  });

  final List<PermissionBlock> blocks;
  final ValueChanged<PermissionBlock> onFix;
  final VoidCallback onCheckAgain;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      key: const ValueKey('permissions-required'),
      color: t.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Icon(Icons.verified_user_outlined, size: 48, color: t.colorScheme.primary),
                const SizedBox(height: 16),
                Text('Before you start', style: t.textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'GET.ride needs these to find your pickup, match you with drivers and keep you updated about '
                  'your ride.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                for (final b in blocks)
                  Card(
                    key: ValueKey('permission-block-${b.name}'),
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(permissionBlockIcon(b), color: t.colorScheme.error),
                              const SizedBox(width: 12),
                              Expanded(child: Text(b.title, style: t.textTheme.titleMedium)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(b.message, style: t.textTheme.bodyMedium),
                          if (permissionBlockHint(b) == null && b.settingsPath != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              b.settingsPath!,
                              style: t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ],
                          const SizedBox(height: 12),
                          FilledButton(
                            key: ValueKey('permission-fix-${b.name}'),
                            onPressed: () => onFix(b),
                            child: Text(permissionBlockAction(b)),
                          ),
                          if (permissionBlockHint(b) case final hint?) ...[
                            const SizedBox(height: 6),
                            Text(
                              hint,
                              key: ValueKey('permission-hint-${b.name}'),
                              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                TextButton.icon(
                  key: const ValueKey('permissions-check-again'),
                  onPressed: onCheckAgain,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Check again'),
                ),
                TextButton(
                  key: const ValueKey('permissions-sign-out'),
                  onPressed: onSignOut,
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
