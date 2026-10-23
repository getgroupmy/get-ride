import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/call_ring.dart';
import '../core/push_logic.dart';
import 'call_ringer.dart';

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
///     arrive while the app is open ([foreground]) — iOS shows those itself;
///   * on a phone with a native call screen (call_ringer.dart), registers the
///     token with the `call_ui` capability (migration 0134), so a ride call
///     arrives as a data message that rings it — through
///     [firebaseBackgroundPush] while the app is closed, and [calls] while it
///     is open — and on an iPhone also registers the PushKit (VoIP) token.
///
/// The OS displays every other notification while the app is in the
/// background. Everything is best-effort: a failure here is logged and never
/// stops the app.
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
  final _calls = StreamController<Map<String, dynamic>>.broadcast();
  final _received = StreamController<Map<String, dynamic>>.broadcast();

  /// The VoIP token stored for the signed-in profile.
  String? _registeredVoip;

  /// Routes to open because a notification was tapped.
  Stream<String> get taps => _taps.stream;

  /// Messages received while the app is in the foreground on Android.
  Stream<RemoteMessage> get foreground => _foreground.stream;

  /// Ride-call data messages (`ride_call`, `ride_call_end`) received while
  /// the app is open.
  Stream<Map<String, dynamic>> get calls => _calls.stream;

  /// The data of every push that reaches the open app, on every platform,
  /// so a screen can re-read what it says changed without waiting on a live
  /// update (which can lag or drop).
  Stream<Map<String, dynamic>> get received => _received.stream;

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
      // A ride call to a closed app is a data message, rung from here.
      if (nativeCallRingerAvailable) FirebaseMessaging.onBackgroundMessage(firebaseBackgroundPush);
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
      unawaited(_ack(message.data, 'delivered'));
      _received.add(message.data);
      if (callRingFromPush(message.data) != null || endedCallFromPush(message.data) != null) {
        _calls.add(message.data);
      }
      if (defaultTargetPlatform == TargetPlatform.android) _foreground.add(message);
    });
    if (nativeCallRingerAvailable && defaultTargetPlatform == TargetPlatform.iOS) {
      // iOS hands the app its PushKit token whenever it likes.
      FlutterCallkitIncoming.onEvent.listen((event) {
        if (event is CallEventActionDidUpdateDevicePushTokenVoip) unawaited(_registerVoip());
      }, onError: (Object _) {});
    }
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      unawaited(_ack(message.data, 'read'));
      final route = pushRouteFor(message.data);
      if (route != null) _taps.add(route);
    });
    _messaging.getInitialMessage().then((message) {
      if (message != null) unawaited(_ack(message.data, 'read'));
      final route = message == null ? null : pushRouteFor(message.data);
      if (route == null) return;
      if (_taps.hasListener) {
        _taps.add(route);
      } else {
        _pendingRoute = route;
      }
    }).catchError((Object e) => debugPrint('[push] initial message: $e'));

    _messaging.onTokenRefresh.listen((token) {
      // A rotated token replaces the stored one: the old row goes, so this
      // phone is not sent everything twice (a database before 0165 has no
      // device key to do it by).
      final old = _registeredToken;
      _registeredFor = null;
      unawaited(() async {
        await _register(token: token);
        if (old != null && old != token && _registeredToken == token) {
          try {
            await _db.rpc('push_unregister_token', params: {'p_token': old});
          } catch (_) {}
        }
      }());
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

  /// The mode the app is in ('rider' or 'partner'), as last reported.
  String? _mode;

  /// The mode the server last stored for this phone's tokens.
  String? _modeSent;

  /// The app moved into [mode]: the server is told, so notifications that
  /// belong to the other mode (ride offers while browsing as a passenger)
  /// skip this phone (`push_set_mode`, migration 0166). Quiet on failure: a
  /// database without it sends everything, as before.
  void reportMode(String? mode) {
    if (mode == null || mode == _mode) return;
    _mode = mode;
    unawaited(_sendMode());
  }

  Future<void> _sendMode() async {
    final mode = _mode;
    final tokens = [?_registeredToken, ?_registeredVoip];
    if (mode == null || tokens.isEmpty || _db.auth.currentUser == null) return;
    final key = '$mode:${tokens.join(',')}';
    if (_modeSent == key) return;
    try {
      await _db.rpc('push_set_mode', params: {'p_tokens': tokens, 'p_mode': mode});
      _modeSent = key;
    } catch (e) {
      debugPrint('[push] mode not stored: $e');
    }
  }

  LatLng? _locatedAt;
  DateTime? _locatedWhen;

  /// Whether this phone has a token stored for the signed-in profile, so a
  /// check-in (or the closed app's report) has something to move.
  bool get hasTokens => _db.auth.currentUser != null && [?_registeredToken, ?_registeredVoip].isNotEmpty;

  /// The open app's light check-in (`push_checkin`, migration 0272): where
  /// the phone is now, moved or not, from the foreground; whether location
  /// is set to always; and, when it is, the install's background key
  /// ([bgKey], only its hash is stored) that the closed app reports with.
  /// The server refreshes the area from its regions after a move (0275);
  /// [reportLocation] still names it from the geocoder. True when the server
  /// took it; quiet on failure (a database without it: the area report
  /// still runs).
  Future<bool> checkIn(LatLng point, {required bool always, String? bgKey}) async {
    final tokens = [?_registeredToken, ?_registeredVoip];
    if (tokens.isEmpty || _db.auth.currentUser == null) return false;
    try {
      await _db.rpc('push_checkin', params: {
        'p_tokens': tokens,
        'p_lat': point.latitude,
        'p_lng': point.longitude,
        'p_background': false,
        'p_always': always,
        'p_bg_key': always ? bgKey : null,
      });
      return true;
    } catch (e) {
      debugPrint('[push] check-in not stored: $e');
      return false;
    }
  }

  /// Whether [point] is worth reporting now (shouldReportPushLocation).
  bool wantsLocation(LatLng point, DateTime now) =>
      shouldReportPushLocation(point: point, now: now, lastPoint: _locatedAt, lastAt: _locatedWhen);

  /// Tells the server where this phone is, for area broadcasts
  /// (`push_set_location`, migration 0168). Quiet on failure: a database
  /// without it simply cannot send by area.
  Future<void> reportLocation(
    LatLng point,
    ({String? country, String? state, String? city, String? suburb}) place,
  ) async {
    final tokens = [?_registeredToken, ?_registeredVoip];
    if (tokens.isEmpty || _db.auth.currentUser == null) return;
    try {
      await _db.rpc('push_set_location', params: {
        'p_tokens': tokens,
        'p_lat': point.latitude,
        'p_lng': point.longitude,
        'p_country': place.country,
        'p_state': place.state,
        'p_city': place.city,
        'p_suburb': place.suburb,
      });
      _locatedAt = point;
      _locatedWhen = DateTime.now();
    } catch (e) {
      debugPrint('[push] location not stored: $e');
    }
  }

  /// Tells the server this phone has the push, so it isn't sent again
  /// (`ack_notification`, migration 0144). Quiet on failure.
  Future<void> _ack(Map<String, dynamic> data, String state) async {
    final id = pushEventId(data);
    if (id == null || _db.auth.currentUser == null) return;
    try {
      await _db.rpc('ack_notification', params: {'p_event_id': id, 'p_state': state});
    } catch (_) {}
  }

  /// Whether the signed-in user has turned notifications off for the app
  /// (refused, not just never asked): calls and new rides can't reach them
  /// while it's closed, so the app says so (NotificationsOffBanner).
  final notificationsOff = ValueNotifier<bool>(false);

  /// Back from the background: notifications may have been switched on (or
  /// off) in Settings meanwhile. Switched on, the phone is registered now.
  Future<void> recheckPermission() async {
    if (_db.auth.currentUser == null) return;
    try {
      final status = (await _messaging.getNotificationSettings()).authorizationStatus;
      final off = status == AuthorizationStatus.denied || status == AuthorizationStatus.deniedPermanently;
      final wasOff = notificationsOff.value;
      notificationsOff.value = off;
      if (wasOff && !off) unawaited(_register());
      // The VoIP token doesn't need notifications, and may have come late.
      unawaited(_registerVoip());
    } catch (_) {}
  }

  /// At launch, once the splash is gone: the system's question about
  /// notifications, if it can still be shown (never answered on an iPhone,
  /// not allowed yet on Android), whether or not anyone is signed in.
  bool _launchAsked = kIsWeb;

  Future<void> askOnLaunch() async {
    if (_launchAsked) return;
    try {
      final status = (await _messaging.getNotificationSettings()).authorizationStatus;
      final ask = defaultTargetPlatform == TargetPlatform.iOS
          ? status == AuthorizationStatus.notDetermined
          : status != AuthorizationStatus.authorized && status != AuthorizationStatus.deniedPermanently;
      if (ask) await _messaging.requestPermission();
    } catch (e) {
      debugPrint('[push] launch permission ask: $e');
    }
    _launchAsked = true;
    if (_db.auth.currentUser != null) {
      _registeredFor = null;
      await _register();
    }
  }

  Future<void> _register({String? token}) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return;
    // A call rings CallKit through PushKit, which needs no notification
    // permission: its token is stored whatever the answer below.
    unawaited(_registerVoip());
    if (_registering) return;
    _registering = true;
    try {
      // Until the launch ask (after the splash) the answer is only read, so
      // no question appears over the splash.
      final settings = _launchAsked ? await _messaging.requestPermission() : await _messaging.getNotificationSettings();
      final allowed = settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      if (_launchAsked) {
        notificationsOff.value = settings.authorizationStatus == AuthorizationStatus.denied ||
            settings.authorizationStatus == AuthorizationStatus.deniedPermanently;
      }
      if (!allowed) {
        debugPrint('[push] notification permission not granted');
        return;
      }

      final fcmToken = token ?? await _fcmToken();
      if (fcmToken == null) return;
      final key = '$userId:$fcmToken';
      if (_registeredFor == key) return;

      await _registerDevice(fcmToken, pushPlatformName(defaultTargetPlatform));
      _registeredToken = fcmToken;
      _registeredFor = key;
      unawaited(_sendMode());
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

  /// Stores [token] for the signed-in profile, saying whether this build
  /// rings ride calls on the phone's call screen. A database without
  /// migration 0134 gets the old registration (and ordinary notifications).
  Future<void> _registerDevice(String token, String? platform) async {
    final caps = nativeCallRingerAvailable ? const [callUiCapability] : const <String>[];
    final params = <String, dynamic>{
      'p_token': token,
      'p_platform': platform,
      'p_device_name': null,
      'p_capabilities': caps,
    };
    final key = await _deviceKey();
    if (key != null) {
      try {
        // With the device key (0165): this phone's earlier token goes.
        await _db.rpc('push_register_device', params: {...params, 'p_device_key': key});
        return;
      } on PostgrestException catch (e) {
        // A database before 0165 has no such argument: the same call without.
        if (!_missingRpc(e)) rethrow;
      }
    }
    try {
      await _db.rpc('push_register_device', params: params);
    } on PostgrestException catch (e) {
      if (!_missingRpc(e) || platform == voipPlatform) rethrow;
      await _registerLegacy(token, platform);
    }
  }

  /// A database before 0134.
  Future<void> _registerLegacy(String token, String? platform) => _db.rpc('push_register_token', params: {
        'p_token': token,
        'p_platform': platform,
        'p_device_name': null,
      });

  String? _deviceKeyCache;

  /// What identifies this phone to the push server (pushDeviceKey): on an
  /// iPhone its APNs token, which a reinstall usually keeps, so the old
  /// install's token is replaced; on Android an id made once per install
  /// (an uninstalled app's token is already refused by FCM and pruned).
  /// Never a hardware id, and never Android's Build.ID, which every phone
  /// on the same OS build shares.
  Future<String?> _deviceKey() async {
    if (_deviceKeyCache != null) return _deviceKeyCache;
    if (kIsWeb) return null;
    try {
      final String? raw;
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        raw = await _messaging.getAPNSToken();
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        final prefs = await SharedPreferences.getInstance();
        raw = prefs.getString(pushInstallIdKey) ?? const Uuid().v4();
        await prefs.setString(pushInstallIdKey, raw);
      } else {
        raw = null;
      }
      return _deviceKeyCache = pushDeviceKey(raw);
    } catch (_) {
      return null;
    }
  }

  /// PostgREST's "no such function" (a database before the migration).
  static bool _missingRpc(PostgrestException e) =>
      e.code == 'PGRST202' || e.code == '42883' || e.message.contains('push_register_device');

  bool _registeringVoip = false;

  /// The iPhone's PushKit token, which rings a closed app's CallKit screen
  /// (send-push only sends it ride calls, and only with the APNs key).
  /// iOS hands it over when it likes, often a moment after launch, so a
  /// token not there yet (or a failed store) is tried again a few times.
  Future<void> _registerVoip() async {
    if (!nativeCallRingerAvailable || defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_registeringVoip) return;
    _registeringVoip = true;
    try {
      for (var attempt = 0; attempt < voipRetryDelays.length + 1; attempt++) {
        if (attempt > 0) await Future<void>.delayed(voipRetryDelays[attempt - 1]);
        if (_db.auth.currentUser == null) return;
        try {
          final token = await NativeCallRinger().voipToken();
          if (token == _registeredVoip && token != null) return;
          if (token == null) continue;
          await _registerDevice(token, voipPlatform);
          _registeredVoip = token;
          unawaited(_sendMode());
          return;
        } catch (e) {
          debugPrint('[push] VoIP registration failed: $e');
        }
      }
      debugPrint('[push] no VoIP token from iOS yet');
    } finally {
      _registeringVoip = false;
    }
  }

  Future<void> _unregister() async {
    final token = _registeredToken;
    final voip = _registeredVoip;
    _registeredToken = null;
    _registeredFor = null;
    _registeredVoip = null;
    notificationsOff.value = false;
    _modeSent = null;
    _locatedAt = null;
    _locatedWhen = null;
    for (final t in [token, voip]) {
      if (t == null) continue;
      try {
        await _db.rpc('push_unregister_token', params: {'p_token': t});
      } catch (e) {
        debugPrint('[push] unregister failed: $e');
      }
    }
  }
}
