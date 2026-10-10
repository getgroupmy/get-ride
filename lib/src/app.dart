import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'admin/admin_providers.dart' show adminAccessProvider;
import 'admin/admin_routes.dart';
import 'config.dart';
import 'admin/screens/meterapp/always_on_screen.dart' show alwaysOnStoreProvider, defaultAlwaysOnRoutes;
import 'core/always_on.dart';
import 'core/app_branding.dart';
import 'core/connection_check.dart';
import 'core/demo_mode.dart';
import 'core/push_logic.dart';
import 'data/auth_repository.dart';
import 'data/app_display_repository.dart';
import 'data/branding_cache.dart';
import 'data/messaging_repository.dart';
import 'data/push_service.dart';
import 'data/session_tracker.dart';
import 'features/auth/otp_screen.dart';
import 'features/ev/ev_order_screen.dart';
import 'features/meter/hail_destination_screen.dart';
import 'features/meter/meter_screen.dart';
import 'features/ride/shared_ride_screen.dart';
import 'features/meter/obd_reader_screen.dart';
import 'features/meter/printer_screen.dart';
import 'features/meter/vehicle_info_screen.dart';
import 'features/auth/phone_screen.dart';
import 'features/auth/pin_screen.dart';
import 'features/auth/registration_closed_screen.dart';
import 'features/auth/signup_photo_screen.dart';
import 'features/auth/set_pin_screen.dart';
import 'features/partner/demo_jobs.dart';
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
import 'features/ride/demo_ride.dart';
import 'features/ride/home_screen.dart';
import 'features/ride/ride_call_screen.dart';
import 'features/ride/ride_chat_screen.dart';
import 'features/ride/ride_tracking_screen.dart';
import 'features/ride/trip_receipt_screen.dart';
import 'features/ride/trips_screen.dart';
import 'features/settings/change_phone_screen.dart';
import 'features/settings/auth_diagnostics_screen.dart';
import 'features/settings/change_pin_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/brand_splash.dart';
import 'features/shell/app_side_menu.dart';
import 'features/shell/update_gate.dart';
import 'features/safety/voice_protection_controller.dart';
import 'features/support/help_assistant_screen.dart';
import 'features/support/support_chat_screen.dart';
import 'features/support/support_screen.dart';
import 'features/wallet/coin_trade_screen.dart';
import 'features/wallet/incoming_transfer_listener.dart';
import 'features/support/call/call_screen.dart';
import 'features/support/call/incoming_call_listener.dart';
import 'features/wallet/wallet_history_screen.dart';
import 'features/wallet/wallet_qr_screens.dart';
import 'features/wallet/wallet_screen.dart';
import 'providers.dart';
import 'platform/web_favicon.dart';
import 'widgets/app_icon_changed.dart';
import 'widgets/connection_status_dialog.dart';
import 'widgets/keyboard_dismiss.dart';
import 'widgets/map_sheet_layout.dart' show appBottomSheetTheme;

const brandAccent = Color(0xFF2DABE2);

/// The app theme. Note that [FilledButton]s are full width by default
/// (`Size.fromHeight`): one placed in a row or a list tile's `trailing` needs
/// its own `minimumSize`. [colors] are the admin's overrides for this theme
/// (Admin → App Settings → Theme Colors, keys from [themeColorKeys]); any
/// not set keeps the colour below.
ThemeData appTheme(Brightness b, {Map<String, String> colors = const {}}) {
  final light = b == Brightness.light;
  Color? pick(String key) => brandHexColor(colors[key]);
  final accent = pick('accent') ?? brandAccent;
  final primary = pick('primary') ?? (light ? const Color(0xFF111827) : accent);
  final background = pick('background') ?? (light ? Colors.white : const Color(0xFF0B0F17));
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: b,
    primary: primary,
    onPrimary: primary.computeLuminance() > 0.18 ? Colors.black : Colors.white,
    onSurface: pick('text'),
    onSurfaceVariant: pick('textSecondary'),
    outlineVariant: pick('border'),
    error: pick('error'),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: background,
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
    // Every bottom sheet: rounded top corners and a handle to drag it by
    // (down to close; the tall ones also up to expand).
    bottomSheetTheme: appBottomSheetTheme,
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
      // Diagnostics are for people who can't sign in, so they work either way.
      if (loc == '/diagnostics') return null;
      // A shared ride is for whoever was sent the link, account or not.
      if (loc.startsWith('/share/')) return null;
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
            createUser: s.uri.queryParameters['new'] == '1',
          ),
        ),
        GoRoute(path: 'pin', builder: (_, s) => PinScreen(phone: s.uri.queryParameters['phone'] ?? '')),
        GoRoute(
          path: 'closed',
          builder: (_, s) => RegistrationClosedScreen(phone: s.uri.queryParameters['phone'] ?? ''),
        ),
        GoRoute(
          path: 'set-pin',
          builder: (_, _) => const SetPinScreen(),
        ),
      ]),
      // The rider's and the driver's pages, under the Expo side menu that
      // pushes them aside: the rider menu or the driver menu by mode
      // ([AppSideMenuHost]).
      ShellRoute(
        builder: (_, state, child) => AppSideMenuHost(location: state.uri.path, child: child),
        routes: [
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
                  GoRoute(path: 'help', builder: (_, _) => const HelpAssistantScreen()),
                  GoRoute(path: 'settings', builder: (_, _) => const SettingsScreen(), routes: [
                    GoRoute(path: 'phone', builder: (_, _) => const ChangePhoneScreen()),
                    GoRoute(path: 'pin', builder: (_, _) => const ChangePinScreen()),
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
          GoRoute(
            path: '/ride/demo',
            builder: (_, s) => s.extra is DemoTripArgs ? DemoTripScreen(args: s.extra! as DemoTripArgs) : const HomeScreen(),
          ),
          GoRoute(
            path: '/ride/:id',
            builder: (_, s) => RideTrackingScreen(requestId: s.pathParameters['id']!),
            routes: [GoRoute(path: 'chat', builder: (_, s) => RideChatScreen(requestId: s.pathParameters['id']!))],
          ),
          GoRoute(path: '/ev', builder: (_, _) => const EvOrderScreen()),
          // Driver mode's pages, under the driver menu.
          GoRoute(path: '/drive/onboarding', builder: (_, _) => const PartnerOnboardingScreen()),
          GoRoute(
            path: '/drive/demo',
            builder: (_, s) => s.extra is DemoJob ? DemoJobScreen(job: s.extra! as DemoJob) : const PartnerScreen(),
          ),
          GoRoute(path: '/meter/vehicle', builder: (_, _) => const VehicleInfoScreen()),
          GoRoute(path: '/drive/permit', builder: (_, _) => const DriverPermitScreen()),
          GoRoute(path: '/drive/vehicles', builder: (_, _) => const VehiclesScreen()),
          GoRoute(path: '/drive/vehicles/new', builder: (_, _) => const VehicleOnboardingScreen()),
          GoRoute(
            path: '/drive/vehicles/:id',
            builder: (_, s) => VehicleOnboardingScreen(vehicleId: s.pathParameters['id']),
          ),
          GoRoute(
            path: '/drive/trip/:id',
            builder: (_, s) => PartnerTripScreen(requestId: s.pathParameters['id']!),
            routes: [GoRoute(path: 'chat', builder: (_, s) => RideChatScreen(requestId: s.pathParameters['id']!))],
          ),
        ],
      ),
      GoRoute(
        path: '/signup/photo',
        // Only the two sign-up landings, never an arbitrary route from the URL.
        builder: (_, s) => SignupPhotoScreen(
          next: signupLanding(s.uri.queryParameters['next'] == '/drive' ? 'driver' : null),
        ),
      ),
      GoRoute(path: '/diagnostics', builder: (_, _) => const AuthDiagnosticsScreen()),
      GoRoute(path: '/share/:token', builder: (_, st) => SharedRideScreen(token: st.pathParameters['token']!)),
      GoRoute(
        path: '/meter',
        builder: (_, st) => MeterScreen(launch: st.extra is MeterLaunch ? st.extra! as MeterLaunch : null),
      ),
      GoRoute(path: '/meter/reader', builder: (_, _) => const ObdReaderScreen()),
      GoRoute(path: '/meter/printer', builder: (_, _) => const PrinterScreen()),
      GoRoute(
        path: '/meter/destination',
        // Only reachable from the meter, which hands over its card.
        redirect: (_, st) => st.extra is HailDestinationArgs ? null : '/meter',
        builder: (_, st) => HailDestinationScreen(args: st.extra! as HailDestinationArgs),
      ),
      GoRoute(
        path: '/call/:id',
        builder: (_, s) => CallScreen(callId: s.pathParameters['id']!, peerName: s.uri.queryParameters['name']),
      ),
      // A rider ↔ driver call (migration 0131).
      GoRoute(path: '/ride-call/:id', builder: (_, s) => RideCallScreen(callId: s.pathParameters['id']!)),
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
  MessagingPresence? _presence;

  @override
  void initState() {
    super.initState();
    _branding = BrandingSync(ref.read(supabaseProvider));
    setWebFavicon(widget.branding?.branding.appIconUrl);
    _branding!.latest.addListener(_brandingChanged);
    unawaited(_branding!.start());
    _startSessionTracking();
    _startAlwaysOn();
    _startMessagingPresence();
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

  /// The admin's app icon (Admin → App Settings): the website's tab icon
  /// follows it, and each device is told once when it changes.
  Future<void> _brandingChanged() async {
    final b = _branding?.latest.value;
    if (b == null) return;
    setWebFavicon(b.appIconUrl);
    if (!await takeIconChange(b)) return;
    for (var i = 0; i < 40 && mounted; i++) {
      final ctx = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await showAppIconChanged(ctx, b.appIconUrl);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
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

  /// An admin's install is listed under Admin → SMS / WhatsApp so it can be
  /// picked to take support calls; its heartbeat runs while an admin is
  /// signed in and stops when they sign out.
  void _startMessagingPresence() {
    ref.listenManual(adminAccessProvider, (_, next) async {
      final admin = next.value?.isAdmin ?? false;
      if (!admin) {
        _presence?.stop();
        _presence = null;
        return;
      }
      if (_presence != null) return;
      final device = currentDevice();
      final id = await ref.read(authRepositoryProvider).deviceIdentifier();
      if (!mounted || _presence != null) return;
      _presence = MessagingPresence(
        repo: ref.read(messagingRepositoryProvider),
        deviceId: id,
        label: '${device.osName} ${device.deviceType}',
        platform: device.osName,
      )..start();
    }, fireImmediately: true);
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
    _presence?.stop();
    _branding?.latest.removeListener(_brandingChanged);
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
    // A ride call already rings full screen (RideCallListener).
    if (message.data['type'] == 'ride_call') return;
    final route = pushRouteFor(message.data);
    // A chat message while that chat is on screen is already in front of them.
    if (route != null && route == ref.read(routerProvider).routerDelegate.currentConfiguration.uri.path) return;
    _messenger.currentState?.showSnackBar(SnackBar(
      content: Text([title, body].where((s) => s.isNotEmpty).join('\n')),
      duration: const Duration(seconds: 6),
      action: route == null ? null : SnackBarAction(label: 'Open', onPressed: () => _open(route)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final router = ref.watch(routerProvider);
    final live = _branding?.latest;
    if (live == null) return _app(widget.branding?.branding, mode, router);
    return ValueListenableBuilder<AppBranding?>(
      valueListenable: live,
      builder: (_, latest, _) => _app(latest ?? widget.branding?.branding, mode, router),
    );
  }

  /// The app under [branding]'s theme colours (Admin → App Settings), which
  /// change live as the admin saves them.
  Widget _app(AppBranding? branding, ThemeMode mode, GoRouter router) {
    return MaterialApp.router(
      title: 'GET.ride',
      scaffoldMessengerKey: _messenger,
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light, colors: branding?.lightColors ?? const {}),
      darkTheme: appTheme(Brightness.dark, colors: branding?.darkColors ?? const {}),
      themeMode: mode,
      routerConfig: router,
      builder: (_, child) => SplashGate(
        cached: widget.branding,
        live: _branding?.latest,
        child: UpdateGate(
          child: VoiceProtectionHost(
            child: IncomingTransferListener(
              child: IncomingCallListener(
                child: RideCallListener(
                  child: KeyboardDismissOnChange(
                    listenable: router.routerDelegate,
                    child: KeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
