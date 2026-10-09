/// Global display settings — the pure half of the Expo
/// `contexts/DisplaySettingsContext.tsx` (normalisation, defaults, side-menu
/// and vehicle-bar edits). The whole blob lives in one row of
/// `admin_display_settings` (`id = 'global'`, column `settings` jsonb), so
/// every edit here is a function from the current blob to the next one; keys
/// this app does not know are carried through untouched.
library;

import 'dart:math' as math;

const displaySettingsTable = 'admin_display_settings';
const displaySettingsRowId = 'global';

const serviceBoxCount = 5;
const recentLocationsMin = 0;
const recentLocationsMax = 8;

const profileMenuItemId = 'profile';
const partnerModeMenuItemId = 'partner-mode-button';
const passengerModeMenuItemId = 'passenger-mode-button';
const partnerModeDefaultLabel = 'Partner Mode';
const passengerModeDefaultLabel = 'Passenger Mode';
const vehicleInfoMenuItemId = 'vehicle-information';
const emergencyContactsMenuItemId = 'emergency-contacts';
const inviteFriendsMenuItemId = 'invite-friends';

const defaultUserMenuItems = <(String, String)>[
  ('teksi-ev', 'Book TEKSI EV'),
  ('city', 'City'),
  ('request-history', 'Request history'),
  ('freight', 'Freight'),
  ('wallet', 'Wallet'),
  ('notifications', 'Notifications'),
  ('safety', 'Safety'),
  ('settings', 'Settings'),
  ('user-guide', 'User Guide'),
  ('support', 'Support'),
  // This app's own rows (the Expo menu has no such items and skips them).
  (emergencyContactsMenuItemId, 'Emergency contacts'),
  (inviteFriendsMenuItemId, 'Invite friends'),
  ('logout', 'Logout'),
];

const defaultPartnerMenuItems = <(String, String)>[
  ('teksi-ev', 'Book TEKSI EV'),
  ('dashboard', 'Dashboard'),
  ('earnings', 'Earnings'),
  ('wallet', 'Wallet'),
  ('trip-history', 'Trip history'),
  ('vehicle', 'Vehicle'),
  (vehicleInfoMenuItemId, 'Vehicle information'),
  ('documents', 'Documents'),
  ('notifications', 'Notifications'),
  ('support', 'Support'),
  ('settings', 'Settings'),
  ('sign-out', 'Sign out'),
];

List<(String, String)> defaultMenuItems(String menu) => menu == 'user' ? defaultUserMenuItems : defaultPartnerMenuItems;

/// Default link of each built-in item (before any admin override).
const defaultMenuRoutes = <String, Map<String, String>>{
  'user': {
    'teksi-ev': '/teksi-ev',
    'city': '/',
    'request-history': '/',
    'freight': '/',
    'wallet': '/wallet',
    'notifications': '/',
    'safety': '/safety',
    'settings': '/settings',
    'user-guide': '/user-guide',
    'support': '/support',
  },
  'partner': {
    'teksi-ev': '/teksi-ev',
    'wallet': '/wallet',
    'documents': '/partner-documents',
    'safety': '/safety',
    'support': '/support',
  },
};

/// Icon names the Expo app understands for custom menu items.
const sideMenuIcons = [
  'Bell', 'BookOpen', 'Car', 'Clock', 'FileText', 'Gift', 'HelpCircle', 'Heart', 'Mail', 'MapPin',
  'MessageCircle', 'Phone', 'Settings', 'Shield', 'Star', 'Tag', 'User', 'Wallet',
];

/// Icon names for the home service boxes (Expo `SERVICE_BOX_ICONS`).
const serviceBoxIcons = [
  'ShoppingBag', 'Car', 'Building2', 'Package', 'Truck', 'Bike', 'Bus', 'Plane', 'MapPin', 'Navigation',
  'Clock', 'Bell',
];

const defaultServiceBoxIcons = ['ShoppingBag', 'Car', 'Building2', 'Package', 'Truck'];

/// Every navigable Expo route, for the "link to page" pickers (stored values
/// are Expo paths, so the Expo app keeps working).
const allAppRoutes = <String>[
  '/', '/onboarding', '/role-selection', '/phone-auth', '/otp-verify', '/pin-setup', '/pin-verify',
  '/change-pin', '/change-number', '/name-entry', '/profile', '/edit-profile', '/profile-photo', '/settings',
  '/dark-mode', '/language', '/distances', '/navigation', '/user-guide', '/rules-terms', '/safety',
  '/emergency-contacts', '/emergency-contact-edit', '/search', '/map-picker', '/offer-fare', '/ride-detail',
  '/ride-confirm', '/ride-running', '/ride-tracking', '/teksi-ev', '/support', '/support-call',
  '/support-chat', '/partner-teksi', '/partner-ehailing', '/partner-onboarding', '/partner-documents',
  '/vehicle-onboarding', '/auth-diagnostics', '/admin-login', '/admin-dashboard', '/admin-orders',
  '/admin-session-history', '/admin-support', '/admin-support-chat', '/admin-support-pool',
  '/admin-partners', '/admin-partners-all', '/admin-partners-approved', '/admin-partners-blocked',
  '/admin-partners-rejected', '/admin-partners-unapproved', '/admin-partners-unapproved-docs',
  '/admin-partners-permit-pending', '/admin-partners-permit-verified', '/admin-partners-permit-non-verified',
  '/admin-partner-add', '/admin-partner-edit', '/admin-users', '/admin-users-all', '/admin-users-approved',
  '/admin-users-blocked', '/admin-users-rejected', '/admin-users-deleted', '/admin-users-unapproved',
  '/admin-users-unapproved-docs', '/admin-user-add', '/admin-user-edit', '/admin-vehicles',
  '/admin-vehicles-all', '/admin-vehicles-approved', '/admin-vehicles-blocked', '/admin-vehicles-rejected',
  '/admin-vehicles-unapproved', '/admin-vehicles-unapproved-docs', '/admin-vehicles-permit-pending',
  '/admin-vehicles-permit-verified', '/admin-vehicles-permit-non-verified', '/admin-vehicle-add',
  '/admin-vehicle-edit', '/admin-documents', '/admin-documents-users', '/admin-documents-partners',
  '/admin-documents-vehicles', '/admin-settings', '/admin-settings-display', '/admin-settings-mock',
  '/admin-settings-site', '/admin-settings-splash', '/admin-settings-app-icon',
  '/admin-settings-app-version', '/admin-settings-social-links', '/admin-settings-sub-admin',
  '/admin-settings-supabase', '/admin-settings-page-list', '/admin-settings-service',
  '/admin-settings-assign-service', '/admin-settings-assign-service-page',
  '/admin-settings-vehicle-services', '/admin-settings-vehicle-make-model', '/admin-settings-partner-type',
  '/admin-settings-payment-type', '/admin-settings-payment-gateway', '/admin-settings-world-currency',
  '/admin-settings-document-type', '/admin-settings-required-documents',
  '/admin-settings-country-states-cities', '/admin-settings-airport-areas',
  '/admin-settings-multi-gate-places', '/admin-settings-multi-gate-place-gates',
  '/admin-settings-geo-fencing', '/admin-settings-search-radius', '/admin-settings-fixed-price',
  '/admin-settings-free-ride', '/admin-settings-rides', '/admin-settings-promocode',
  '/admin-settings-referral', '/admin-settings-referral-tree', '/admin-settings-leaderboard',
  '/admin-settings-driver-incentive', '/admin-settings-subscription-plan',
  '/admin-settings-push-notification', '/admin-settings-email-templates',
  '/admin-settings-advertisement-banners', '/admin-settings-api-keys', '/admin-settings-api-keys-keys',
  '/admin-settings-api-keys-services', '/admin-settings-api-elife', '/admin-settings-insurance-providers',
  '/admin-settings-insurance-types', '/admin-settings-insurance-durations',
  '/admin-settings-insurance-premium', '/admin-settings-ev-vehicle-details',
  '/admin-settings-ev-vehicle-inventory', '/admin-settings-ev-finance-options',
  '/admin-settings-ev-order-fee', '/admin-settings-ev-delivery-advisors',
];
const _routeAcronyms = {'api', 'ev', 'pin', 'otp', 'ui', 'teksi', 'id'};
const _routeLabelOverrides = {
  '/': 'Home',
  '/teksi-ev': 'Book TEKSI EV',
  '/partner-teksi': 'Partner TEKSI',
  '/partner-ehailing': 'Partner eHailing',
  '/rules-terms': 'Rules & Terms',
  '/phone-auth': 'Phone Login',
  '/admin-settings-api-elife': 'Admin API – Elife',
};

String routeLabel(String path) {
  final o = _routeLabelOverrides[path];
  if (o != null) return o;
  return path
      .replaceFirst(RegExp(r'^/'), '')
      .split('-')
      .map((w) => _routeAcronyms.contains(w) ? w.toUpperCase() : (w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)))
      .join(' ');
}

String routeLabelFor(String? path) => path == null || path.isEmpty ? 'Not linked' : routeLabel(path);

/// A service-box route this app can open, or null (`normalizeServiceBoxRoute`).
String? normalizeServiceBoxRoute(Object? raw) {
  if (raw is! String) return null;
  final t = raw.trim();
  if (t.isEmpty || !t.startsWith('/') || t.startsWith('//') || RegExp(r'\s').hasMatch(t)) return null;
  return t;
}

Map<String, dynamic> emptyMenu() =>
    {'renames': <String, dynamic>{}, 'routes': <String, dynamic>{}, 'customItems': <dynamic>[], 'hidden': <dynamic>[], 'comingSoon': <dynamic>[], 'order': <dynamic>[]};

List<Map<String, dynamic>> defaultServiceBoxes() => [
      for (var i = 0; i < serviceBoxCount; i++) {'id': 'box-$i', 'iconName': defaultServiceBoxIcons[i]},
    ];

Map<String, dynamic> defaultDisplaySettings() => {
      'rideTypes': true,
      'searchBar': true,
      'recentLocations': true,
      'serviceCategories': false,
      'recenterButton': true,
      'addressBar': true,
      'serviceBoxBadge': true,
      'serviceEnabled': true,
      'registrationEnabled': true,
      'signInLogo': true,
      'userMockEnabled': true,
      'partnerMockEnabled': true,
      'riderTripSimEnabled': true,
      'partnerDriveSimEnabled': true,
      'showAiTollBooths': true,
      'showAiTollCharges': true,
      'connectedPopupEnabled': true,
      'connectionFailedPopupEnabled': true,
      'recentLocationsCount': 4,
      'serviceBoxes': defaultServiceBoxes(),
      'recenterButtonBottom': 459,
      'mapHeightOffset': 365,
      'dropPinTopOffset': 0,
      'dropPinHorizontalOffset': 0,
      'addressBarTopOffset': 0,
      'discountBarHeightOffset': 0,
      'discountBarInFront': false,
      'discountBar': true,
      'rcBackVertical': 0,
      'rcBackHorizontal': 0,
      'rcRecenterVertical': 0,
      'rcRecenterHorizontal': 0,
      'rcDisclaimerVertical': 0,
      'rcDisclaimerHorizontal': 0,
      'rcAddressVertical': 0,
      'rcAddressHorizontal': 0,
      'rtRecenterVertical': 0,
      'rtRecenterHorizontal': 0,
      'prRecenterVertical': 0,
      'prRecenterHorizontal': 0,
      'hiddenVehicleServiceIds': <dynamic>[],
      'showVehicleMarkers': false,
      'vehicleBarOrder': <dynamic>[],
      'userMenu': emptyMenu(),
      'partnerMenu': emptyMenu(),
    };

List<String> _strings(Object? v) => v is List ? v.whereType<String>().toList() : <String>[];

Map<String, String> _stringMap(Object? v) => v is Map
    ? {
        for (final e in v.entries)
          if (e.key is String && e.value is String && (e.value as String).trim().isNotEmpty) e.key as String: e.value as String,
      }
    : <String, String>{};

Map<String, dynamic> normalizeMenu(Object? m) {
  if (m is! Map) return emptyMenu();
  final custom = <Map<String, dynamic>>[];
  if (m['customItems'] is List) {
    for (final c in m['customItems'] as List) {
      if (c is Map && c['id'] is String && c['label'] is String) {
        custom.add({
          'id': c['id'],
          'label': c['label'],
          'iconName': c['iconName'] is String ? c['iconName'] : 'Star',
          if (c['route'] is String && (c['route'] as String).trim().isNotEmpty) 'route': (c['route'] as String).trim(),
        });
      }
    }
  }
  return {
    'renames': _stringMap(m['renames']),
    'routes': _stringMap(m['routes']),
    'customItems': custom,
    'hidden': _strings(m['hidden']),
    'comingSoon': _strings(m['comingSoon']),
    'order': _strings(m['order']),
  };
}

List<Map<String, dynamic>> normalizeBoxes(Object? boxes) {
  final base = defaultServiceBoxes();
  final list = boxes is List ? boxes : const [];
  return [
    for (var i = 0; i < base.length; i++)
      () {
        final merged = <String, dynamic>{...base[i], if (i < list.length && list[i] is Map) ...Map<String, dynamic>.from(list[i] as Map)};
        final route = normalizeServiceBoxRoute(merged['route']);
        if (route != null) {
          merged['route'] = route;
        } else {
          merged.remove('route');
        }
        merged['comingSoon'] = merged['comingSoon'] == true;
        return merged;
      }(),
  ];
}

/// The stored blob merged over the defaults (`mergeRemote`); unknown keys
/// are kept.
Map<String, dynamic> mergeDisplaySettings(Object? raw) {
  final parsed = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  return {
    ...defaultDisplaySettings(),
    ...parsed,
    'serviceBoxes': normalizeBoxes(parsed['serviceBoxes']),
    'hiddenVehicleServiceIds': _strings(parsed['hiddenVehicleServiceIds']),
    'vehicleBarOrder': _strings(parsed['vehicleBarOrder']),
    'userMenu': normalizeMenu(parsed['userMenu']),
    'partnerMenu': normalizeMenu(parsed['partnerMenu']),
  };
}

bool displayBool(Map<String, dynamic> s, String key) {
  final v = s[key];
  return v is bool ? v : (defaultDisplaySettings()[key] == true);
}

num displayNum(Map<String, dynamic> s, String key) {
  final v = s[key];
  return v is num ? v : (defaultDisplaySettings()[key] as num? ?? 0);
}

Map<String, dynamic> setDisplayValue(Map<String, dynamic> s, String key, Object? value) => {...s, key: value};

/// Clamps and rounds a stepper value (`setNumeric` / `setRecentLocationsCount`).
Map<String, dynamic> setDisplayNumber(Map<String, dynamic> s, String key, num value, num min, num max) =>
    {...s, key: math.max(min, math.min(max, value.round()))};

/// A stepper on the display screen.
class LayoutItem {
  const LayoutItem(this.key, this.label, this.description, this.min, this.max, this.step);
  final String key;
  final String label;
  final String description;
  final int min;
  final int max;
  final int step;
}

const _vDesc = '(negative = up, positive = down)';
const _hDesc = '(negative = left, positive = right)';

const mapLayoutItems = [
  LayoutItem('recenterButtonBottom', 'Recenter button height',
      'Distance from the bottom of the screen (the button still stays above the bottom sheet)', 100, 700, 10),
  LayoutItem('mapHeightOffset', 'Map height', 'Extra map height extending above the screen (raises the pin by half)', 0, 800, 25),
  LayoutItem('dropPinTopOffset', 'Drop pin height', 'Vertical offset of the pin $_vDesc', -200, 200, 5),
  LayoutItem('dropPinHorizontalOffset', 'Drop pin left/right', 'Horizontal offset of the pin $_hDesc', -200, 200, 5),
  LayoutItem('addressBarTopOffset', 'Address bar height',
      'Vertical offset of the address pill above the pin $_vDesc; it never covers the pin', -300, 300, 5),
];

const rideConfirmLayoutItems = [
  LayoutItem('discountBarHeightOffset', 'Discount bar height', 'Vertical offset of the promo/discount bar $_vDesc', -300, 300, 5),
  LayoutItem('rcBackVertical', 'Back button height', 'Vertical offset of the back button $_vDesc', -300, 300, 5),
  LayoutItem('rcBackHorizontal', 'Back button left/right', 'Horizontal offset of the back button $_hDesc', -300, 300, 5),
  LayoutItem('rcRecenterVertical', 'Recenter button height', 'Vertical offset of the recenter button $_vDesc', -300, 300, 5),
  LayoutItem('rcRecenterHorizontal', 'Recenter button left/right', 'Horizontal offset of the recenter button $_hDesc', -300, 300, 5),
  LayoutItem('rcDisclaimerVertical', 'Disclaimer box height', 'Vertical offset of the disclaimer box $_vDesc', -300, 300, 5),
  LayoutItem('rcDisclaimerHorizontal', 'Disclaimer box left/right', 'Horizontal offset of the disclaimer box $_hDesc', -300, 300, 5),
  LayoutItem('rcAddressVertical', 'Address box height', 'Vertical offset of the address box $_vDesc', -300, 300, 5),
  LayoutItem('rcAddressHorizontal', 'Address box left/right', 'Horizontal offset of the address box $_hDesc', -300, 300, 5),
];

const rideTrackingLayoutItems = [
  LayoutItem('rtRecenterVertical', 'User: recenter height', 'Recenter button on the user ride-tracking map $_vDesc', -300, 300, 5),
  LayoutItem('rtRecenterHorizontal', 'User: recenter left/right', 'Recenter button on the user ride-tracking map $_hDesc', -300, 300, 5),
  LayoutItem('prRecenterVertical', 'Partner: recenter height', 'Recenter button on the partner ride map $_vDesc', -300, 300, 5),
  LayoutItem('prRecenterHorizontal', 'Partner: recenter left/right', 'Recenter button on the partner ride map $_hDesc', -300, 300, 5),
];

/// Home-screen section switches (`DISPLAY_SETTINGS_META`).
const homeSectionToggles = [
  ('rideTypes', 'Vehicle Types Bar', 'Top horizontal vehicle type selector'),
  ('searchBar', 'Search Bar', 'Where to & for how much? input'),
  ('recentLocations', 'Recent Locations', 'Recently visited places list'),
  ('serviceCategories', 'Service Categories', 'Popular nearby places (5 boxes)'),
  ('recenterButton', 'Recenter Button', 'Floating recenter map button'),
  ('addressBar', 'Address Bar', 'Top centered address pill'),
];

// --- Service boxes -----------------------------------------------------------

Map<String, dynamic> updateServiceBox(Map<String, dynamic> s, int index, Map<String, dynamic> patch) {
  final boxes = normalizeBoxes(s['serviceBoxes']);
  final next = {...boxes[index], ...patch}..removeWhere((k, v) => v == null);
  boxes[index] = next;
  return {...s, 'serviceBoxes': boxes};
}

// --- Side menus ----------------------------------------------------------------

String menuKey(String menu) => menu == 'user' ? 'userMenu' : 'partnerMenu';

Map<String, dynamic> menuOf(Map<String, dynamic> s, String menu) => normalizeMenu(s[menuKey(menu)]);

Map<String, dynamic> _withMenu(Map<String, dynamic> s, String menu, Map<String, dynamic> cfg) => {...s, menuKey(menu): cfg};

/// Default + custom items in display order (`getMenuItemOrder`).
List<({String id, bool isCustom})> menuItemOrder(String menu, Map<String, dynamic> cfg) {
  final all = <({String id, bool isCustom})>[
    for (final d in defaultMenuItems(menu)) (id: d.$1, isCustom: false),
    for (final c in (cfg['customItems'] as List)) (id: (c as Map)['id'] as String, isCustom: true),
  ];
  final order = _strings(cfg['order']);
  int rank(String id) {
    final i = order.indexOf(id);
    return i == -1 ? 1 << 30 : i;
  }

  final indexed = [for (var i = 0; i < all.length; i++) (item: all[i], natural: i)];
  indexed.sort((a, b) {
    final r = rank(a.item.id).compareTo(rank(b.item.id));
    return r != 0 ? r : a.natural.compareTo(b.natural);
  });
  return [for (final x in indexed) x.item];
}

Map<String, dynamic> renameMenuItem(Map<String, dynamic> s, String menu, String itemId, String label) {
  final cfg = menuOf(s, menu);
  final trimmed = label.trim();
  final def = defaultMenuItems(menu).where((d) => d.$1 == itemId).firstOrNull;
  final renames = Map<String, dynamic>.from(cfg['renames'] as Map);
  if (trimmed.isEmpty || (def != null && trimmed == def.$2)) {
    renames.remove(itemId);
  } else {
    renames[itemId] = trimmed;
  }
  final custom = [
    for (final c in cfg['customItems'] as List)
      (c as Map)['id'] == itemId && trimmed.isNotEmpty ? {...c, 'label': trimmed} : c,
  ];
  return _withMenu(s, menu, {...cfg, 'renames': renames, 'customItems': custom});
}

Map<String, dynamic> addCustomMenuItem(Map<String, dynamic> s, String menu, String label, String iconName, String? route,
    {required String id}) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return s;
  final cfg = menuOf(s, menu);
  final item = <String, dynamic>{'id': id, 'label': trimmed, 'iconName': iconName};
  if (route != null && route.trim().isNotEmpty) item['route'] = route.trim();
  return _withMenu(s, menu, {...cfg, 'customItems': [...cfg['customItems'] as List, item]});
}

Map<String, dynamic> setMenuItemRoute(Map<String, dynamic> s, String menu, String itemId, String? route) {
  final cfg = menuOf(s, menu);
  final trimmed = (route ?? '').trim();
  final routes = Map<String, dynamic>.from(cfg['routes'] as Map);
  final custom = [
    for (final c in cfg['customItems'] as List)
      if ((c as Map)['id'] != itemId)
        c
      else if (trimmed.isNotEmpty)
        {...c, 'route': trimmed}
      else
        ({...c}..remove('route')),
  ];
  if (trimmed.isNotEmpty) {
    routes[itemId] = trimmed;
  } else {
    routes.remove(itemId);
  }
  return _withMenu(s, menu, {...cfg, 'routes': routes, 'customItems': custom});
}

Map<String, dynamic> _toggleIn(Map<String, dynamic> s, String menu, String listKey, String itemId, bool include) {
  final cfg = menuOf(s, menu);
  final set = {..._strings(cfg[listKey])};
  if (include) {
    set.add(itemId);
  } else {
    set.remove(itemId);
  }
  return _withMenu(s, menu, {...cfg, listKey: set.toList()});
}

Map<String, dynamic> setMenuItemVisibility(Map<String, dynamic> s, String menu, String itemId, bool visible) =>
    _toggleIn(s, menu, 'hidden', itemId, !visible);

Map<String, dynamic> setMenuItemComingSoon(Map<String, dynamic> s, String menu, String itemId, bool comingSoon) =>
    _toggleIn(s, menu, 'comingSoon', itemId, comingSoon);

List<String>? _moved(List<String> ids, String id, int dir) {
  final order = [...ids];
  final from = order.indexOf(id);
  if (from == -1) return null;
  final to = from + dir;
  if (to < 0 || to >= order.length) return null;
  final m = order.removeAt(from);
  order.insert(to, m);
  return order;
}

Map<String, dynamic> moveMenuItem(Map<String, dynamic> s, String menu, String itemId, int dir) {
  final cfg = menuOf(s, menu);
  final order = _moved([for (final o in menuItemOrder(menu, cfg)) o.id], itemId, dir);
  return order == null ? s : _withMenu(s, menu, {...cfg, 'order': order});
}

Map<String, dynamic> removeCustomMenuItem(Map<String, dynamic> s, String menu, String itemId) {
  final cfg = menuOf(s, menu);
  return _withMenu(s, menu, {
    ...cfg,
    'customItems': [for (final c in cfg['customItems'] as List) if ((c as Map)['id'] != itemId) c],
    'hidden': _strings(cfg['hidden']).where((x) => x != itemId).toList(),
    'comingSoon': _strings(cfg['comingSoon']).where((x) => x != itemId).toList(),
    'order': _strings(cfg['order']).where((x) => x != itemId).toList(),
  });
}

// --- Vehicle type bar ---------------------------------------------------------------

Map<String, dynamic> setVehicleServiceVisibility(Map<String, dynamic> s, String id, bool visible) {
  final set = {..._strings(s['hiddenVehicleServiceIds'])};
  if (visible) {
    set.remove(id);
  } else {
    set.add(id);
  }
  return {...s, 'hiddenVehicleServiceIds': set.toList()};
}

Map<String, dynamic> moveVehicleInBar(Map<String, dynamic> s, String id, int dir, List<String> visibleIds) {
  final order = _moved(visibleIds, id, dir);
  return order == null ? s : {...s, 'vehicleBarOrder': order};
}

/// Visible vehicles (active, not hidden) in bar order, then displayPriority.
List<T> arrangeVehicles<T>(List<T> entries, Map<String, dynamic> s,
    {required String Function(T) id, required Map<String, dynamic> Function(T) values}) {
  final hidden = _strings(s['hiddenVehicleServiceIds']).toSet();
  final order = _strings(s['vehicleBarOrder']);
  final visible = entries.where((e) {
    final st = values(e)['status'];
    final on = st == null ? true : (st != false && st != 0 && st != '' && st != 'false');
    return on && !hidden.contains(id(e));
  }).toList();
  int idx(T e) {
    final i = order.indexOf(id(e));
    return i == -1 ? 1 << 30 : i;
  }

  num prio(T e) => num.tryParse('${values(e)['displayPriority'] ?? 9999}') ?? 9999;
  visible.sort((a, b) {
    final c = idx(a).compareTo(idx(b));
    return c != 0 ? c : prio(a).compareTo(prio(b));
  });
  return visible;
}

// --- Mock / simulation -----------------------------------------------------------

const mockKeys = ['userMockEnabled', 'riderTripSimEnabled', 'partnerMockEnabled', 'partnerDriveSimEnabled'];

bool anyMockEnabled(Map<String, dynamic> s) => mockKeys.any((k) => displayBool(s, k));

Map<String, dynamic> setAllMocks(Map<String, dynamic> s, bool enabled) => {...s, for (final k in mockKeys) k: enabled};
