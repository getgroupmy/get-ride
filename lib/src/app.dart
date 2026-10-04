import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin/admin_routes.dart';
import 'data/auth_repository.dart';
import 'features/auth/otp_screen.dart';
import 'features/auth/phone_screen.dart';
import 'features/auth/pin_screen.dart';
import 'features/auth/set_pin_screen.dart';
import 'features/partner/partner_screen.dart';
import 'features/partner/partner_trip_screen.dart';
import 'features/profile/account_screen.dart';
import 'features/profile/edit_profile_screen.dart';
import 'features/profile/emergency_contacts_screen.dart';
import 'features/ride/home_screen.dart';
import 'features/ride/ride_tracking_screen.dart';
import 'features/ride/trips_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/support/support_chat_screen.dart';
import 'features/support/support_screen.dart';
import 'features/wallet/wallet_screen.dart';
import 'providers.dart';

const brandAccent = Color(0xFF2DABE2);

ThemeData _theme(Brightness b) {
  final scheme = ColorScheme.fromSeed(
    seedColor: brandAccent,
    brightness: b,
    primary: b == Brightness.light ? const Color(0xFF111827) : brandAccent,
    onPrimary: b == Brightness.light ? Colors.white : Colors.black,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: b == Brightness.light ? Colors.white : const Color(0xFF0B0F17),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      filled: true,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
  );
}

/// Re-runs router redirects whenever the auth session changes.
class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Stream<AuthState> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }
  late final StreamSubscription<AuthState> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final db = ref.watch(supabaseProvider);
  final refresh = _AuthListenable(db.auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final signedIn = db.auth.currentSession != null;
      final loc = state.matchedLocation;
      final onAuth = loc.startsWith('/login');
      if (!signedIn && !onAuth) return '/login';
      // A fresh OTP session still has to choose a PIN before entering the app.
      if (signedIn && AuthRepository.pinSetupPending) {
        return loc == '/login/set-pin' ? null : '/login/set-pin';
      }
      if (signedIn && onAuth) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const PhoneScreen(), routes: [
        GoRoute(
          path: 'otp',
          builder: (_, s) => OtpScreen(
            phone: s.uri.queryParameters['phone'] ?? '',
            next: s.uri.queryParameters['next'] ?? 'set-pin',
            pin: s.extra as String?,
          ),
        ),
        GoRoute(path: 'pin', builder: (_, s) => PinScreen(phone: s.uri.queryParameters['phone'] ?? '')),
        GoRoute(
          path: 'set-pin',
          builder: (_, s) => SetPinScreen(changing: s.uri.queryParameters['change'] == '1'),
        ),
      ]),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/trips', builder: (_, _) => const TripsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/wallet', builder: (_, _) => const WalletScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/drive', builder: (_, _) => const PartnerScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/account', builder: (_, _) => const AccountScreen(), routes: [
              GoRoute(path: 'edit', builder: (_, _) => const EditProfileScreen()),
              GoRoute(path: 'emergency', builder: (_, _) => const EmergencyContactsScreen()),
              GoRoute(path: 'settings', builder: (_, _) => const SettingsScreen()),
              GoRoute(path: 'support', builder: (_, _) => const SupportScreen(), routes: [
                GoRoute(
                  path: ':ticketId',
                  builder: (_, s) => SupportChatScreen(ticketId: s.pathParameters['ticketId']!),
                ),
              ]),
            ]),
          ]),
        ],
      ),
      GoRoute(path: '/ride/:id', builder: (_, s) => RideTrackingScreen(requestId: s.pathParameters['id']!)),
      GoRoute(path: '/drive/trip/:id', builder: (_, s) => PartnerTripScreen(requestId: s.pathParameters['id']!)),
      adminRoute,
    ],
  );
});

class GetRideApp extends ConsumerWidget {
  const GetRideApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'GET.ride',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
