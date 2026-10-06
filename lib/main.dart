import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/config.dart';
import 'src/core/referral.dart';
import 'src/data/branding_cache.dart';
import 'src/data/push_service.dart';

Future<void> main() async {
  // Real paths (/rides) instead of hash URLs (/#/rides) on web, so links read
  // cleanly and Vercel Analytics can tell screens apart. No-op elsewhere.
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  // An invite link (getride.my/?ref=CODE) carries the friend's code; it is
  // offered on the set-PIN step of a new account.
  PendingReferral.code = referralCodeFromUri(Uri.base);
  await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseAnonKey);
  // Push notifications, on Android and iOS builds that carry a Firebase
  // project. A no-op everywhere else.
  await PushService.start(Supabase.instance.client);
  // The admin's splash, as cached by the last launch, so it paints on the
  // first frame (see BrandSplash).
  final branding = await BrandingCache.load();
  runApp(ProviderScope(child: GetRideApp(branding: branding)));
}
