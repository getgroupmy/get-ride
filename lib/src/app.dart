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
import 'core/date_order.dart' show setProfileDateCountry;
import 'core/launch_destination.dart' show AppLaunch;
import 'core/auth_utils.dart'
    show
        PendingSignInRoute,
        ResyncPin,
        SignInPhone,
        rememberSignInTarget,
        signedInTarget,
        signInLocation,
        signInNextPath,
        signInStepPhone,
        signInStepRedirect;
import 'core/connection_check.dart';
import 'data/app_connection.dart';
import 'core/demo_mode.dart';
import 'core/my_qr.dart' show QrKind, isQrLinkLocation, qrSchemeLinkLocation;
import 'core/trip_card.dart' show tripCardLinkLocation;
import 'core/partner_remote_action.dart' show RemoteActionRequest, remoteActionIdFromPush, remoteActionLinkLocation, remoteActionRoute;
import 'features/partner/remote_action.dart' show remoteActionAskProvider, remoteActionHandlerProvider;
import 'data/trip_card_controller.dart' show tripCardControllerProvider;
import 'core/push_logic.dart';
import 'core/ride_bidding.dart' show BiddingRegion, pushPlaceAt;
import 'data/app_icon_service.dart';
import 'data/app_version_repository.dart' show appUpdateProvider, recordAppVersion;
import 'data/auth_repository.dart';
import 'data/app_display_repository.dart';
import 'data/branding_cache.dart';
import 'data/live_share.dart';
import 'data/live_tables.dart';
import 'data/messaging_repository.dart';
import 'data/background_location.dart';
import 'data/geo_service.dart' show AreaInfo, checkinPosition;
import 'data/notifications_repository.dart';
import 'data/permission_probe.dart';
import 'data/push_service.dart';
import 'data/session_guard.dart';
import 'data/session_tracker.dart';
import 'features/dispatch/dispatch_screen.dart';
import 'features/partner/stand_groups_screen.dart';
import 'features/partner/telematics_screen.dart';
import 'features/partner/ride_extras_parts.dart' show RideExtrasScreen;
import 'features/install/app_install_screen.dart';
import 'features/auth/otp_screen.dart';
import 'features/ev/ev_order_screen.dart';
import 'features/meter/hail_destination_screen.dart';
import 'features/meter/meter_screen.dart';
import 'features/ride/scheduled_rides_screen.dart';
import 'features/ride/shared_ride_screen.dart';
import 'features/meter/obd_reader_screen.dart';
import 'features/meter/printer_screen.dart';
import 'features/meter/vehicle_info_screen.dart';
import 'features/auth/phone_screen.dart';
import 'features/auth/welcome_screen.dart';
import 'features/auth/pin_screen.dart';
import 'features/auth/registration_closed_screen.dart';
import 'features/auth/signup_photo_screen.dart';
import 'features/auth/set_pin_screen.dart';
import 'features/partner/scheduled_jobs_screen.dart';
import 'features/partner/demo_jobs.dart';
import 'features/partner/my_ride_code_screen.dart';
import 'features/partner/my_permits_screen.dart';
import 'features/partner/driver_services_screen.dart';
import 'features/partner/earnings_screen.dart';
import 'features/partner/statement_verify_screen.dart';
import 'features/partner/statements_screen.dart';
import 'features/partner/partner_trip_history_screen.dart';
import 'features/partner/partner_onboarding_screen.dart';
import 'features/partner/driver_permit_screen.dart';
import 'features/partner/partner_screen.dart';
import 'features/partner/vehicle_screens.dart';
import 'features/partner/partner_trip_screen.dart';
import 'features/profile/account_screen.dart';
import 'features/profile/edit_profile_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/profile/emergency_contacts_screen.dart';
import 'features/profile/referral_screen.dart';
import 'features/my_ride/my_ride_screen.dart';
import 'features/my_qr/my_qr_screen.dart';
import 'features/my_qr/qr_link_screen.dart';
import 'features/my_qr/qr_result_sheet.dart' show PendingQrLink;
import 'features/profile/user_guide_screen.dart';
import 'features/safety/safety_screen.dart';
import 'features/ride/demo_ride.dart';
import 'features/ride/home_screen.dart';
import 'features/ride/ride_call_screen.dart';
import 'features/ride/ride_chat_screen.dart';
import 'features/ride/ride_tracking_screen.dart';
import 'features/ride/trip_receipt_screen.dart';
import 'features/ride/trips_screen.dart';
import 'features/settings/app_icon_screen.dart';
import 'features/settings/change_phone_screen.dart';
import 'features/settings/confirm_number_screen.dart';
import 'features/settings/auth_diagnostics_screen.dart';
import 'features/settings/change_pin_screen.dart';
import 'features/settings/delete_account_screen.dart';
import 'features/settings/passkeys_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/settings/show_location_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/brand_splash.dart';
import 'features/shell/not_found_screen.dart';
import 'features/shell/app_side_menu.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/notifications/push_message_screen.dart';
import 'features/shell/permission_gate.dart';
import 'features/shell/update_gate.dart';
import 'features/shell/web_build_gate.dart';
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
import 'widgets/android_nav_bar_inset.dart';
import 'widgets/keyboard_dismiss.dart';
import 'widgets/page_style_host.dart';
import 'widgets/route_title.dart';
import 'widgets/web_overlay_back.dart';
import 'core/page_styles.dart' show PageStyles;
import 'data/page_styles_repository.dart' show pageStylesProvider;
import 'data/device_details.dart';
import 'widgets/notifications_off_banner.dart';
import 'widgets/map_sheet_layout.dart' show appBottomSheetTheme;
import 'core/map_profile.dart' show waitForMapProfile;
import 'data/map_profile_repository.dart' show mapProfileProvider;
import 'data/map_appearance_repository.dart' show mapAppearanceProvider;
import 'core/map_appearance.dart' show MapAppearance;
import 'widgets/map_brightness.dart' show MapAppearanceScope;

const brandAccent = Color(0xFF2DABE2);

/// The largest text size the app takes from the phone's settings (Android
/// font size, iOS Larger Text); every screen is checked to fit at it.
const maxAppTextScale = 1.3;

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
  _AuthListenable(Stream<AuthState> stream, {Future<void> Function(AuthState)? onChange}) {
    _sub = stream.listen((s) {
      notifyListeners();
      // Then again once the server has said what the account still needs
      // (a PIN, 0192), so the redirect can act on it.
      onChange?.call(s).then((_) => notifyListeners(), onError: (_) {});
    });
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
  final refresh = _AuthListenable(
    db.auth.onAuthStateChange,
    onChange: (s) async {
      if (s.session != null && (s.event == AuthChangeEvent.initialSession || s.event == AuthChangeEvent.signedIn)) {
        await ref.read(authRepositoryProvider).syncPinRequirement();
      }
    },
  );
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: '/',
    // On the web, a sheet, dialog, menu or picker gets a browser history
    // entry, so Back closes it first (widgets/web_overlay_back.dart).
    observers: webOverlayBackObservers(),
    refreshListenable: refresh,
    // An address that is no page here (an old or mistyped link) gets a way
    // home instead of the router's bare error. Signed-out visitors are still
    // sent to sign-in first by [redirect]; /share/ and /install/ links match
    // their own routes and never land here.
    errorBuilder: notFoundPage,
    redirect: (context, state) {
      // getride://<kind>/<token> opened from outside: the router is handed
      // the whole URI, and the kind is its host, not its path.
      final schemeLink = qrSchemeLinkLocation(state.uri);
      if (schemeLink != null) return schemeLink;
      // getride://trip/<ride>?do=<button>: a button on the trip card
      // (core/trip_card.dart) opens the trip, to run it there.
      final cardLink = tripCardLinkLocation(state.uri);
      if (cardLink != null) return cardLink;
      // getride://remote/<id>: support's request the driver tapped on the
      // Android notification (0286) opens the Drive page that runs it.
      final remoteLink = remoteActionLinkLocation(state.uri);
      if (remoteLink != null) return remoteLink;
      final signedIn = db.auth.currentSession != null;
      final loc = state.matchedLocation;
      // The first app page of this run, for the launch-only rules.
      if (signedIn) AppLaunch.note(loc);
      final onAuth = loc.startsWith('/login');
      // Diagnostics are for people who can't sign in, so they work either way.
      if (loc == '/diagnostics') return null;
      // A shared ride is for whoever was sent the link, account or not.
      if (loc.startsWith('/share/')) return null;
      // So is confirming a new number support set: the link in the SMS (0282).
      if (loc.startsWith('/number/')) return null;
      // So is checking a statement's QR code: whoever was handed the statement.
      if (loc.startsWith('/verify/')) return null;
      // So is installing a test build: the tester has no account yet.
      if (loc.startsWith('/install/')) return null;
      // A personal QR link (My QR) works signed out too: a referral code is
      // carried into sign-up, a driver's code asks to sign in first. Both
      // /q/<kind>/<token> and the app-link form /<kind>/<token>.
      if (isQrLinkLocation(loc)) return null;
      // A deep link opened signed out: kept, and opened once signed in.
      if (!signedIn && !onAuth) {
        PendingSignInRoute.path = signInNextPath(state.uri.toString());
        return signInLocation(state.uri.toString());
      }
      // On a sign-in page: kept from /login's `next` or a later step's `to`
      // (a reload of /login/phone or /login/pin keeps it too).
      if (!signedIn && onAuth) rememberSignInTarget(loc, state.uri.queryParameters);
      // A sign-in step reloaded without its phone starts again from the number.
      if (!signedIn) {
        final step = signInStepRedirect(
          loc,
          state.uri.queryParameters,
          resyncPin: ResyncPin.value,
          phone: SignInPhone.value,
        );
        if (step != null) return step;
      }
      // A fresh OTP session still has to choose a PIN before entering the app.
      if (signedIn && AuthRepository.pinSetupPending) {
        return loc == '/login/set-pin' ? null : '/login/set-pin';
      }
      // Signed in after opening a driver's code: back to that code.
      if (signedIn && (onAuth || loc == '/') && PendingQrLink.path != null) return PendingQrLink.take();
      if (signedIn) {
        final target = signedInTarget(loc);
        if (target != null) return target;
      } else {
        PendingSignInRoute.signedOut();
      }
      if (signedIn && onAuth) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        // After the splash: continue with a passkey or with the phone.
        builder: (_, _) => const WelcomeScreen(),
        routes: [
          GoRoute(path: 'phone', builder: (_, _) => const PhoneScreen()),
          GoRoute(
            path: 'otp',
            builder: (_, s) => OtpScreen(
              phone: signInStepPhone(s.uri.queryParameters),
              next: s.uri.queryParameters['next'] ?? 'set-pin',
              pin: ResyncPin.value,
              createUser: s.uri.queryParameters['new'] == '1',
            ),
          ),
          GoRoute(
            path: 'pin',
            builder: (_, s) => PinScreen(phone: signInStepPhone(s.uri.queryParameters)),
          ),
          GoRoute(
            path: 'closed',
            builder: (_, s) => RegistrationClosedScreen(phone: signInStepPhone(s.uri.queryParameters)),
          ),
          GoRoute(path: 'set-pin', builder: (_, _) => const SetPinScreen()),
        ],
      ),
      // The rider's and the driver's pages, under the Expo side menu that
      // pushes them aside: the rider menu or the driver menu by mode
      // ([AppSideMenuHost]).
      ShellRoute(
        builder: (_, state, child) => AppSideMenuHost(location: state.uri.path, child: child),
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => AppShell(shell: shell),
            branches: [
              StatefulShellBranch(
                routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/trips',
                    builder: (_, _) => const TripsScreen(),
                    routes: [
                      // Before ':id', which would take "scheduled" for a ride.
                      GoRoute(path: 'scheduled', builder: (_, _) => const ScheduledRidesScreen()),
                      GoRoute(
                        path: ':id',
                        // A demo request has no receipt: the server never saw it.
                        redirect: (_, s) => isDemoRideId(s.pathParameters['id'] ?? '') ? '/trips' : null,
                        builder: (_, s) => TripReceiptScreen(requestId: s.pathParameters['id']!),
                      ),
                    ],
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/wallet',
                    builder: (_, _) => const WalletScreen(),
                    routes: [
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
                    ],
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/drive',
                    // ?remote=<id>: support's request the driver confirmed (0286).
                    builder: (_, s) => PartnerScreen(remoteActionId: s.uri.queryParameters['remote']),
                    // The driver's own pages, in the same shell as the
                    // rider's /account, /wallet and /trips: the navigation
                    // rail beside them on a wide screen.
                    routes: [
                      GoRoute(path: 'permit', builder: (_, _) => const DriverPermitScreen()),
                      GoRoute(path: 'my-ride', builder: (_, _) => const MyRideCodeScreen()),
                      GoRoute(
                        path: 'scheduled',
                        builder: (_, s) =>
                            ScheduledJobsScreen(initialTab: s.uri.queryParameters['tab'] == 'mine' ? 1 : 0),
                      ),
                      GoRoute(path: 'earnings', builder: (_, _) => const EarningsScreen()),
                      GoRoute(path: 'telematics', builder: (_, _) => const TelematicsScreen()),
                      GoRoute(path: 'groups', builder: (_, _) => const StandGroupsScreen()),
                      GoRoute(path: 'statements', builder: (_, _) => const StatementsScreen()),
                      GoRoute(
                        path: 'history',
                        builder: (_, _) => const PartnerTripHistoryScreen(),
                        routes: [
                          GoRoute(
                            path: ':id',
                            redirect: (_, s) => isDemoRideId(s.pathParameters['id'] ?? '') ? '/drive/history' : null,
                            builder: (_, s) => TripReceiptScreen(requestId: s.pathParameters['id']!),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/account',
                    builder: (_, _) => const AccountScreen(),
                    routes: [
                      GoRoute(path: 'profile', builder: (_, _) => const ProfileScreen()),
                      GoRoute(path: 'edit', builder: (_, _) => const EditProfileScreen()),
                      GoRoute(
                        path: 'notifications',
                        builder: (_, _) => const NotificationsScreen(),
                        // An admin push's full message (0279), from the
                        // push or its row on the page.
                        routes: [
                          GoRoute(
                            path: ':messageId',
                            builder: (_, s) => PushMessageScreen(messageId: s.pathParameters['messageId']!),
                          ),
                        ],
                      ),
                      GoRoute(path: 'referral', builder: (_, _) => const ReferralScreen()),
                      GoRoute(
                        path: 'my-ride',
                        builder: (_, _) => const MyRideScreen(),
                        routes: [GoRoute(path: 'settings', builder: (_, _) => const MyRideSettingsScreen())],
                      ),
                      GoRoute(path: 'my-qr', builder: (_, _) => const MyQrScreen()),
                      // The permissions page became a card in Settings: old
                      // links land there.
                      GoRoute(path: 'permissions', redirect: (_, _) => '/account/settings'),
                      GoRoute(path: 'safety', builder: (_, _) => const SafetyScreen()),
                      GoRoute(path: 'emergency', builder: (_, _) => const EmergencyContactsScreen()),
                      GoRoute(path: 'guide', builder: (_, _) => const UserGuideScreen()),
                      GoRoute(path: 'help', builder: (_, _) => const HelpAssistantScreen()),
                      GoRoute(
                        path: 'settings',
                        builder: (_, _) => const SettingsScreen(),
                        routes: [
                          GoRoute(path: 'phone', builder: (_, _) => const ChangePhoneScreen()),
                          GoRoute(path: 'pin', builder: (_, _) => const ChangePinScreen()),
                          GoRoute(path: 'passkeys', builder: (_, _) => const PasskeysScreen()),
                          GoRoute(path: 'delete', builder: (_, _) => const DeleteAccountScreen()),
                          GoRoute(path: 'show-location', builder: (_, _) => const ShowLocationScreen()),
                          GoRoute(path: 'app-icon', builder: (_, _) => const AppIconScreen()),
                          GoRoute(path: 'ride-extras', builder: (_, _) => const RideExtrasScreen()),
                        ],
                      ),
                      GoRoute(
                        path: 'support',
                        builder: (_, _) => const SupportScreen(),
                        routes: [
                          GoRoute(
                            path: ':ticketId',
                            builder: (_, s) => SupportChatScreen(ticketId: s.pathParameters['ticketId']!),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/ride/demo',
            builder: (_, s) =>
                s.extra is DemoTripArgs ? DemoTripScreen(args: s.extra! as DemoTripArgs) : const HomeScreen(),
          ),
          GoRoute(
            path: '/ride/:id',
            builder: (_, s) =>
                RideTrackingScreen(requestId: s.pathParameters['id']!, cardAction: s.uri.queryParameters['card']),
            routes: [
              GoRoute(
                path: 'chat',
                // A demo request has no driver to message.
                redirect: (_, s) {
                  final id = s.pathParameters['id'] ?? '';
                  return isDemoRideId(id) ? '/ride/$id' : null;
                },
                builder: (_, s) => RideChatScreen(requestId: s.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(path: '/ev', builder: (_, _) => const EvOrderScreen()),
          // Order dispatch (0251): a stand's console, its staff and charges, a fleet.
          GoRoute(path: '/dispatch', builder: (_, _) => const DispatchScreen()),
          // Driver mode's pages, under the driver menu.
          GoRoute(
            path: '/drive/onboarding',
            builder: (_, s) => PartnerOnboardingScreen(startAt: onboardingStepFromQuery(s.uri.queryParameters['step'])),
          ),
          GoRoute(
            path: '/drive/demo',
            builder: (_, s) => s.extra is DemoJob ? DemoJobScreen(job: s.extra! as DemoJob) : const PartnerScreen(),
          ),
          GoRoute(path: '/drive/vehicles', builder: (_, _) => const VehiclesScreen()),
          GoRoute(path: '/drive/vehicles/new', builder: (_, _) => const VehicleOnboardingScreen()),
          GoRoute(
            path: '/drive/vehicles/:id',
            builder: (_, s) => VehicleOnboardingScreen(vehicleId: s.pathParameters['id']),
            routes: [
              GoRoute(path: 'permit', builder: (_, s) => MyPermitsScreen(vehicleId: s.pathParameters['id'])),
            ],
          ),
          // Side menu > My permit (0254): the vehicle being driven and the driver's own.
          GoRoute(path: '/drive/permits', builder: (_, _) => const MyPermitsScreen()),
          // Side menu > Services (0263): what the car in use takes.
          GoRoute(path: '/drive/services', builder: (_, _) => const DriverServicesScreen()),
          GoRoute(
            path: '/drive/trip/:id',
            // Demo jobs play out on /drive/demo, never as a real trip.
            redirect: (_, s) => isDemoRideId(s.pathParameters['id'] ?? '') ? '/drive' : null,
            builder: (_, s) =>
                PartnerTripScreen(requestId: s.pathParameters['id']!, cardAction: s.uri.queryParameters['card']),
            routes: [
              GoRoute(
                path: 'chat',
                builder: (_, s) => RideChatScreen(requestId: s.pathParameters['id']!),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/signup/photo',
        // Only the two sign-up landings, never an arbitrary route from the URL.
        builder: (_, s) => SignupPhotoScreen(next: signupPhotoNext(s.uri.queryParameters['next'])),
      ),
      GoRoute(path: '/diagnostics', builder: (_, _) => const AuthDiagnosticsScreen()),
      GoRoute(
        path: '/share/:token',
        builder: (_, st) => SharedRideScreen(token: st.pathParameters['token']!),
      ),
      GoRoute(
        path: '/number/:token',
        builder: (_, st) => ConfirmNumberScreen(token: st.pathParameters['token']!),
      ),
      GoRoute(
        path: '/verify/:token',
        builder: (_, st) => StatementVerifyScreen(token: st.pathParameters['token']!),
      ),
      GoRoute(
        path: '/q/:kind/:token',
        builder: (_, st) => QrLinkScreen(kind: st.pathParameters['kind']!, token: st.pathParameters['token']!),
      ),
      // The same page as an app link on qr.getride.my arrives (a phone camera
      // opening the app, or the web app on that host): /ref|me|now/<token>.
      for (final k in QrKind.values)
        GoRoute(
          path: '/${k.pathSegment}/:token',
          builder: (_, st) => QrLinkScreen(kind: k.pathSegment, token: st.pathParameters['token']!),
        ),
      // Never in an App Store build: it installs builds over itms-services.
      if (!AppConfig.storeBuild)
        GoRoute(
          path: '/install/:platform',
          builder: (_, st) => AppInstallScreen(platform: st.pathParameters['platform']!),
        ),
      GoRoute(
        path: '/meter',
        builder: (_, st) => MeterScreen(launch: st.extra is MeterLaunch ? st.extra! as MeterLaunch : null),
      ),
      // The meter's own pages sit outside the side-menu shell: the meter
      // pushes them from outside it, and pushing a shell page from there
      // stacks a second copy of the shell over the one below -- a navigator
      // key clash that left Vehicle information a black screen.
      GoRoute(path: '/meter/reader', builder: (_, _) => const ObdReaderScreen()),
      GoRoute(path: '/meter/vehicle', builder: (_, _) => const VehicleInfoScreen()),
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
      GoRoute(
        path: '/ride-call/:id',
        builder: (_, s) => RideCallScreen(
          // A new key per answer, so Accept on the phone over the in-app
          // incoming call replaces it with one that answers.
          key: ValueKey('${s.pathParameters['id']}:${s.uri.queryParameters['answer']}'),
          callId: s.pathParameters['id']!,
          answer: s.uri.queryParameters['answer'] == '1',
        ),
      ),
      adminRoute,
    ],
  );
  // On the web, the browser's Back closes an open sheet, modal or side
  // menu before the router hears of it (widgets/web_overlay_back.dart).
  attachWebOverlayBack(() => router.routeInformationProvider.value);
  return router;
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
  late final Future<void> _updateChecked = ref.read(appUpdateProvider.future);

  @override
  void initState() {
    super.initState();
    _branding = BrandingSync(ref.read(supabaseProvider));
    setWebFavicon(widget.branding?.branding.appIconUrl);
    _branding!.latest.addListener(_brandingChanged);
    unawaited(_branding!.start());
    // The branding row live, on the app's live-settings channel rather than
    // a channel of its own (PERF-52).
    ref.listenManual(liveTablesProvider.select((r) => r['app_branding'] ?? 0), (_, _) {
      unawaited(_branding?.resync());
    });
    _startSessionTracking();
    _startAlwaysOn();
    _startMessagingPresence();
    _startPushLocation();
    ref.listenManual(remoteActionAskProvider, (_, r) {
      if (r != null) _askRemoteAction(r);
    });
    // In driver mode: a request from support may be waiting (0286).
    ref.listenManual(appModeProvider, (_, mode) {
      if (mode == 'partner') _runRemoteAction(null);
    }, fireImmediately: true);
    // The trip card on the lock screen (data/trip_card_controller.dart).
    ref.listenManual(tripCardControllerProvider, (_, _) {}, fireImmediately: true);
    // Admin → Settings → Maps: this user's and device's tiles and lookups.
    // The maps wait for them rather than show the app's own map first (on a
    // first launch at most `mapProfileFirstWait`, then the app's own map).
    waitForMapProfile();
    ref.listenManual(mapProfileProvider, (_, _) {}, fireImmediately: true);
    // Dates are typed and shown in the order of the user's country (the
    // profile's, else the phone's): DD/MM/YYYY, MM/DD/YYYY or YYYY/MM/DD.
    ref.listenManual(profileProvider, (_, next) => setProfileDateCountry(next.value?.nationality),
        fireImmediately: true);
    // The home-screen icon: the admin's season or the passenger's choice.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(appIconSyncProvider).sync());
    });
    unawaited(_connectionPopup());
    final push = PushService.instance;
    if (push == null) return;
    _subs.add(push.taps.listen(_open));
    _subs.add(push.foreground.listen(_showForeground));
    // A push about a ride (a driver took it, a trip started): the trip card
    // looks for the trip it may now show.
    _subs.add(push.received.listen((data) {
      if (data['request_id'] != null) unawaited(ref.read(tripCardControllerProvider.notifier).refresh());
      // God View asked for fresh phone details (0282); the closed app answers natively.
      if (data['type'] == 'location_ping' || data['type'] == 'location_live') unawaited(_tracker?.pinged());
      // Support asked this phone to change the driver's status (0286).
      final remote = remoteActionIdFromPush(data);
      if (remote != null) _runRemoteAction(remote);
    }));
    _startNotificationsWarning(push);
    // Notifications are asked for at launch, as soon as the splash is gone.
    unawaited(
      splashGone.future.then((_) => Future<void>.delayed(const Duration(milliseconds: 600))).then((_) {
        if (mounted) unawaited(push.askOnLaunch());
      }),
    );
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
  /// navigator exists, so after the splash. The server is only pinged when
  /// one of the popups is on.
  Future<void> _connectionPopup() async {
    final display = await ref.read(appDisplayProvider.future);
    final check = await checkBackendForPopups(
      AppConfig.supabaseUrl,
      AppConfig.supabaseAnonKey,
      connectedOn: display.connectedPopup,
      failedOn: display.connectionFailedPopup,
    );
    if (check == null) return;
    // What the check found also tells the offline strip (OfflineStrip).
    if (mounted) ref.read(appOfflineProvider.notifier).reachable(check.reachable);
    final popup = connectionPopupFor(
      check,
      connectedOn: display.connectedPopup,
      failedOn: display.connectionFailedPopup,
    );
    if (popup == null) return;
    for (var i = 0; i < 40 && mounted; i++) {
      final router = ref.read(routerProvider);
      final ctx = router.routerDelegate.navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        // Diagnostics already say what the popup would.
        if (onDiagnostics(router)) return;
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
      details: DeviceDetailsReader(
        permissions: ref.read(permissionProbeProvider),
        pushKey: () async => PushService.instance?.deviceKey(),
      ).read,
    );
    _tracker = tracker;
    unawaited(tracker.launched(userId: db.auth.currentUser?.id, phone: db.auth.currentUser?.phone));
    ref.listenManual<String?>(currentUserIdProvider, (_, id) {
      unawaited(tracker.userChanged(id, phone: db.auth.currentUser?.phone));
      // The installed version on the account, at launch and every sign-in.
      if (id != null) unawaited(recordAppVersion(db));
      // One device per account (0180): settle on one at launch without
      // taking the account back from a newer sign-in, and sign out here
      // the moment another device signs in.
      final guard = ref.read(authRepositoryProvider).guard;
      if (id != null) {
        unawaited(guard.claim(onlyIfUnclaimed: true));
        guard.watch(id);
        if (AuthRepository.offerPasskeyAfterSignIn) {
          AuthRepository.offerPasskeyAfterSignIn = false;
          unawaited(_offerPasskey(id));
        }
      } else {
        guard.unwatch();
      }
    }, fireImmediately: true);
    _sessionCheckTimer = Timer.periodic(sessionCheckEvery, (_) {
      unawaited(ref.read(authRepositoryProvider).guard.check());
    });
    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(tracker.resumed());
        unawaited(ref.read(authRepositoryProvider).guard.check());
        unawaited(_alwaysOn?.reload());
        unawaited(_branding?.resync());
        unawaited(_reportPushLocation());
        unawaited(PushService.instance?.recheckPermission());
        unawaited(ref.read(tripCardControllerProvider.notifier).refresh());
        // A driver back in the app: a request from support waiting (0286).
        if (ref.read(appModeProvider) == 'partner') _runRemoteAction(null);
        ref.invalidate(appIconRegionsProvider);
        unawaited(ref.read(appIconSyncProvider).sync());
      },
    );
  }

  bool _notificationsWarned = false;
  bool _notificationsDismissed = false;

  /// Notifications switched off for the app: calls and new rides can't reach
  /// a closed app, so the rider's and driver's screens say so, with the way
  /// to Settings. Gone once they are switched back on, or after "Not now"
  /// until the next launch.
  void _startNotificationsWarning(PushService push) {
    final router = ref.read(routerProvider);
    void sync() {
      if (!mounted) return;
      final warn = shouldWarnNotificationsOff(
        off: push.notificationsOff.value,
        signedIn: ref.read(currentUserIdProvider) != null,
        dismissed: _notificationsDismissed,
        location: router.routerDelegate.currentConfiguration.uri.path,
      );
      if (warn == _notificationsWarned) return;
      _notificationsWarned = warn;
      final messenger = _messenger.currentState;
      if (!warn) {
        messenger?.hideCurrentMaterialBanner();
        return;
      }
      messenger?.showMaterialBanner(
        notificationsOffBanner(
          onSettings: () => unawaited(ref.read(permissionProbeProvider).openNotificationSettings()),
          onDismiss: () {
            _notificationsDismissed = true;
            sync();
          },
        ),
      );
    }

    push.notificationsOff.addListener(sync);
    router.routerDelegate.addListener(sync);
    _notificationsSync = () {
      push.notificationsOff.removeListener(sync);
      router.routerDelegate.removeListener(sync);
    };
  }

  VoidCallback? _notificationsSync;

  Timer? _pushLocationTimer;
  Timer? _sessionCheckTimer;

  /// Once settled after a sign-in with number and PIN, offers to save a
  /// passkey (Settings → Passkeys) where they are offered.
  Future<void> _offerPasskey(String userId) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    for (var i = 0; i < 20 && mounted; i++) {
      final ctx = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (ctx != null && ctx.mounted && ref.read(currentUserIdProvider) == userId) {
        await offerPasskeyOnce(ctx, ref, userId);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Where this phone is, for Admin -> God View and Push Notification's
  /// area broadcasts, never by asking for permission:
  ///   * while the app is on screen and someone is signed in, a light
  ///     check-in every 2 minutes, moved or not (push_checkin, migration
  ///     0272; pushCheckinDue), also on start and on resume;
  ///   * the area (the regions and the reverse geocode, push_set_location,
  ///     0168) only after a move of ~200 m or every half hour
  ///     (shouldReportPushLocation);
  ///   * location already set to "Allow all the time" / "Always": the
  ///     native reporter keeps going while the app is in the background or
  ///     closed (BackgroundLocation), and stops at sign-out or once the
  ///     permission is no longer always.
  void _startPushLocation() {
    if (PushService.instance == null) return;
    Future<void>.delayed(const Duration(seconds: 8), _reportPushLocation);
    _pushLocationTimer = Timer.periodic(pushCheckinEvery, (_) => unawaited(_reportPushLocation()));
    ref.listenManual<String?>(currentUserIdProvider, (previous, id) {
      if (id == previous) return;
      _checkedInAt = null;
      _backgroundArmed = null;
      if (previous != null) unawaited(_background.disarm(forgetKey: true));
    });
  }

  final _background = BackgroundLocation();
  DateTime? _checkedInAt;
  bool? _backgroundArmed;
  bool _reporting = false;

  Future<void> _reportPushLocation() async {
    final push = PushService.instance;
    if (push == null || !mounted || _reporting) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (!pushCheckinDue(
      signedIn: ref.read(currentUserIdProvider) != null,
      foreground: life == null || life == AppLifecycleState.resumed,
      now: DateTime.now(),
      lastAt: _checkedInAt,
    )) {
      return;
    }
    _reporting = true;
    try {
      final fix = await checkinPosition();
      if (fix == null || !mounted) return;
      final point = fix.point;
      final key = fix.always && _background.supported ? await _background.key() : null;
      if (await push.checkIn(point, always: fix.always, bgKey: key)) {
        _checkedInAt = DateTime.now();
        await _syncBackground(push, always: fix.always, key: key);
      }
      if (!mounted || !push.wantsLocation(point, DateTime.now())) return;
      List<BiddingRegion> regions;
      try {
        regions = await ref.read(rideRepositoryProvider).biddingRegions(at: point);
      } catch (_) {
        regions = const [];
      }
      if (!mounted) return;
      AreaInfo? area;
      try {
        area = await ref.read(geoServiceProvider).reverseArea(point);
      } catch (_) {}
      await push.reportLocation(point, pushPlaceAt(regions, point, area));
    } finally {
      _reporting = false;
    }
  }

  /// The closed app's reporter on while location is set to always (and the
  /// server holds this install's key), off otherwise.
  Future<void> _syncBackground(PushService push, {required bool always, String? key}) async {
    final want = key != null &&
        backgroundReportingWanted(
          signedIn: ref.read(currentUserIdProvider) != null,
          locationAlways: always,
          hasTokens: push.hasTokens,
        );
    if (want == _backgroundArmed) return;
    if (want) {
      _backgroundArmed = await _background.arm(url: AppConfig.supabaseUrl, anonKey: AppConfig.supabaseAnonKey, key: key);
    } else {
      await _background.disarm();
      _backgroundArmed = false;
    }
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
  /// `core/always_on.dart`). The set is re-read when an admin changes it
  /// (live settings) and whenever the app comes back to the foreground.
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
    String? pushMode;
    void onRoute() {
      final path = router.routerDelegate.currentConfiguration.uri.path;
      unawaited(controller.navigated(path));
      // Ride offers reach a phone in driver mode, user broadcasts one in
      // passenger mode (pushModeAt, migration 0166).
      pushMode = pushModeAt(path, pushMode);
      PushService.instance?.reportMode(pushMode);
      ref.read(appModeProvider.notifier).set(pushMode);
    }
    _routeListener = onRoute;
    router.routerDelegate.addListener(onRoute);
    unawaited(controller.reload().then((_) => onRoute()));
    ref.listenManual(liveTablesProvider.select((r) => r['settings_entries'] ?? 0), (_, _) {
      unawaited(controller.reload().then((_) => onRoute()));
    });
  }

  @override
  void dispose() {
    if (_routeListener != null) ref.read(routerProvider).routerDelegate.removeListener(_routeListener!);
    unawaited(_alwaysOn?.dispose());
    _lifecycle?.dispose();
    _notificationsSync?.call();
    _pushLocationTimer?.cancel();
    _sessionCheckTimer?.cancel();
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

  /// Support's request [id] (Edit Partner › Change status, 0286), or the
  /// driver's open one: run through the driver's own buttons
  /// (features/partner/remote_action.dart). Never throws.
  void _runRemoteAction(String? id) {
    if (ref.read(supabaseProvider).auth.currentUser == null) return;
    unawaited(ref.read(remoteActionHandlerProvider).handle(id).then((_) {}, onError: (Object _) {}));
  }

  /// Requests already given a second try on the Drive page.
  final _remoteRetried = <String>{};

  /// Going online needs the Drive page: the driver is asked first, and the
  /// request waits for the tap.
  void _askRemoteAction(RemoteActionRequest r) {
    final route = remoteActionRoute(r.id);
    // On the Drive page already (still coming up): once it is, it runs it.
    if (ref.read(routerProvider).routerDelegate.currentConfiguration.uri.path == '/drive' && _remoteRetried.add(r.id)) {
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _runRemoteAction(r.id);
      });
      return;
    }
    _messenger.currentState?.showSnackBar(
      SnackBar(
        key: const ValueKey('remote-action-ask'),
        content: Text('${r.action.prompt}. Tap to confirm'),
        duration: const Duration(seconds: 30),
        action: SnackBarAction(label: 'Confirm', onPressed: () => _open(route)),
      ),
    );
  }

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
    _messenger.currentState?.showSnackBar(
      SnackBar(
        content: Text([title, body].where((s) => s.isNotEmpty).join('\n')),
        duration: const Duration(seconds: 6),
        action: route == null ? null : SnackBarAction(label: 'Open', onPressed: () => _open(route)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final router = ref.watch(routerProvider);
    final styles = ref.watch(pageStylesProvider).value ?? PageStyles.none;
    // Admin → Settings → Maps → Map appearance, for every map (live).
    final maps = ref.watch(mapAppearanceProvider).value ?? MapAppearance.phone;
    final live = _branding?.latest;
    if (live == null) return _app(widget.branding?.branding, mode, router, styles, maps);
    return ValueListenableBuilder<AppBranding?>(
      valueListenable: live,
      builder: (_, latest, _) => _app(latest ?? widget.branding?.branding, mode, router, styles, maps),
    );
  }

  /// The app under [branding]'s theme colours (Admin → App Settings), which
  /// change live as the admin saves them, and App Page Settings' [styles]
  /// for every page, sheet and modal, with every map light or dark as
  /// [maps] says.
  Widget _app(AppBranding? branding, ThemeMode mode, GoRouter router, PageStyles styles, MapAppearance maps) {
    return MaterialApp.router(
      title: 'GET.ride',
      scaffoldMessengerKey: _messenger,
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light, colors: branding?.lightColors ?? const {}),
      darkTheme: appTheme(Brightness.dark, colors: branding?.darkColors ?? const {}),
      themeMode: mode,
      routerConfig: router,
      // The phone's text size is honoured up to [maxAppTextScale]: beyond it
      // rows of buttons and switches no longer fit a phone's width.
      builder: (_, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: maxAppTextScale,
        child: MapAppearanceScope(
          appearance: maps,
          child: AndroidNavBarInset(
            child: SplashGate(
              cached: widget.branding,
              live: _branding?.latest,
              // Ready once the update check has answered (PERF-19), so a build
              // the admin requires to update goes straight to its notice.
              ready: _updateChecked,
              child: UpdateGate(
                child: PermissionGate(
                  location: () => router.routerDelegate.currentConfiguration.uri.path,
                  listenable: router.routerDelegate,
                  child: WebBuildGate(
                    location: () => router.routerDelegate.currentConfiguration.uri.path,
                    child: VoiceProtectionHost(
                      child: IncomingTransferListener(
                        child: IncomingCallListener(
                          child: RideCallListener(
                            child: KeyboardDismissOnChange(
                              listenable: router.routerDelegate,
                              child: KeyboardDismissOnTap(
                                child: PageStyleHost(
                                  styles: styles,
                                  location: () => router.routerDelegate.currentConfiguration.fullPath,
                                  listenable: router.routerDelegate,
                                  // The browser tab names the page ("Trips · GET.ride").
                                  child: RouteTitle(
                                    location: () => router.routerDelegate.currentConfiguration.uri.path,
                                    listenable: router.routerDelegate,
                                    // "Shared live with support" while God View streams them (0282).
                                    child: LiveShareNotice(child: child ?? const SizedBox.shrink()),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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
