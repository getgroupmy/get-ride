import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/push_logic.dart';

/// The device's push-notification lifecycle (the Flutter counterpart of
/// `PushNotificationContext` in the Expo app):
///
///   * starts Firebase when this build carries a Firebase project
///     (see push_logic.dart), and does nothing at all otherwise;
///   * once someone is signed in, asks for notification permission and
///     stores the FCM token against their profile through the
///     `push_register_token` RPC, the same one the Expo app uses;
///   * on sign-out removes the token with `push_unregister_token`, which
///     works without a session, so the next account on this phone does not
///     get the previous one's notifications;
///   * reports taps ([taps], a route to open) and, on Android, messages that
///     arrive while the app is open ([foreground]) — iOS shows those itself.
///
/// The OS displays notifications while the app is in the background, so no
/// background handler is needed. Everything is best-effort: a failure here
/// is logged and never stops the app.
class PushService {
  PushService._(this._db, this._messaging);

  static PushService? _instance;

  /// The running service, or null when this build has no push.
  static PushService? get instance => _instance;

  final SupabaseClient _db;
  final FirebaseMessaging _messaging;

  /// The token stored for the signed-in profile, so sign-out can remove it.
  String? _registeredToken;
  String? _registeredFor;
  bool _registering = false;

  /// A route from the notification that launched the app, kept until the app
  /// is ready to open it.
  String? _pendingRoute;

  final _taps = StreamController<String>.broadcast();
  final _foreground = StreamController<RemoteMessage>.broadcast();

  /// Routes to open because a notification was tapped.
  Stream<String> get taps => _taps.stream;

  /// Messages received while the app is in the foreground on Android.
  Stream<RemoteMessage> get foreground => _foreground.stream;

  /// The route from the notification the app was launched from, once.
  String? takePendingRoute() {
    final route = _pendingRoute;
    _pendingRoute = null;
    return route;
  }

  /// Starts push if this build and platform have it. Never throws.
  static Future<PushService?> start(SupabaseClient db) async {
    final options = firebaseOptionsFor(
      defaultTargetPlatform,
      const FirebaseEnv.fromEnvironment(),
      isWeb: kIsWeb,
    );
    if (options == null) return null;
    try {
      await Firebase.initializeApp(options: options);
      final service = PushService._(db, FirebaseMessaging.instance);
      _instance = service;
      service._listen();
      return service;
    } catch (e) {
      debugPrint('[push] Firebase did not start: $e');
      return null;
    }
  }

  void _listen() {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Show banners while the app is open, as the Expo app does.
      _messaging
          .setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true)
          .catchError((Object e) => debugPrint('[push] presentation options: $e'));
    }

    FirebaseMessaging.onMessage.listen((message) {
      if (defaultTargetPlatform == TargetPlatform.android) _foreground.add(message);
    });
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final route = pushRouteFor(message.data);
      if (route != null) _taps.add(route);
    });
    _messaging.getInitialMessage().then((message) {
      final route = message == null ? null : pushRouteFor(message.data);
      if (route == null) return;
      if (_taps.hasListener) {
        _taps.add(route);
      } else {
        _pendingRoute = route;
      }
    }).catchError((Object e) => debugPrint('[push] initial message: $e'));

    _messaging.onTokenRefresh.listen((token) {
      // A rotated token replaces the stored one on the next registration.
      _registeredFor = null;
      unawaited(_register(token: token));
    });

    _db.auth.onAuthStateChange.listen((change) {
      switch (change.event) {
        case AuthChangeEvent.initialSession:
        case AuthChangeEvent.signedIn:
        case AuthChangeEvent.userUpdated:
          if (change.session != null) unawaited(_register());
        case AuthChangeEvent.signedOut:
          unawaited(_unregister());
        default:
          break;
      }
    });
  }

  Future<void> _register({String? token}) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null || _registering) return;
    _registering = true;
    try {
      final settings = await _messaging.requestPermission();
      final allowed = settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!allowed) {
        debugPrint('[push] notification permission not granted');
        return;
      }

      final fcmToken = token ?? await _fcmToken();
      if (fcmToken == null) return;
      final key = '$userId:$fcmToken';
      if (_registeredFor == key) return;

      await _db.rpc('push_register_token', params: {
        'p_token': fcmToken,
        'p_platform': pushPlatformName(defaultTargetPlatform),
        'p_device_name': null,
      });
      _registeredToken = fcmToken;
      _registeredFor = key;
    } catch (e) {
      debugPrint('[push] registration failed: $e');
    } finally {
      _registering = false;
    }
  }

  /// The FCM token. On iOS it only exists once Apple has handed the app its
  /// APNs token, which can take a moment after permission is granted.
  Future<String?> _fcmToken() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      for (var attempt = 0; attempt < 10; attempt++) {
        if (await _messaging.getAPNSToken() != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (await _messaging.getAPNSToken() == null) {
        debugPrint('[push] no APNs token (simulator, or the Push Notifications capability is missing)');
        return null;
      }
    }
    return _messaging.getToken();
  }

  Future<void> _unregister() async {
    final token = _registeredToken;
    _registeredToken = null;
    _registeredFor = null;
    if (token == null) return;
    try {
      await _db.rpc('push_unregister_token', params: {'p_token': token});
    } catch (e) {
      debugPrint('[push] unregister failed: $e');
    }
  }
}
