import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/admin_providers.dart';
import '../../admin/screens/meterapp/display_logic.dart' show normalizeMenu, profileMenuItemId;
import '../../app.dart' show brandAccent;
import '../../core/side_menu.dart';
import '../../data/app_display_repository.dart';
import '../../providers.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/side_menu_tiles.dart';
import '../profile/account_screen.dart' show riderMenuAction;

/// The rider's pages under the Expo side menu ([SideMenuHost]): on phones,
/// everywhere but driver mode, which has a menu of its own.
class RiderSideMenuHost extends StatelessWidget {
  const RiderSideMenuHost({super.key, required this.location, required this.child});

  /// Where the app is, which decides whether the menu applies.
  final String location;
  final Widget child;

  /// Whether the rider menu applies at [location] on a screen [width] wide:
  /// phones only (wider screens have the rail), and not in driver mode.
  static bool appliesAt(String location, double width) =>
      width < 720 && !(location == '/drive' || location.startsWith('/drive/'));

  @override
  Widget build(BuildContext context) => SideMenuHost(
    enabled: appliesAt(location, MediaQuery.sizeOf(context).width),
    menu: const RiderSideMenu(),
    child: child,
  );
}

/// What the rider's stars show until ratings of riders are kept (Expo
/// shows a fixed figure too), so the stars and the number agree.
const riderMenuRating = 5.0;

/// The side menu's panel, as Expo's `MenuSideSheet`: who is signed in with
/// their stars, the admin's rider menu as plain rows, then the driver mode
/// button and the social links. Every row closes the menu before it opens
/// its page.
class RiderSideMenu extends ConsumerWidget {
  const RiderSideMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final close = SideMenuHost.of(context)?.close;
    final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
    final menu = resolveSideMenu(blob, 'user');
    final mode = sideMenuModeButton(blob, 'user');
    final profileHidden = (normalizeMenu(blob['userMenu'])['hidden'] as List).contains(profileMenuItemId);
    final isAdmin = ref.watch(adminAccessProvider).value?.isAdmin ?? false;
    final profile = ref.watch(profileProvider).value;
    final divider = Divider(height: 1, thickness: 1, color: t.colorScheme.outlineVariant);
    void go(String route) {
      final router = GoRouter.of(context);
      close?.call();
      router.go(route);
    }

    return Material(
      key: const ValueKey('rider-side-menu'),
      color: t.colorScheme.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            if (!profileHidden) ...[
              InkWell(
                key: const ValueKey('menu-profile'),
                onTap: () => go('/account/edit'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: t.colorScheme.surfaceContainerHighest,
                        backgroundImage: profile?.avatarUrl != null ? NetworkImage(profile!.avatarUrl!) : null,
                        child: profile?.avatarUrl == null
                            ? Icon(Icons.sentiment_satisfied_alt, size: 30, color: t.colorScheme.onSurfaceVariant)
                            : null,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              profile?.name ?? 'Add your name',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              key: const ValueKey('menu-rating'),
                              children: [
                                for (var i = 1; i <= 5; i++)
                                  Icon(
                                    i <= riderMenuRating.round() ? Icons.star_rounded : Icons.star_outline_rounded,
                                    size: 18,
                                    color: const Color(0xFFFF9F0A),
                                  ),
                                const SizedBox(width: 8),
                                Text(riderMenuRating.toStringAsFixed(1), style: t.textTheme.bodyMedium),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: t.colorScheme.onSurface),
                    ],
                  ),
                ),
              ),
              divider,
            ],
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  for (final e in menu)
                    SideMenuTile(
                      entry: e,
                      plain: true,
                      color: e.id == 'logout' ? t.colorScheme.error : null,
                      beforeOpen: close,
                      builtIn: (c, id) => riderMenuAction(c, ref, id, beforeOpen: close),
                    ),
                  // This app's own rows, which the Expo menu does not list.
                  ListTile(
                    key: const ValueKey('menu-emergency'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 22),
                    minVerticalPadding: 14,
                    leading: Icon(Icons.contact_emergency_outlined, size: 26, color: t.colorScheme.onSurfaceVariant),
                    title: Text('Emergency contacts', style: t.textTheme.titleMedium?.copyWith(fontSize: 18)),
                    onTap: () => go('/account/emergency'),
                  ),
                  ListTile(
                    key: const ValueKey('menu-invite'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 22),
                    minVerticalPadding: 14,
                    leading: Icon(Icons.card_giftcard, size: 26, color: t.colorScheme.onSurfaceVariant),
                    title: Text('Invite friends', style: t.textTheme.titleMedium?.copyWith(fontSize: 18)),
                    onTap: () => go('/account/referral'),
                  ),
                ],
              ),
            ),
            divider,
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                children: [
                  if (mode != null)
                    FilledButton(
                      key: const ValueKey('menu-partner-mode'),
                      style: FilledButton.styleFrom(
                        backgroundColor: brandAccent,
                        foregroundColor: Colors.black,
                        minimumSize: const Size.fromHeight(56),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                      ),
                      onPressed: () => mode.comingSoon ? showComingSoon(context) : go('/drive'),
                      child: Text(mode.label),
                    ),
                  if (isAdmin) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      key: const ValueKey('menu-admin'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                      label: const Text('Admin panel'),
                      onPressed: () => go('/admin'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const _SocialLinks(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// TikTok, Facebook and Instagram, as at the foot of Expo's menu.
class _SocialLinks extends StatelessWidget {
  const _SocialLinks();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurface;
    Widget link(String name, Widget icon) => Tooltip(
      message: 'GET.ride on $name',
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: icon),
    );
    return Row(
      key: const ValueKey('menu-social'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        link('TikTok', Icon(Icons.tiktok, size: 32, color: c)),
        link('Facebook', Icon(Icons.facebook, size: 32, color: c)),
        link('Instagram', CustomPaint(size: const Size.square(30), painter: _InstagramGlyph(c))),
      ],
    );
  }
}

/// Instagram's camera outline: a rounded square, a lens and a dot (Material
/// icons have no Instagram).
class _InstagramGlyph extends CustomPainter {
  const _InstagramGlyph(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.09;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.06, w * 0.06, w * 0.88, w * 0.88), Radius.circular(w * 0.26)),
      line,
    );
    canvas.drawCircle(Offset(w / 2, w / 2), w * 0.2, line);
    canvas.drawCircle(Offset(w * 0.74, w * 0.26), w * 0.055, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_InstagramGlyph old) => old.color != color;
}
