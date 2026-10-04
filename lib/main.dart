import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/config.dart';
import 'src/data/push_service.dart';

Future<void> main() async {
  // Real paths (/rides) instead of hash URLs (/#/rides) on web, so links read
  // cleanly and Vercel Analytics can tell screens apart. No-op elsewhere.
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseAnonKey);
  // Push notifications, on Android and iOS builds that carry a Firebase
  // project. A no-op everywhere else.
  await PushService.start(Supabase.instance.client);
  runApp(const ProviderScope(child: GetRideApp()));
}
