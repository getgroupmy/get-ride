import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/config.dart';
import 'src/core/app_branding.dart';
import 'src/core/backend_network.dart';
import 'src/core/backend_route.dart';
import 'src/core/push_logic.dart' show supabaseSessionKey;
import 'src/core/referral.dart';
import 'src/data/backend_lookup.dart' show pinnedHttpClient;
import 'src/data/backend_resolver.dart';
import 'src/data/branding_cache.dart';
import 'src/data/push_service.dart';
import 'src/data/timeout_http_client.dart';

Future<void> main() async {
  // Real paths (/rides) instead of hash URLs (/#/rides) on web, so links read
  // cleanly and Vercel Analytics can tell screens apart. No-op elsewhere.
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  // The splash is held for what is LEFT of five seconds from here, not five
  // seconds from the first frame, so a slow start is not made slower still.
  markSplashStart();
  // An invite link (getride.my/?ref=CODE) carries the friend's code; it is
  // offered on the set-PIN step of a new account.
  PendingReferral.code = referralCodeFromUri(Uri.base);
  // Every Supabase request (database, functions, storage, sign-in) goes
  // through a client that gives up on a server that does not answer, instead
  // of leaving the screen waiting on it (see core/server_timeout.dart).
  //
  // On a network that cannot look up the project's host, the backend's
  // second address is used (core/backend_route.dart). The session is kept
  // under the project's own key either way, so switching addresses never
  // signs anyone out.
  //
  // The admin's own addresses and DNS-over-HTTPS resolvers (Admin → App
  // Settings → Backend network) come with the branding cached by the last
  // launch, since a phone that cannot reach the backend cannot read them.
  // When only a resolver could find the address, requests connect to the
  // address it gave while still checking the certificate for the real name.
  final branding = await BrandingCache.load();
  final backend = await pickBackend(AppConfig.supabaseUrl, branding?.branding.network ?? BackendNetwork.none);
  setActiveBackendUrl(backend.url, pinnedIp: backend.pinnedIp);
  final pinned = backend.pinnedIp;
  await Supabase.initialize(
    url: backend.url,
    publishableKey: AppConfig.supabaseAnonKey,
    httpClient: TimeoutHttpClient(pinned == null ? null : pinnedHttpClient(backend.host, pinned)),
    authOptions: FlutterAuthClientOptions(
      localStorage: SharedPreferencesLocalStorage(persistSessionKey: supabaseSessionKey(AppConfig.supabaseUrl)),
    ),
  );
  // Push notifications, on Android and iOS builds that carry a Firebase
  // project. A no-op everywhere else.
  await PushService.start(Supabase.instance.client);
  // The admin's splash, as cached by the last launch (read above), so it
  // paints on the first frame (see SplashGate).
  applyBrandingGlobals(branding?.branding);
  runApp(ProviderScope(child: GetRideApp(branding: branding)));
}
