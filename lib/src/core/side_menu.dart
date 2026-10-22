/// The rider and driver menus as Admin → Display Settings → Side Menus
/// arranges them (Expo `MenuSideSheet` / `PartnerSideSheet`): built-in items
/// plus the admin's own, renamed, relinked, hidden, marked "coming soon" and
/// reordered. Pure: the screens only draw the result.
library;

import '../admin/screens/meterapp/display_logic.dart';
import 'expo_routes.dart';

class MenuEntry {
  const MenuEntry({
    required this.id,
    required this.label,
    required this.custom,
    this.iconName,
    this.route,
    this.overridden = false,
    this.comingSoon = false,
  });

  final String id;
  final String label;
  final bool custom;

  /// The item's icon: a custom item's, or the one the admin gave a built-in
  /// item; an Expo icon name or a Media Gallery upload (`media:<id>`). Null
  /// for a built-in item that keeps its icon in code.
  final String? iconName;

  /// Where the item goes in this app: the admin's link when they set one,
  /// translated from its Expo path; null for a built-in item that keeps its
  /// own behaviour, or a link with no screen here.
  final String? route;

  /// Whether the admin relinked a built-in item.
  final bool overridden;
  final bool comingSoon;
}

/// [menu] is `'user'` or `'partner'`; [settings] the display blob.
List<MenuEntry> resolveSideMenu(Map<String, dynamic> settings, String menu) {
  final cfg = normalizeMenu(settings[menu == 'user' ? 'userMenu' : 'partnerMenu']);
  final renames = (cfg['renames'] as Map).cast<String, String>();
  final routes = (cfg['routes'] as Map).cast<String, String>();
  final icons = (cfg['icons'] as Map).cast<String, String>();
  final hidden = (cfg['hidden'] as List).cast<String>().toSet();
  final soon = (cfg['comingSoon'] as List).cast<String>().toSet();
  final order = (cfg['order'] as List).cast<String>();
  final natural = <MenuEntry>[
    for (final (id, label) in defaultMenuItems(menu))
      MenuEntry(
        id: id,
        label: renames[id] ?? label,
        custom: false,
        iconName: icons[id],
        route: routes[id] == null ? null : flutterRouteFor(routes[id]),
        overridden: routes[id] != null,
        comingSoon: soon.contains(id),
      ),
    for (final c in (cfg['customItems'] as List).cast<Map<String, dynamic>>())
      MenuEntry(
        id: c['id'] as String,
        label: c['label'] as String,
        custom: true,
        iconName: c['iconName'] as String?,
        route: flutterRouteFor(c['route'] as String?),
        comingSoon: soon.contains(c['id']),
      ),
  ];
  final visible = [
    for (final e in natural)
      if (!hidden.contains(e.id)) e,
  ];
  // An item the saved order doesn't name (one added to the app after the
  // admin arranged the menu) goes after the item it follows by default
  // when the admin placed that one, or when it was itself placed that way,
  // so a run of new items stays together; otherwise at the end, as before.
  final placed = [...order];
  final next = <String, int>{};
  final chained = <String>{};
  for (var i = 0; i < natural.length; i++) {
    final id = natural[i].id;
    if (placed.contains(id)) continue;
    final anchor = i == 0 ? null : natural[i - 1].id;
    if (anchor == null || !(order.contains(anchor) || chained.contains(anchor))) {
      placed.add(id);
      continue;
    }
    final at = next[anchor] ?? placed.indexOf(anchor) + 1;
    placed.insert(at, id);
    chained.add(id);
    next[anchor] = at + 1;
    next.updateAll((k, v) => k != anchor && v >= at ? v + 1 : v);
  }
  // Log out / Sign out stays the last row unless the admin put it elsewhere.
  for (final id in const ['logout', 'sign-out']) {
    if (placed.contains(id) && (order.isEmpty || !order.contains(id) || order.last == id)) {
      placed
        ..remove(id)
        ..add(id);
    }
  }
  int rank(MenuEntry e) => placed.indexOf(e.id);

  visible.sort((a, b) => rank(a).compareTo(rank(b)));
  return visible;
}

/// The profile header at the top of a menu: whether it shows, and whether
/// the admin marked it "coming soon" (Display → Side Menus → Profile).
({bool show, bool comingSoon}) sideMenuProfile(Map<String, dynamic> settings, String menu) {
  final cfg = normalizeMenu(settings[menuKey(menu)]);
  return (
    show: !(cfg['hidden'] as List).contains(profileMenuItemId),
    comingSoon: (cfg['comingSoon'] as List).contains(profileMenuItemId),
  );
}

/// The footer mode switch ("Partner Mode" / "Passenger Mode"): its label,
/// or null when hidden; [comingSoon] when the admin marked it so.
({String label, bool comingSoon})? sideMenuModeButton(Map<String, dynamic> settings, String menu) {
  final cfg = normalizeMenu(settings[menu == 'user' ? 'userMenu' : 'partnerMenu']);
  final id = menu == 'user' ? partnerModeMenuItemId : passengerModeMenuItemId;
  if ((cfg['hidden'] as List).contains(id)) return null;
  final label =
      (cfg['renames'] as Map)[id] as String? ?? (menu == 'user' ? partnerModeDefaultLabel : passengerModeDefaultLabel);
  return (label: label, comingSoon: (cfg['comingSoon'] as List).contains(id));
}

const comingSoonTitle = 'Coming Soon';
const comingSoonBody = "This feature isn't available yet.";
