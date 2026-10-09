// What the push-notification layer decides, kept free of plugins so it can be
// unit-tested. The plugin side is lib/src/data/push_service.dart.
//
// Push goes through Firebase Cloud Messaging on Android and iOS. The Firebase
// project is supplied at build time rather than through google-services.json /
// GoogleService-Info.plist, so a build without it simply has no push:
//
//   --dart-define=FIREBASE_PROJECT_ID=...
//   --dart-define=FIREBASE_MESSAGING_SENDER_ID=...
//   --dart-define=FIREBASE_ANDROID_APP_ID=...   --dart-define=FIREBASE_ANDROID_API_KEY=...
//   --dart-define=FIREBASE_IOS_APP_ID=...       --dart-define=FIREBASE_IOS_API_KEY=...
//
// These are Firebase's public client identifiers, not secrets. The server
// side (sending) is the send-push edge function (supabase/functions/send-push).
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// The Firebase client settings for one build, as passed with --dart-define.
class FirebaseEnv {
  const FirebaseEnv({
    this.projectId = '',
    this.messagingSenderId = '',
    this.androidAppId = '',
    this.androidApiKey = '',
    this.iosAppId = '',
    this.iosApiKey = '',
    this.iosBundleId = '',
  });

  /// The values compiled into this build.
  const FirebaseEnv.fromEnvironment()
      : projectId = const String.fromEnvironment('FIREBASE_PROJECT_ID'),
        messagingSenderId = const String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID'),
        androidAppId = const String.fromEnvironment('FIREBASE_ANDROID_APP_ID'),
        androidApiKey = const String.fromEnvironment('FIREBASE_ANDROID_API_KEY'),
        iosAppId = const String.fromEnvironment('FIREBASE_IOS_APP_ID'),
        iosApiKey = const String.fromEnvironment('FIREBASE_IOS_API_KEY'),
        iosBundleId = const String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID', defaultValue: 'com.taxxee.teksi');

  final String projectId;
  final String messagingSenderId;
  final String androidAppId;
  final String androidApiKey;
  final String iosAppId;
  final String iosApiKey;
  final String iosBundleId;
}

/// Firebase options for [platform], or null when this build has no push
/// there: on web and desktop, or when any value the platform needs is
/// missing. A half-configured build gets no push rather than a crash.
FirebaseOptions? firebaseOptionsFor(TargetPlatform platform, FirebaseEnv env, {bool isWeb = false}) {
  if (isWeb) return null;
  String clean(String v) => v.trim();
  final project = clean(env.projectId);
  final sender = clean(env.messagingSenderId);
  if (project.isEmpty || sender.isEmpty) return null;

  switch (platform) {
    case TargetPlatform.android:
      final appId = clean(env.androidAppId);
      final apiKey = clean(env.androidApiKey);
      if (appId.isEmpty || apiKey.isEmpty) return null;
      return FirebaseOptions(apiKey: apiKey, appId: appId, messagingSenderId: sender, projectId: project);
    case TargetPlatform.iOS:
      final appId = clean(env.iosAppId);
      final apiKey = clean(env.iosApiKey);
      if (appId.isEmpty || apiKey.isEmpty) return null;
      return FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: sender,
        projectId: project,
        iosBundleId: clean(env.iosBundleId).isEmpty ? null : clean(env.iosBundleId),
      );
    default:
      return null;
  }
}

/// The `platform` stored beside the token in `push_tokens`, matching what
/// the Expo app writes (`Platform.OS`).
String? pushPlatformName(TargetPlatform platform) => switch (platform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => null,
    };

/// Where tapping a notification opens, from the `data` the database
/// triggers attach (migrations 0067 / 0077 / 0129 / 0131). Null
/// opens the app wherever it was.
String? pushRouteFor(Map<String, dynamic> data) {
  switch (data['type']) {
    case 'ride_request':
    case 'ride_request_fare_raised':
      // Only partners are sent these; the queue is on the Drive tab.
      return '/drive';
    case 'wallet_transfer_request':
    case 'wallet_transfer_response':
      return '/wallet';
    case 'ride_message':
      // The chat over the recipient's own trip screen (migration 0129 says
      // which side they are on).
      final id = data['request_id'];
      if (id is! String || id.isEmpty) return null;
      final ride = Uri.encodeComponent(id);
      return data['role'] == 'partner' ? '/drive/trip/$ride/chat' : '/ride/$ride/chat';
    case 'ride_call':
      // The full-screen incoming call (migration 0131); it goes back to the
      // trip once the call is over.
      final call = data['call_id'];
      if (call is! String || call.isEmpty) return null;
      return '/ride-call/${Uri.encodeComponent(call)}';
    default:
      return null;
  }
}
