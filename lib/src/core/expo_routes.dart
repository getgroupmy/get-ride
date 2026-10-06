/// Admin settings store links as Expo paths (`/teksi-ev`, `/safety`, …), so
/// the Expo app keeps working; this maps one onto the Flutter screen that
/// does the same job. Null means there is no such screen here.
library;

const _flutterRoots = ['/account', '/drive', '/meter', '/wallet', '/trips', '/ev', '/admin', '/ride'];

const _expoToFlutter = <String, String>{
  '/': '/',
  '/search': '/',
  '/map-picker': '/',
  '/ride-confirm': '/',
  '/offer-fare': '/',
  '/ride-detail': '/trips',
  '/ride-tracking': '/trips',
  '/profile': '/account',
  '/edit-profile': '/account/edit',
  '/profile-photo': '/account/edit',
  '/name-entry': '/account/edit',
  '/settings': '/account/settings',
  '/dark-mode': '/account/settings',
  '/language': '/account/settings',
  '/distances': '/account/settings',
  '/navigation': '/account/settings',
  '/rules-terms': '/account/settings',
  '/change-pin': '/account/settings',
  '/change-number': '/account/settings/phone',
  '/user-guide': '/account/guide',
  '/safety': '/account/safety',
  '/emergency-contacts': '/account/emergency',
  '/emergency-contact-edit': '/account/emergency',
  '/referral-card': '/account/referral',
  '/support': '/account/support',
  '/support-chat': '/account/support',
  '/teksi-ev': '/ev',
  '/wallet': '/wallet',
  '/wallet-trade': '/wallet/trade',
  '/partner-teksi': '/drive',
  '/partner-ehailing': '/drive',
  '/ride-running': '/drive',
  '/partner-onboarding': '/drive/onboarding',
  '/partner-documents': '/drive/onboarding',
  '/vehicle-onboarding': '/drive/vehicles/new',
  '/driver-permit': '/drive/permit',
  '/meter-digital': '/meter',
  '/obd2-reader': '/meter/reader',
  '/meter-printer': '/meter/printer',
  '/vehicle-information': '/meter/vehicle',
};

String? flutterRouteFor(String? path) {
  final raw = path?.trim() ?? '';
  if (raw.isEmpty || !raw.startsWith('/') || raw.startsWith('//')) return null;
  final p = raw.split('?').first.split('#').first;
  final mapped = _expoToFlutter[p];
  if (mapped != null) return mapped;
  if (p.startsWith('/admin')) return '/admin';
  for (final root in _flutterRoots) {
    if (p == root || p.startsWith('$root/')) return p;
  }
  return null;
}
