import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/admin_providers.dart';
import '../../admin/screens/meterapp/display_logic.dart' show normalizeMenu, profileMenuItemId, vehicleInfoMenuItemId;
import '../../core/side_menu.dart';
import '../../data/app_display_repository.dart';
import '../../data/obd/obd_session.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/side_menu_style.dart';
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
            color: e.id == 'logout' ? const Color(0xFFFF6B6B) : null,
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
              color: e.id == 'sign-out' ? const Color(0xFFFF6B6B) : null,
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
                showGoOfflineToBook(context);
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
  Widget build(BuildContext context) => SideMenuRow(icon: icon, label: label, onTap: onTap);
}

/// The user and driver menus' layout ([SideMenuFrame]): who is signed in
/// with their stars, the rows, then the mode button, the admin panel for
/// admins and the social links.
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
    final profile = ref.watch(profileProvider).value;
    final isAdmin = ref.watch(adminAccessProvider).value?.isAdmin ?? false;
    return SideMenuFrame(
      header: showProfile
          ? SideMenuHeader(
              name: profile?.name ?? 'Add your name',
              avatarUrl: profile?.avatarUrl,
              subtitle: const SideMenuStars(rating: riderMenuRating),
              onTap: onProfile == null ? null : () => onProfile!(context),
            )
          : null,
      rows: rows,
      buttonLabel: modeLabel,
      buttonKey: modeKey,
      onButton: onMode,
      footer: [
        if (isAdmin)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: OutlinedButton.icon(
              key: const ValueKey('menu-admin'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                foregroundColor: SideMenuStyle.text,
                side: const BorderSide(color: SideMenuStyle.divider),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: const Text('Admin panel'),
              onPressed: () {
                final router = GoRouter.of(context);
                SideMenuHost.of(context)?.close();
                router.go('/admin');
              },
            ),
          ),
        const SideMenuSocialLinks(),
      ],
    );
  }
}
