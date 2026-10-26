/// Global display settings — the pure half of the Expo
/// `contexts/DisplaySettingsContext.tsx` (normalisation, defaults, side-menu
/// and vehicle-bar edits). The whole blob lives in one row of
/// `admin_display_settings` (`id = 'global'`, column `settings` jsonb), so
/// every edit here is a function from the current blob to the next one; keys
/// this app does not know are carried through untouched.
library;

import 'dart:math' as math;
import '../../../core/home_sections.dart' show pinMiddleOffsetKey;
import '../../../core/home_layout.dart' show HomeLayouts, HomeSectionType;
import '../../../core/demo_mode.dart' show demoAccountIds, demoDriverIdsKey, demoRiderIdsKey;
import '../../../core/ride_assistance.dart';
import '../../../core/ride_option_settings.dart';
import '../../../core/ride_pets.dart';
import '../../../core/sheet_min_height.dart';

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
const helpAssistantMenuItemId = 'help-assistant';
const myRideMenuItemId = 'my-ride';
const myQrMenuItemId = 'my-qr';

/// The scheduled rides (0189): the rider's bookings, the driver's taken
/// ones; shown only while scheduled rides are on.
const scheduledRidesMenuItemId = 'scheduled-rides';

/// The built-in service rows of the rider menu (Courier, Grocery, Food…).
const serviceMenuItemIds = <String>{
  'courier',
  'buy-sell',
  'grocery',
  'city-to-city',
  'food',
  'pharmacy',
  'shopping',
  'mall',
  'finance',
  'bills-prepaid',
  'dine-out',
  'mart',
  'express',
  'hotel',
  'gift',
  'loan',
  'pay-later',
  'insurance',
};

/// The driver's My Ride code (QR and the riders who added them); shown only
/// where the database has My Ride (migration 0160).
const myRideCodeMenuItemId = 'my-ride-code';

const defaultUserMenuItems = <(String, String)>[
  ('teksi-ev', 'Book TEKSI EV'),
  ('city', 'City'),
  ('request-history', 'Request history'),
  (scheduledRidesMenuItemId, 'Ride Later'), // this app's own; the Expo menu skips it
  (myRideMenuItemId, 'My Ride'), // favourite drivers (0160); this app's own, the Expo menu skips it
  (myQrMenuItemId, 'My QR'), // personal QR codes (0161); this app's own, the Expo menu skips it
  ('freight', 'Freight'),
  // The services listed in the menu (owner, 2026-10-22). Built in, so they
  // can be hidden or relinked but not deleted; Courier opens its page, the
  // rest say "coming soon" until the admin links a page.
  ('courier', 'Courier'),
  ('buy-sell', 'Buy & Sell'),
  ('grocery', 'Groceries'),
  ('city-to-city', 'City to City'),
  ('food', 'Food'),
  ('pharmacy', 'Pharmacy'),
  ('shopping', 'Shopping'),
  ('mall', 'Mall'),
  ('finance', 'Finance'),
  ('bills-prepaid', 'Bills & Prepaid'),
  ('dine-out', 'Dine Out'),
  ('mart', 'Mart'),
  ('express', 'Express'),
  ('hotel', 'Hotel'),
  ('gift', 'Gift'),
  ('loan', 'Loan'),
  ('pay-later', 'Pay Later'),
  ('insurance', 'Insurance'),
  ('wallet', 'Wallet'),
  ('notifications', 'Notifications'),
  ('safety', 'Safety'),
  ('settings', 'Settings'),
  ('user-guide', 'User Guide'),
  (helpAssistantMenuItemId, 'Help assistant'), // this app's own; the Expo menu skips it
  ('support', 'Support'),
  // This app's own rows (the Expo menu has no such items and skips them).
  (emergencyContactsMenuItemId, 'Emergency contacts'),
  (inviteFriendsMenuItemId, 'Invite friends'),
  ('logout', 'Logout'),
];

/// The driver menu's stand groups and fleets to join (0251).
const standGroupsMenuItemId = 'stand-groups';

/// The driver's permits, any time (0254).
const myPermitMenuItemId = 'my-permit';
/// The driver menu's Telematics: their km and trips (0255).
const telematicsMenuItemId = 'telematics';
/// The driver menu's Services: what the car in use takes (0263).
const servicesMenuItemId = 'services';

const defaultPartnerMenuItems = <(String, String)>[
  ('teksi-ev', 'Book TEKSI EV'),
  ('dashboard', 'Dashboard'),
  (myRideCodeMenuItemId, 'My Ride code'), // this app's own; the Expo menu skips it
  ('earnings', 'Earnings'),
  (telematicsMenuItemId, 'Telematics'), // this app's own (0255); the Expo menu skips it
  ('wallet', 'Wallet'),
  (myQrMenuItemId, 'My QR'), // GET.Referral / GET.me / GET.now (0161); this app's own
  ('trip-history', 'Trip history'),
  (scheduledRidesMenuItemId, 'Scheduled rides'), // this app's own; the Expo menu skips it
  ('vehicle', 'Vehicle'),
  (servicesMenuItemId, 'Services'), // this app's own (0263): the services the car in use takes
  (myPermitMenuItemId, 'My permit'), // this app's own (0254): the vehicle's and driver's permits
  (standGroupsMenuItemId, 'Stand groups'), // this app's own (0251): groups a driver asks to join
  (vehicleInfoMenuItemId, 'Vehicle information'),
  ('documents', 'Documents'),
  ('notifications', 'Notifications'),
  (helpAssistantMenuItemId, 'Help assistant'), // this app's own; the Expo menu skips it
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
    myRideMenuItemId: '/my-ride',
    myQrMenuItemId: '/my-qr',
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
    myQrMenuItemId: '/my-qr',
    'documents': '/partner-documents',
    'safety': '/safety',
    'support': '/support',
  },
};

/// The icon (a [sideMenuIcons] name) each built-in menu item shows in Admin
/// → Display Settings → Side Menus, and the Media Gallery counts it under.
const defaultMenuIconNames = <String, Map<String, String>>{
  'user': {
    'teksi-ev': 'Car',
    'wallet': 'Wallet',
    'emergency-contacts': 'Phone',
    'invite-friends': 'Gift',
    'city': 'Car',
    'request-history': 'Clock',
    'scheduled-rides': 'Clock',
    'my-ride': 'Heart',
    'my-qr': 'Tag',
    'freight': 'Truck',
    'courier': 'Package',
    'buy-sell': 'Tag',
    'grocery': 'ShoppingCart',
    'city-to-city': 'Navigation',
    'food': 'Utensils',
    'pharmacy': 'Pill',
    'shopping': 'ShoppingBag',
    'mall': 'Building2',
    'finance': 'Landmark',
    'bills-prepaid': 'Receipt',
    'dine-out': 'Coffee',
    'mart': 'Store',
    'express': 'Zap',
    'hotel': 'Hotel',
    'gift': 'Gift',
    'loan': 'Banknote',
    'pay-later': 'CreditCard',
    'insurance': 'Shield',
    'notifications': 'Bell',
    'safety': 'Shield',
    'settings': 'Settings',
    'user-guide': 'BookOpen',
    'support': 'MessageCircle',
    'logout': 'User',
  },
  'partner': {
    'teksi-ev': 'Car',
    'wallet': 'Wallet',
    'vehicle-information': 'Car',
    'my-qr': 'Tag',
    'dashboard': 'Settings',
    'my-ride-code': 'Star',
    'earnings': 'Wallet',
    'telematics': 'Clock',
    'trip-history': 'Clock',
    'scheduled-rides': 'Clock',
    'vehicle': 'Car',
    'documents': 'FileText',
    'notifications': 'Bell',
    'safety': 'Shield',
    'support': 'HelpCircle',
    'settings': 'Settings',
    'sign-out': 'User',
  },
};

/// Icon names for custom menu items (the Expo app knows the first 18).
const sideMenuIcons = [
  'Bell', 'BookOpen', 'Car', 'Clock', 'FileText', 'Gift', 'HelpCircle', 'Heart', 'Mail', 'MapPin',
  'MessageCircle', 'Phone', 'Settings', 'Shield', 'Star', 'Tag', 'User', 'Wallet',
  // Services listed in the menu (Courier, Grocery, Food, Pharmacy, Finance, Hotel…).
  'Package', 'ShoppingCart', 'Navigation', 'Utensils', 'Pill', 'ShoppingBag', 'Building2', 'Landmark',
  'Receipt', 'Coffee', 'Store', 'Zap', 'Hotel', 'Banknote', 'CreditCard',
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
  // The Freight and Courier pages (0267, 0268), for the home service boxes.
  '/freight', '/courier',
  '/', '/onboarding', '/role-selection', '/phone-auth', '/otp-verify', '/pin-setup', '/pin-verify',
  '/change-pin', '/change-number', '/name-entry', '/profile', '/edit-profile', '/profile-photo', '/settings',
  '/dark-mode', '/language', '/distances', '/navigation', '/user-guide', '/rules-terms', '/safety',
  '/emergency-contacts', '/emergency-contact-edit', '/my-ride', '/my-qr', '/search', '/map-picker', '/offer-fare', '/ride-detail',
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
  '/admin-settings-site', '/admin-settings-splash', '/admin-settings-app-icon', '/admin-settings-maps',
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
  '/admin-settings-ev-order-fee', '/admin-settings-ev-delivery-advisors', '/admin-settings-ev-profiles',
];
const _routeAcronyms = {'api', 'ev', 'pin', 'otp', 'ui', 'teksi', 'id'};
const _routeLabelOverrides = {
  '/': 'Home',
  '/freight': 'Freight',
  '/courier': 'Courier',
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
    {'renames': <String, dynamic>{}, 'routes': <String, dynamic>{}, 'icons': <String, dynamic>{}, 'customItems': <dynamic>[], 'hidden': <dynamic>[], 'comingSoon': <dynamic>[], 'order': <dynamic>[]};

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
      'passengerRegistrationEnabled': true,
      'driverRegistrationEnabled': true,
      'signInLogo': true,
      // Off unless stored on, as the apps read them (DemoSettings): a
      // default of on showed mocks as running when they weren't, and a save
      // or a reset would have switched them on for real.
      'userMockEnabled': false,
      'partnerMockEnabled': false,
      'riderTripSimEnabled': false,
      'partnerDriveSimEnabled': false,
      'showAiTollBooths': true,
      'showAiTollCharges': true,
      'connectedPopupEnabled': true,
      'connectionFailedPopupEnabled': true,
      'recentLocationsCount': 4,
      // Seconds before a popup message closes by itself; 0 keeps it open
      // (core/app_display.dart, widgets/app_notice.dart).
      'popupAutoCloseSeconds': 0,
      // Seconds with no offer before the search sheet offers a raise
      // (core/raise_nudge.dart).
      'raiseFareAfterSeconds': 45,
      'serviceBoxes': defaultServiceBoxes(),
      'recenterButtonBottom': 459,
      'mapHeightOffset': 365,
      'dropPinTopOffset': 0,
      pinMiddleOffsetKey: 0,
      'dropPinHorizontalOffset': 0,
      'addressBarTopOffset': 0,
      'discountBarHeightOffset': 0,
      'discountBarInFront': false,
      'discountBar': true,
      'addStopConfirm': true,
      'confirmShowCoin': true,
      'confirmShowBookForOther': true,
      'confirmShowMyRide': true,
      'confirmShowAutoAccept': true,
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
      // Bottom sheet minimum height: the admin's px on top of what each
      // sheet's shown items need (core/sheet_min_height.dart).
      homeSheetMinAdjustKey: 0,
      confirmSheetMinAdjustKey: 0,
      trackingSheetMinAdjustKey: 0,
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
    'icons': _stringMap(m['icons']),
    'customItems': custom,
    'hidden': _strings(m['hidden']),
    'comingSoon': _strings(m['comingSoon']),
    'order': _strings(m['order']),
  };
}

List<Map<String, dynamic>> normalizeBoxes(Object? boxes) {
  final list = boxes is List ? boxes : const [];
  return [for (var i = 0; i < serviceBoxCount; i++) normalizeBox(i < list.length ? list[i] : null, i)];
}

/// Box [i] over its defaults: a route this app can open (else none) and a
/// plain Coming soon switch. Past the first five, the five defaults again.
Map<String, dynamic> normalizeBox(Object? raw, int i) {
  final base = defaultServiceBoxes()[i % serviceBoxCount];
  final merged = <String, dynamic>{
    ...base,
    if (i >= serviceBoxCount) 'id': 'box-$i',
    if (raw is Map) ...Map<String, dynamic>.from(raw),
  };
  final route = normalizeServiceBoxRoute(merged['route']);
  if (route != null) {
    merged['route'] = route;
  } else {
    merged.remove('route');
  }
  merged['comingSoon'] = merged['comingSoon'] == true;
  return merged;
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

/// Whether new [role] ('passenger' or 'driver') sign-up is on, as the apps
/// read it (`AppDisplay`): the old single switch off closes both.
bool registrationOpen(Map<String, dynamic> s, String role) =>
    displayBool(s, 'registrationEnabled') &&
    displayBool(s, role == 'driver' ? 'driverRegistrationEnabled' : 'passengerRegistrationEnabled');

/// Turns [role]'s sign-up on or off, keeping the other as it reads now, and
/// the old single switch as "either is open" for apps that only know it.
Map<String, dynamic> setRegistrationOpen(Map<String, dynamic> s, String role, bool on) {
  final passenger = role == 'driver' ? registrationOpen(s, 'passenger') : on;
  final driver = role == 'driver' ? on : registrationOpen(s, 'driver');
  return {
    ...s,
    'passengerRegistrationEnabled': passenger,
    'driverRegistrationEnabled': driver,
    'registrationEnabled': passenger || driver,
  };
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
  LayoutItem('mapHeightOffset', 'Map height', 'Extra map height extending above the screen (the pin stays where it is)', 0, 800, 25),
  LayoutItem(pinMiddleOffsetKey, 'Pin up/down',
      'The pin, its address bar and the current place sit halfway between the top of the screen and the top of the '
          'bottom sheet all the way down; this moves them from there $_vDesc', -200, 200, 5),
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

/// Home-screen switches for what sits over the map. The parts under it
/// (search bar, vehicle bar, recent places, service boxes and the rest) are
/// laid out on Display Settings → Home page (core/home_layout.dart).
const homeSectionToggles = [
  ('recenterButton', 'Recenter Button', 'Floating recenter map button'),
  ('addressBar', 'Address Bar', 'Top centered address pill'),
];

// --- Bottom sheet minimum height -------------------------------------------------

/// The admin can't measure a phone: these are estimated heights, in px, of
/// what each sheet shows all the way down, read off the widgets. The phone
/// itself measures the real ones.
const sheetHandleAndGaps = 30;

/// Between items, and above the first and under the last.
const sheetItemGap = 8;

const homeSheetItemHeights = {
  'searchBar': 48,
  'whereToRow': 56,
  'rideTypes': 64,
  'recentLocations': 116,
  'serviceCategories': 84,
};

/// The confirm sheet: the distance and time line, two vehicle cards and the
/// pinned "Find a driver" bar (payment, GET.coin, who's riding).
const confirmSheetItemHeights = {'routeLine': 32, 'vehicleCards': 152, 'findDriverBar': 136};

/// The rider's tracking sheet with a driver on the way: the status line,
/// the driver card, its Call and Message row and the pinned Cancel ride bar.
const trackingSheetItemHeights = {'statusTitle': 36, 'driverCard': 132, 'callRow': 48, 'cancelBar': 72};

/// One shown item of a sheet and its estimated height.
typedef SheetItemEstimate = ({String label, int px});

/// The items a sheet shows all the way down, in order, as the current
/// switches have them; the first is always shown.
List<SheetItemEstimate> sheetItemEstimates(String key, Map<String, dynamic> s) {
  switch (key) {
    case homeSheetMinAdjustKey:
      // The master home page's parts above the fold, in its order.
      const h = homeSheetItemHeights;
      final layout = HomeLayouts.fromSettings(s).master;
      return [
        for (final x in layout.sections.takeWhile((x) => x.type != HomeSectionType.fold))
          ...switch (x.type) {
            HomeSectionType.search => [
                x.on ? (label: 'Search Bar', px: h['searchBar']!) : (label: 'Where to? row', px: h['whereToRow']!),
              ],
            HomeSectionType.vehicles when x.on => [(label: 'Vehicle Types Bar', px: h['rideTypes']!)],
            HomeSectionType.pickup when x.on => [(label: 'Pickup row', px: h['whereToRow']!)],
            HomeSectionType.recent when x.on => [(label: 'Recent Locations', px: h['recentLocations']!)],
            HomeSectionType.boxes when x.on => [(label: 'Service Categories', px: h['serviceCategories']!)],
            _ => const <SheetItemEstimate>[],
          },
      ];
    case confirmSheetMinAdjustKey:
      const h = confirmSheetItemHeights;
      return [
        (label: 'Distance and time', px: h['routeLine']!),
        (label: 'Vehicle cards', px: h['vehicleCards']!),
        (label: 'Find a driver bar', px: h['findDriverBar']!),
      ];
    default:
      const h = trackingSheetItemHeights;
      return [
        (label: 'Ride status', px: h['statusTitle']!),
        (label: 'Driver card', px: h['driverCard']!),
        (label: 'Call and Message', px: h['callRow']!),
        (label: 'Cancel ride bar', px: h['cancelBar']!),
      ];
  }
}

/// A sheet's least height as the admin row shows it: the estimated
/// automatic part, the floor it never goes under, the stored adjustment and
/// the total.
class SheetMinEstimate {
  const SheetMinEstimate({required this.items, required this.adjust, required this.floor});

  final List<SheetItemEstimate> items;
  final int adjust;

  /// The handle and the first always-shown item whole (with what is pinned
  /// under the sheet): the least it ever rests at.
  final int floor;

  /// The handle and gaps, the items and the gaps around them.
  int get automatic =>
      sheetHandleAndGaps + items.fold<int>(0, (sum, i) => sum + i.px) + sheetItemGap * (items.length + 1);

  /// Automatic plus the adjustment, never under [floor].
  int get total => math.max(floor, automatic + adjust);

  bool get atFloor => total <= floor;

  /// "Items shown: Search Bar 48 + … + handle and gaps → 186 px automatic ·
  /// your adjustment +20 px → 206 px".
  String get breakdown {
    final parts = [for (final i in items) '${i.label} ${i.px}', 'handle and gaps'].join(' + ');
    final sign = adjust > 0 ? '+' : (adjust < 0 ? '-' : '');
    return 'Items shown: $parts = $automatic px automatic · your adjustment $sign${adjust.abs()} px = $total px';
  }
}

/// The estimate for the sheet stored at [key] (one of the
/// `…SheetMinAdjust` keys) under the current settings.
SheetMinEstimate sheetMinEstimate(Map<String, dynamic> s, String key) {
  final items = sheetItemEstimates(key, s);
  // What stays whole however low the admin sets it: home's first item (the
  // search bar), tracking's status line over the Cancel ride bar. Confirm
  // goes down to a fixed [confirmSheetMinFloor].
  final whole = switch (key) {
    homeSheetMinAdjustKey => items.first.px,
    _ => trackingSheetItemHeights['statusTitle']! + trackingSheetItemHeights['cancelBar']!,
  };
  return SheetMinEstimate(
    items: items,
    adjust: sheetMinAdjust(s, key).round(),
    floor: key == confirmSheetMinAdjustKey ? confirmSheetMinFloor : sheetHandleAndGaps + whole + sheetItemGap * 2,
  );
}

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

/// The icon of a menu item: [iconName] from [sideMenuIcons] or the Media
/// Gallery (`media:<id>`, `pack:<name>`), or null (or '') for the built-in
/// item's own icon. A custom item keeps its icon on the item itself
/// (null puts back the 'Star' it starts with).
Map<String, dynamic> setMenuItemIcon(Map<String, dynamic> s, String menu, String itemId, String? iconName) {
  final cfg = menuOf(s, menu);
  final name = (iconName ?? '').trim();
  final icons = Map<String, dynamic>.from(cfg['icons'] as Map)..remove(itemId);
  final list = cfg['customItems'] as List;
  if (list.any((c) => (c as Map)['id'] == itemId)) {
    final custom = [
      for (final c in list)
        (c as Map)['id'] == itemId ? {...c, 'iconName': name.isEmpty ? 'Star' : name} : c,
    ];
    return _withMenu(s, menu, {...cfg, 'icons': icons, 'customItems': custom});
  }
  if (name.isNotEmpty) icons[itemId] = name;
  return _withMenu(s, menu, {...cfg, 'icons': icons});
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

// --- Demo riders / demo drivers -------------------------------------------------

/// The accounts on a demo list ([demoRiderIdsKey] or [demoDriverIdsKey]).
List<String> demoAccounts(Map<String, dynamic> s, String key) => demoAccountIds(s[key]);

/// [id] added to the end of the list at [key], once.
Map<String, dynamic> addDemoAccount(Map<String, dynamic> s, String key, String id) {
  final ids = demoAccounts(s, key);
  final t = id.trim();
  return {...s, key: [...ids, if (t.isNotEmpty && !ids.contains(t)) t]};
}

/// [id] taken off the list at [key].
Map<String, dynamic> removeDemoAccount(Map<String, dynamic> s, String key, String id) =>
    {...s, key: [for (final x in demoAccounts(s, key)) if (x != id.trim()) x]};


// --- Ride Options -------------------------------------------------------------------
// The rider's Options sheet (core/ride_option_settings.dart), the pets
// (PetConfig's keys) and the assistance catalogue, each a function from the
// blob to the next one as everything else here.

RideOptionsConfig rideOptionsOf(Map<String, dynamic> s) => RideOptionsConfig.fromSettings(s);

Map<String, dynamic> _withRideOptions(Map<String, dynamic> s, RideOptionsConfig c) => {...s, ...c.toSettings()};

/// Shows or hides an option on the rider's sheet.
Map<String, dynamic> setRideOptionShown(Map<String, dynamic> s, RideOptionKind k, bool shown) {
  final c = rideOptionsOf(s);
  return _withRideOptions(s, c.copyWith(hidden: shown ? ({...c.hidden}..remove(k)) : {...c.hidden, k}));
}

/// The name riders see; blank (or the built-in name) goes back to it.
Map<String, dynamic> renameRideOption(Map<String, dynamic> s, RideOptionKind k, String label) {
  final c = rideOptionsOf(s);
  var t = label.trim();
  if (t.length > RideOptionsConfig.labelMax) t = t.substring(0, RideOptionsConfig.labelMax).trim();
  final labels = {...c.labels}..remove(k);
  if (t.isNotEmpty && t != k.defaultLabel) labels[k] = t;
  return _withRideOptions(s, c.copyWith(labels: labels));
}

/// The picture beside an option on the rider's sheet (a Media Gallery
/// reference); null or '' for none.
Map<String, dynamic> setRideOptionImage(Map<String, dynamic> s, RideOptionKind k, String? image) {
  final c = rideOptionsOf(s);
  final images = {...c.images}..remove(k);
  final v = image?.trim() ?? '';
  if (v.isNotEmpty) images[k] = v;
  return _withRideOptions(s, c.copyWith(images: images));
}

/// Moves an option up (-1) or down (1), past the next one of its own list
/// (a ride's options or the Freight page's).
Map<String, dynamic> moveRideOption(Map<String, dynamic> s, RideOptionKind k, int dir) {
  final c = rideOptionsOf(s);
  final order = [...c.order];
  final i = order.indexOf(k);
  var j = i + dir;
  while (j >= 0 && j < order.length && order[j].freight != k.freight) {
    j += dir;
  }
  if (i < 0 || j < 0 || j >= order.length) return s;
  order[i] = order[j];
  order[j] = k;
  return _withRideOptions(s, c.copyWith(order: order));
}

/// Whether commission and promo codes apply to the option charges.
Map<String, dynamic> setOptionChargeRules(Map<String, dynamic> s, {bool? commission, bool? promo}) {
  final r = OptionChargeRules.fromSettings(s);
  return {
    ...s,
    ...OptionChargeRules(commission: commission ?? r.commission, promo: promo ?? r.promo).toSettings(),
  };
}

/// "Most seats a rider can ask for", 1 to 3.
Map<String, dynamic> setChildSeatMax(Map<String, dynamic> s, num n) =>
    _withRideOptions(s, rideOptionsOf(s).copyWith(childSeatMax: n.round().clamp(1, RideOptionsConfig.childSeatLimit)));

// The pets.

PetConfig petConfigOf(Map<String, dynamic> s) => PetConfig.fromSettings(s);

Map<String, dynamic> _withPets(Map<String, dynamic> s, PetConfig c) => {...s, ...c.toSettings()};

PetConfig _pets(
  PetConfig c, {
  List<String>? types,
  List<String>? sizes,
  int? maxPerType,
  bool? photoRequired,
  Map<String, PetCharge>? charges,
  Map<String, double>? sizeExtras,
}) => PetConfig(
  types: types ?? c.types,
  sizes: sizes ?? c.sizes,
  maxPerType: maxPerType ?? c.maxPerType,
  photoRequired: photoRequired ?? c.photoRequired,
  charges: charges ?? c.charges,
  sizeExtras: sizeExtras ?? c.sizeExtras,
);

/// Why [name] can't be a pet type (beside [others]); null when it can.
String? petTypeProblem(String name, List<String> others) {
  final t = cleanPetTypeName(name);
  if (t.isEmpty) return 'Type a name, e.g. Bird.';
  if (t.length > PetConfig.typeNameMax) return 'Keep it under ${PetConfig.typeNameMax} characters.';
  if (others.any((o) => o.toLowerCase() == t.toLowerCase())) return '$t is already on the list.';
  return null;
}

/// A new pet type at the end of the list (name only: no emoji).
Map<String, dynamic> addPetType(Map<String, dynamic> s, String name, {PetCharge charge = PetCharge.none}) {
  final c = petConfigOf(s);
  final t = cleanPetTypeName(name);
  if (petTypeProblem(t, c.types) != null || c.types.length >= PetConfig.maxTypes) return s;
  return _withPets(s, _pets(c, types: [...c.types, t], charges: {...c.charges, if (!charge.isZero) t: charge}));
}

/// Renames a type (its charge goes with it) and sets its charge.
Map<String, dynamic> updatePetType(Map<String, dynamic> s, String type, {String? name, PetCharge? charge}) {
  final c = petConfigOf(s);
  if (!c.types.contains(type)) return s;
  final t = name == null ? type : cleanPetTypeName(name);
  if (t != type && petTypeProblem(t, [for (final o in c.types) if (o != type) o]) != null) return s;
  final charges = {...c.charges};
  final kept = charges.remove(type);
  final next = charge ?? kept ?? PetCharge.none;
  if (!next.isZero) charges[t] = next;
  return _withPets(s, _pets(c, types: [for (final o in c.types) o == type ? t : o], charges: charges));
}

/// Takes a type off the list; the last one stays.
Map<String, dynamic> removePetType(Map<String, dynamic> s, String type) {
  final c = petConfigOf(s);
  if (!c.types.contains(type) || c.types.length <= 1) return s;
  return _withPets(
    s,
    _pets(c, types: [for (final o in c.types) if (o != type) o], charges: {...c.charges}..remove(type)),
  );
}

Map<String, dynamic> movePetType(Map<String, dynamic> s, String type, int dir) {
  final c = petConfigOf(s);
  final order = _moved(c.types, type, dir);
  return order == null ? s : _withPets(s, _pets(c, types: order));
}

/// Offers [size] or not (XS to XL, in that order); at least one stays.
Map<String, dynamic> setPetSizeOffered(Map<String, dynamic> s, String size, bool on) {
  final c = petConfigOf(s);
  final next = [
    for (final z in PetConfig.defaultSizes)
      if (z == size ? on : c.sizes.contains(z)) z,
  ];
  if (next.isEmpty) return s;
  return _withPets(s, _pets(c, sizes: next, sizeExtras: {...c.sizeExtras}..removeWhere((k, _) => !next.contains(k))));
}

Map<String, dynamic> setPetMaxPerType(Map<String, dynamic> s, num n) =>
    _withPets(s, _pets(petConfigOf(s), maxPerType: n.round().clamp(1, PetConfig.maxPerTypeLimit)));

Map<String, dynamic> setPetPhotoRequired(Map<String, dynamic> s, bool on) =>
    _withPets(s, _pets(petConfigOf(s), photoRequired: on));

/// The extra for each pet of [size]; 0 for none.
Map<String, dynamic> setPetSizeExtra(Map<String, dynamic> s, String size, double amount) {
  final c = petConfigOf(s);
  final extras = {...c.sizeExtras}..remove(size);
  if (amount > 0 && c.sizes.contains(size)) extras[size] = amount;
  return _withPets(s, _pets(c, sizeExtras: extras));
}

// The assistance catalogue.

AssistanceCatalogue assistanceOf(Map<String, dynamic> s) => AssistanceCatalogue.fromSettings(s);

Map<String, dynamic> _withAssistance(Map<String, dynamic> s, List<AssistanceItem> items) =>
    {...s, ...AssistanceCatalogue(items: items).toSettings()};

/// Why [item] can't be saved; null when it can.
String? assistanceItemProblem(AssistanceItem item) {
  if (item.name.trim().isEmpty) return 'Type a name.';
  if (item.name.trim().length > assistanceNameMax) return 'Keep the name under $assistanceNameMax characters.';
  if (item.group.trim().isEmpty) return 'Pick a group or type a new one.';
  if (item.charge.isPercent && item.charge.value > 100) return 'A percentage is at most 100%.';
  return null;
}

/// A new item at the end of its group.
Map<String, dynamic> addAssistanceItem(Map<String, dynamic> s, AssistanceItem item) {
  final items = [...assistanceOf(s).items];
  if (assistanceItemProblem(item) != null || items.any((i) => i.id == item.id)) return s;
  if (items.length >= AssistanceCatalogue.maxItems) return s;
  final last = items.lastIndexWhere((i) => i.group == item.group);
  items.insert(last == -1 ? items.length : last + 1, item);
  return _withAssistance(s, items);
}

/// Replaces the item with [item]'s id.
Map<String, dynamic> updateAssistanceItem(Map<String, dynamic> s, AssistanceItem item) {
  if (assistanceItemProblem(item) != null) return s;
  return _withAssistance(s, [for (final i in assistanceOf(s).items) i.id == item.id ? item : i]);
}

Map<String, dynamic> removeAssistanceItem(Map<String, dynamic> s, String id) =>
    _withAssistance(s, [for (final i in assistanceOf(s).items) if (i.id != id) i]);

Map<String, dynamic> setAssistanceItemShown(Map<String, dynamic> s, String id, bool shown) => _withAssistance(s, [
  for (final i in assistanceOf(s).items) i.id == id ? i.copyWith(hidden: !shown) : i,
]);

/// Moves an item up (-1) or down (1) within its group.
Map<String, dynamic> moveAssistanceItem(Map<String, dynamic> s, String id, int dir) {
  final items = [...assistanceOf(s).items];
  final i = items.indexWhere((x) => x.id == id);
  if (i < 0) return s;
  var j = i + dir;
  while (j >= 0 && j < items.length && items[j].group != items[i].group) {
    j += dir;
  }
  if (j < 0 || j >= items.length) return s;
  final a = items[i];
  items[i] = items[j];
  items[j] = a;
  return _withAssistance(s, items);
}
