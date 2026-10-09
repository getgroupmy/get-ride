import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/settings.dart';

/// The GET.ride Supabase project (the same as the GET.ride app). The anon
/// key is public and RLS-restricted; override both with --dart-define.
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://rqlavogkgywxspuxgiwk.supabase.co');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: _defaultAnonKey);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);
  final settings = await GatewaySettings.load();
  runApp(GatewayApp(db: Supabase.instance.client, settings: settings));
}

/// The project's public anon key (as in the GET.ride app's AppConfig).
const _defaultAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJxbGF2b2drZ3l3eHNwdXhnaXdrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg0NTk5NzQsImV4cCI6MjA5NDAzNTk3NH0.xzx_EdvoOeTLxNQTIzG0EiF9H34OlHirHAdSVA4_aG0';
