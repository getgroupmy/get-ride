/// Build-time configuration.
///
/// Defaults point at the same Supabase project the Expo app uses
/// (`expo/utils/supabase.ts` in getgroupmy/get.ride), so both clients share one
/// database. Override per build with:
///
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
///
/// The anon key is a public, RLS-restricted key — it is safe to ship in a
/// client binary. Never put a service-role key here.
class AppConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://rqlavogkgywxspuxgiwk.supabase.co',
  );

  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJxbGF2b2drZ3l3eHNwdXhnaXdrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg0NTk5NzQsImV4cCI6MjA5NDAzNTk3NH0.xzx_EdvoOeTLxNQTIzG0EiF9H34OlHirHAdSVA4_aG0',
  );

  /// Default currency for new ride requests (matches the Expo default).
  static const currency = String.fromEnvironment('CURRENCY', defaultValue: 'MYR');

  /// Default country calling code pre-filled on the phone screen.
  static const defaultDialCode =
      String.fromEnvironment('DIAL_CODE', defaultValue: '+60');

  /// Open ride requests expire after this long without a partner
  /// (`REQUEST_EXPIRY_MS` in the Expo app).
  static const requestExpiry = Duration(minutes: 7);
}
