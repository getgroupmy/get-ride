import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'admin/admin_routes.dart';
import 'config.dart';
import 'admin/screens/meterapp/always_on_screen.dart' show alwaysOnStoreProvider, defaultAlwaysOnRoutes;
import 'core/always_on.dart';
import 'core/connection_check.dart';
import 'core/push_logic.dart';
import 'data/auth_repository.dart';
import 'data/app_display_repository.dart';
import 'data/branding_cache.dart';
import 'data/push_service.dart';
import 'data/session_tracker.dart';
import 'features/auth/otp_screen.dart';
import 'features/ev/ev_order_screen.dart';
import 'features/meter/meter_screen.dart';
import 'features/meter/obd_reader_screen.dart';
import 'features/meter/printer_screen.dart';
import 'features/meter/vehicle_info_screen.dart';
import 'features/auth/phone_screen.dart';
import 'features/auth/pin_screen.dart';
import 'features/auth/registration_closed_screen.dart';
import 'features/auth/set_pin_screen.dart';
import 'features/partner/partner_onboarding_screen.dart';
import 'features/partner/driver_permit_screen.dart';
import 'features/partner/partner_screen.dart';
import 'features/partner/vehicle_screens.dart';
import 'features/partner/partner_trip_screen.dart';
import 'features/profile/account_screen.dart';
import 'features/profile/edit_profile_screen.dart';
import 'features/profile/emergency_contacts_screen.dart';
import 'features/profile/referral_screen.dart';
import 'features/profile/user_guide_screen.dart';
import 'features/safety/safety_screen.dart';
import 'features/ride/home_screen.dart';
import 'features/ride/ride_tracking_screen.dart';
import 'features/ride/trip_receipt_screen.dart';
import 'features/ride/trips_screen.dart';
import 'features/settings/change_phone_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/brand_splash.dart';
import 'features/shell/update_gate.dart';
import 'features/safety/voice_protection_controller.dart';
import 'features/support/support_chat_screen.dart';
import 'features/support/support_screen.dart';
import 'features/wallet/coin_trade_screen.dart';
import 'features/wallet/incoming_transfer_listener.dart';
import 'features/wallet/wallet_history_screen.dart';
import 'features/wallet/wallet_qr_screens.dart';
import 'features/wallet/wallet_screen.dart';
import 'providers.dart';
import 'widgets/connection_status_dialog.dart';

const brandAccent = Color(0xFF2DABE2);

/// The app theme. Note that [FilledButton]s are full width by default
/// (`Size.fromHeight`): one placed in a row or a list tile's `trailing` needs
/// its own `minimumSize`.
ThemeData appTheme(Brightness b) {
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
          path: 'closed',
          builder: (_, s) => RegistrationClosedScreen(phone: s.uri.queryParameters['phone'] ?? ''),
        ),
        GoRoute(
          path: 'set-pin',
          builder: (_, s) => SetPinScreen(changing: s.uri.queryParameters['change'] == '1'),
        ),
      ]),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/trips', builder: (_, _) => const TripsScreen(), routes: [
              GoRoute(path: ':id', builder: (_, s) => TripReceiptScreen(requestId: s.pathParameters['id']!)),
            ]),
          ]),
          StatefulShellBranch(routes: [GoRoute(path: '/wallet', builder: (_, _) => const WalletScreen(), routes: [
            GoRoute(
              path: 'trade',
              builder: (_, s) => CoinTradeScreen(
                sendTo: s.uri.queryParameters['to'],
                requestedAmount: double.tryParse(s.uri.queryParameters['amt'] ?? ''),
              ),
            ),
            GoRoute(path: 'scan', builder: (_, _) => const ScanPayScreen()),
            GoRoute(path: 'history', builder: (_, _) => const WalletHistoryScreen()),
            GoRoute(
              path: 'receive',
              builder: (_, s) => ReceiveQrScreen(coin: s.uri.queryParameters['coin'] == '1'),
            ),
          ])]),
          StatefulShellBranch(routes: [GoRoute(path: '/drive', builder: (_, _) => const PartnerScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/account', builder: (_, _) => const AccountScreen(), routes: [
              GoRoute(path: 'edit', builder: (_, _) => const EditProfileScreen()),
              GoRoute(path: 'referral', builder: (_, _) => const ReferralScreen()),
              GoRoute(path: 'safety', builder: (_, _) => const SafetyScreen()),
              GoRoute(path: 'emergency', builder: (_, _) => const EmergencyContactsScreen()),
              GoRoute(path: 'guide', builder: (_, _) => const UserGuideScreen()),
              GoRoute(path: 'settings', builder: (_, _) => const SettingsScreen(), routes: [
                GoRoute(path: 'phone', builder: (_, _) => const ChangePhoneScreen()),
              ]),
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
      GoRoute(path: '/drive/onboarding', builder: (_, _) => const PartnerOnboardingScreen()),
      GoRoute(path: '/ev', builder: (_, _) => const EvOrderScreen()),
      GoRoute(path: '/meter', builder: (_, _) => const MeterScreen()),
      GoRoute(path: '/meter/reader', builder: (_, _) => const ObdReaderScreen()),
      GoRoute(path: '/meter/printer', builder: (_, _) => const PrinterScreen()),
      GoRoute(path: '/meter/vehicle', builder: (_, _) => const VehicleInfoScreen()),
      GoRoute(path: '/drive/permit', builder: (_, _) => const DriverPermitScreen()),
      GoRoute(path: '/drive/vehicles', builder: (_, _) => const VehiclesScreen()),
      GoRoute(path: '/drive/vehicles/new', builder: (_, _) => const VehicleOnboardingScreen()),
      GoRoute(
        path: '/drive/vehicles/:id',
        builder: (_, s) => VehicleOnboardingScreen(vehicleId: s.pathParameters['id']),
      ),
      GoRoute(path: '/drive/trip/:id', builder: (_, s) => PartnerTripScreen(requestId: s.pathParameters['id']!)),
      adminRoute,
    ],
  );
});

class GetRideApp extends ConsumerStatefulWidget {
  const GetRideApp({super.key, this.branding});

  /// The splash cached by the previous launch (see [SplashGate]).
  final CachedBranding? branding;

  @override
  ConsumerState<GetRideApp> createState() => _GetRideAppState();
}

class _GetRideAppState extends ConsumerState<GetRideApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _subs = <StreamSubscription<Object?>>[];
  SessionTracker? _tracker;
  AppLifecycleListener? _lifecycle;
  AlwaysOnController? _alwaysOn;
  VoidCallback? _routeListener;
  BrandingSync? _branding;

  @override
  void initState() {
    super.initState();
    _branding = BrandingSync(ref.read(supabaseProvider));
    unawaited(_branding!.start());
    _startSessionTracking();
    _startAlwaysOn();
    unawaited(_connectionPopup());
    final push = PushService.instance;
    if (push == null) return;
    _subs.add(push.taps.listen(_open));
    _subs.add(push.foreground.listen(_showForeground));
    // The notification that launched the app, opened once the router exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = push.takePendingRoute();
      if (route != null) _open(route);
    });
  }

  /// Admin → Display Settings → Connection Status Popups: once per launch,
  /// tell the user whether the server answered. Shown once the router's
  /// navigator exists, so after the splash.
  Future<void> _connectionPopup() async {
    final check = await checkBackend(AppConfig.supabaseUrl, AppConfig.supabaseAnonKey);
    final display = await ref.read(appDisplayProvider.future);
    final popup = connectionPopupFor(
      check,
      connectedOn: display.connectedPopup,
      failedOn: display.connectionFailedPopup,
    );
    if (popup == null) return;
    for (var i = 0; i < 40 && mounted; i++) {
      final ctx = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await showConnectionStatus(ctx, popup, check);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Session and location rows for the admin Session History and fraud
  /// screens (see `data/session_tracker.dart`).
  void _startSessionTracking() {
    final db = ref.read(supabaseProvider);
    final tracker = SessionTracker(
      sink: SupabaseSessionSink(db),
      location: GeolocatorTelemetryLocation(),
      deviceId: ref.read(authRepositoryProvider).deviceIdentifier,
      device: currentDevice(),
    );
    _tracker = tracker;
    unawaited(tracker.launched());
    ref.listenManual<String?>(currentUserIdProvider, (_, id) {
      unawaited(tracker.userChanged(id, phone: db.auth.currentUser?.phone));
    }, fireImmediately: true);
    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(tracker.resumed());
        unawaited(_alwaysOn?.reload());
      },
    );
  }

  /// Keeps the screen awake on the admin's Always ON pages (see
  /// `core/always_on.dart`). The set is re-read whenever the app comes back
  /// to the foreground, so an admin's change lands without a relaunch.
  void _startAlwaysOn() {
    final controller = AlwaysOnController(
      setAwake: (on) => WakelockPlus.toggle(enable: on),
      loadRoutes: () async {
        try {
          return (await ref.read(alwaysOnStoreProvider).fetch()).routes;
        } catch (_) {
          return defaultAlwaysOnRoutes;
        }
      },
    );
    _alwaysOn = controller;
    final router = ref.read(routerProvider);
    void onRoute() => unawaited(controller.navigated(router.routerDelegate.currentConfiguration.uri.path));
    _routeListener = onRoute;
    router.routerDelegate.addListener(onRoute);
    unawaited(controller.reload().then((_) => onRoute()));
  }

  @override
  void dispose() {
    if (_routeListener != null) ref.read(routerProvider).routerDelegate.removeListener(_routeListener!);
    unawaited(_alwaysOn?.dispose());
    _lifecycle?.dispose();
    _tracker?.dispose();
    _branding?.stop();
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  void _open(String route) => ref.read(routerProvider).go(route);

  /// Android does not show a notification that arrives while the app is open,
  /// so it is shown as a banner instead. iOS shows its own.
  void _showForeground(RemoteMessage message) {
    final title = message.notification?.title ?? '';
    final body = message.notification?.body ?? '';
    if (title.isEmpty && body.isEmpty) return;
    final route = pushRouteFor(message.data);
    _messenger.currentState?.showSnackBar(SnackBar(
      content: Text([title, body].where((s) => s.isNotEmpty).join('\n')),
      duration: const Duration(seconds: 6),
      action: route == null ? null : SnackBarAction(label: 'Open', onPressed: () => _open(route)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'GET.ride',
      scaffoldMessengerKey: _messenger,
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
      builder: (_, child) => SplashGate(
        cached: widget.branding,
        live: _branding?.latest,
        child: UpdateGate(
          child: VoiceProtectionHost(
            child: IncomingTransferListener(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }
}
