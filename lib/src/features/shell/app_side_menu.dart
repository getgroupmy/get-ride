import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/admin_providers.dart';
import '../../admin/screens/meterapp/display_logic.dart' show normalizeMenu, profileMenuItemId, vehicleInfoMenuItemId;
import '../../app.dart' show brandAccent;
import '../../core/side_menu.dart';
import '../../data/app_display_repository.dart';
import '../../data/obd/obd_session.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/side_menu_tiles.dart';
import '../partner/driver_online.dart';
import '../partner/partner_menu.dart' show partnerMenuAction;
import '../profile/account_screen.dart' show riderMenuAction;

/// Which side menu a page is under.
enum SideMenuMode { rider, partner }

/// The menu at [location], given the one before: driver mode's pages take
/// the driver menu, the rider's own the rider menu, and the pages both
/// share (wallet, settings, support…) keep whichever mode led there.
SideMenuMode sideMenuModeAt(String location, SideMenuMode previous) {
  bool under(String root) => location == root || location.startsWith('$root/');
  if (under('/drive') || location == '/meter/vehicle') return SideMenuMode.partner;
  if (location == '/' || under('/trips') || under('/ride')) return SideMenuMode.rider;
  return previous;
}

/// The app's pages under the Expo side menu ([SideMenuHost]) on phones:
/// the rider menu in user mode, the driver menu in driver mode, the same
/// on every page of each (wider screens have the rail).
class AppSideMenuHost extends StatefulWidget {
  const AppSideMenuHost({super.key, required this.location, required this.child});

  /// Where the app is, which decides the menu.
  final String location;
  final Widget child;

  /// The side menu is for phones; wider screens have the rail.
  static bool appliesAt(double width) => width < 720;

  @override
  State<AppSideMenuHost> createState() => _AppSideMenuHostState();
}

class _AppSideMenuHostState extends State<AppSideMenuHost> {
  late SideMenuMode _mode = sideMenuModeAt(widget.location, SideMenuMode.rider);

  @override
  void didUpdateWidget(covariant AppSideMenuHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _mode = sideMenuModeAt(widget.location, _mode);
  }

  @override
  Widget build(BuildContext context) => SideMenuHost(
    enabled: AppSideMenuHost.appliesAt(MediaQuery.sizeOf(context).width),
    menu: _mode == SideMenuMode.partner ? const PartnerSideMenu() : const RiderSideMenu(),
    child: widget.child,
  );
}

/// What the stars show until ratings are kept per account (Expo shows a
/// fixed figure too), so the stars and the number agree.
const riderMenuRating = 5.0;

/// The rider side menu (Expo `MenuSideSheet`): the admin's rider menu,
/// then the driver mode button.
class RiderSideMenu extends ConsumerWidget {
  const RiderSideMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final close = SideMenuHost.of(context)?.close;
    final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
    final mode = sideMenuModeButton(blob, 'user');
    void go(String route) {
      final router = GoRouter.of(context);
      close?.call();
      router.go(route);
    }

    return SideMenuPanel(
      key: const ValueKey('rider-side-menu'),
      showProfile: !(normalizeMenu(blob['userMenu'])['hidden'] as List).contains(profileMenuItemId),
      rows: [
        for (final e in resolveSideMenu(blob, 'user'))
          SideMenuTile(
            entry: e,
            plain: true,
            color: e.id == 'logout' ? t.colorScheme.error : null,
            beforeOpen: close,
            builtIn: (c, id) => riderMenuAction(c, ref, id, beforeOpen: close),
          ),
        // This app's own rows, which the Expo menu does not list.
        PlainMenuRow(
          key: const ValueKey('menu-emergency'),
          icon: Icons.contact_emergency_outlined,
          label: 'Emergency contacts',
          onTap: () => go('/account/emergency'),
        ),
        PlainMenuRow(
          key: const ValueKey('menu-invite'),
          icon: Icons.card_giftcard,
          label: 'Invite friends',
          onTap: () => go('/account/referral'),
        ),
      ],
      modeLabel: mode?.label,
      modeKey: const ValueKey('menu-partner-mode'),
      onMode: mode == null ? null : () => mode.comingSoon ? showComingSoon(context) : go('/drive'),
    );
  }
}

/// The driver side menu (Expo `PartnerSideSheet`), drawn as the rider's:
/// the admin's driver menu (Vehicle information only while an OBD-II reader
/// is linked), then the passenger mode button, which waits for the driver
/// to go offline.
class PartnerSideMenu extends ConsumerWidget {
  const PartnerSideMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final close = SideMenuHost.of(context)?.close ?? () {};
    final blob = ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{};
    final linked = ref.watch(obdSessionProvider).linked;
    final mode = sideMenuModeButton(blob, 'partner');
    return SideMenuPanel(
      key: const ValueKey('partner-side-menu'),
      showProfile: true,
      onProfile: null,
      rows: [
        for (final e in resolveSideMenu(blob, 'partner'))
          if (e.id != vehicleInfoMenuItemId || linked)
            SideMenuTile(
              entry: e,
              plain: true,
              color: e.id == 'sign-out' ? t.colorScheme.error : null,
              beforeOpen: close,
              builtIn: (c, id) => partnerMenuAction(c, ref, id, close: close),
            ),
      ],
      modeLabel: mode?.label,
      modeKey: const ValueKey('menu-passenger-mode'),
      onMode: mode == null
          ? null
          : () {
              if (mode.comingSoon) {
                showComingSoon(context);
                return;
              }
              // No greyed-out tab to hold a driver online off booking a
              // ride: the lock lives here.
              if (ref.read(driverOnlineProvider)) {
                showInfo(context, 'Go offline to book a ride');
                return;
              }
              final router = GoRouter.of(context);
              close();
              router.go('/');
            },
    );
  }
}

/// A side menu row of this app's own, drawn as the admin's rows.
class PlainMenuRow extends StatelessWidget {
  const PlainMenuRow({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 22),
      minVerticalPadding: 14,
      leading: Icon(icon, size: 26, color: t.colorScheme.onSurfaceVariant),
      title: Text(label, style: t.textTheme.titleMedium?.copyWith(fontSize: 18)),
      onTap: onTap,
    );
  }
}

/// One side menu's layout, the same in both modes (Expo `MenuSideSheet`):
/// who is signed in with their stars, the rows, then a divider, the mode
/// button, the admin panel for admins and the social links.
class SideMenuPanel extends ConsumerWidget {
  const SideMenuPanel({
    super.key,
    required this.rows,
    this.showProfile = true,
    this.onProfile = _editProfile,
    this.modeLabel,
    this.modeKey,
    this.onMode,
  });

  final List<Widget> rows;
  final bool showProfile;

  /// The profile header's tap; null leaves the header as information.
  final void Function(BuildContext context)? onProfile;

  /// The mode button, when shown.
  final String? modeLabel;
  final Key? modeKey;
  final VoidCallback? onMode;

  static void _editProfile(BuildContext context) {
    final router = GoRouter.of(context);
    SideMenuHost.of(context)?.close();
    router.go('/account/edit');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final profile = ref.watch(profileProvider).value;
    final isAdmin = ref.watch(adminAccessProvider).value?.isAdmin ?? false;
    final divider = Divider(height: 1, thickness: 1, color: t.colorScheme.outlineVariant);
    final header = Padding(
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
          if (onProfile != null) Icon(Icons.chevron_right, color: t.colorScheme.onSurface),
        ],
      ),
    );
    return Material(
      color: t.colorScheme.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            if (showProfile) ...[
              onProfile == null
                  ? KeyedSubtree(key: const ValueKey('menu-profile'), child: header)
                  : InkWell(key: const ValueKey('menu-profile'), onTap: () => onProfile!(context), child: header),
              divider,
            ],
            Expanded(
              child: ListView(padding: const EdgeInsets.symmetric(vertical: 4), children: rows),
            ),
            divider,
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                children: [
                  if (modeLabel != null)
                    FilledButton(
                      key: modeKey,
                      style: FilledButton.styleFrom(
                        backgroundColor: brandAccent,
                        foregroundColor: Colors.black,
                        minimumSize: const Size.fromHeight(56),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                      ),
                      onPressed: onMode,
                      child: Text(modeLabel!),
                    ),
                  if (isAdmin) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      key: const ValueKey('menu-admin'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                      label: const Text('Admin panel'),
                      onPressed: () {
                        final router = GoRouter.of(context);
                        SideMenuHost.of(context)?.close();
                        router.go('/admin');
                      },
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
