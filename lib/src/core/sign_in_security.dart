// Sign-in security (migrations 0179 and 0180): the admin's switches for
// passkeys on each surface and for one device per account, and the rules
// the app applies with them. Pure.
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Admin → App Settings → Sign-in security, as `sign_in_config()` returns
/// it. Every switch ships off.
@immutable
class SignInConfig {
  const SignInConfig({
    this.passkeyWeb = false,
    this.passkeyAndroid = false,
    this.passkeyIos = false,
    this.oneDevice = false,
  });

  final bool passkeyWeb;
  final bool passkeyAndroid;
  final bool passkeyIos;
  final bool oneDevice;

  static const off = SignInConfig();

  factory SignInConfig.fromJson(Object? json) {
    if (json is! Map) return off;
    bool on(String k) => json[k] == true || json[k] == 'true';
    return SignInConfig(
      passkeyWeb: on('passkeyWeb'),
      passkeyAndroid: on('passkeyAndroid'),
      passkeyIos: on('passkeyIos'),
      oneDevice: on('oneDevice'),
    );
  }

  Map<String, dynamic> toJson() => {
    'passkeyWeb': passkeyWeb,
    'passkeyAndroid': passkeyAndroid,
    'passkeyIos': passkeyIos,
    'oneDevice': oneDevice,
  };

  SignInConfig copyWith({bool? passkeyWeb, bool? passkeyAndroid, bool? passkeyIos, bool? oneDevice}) => SignInConfig(
    passkeyWeb: passkeyWeb ?? this.passkeyWeb,
    passkeyAndroid: passkeyAndroid ?? this.passkeyAndroid,
    passkeyIos: passkeyIos ?? this.passkeyIos,
    oneDevice: oneDevice ?? this.oneDevice,
  );

  @override
  bool operator ==(Object other) =>
      other is SignInConfig &&
      other.passkeyWeb == passkeyWeb &&
      other.passkeyAndroid == passkeyAndroid &&
      other.passkeyIos == passkeyIos &&
      other.oneDevice == oneDevice;

  @override
  int get hashCode => Object.hash(passkeyWeb, passkeyAndroid, passkeyIos, oneDevice);
}

/// Where the app is running, as far as passkeys care: each needs its own
/// setup, so each has its own switch. Desktop apps are not offered them.
enum SignInSurface { web, android, ios, other }

SignInSurface signInSurface({required bool isWeb, required TargetPlatform platform}) {
  if (isWeb) return SignInSurface.web;
  return switch (platform) {
    TargetPlatform.android => SignInSurface.android,
    TargetPlatform.iOS => SignInSurface.ios,
    _ => SignInSurface.other,
  };
}

/// Whether the admin has turned passkeys on for [surface].
bool passkeyOffered(SignInConfig c, SignInSurface surface) => switch (surface) {
  SignInSurface.web => c.passkeyWeb,
  SignInSurface.android => c.passkeyAndroid,
  SignInSurface.ios => c.passkeyIos,
  SignInSurface.other => false,
};

/// What a device signed out by a newer sign-in elsewhere is told.
const signedOutElsewhereMessage =
    "You signed in on another device, so you've been signed out here. "
    "If that wasn't you, sign in again and change your PIN.";

/// The server's refusal of a session that is no longer the account's one
/// (`request_guard`, migration 0180), from any error the API returned.
bool isSignedInElsewhere(Object? error) {
  if (error == null) return false;
  return '$error'.contains('signed_in_elsewhere');
}

/// The Auth session a token belongs to (its `session_id` claim), or null.
String? sessionIdOf(String? accessToken) {
  if (accessToken == null) return null;
  final parts = accessToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final id = payload is Map ? payload['session_id'] : null;
    return id is String && id.isNotEmpty ? id : null;
  } catch (_) {
    return null;
  }
}

/// Whether an `active_sessions` row says this device was replaced: a row
/// for the account naming another session.
bool replacedBy(Map<String, dynamic>? row, String? mySessionId) {
  final other = row?['session_id'];
  return mySessionId != null && other is String && other.isNotEmpty && other != mySessionId;
}

/// The admin's line for an account's current device, e.g.
/// "iPhone · ios · app 1.4.8 · since 14 Oct 09:12".
String activeDeviceLine(Map<String, dynamic> row, {String Function(DateTime)? when}) {
  final parts = <String>[
    if ('${row['device_label'] ?? ''}'.trim().isNotEmpty) '${row['device_label']}'.trim(),
    if ('${row['platform'] ?? ''}'.trim().isNotEmpty) '${row['platform']}'.trim(),
    if ('${row['app_version'] ?? ''}'.trim().isNotEmpty) 'app ${row['app_version']}'.trim(),
  ];
  final at = DateTime.tryParse('${row['claimed_at'] ?? ''}');
  if (at != null && when != null) parts.add('since ${when(at.toLocal())}');
  return parts.isEmpty ? 'Signed out everywhere' : parts.join(' · ');
}
