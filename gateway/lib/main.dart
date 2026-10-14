import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/backend.dart';
import 'src/engine.dart';
import 'src/keeper.dart';
import 'src/permissions.dart';
import 'src/settings.dart';
import 'src/sms_platform.dart';

/// The GET.ride Supabase project (the same as the GET.ride app). The anon
/// key is public and RLS-restricted; override both with --dart-define.
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://rqlavogkgywxspuxgiwk.supabase.co');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: _defaultAnonKey);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);
  final db = Supabase.instance.client;
  final settings = await GatewaySettings.load();
  final platform = MethodChannelSmsPlatform();
  final permissions = PluginGatewayPermissions();
  // Made here, not by the screen: Android may run this with no screen at all
  // (the service brings the gateway back after a restart or the app being
  // ended), and the gateway runs on after the screen is closed.
  final engine = GatewayEngine(
    backend: SupabaseGatewayBackend(db),
    platform: platform,
    config: settings.config,
    appVersion: gatewayVersion,
  );
  final keeper = GatewayKeeper(
    engine: engine,
    settings: settings,
    platform: platform,
    permissions: permissions,
    signedIn: () => db.auth.currentSession != null,
  );
  platform.onResume(keeper.resume);
  runApp(GatewayApp(db: db, settings: settings, platform: platform, permissions: permissions, engine: engine));
  await keeper.resume();
}

/// The project's public anon key (as in the GET.ride app's AppConfig).
const _defaultAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJxbGF2b2drZ3l3eHNwdXhnaXdrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg0NTk5NzQsImV4cCI6MjA5NDAzNTk3NH0.xzx_EdvoOeTLxNQTIzG0EiF9H34OlHirHAdSVA4_aG0';
