/// A `passkeys_web` that does nothing, so the web build survives.
///
/// This package exists because of an outage. It is worth writing the
/// whole reason down, because nothing about it is visible from the pub
/// page, from `flutter analyze`, or from a `flutter build web` that
/// succeeds.
///
/// Corbado's `passkeys` plugin was added for Android and iOS. It
/// worked. It then WHITE-SCREENED PRODUCTION on deploy — the landing
/// page included, which has nothing to do with passkeys.
///
/// `passkeys` federates by `default_package`, and one of those is
/// `passkeys_web`. Flutter generates `web_plugin_registrant.dart` from
/// the platform declarations of every package in the tree, so adding
/// the plugin for a phone silently enrols the web implementation too.
/// There is no per-platform dependency in `pubspec.yaml` and nothing
/// asks whether you wanted it.
///
/// `PasskeysWeb.registerWith` then runs inside `registerPlugins()`,
/// which runs BEFORE `runApp`, and the real one's last line is an
/// unconditional call to a JS global:
///
/// ```dart
/// @JS('PasskeyAuthenticator.init')
/// external void init();
/// ```
///
/// That global exists only if Corbado's `bundle.js` is in
/// `index.html`. It is not, and `script-src 'self'` in
/// `deploy/vercel-output-config.json` would refuse to load it if it
/// were. So `init()` throws during bootstrap, `main()` never finishes,
/// and every page is blank. The guard above it does not help: it reads
/// `window['PasskeyAuthenticator']`, which returns null rather than
/// throwing for a missing global, so the `catch` never fires.
///
/// ## Why a no-op rather than a fix
///
/// The web half of this app has never needed the plugin. It calls the
/// browser's own WebAuthn directly — `passkey_web.dart`, through the
/// `PublicKeyCredential` JSON converters — and does it without any
/// third-party JavaScript, which is also why it survives a strict CSP.
/// So there is nothing here to lose by making this side do nothing.
///
/// What it must still do is REGISTER, and register silently. The
/// generated registrant calls `PasskeysWeb.registerWith(registrar)`
/// unconditionally; a package that did not offer that method would
/// fail to compile the web bundle instead of failing to run it.
///
/// `scripts/check_web_plugin_registrant.py` is the tripwire that keeps
/// this in place. It refuses a pubspec that depends on `passkeys`
/// without overriding `passkeys_web` at a local `path:` — a version
/// override is refused too, because a version override is still the
/// real implementation.
library;

import 'package:passkeys_platform_interface/passkeys_platform_interface.dart';
import 'package:passkeys_platform_interface/types/types.dart';

/// The web implementation that is not one.
class PasskeysWeb extends PasskeysPlatform {
  /// Registers this as the platform instance, and does nothing else.
  ///
  /// Every line the real one runs after this is the outage. No JS
  /// global is read, nothing is initialised, and `window.close()` is
  /// not called on a tab this script did not open.
  ///
  /// The registrar is accepted and ignored, exactly as the real one
  /// does — Flutter passes it positionally and optionally.
  static void registerWith([Object? registrar]) {
    PasskeysPlatform.instance = PasskeysWeb();
  }

  /// Never called. `passkey_web.dart` is what the web actually uses.
  ///
  /// Thrown rather than returned empty, because an empty
  /// [RegisterResponseType] is a credential GoTrue would reject with a
  /// signature error — a confusing way to say "this was never wired
  /// up". If this ever fires, the conditional import in `passkey.dart`
  /// has been changed and that is the thing to look at.
  @override
  Future<RegisterResponseType> register(RegisterRequestType request) async =>
      throw UnsupportedError(_why);

  /// Never called, for the reason [register] is not.
  @override
  Future<AuthenticateResponseType> authenticate(
    AuthenticateRequestType request,
  ) async => throw UnsupportedError(_why);

  /// Nothing is ever in flight, so there is nothing to cancel.
  ///
  /// Returns rather than throws: `PasskeyAuthenticator` calls this
  /// before every ceremony as housekeeping, and housekeeping that
  /// throws would turn a no-op into a crash.
  @override
  Future<void> cancelCurrentAuthenticatorOperation() async {}

  /// No passkey support, which is true of this class and not of the
  /// browser.
  ///
  /// `passkeysUsable()` in `passkey_web.dart` is what the app asks, and
  /// it asks the browser directly. Nothing reaches this.
  @override
  Future<AvailabilityType> getAvailability() async => AvailabilityTypeWeb(
    hasPasskeySupport: false,
    isNative: false,
    isUserVerifyingPlatformAuthenticatorAvailable: false,
    isConditionalMediationAvailable: false,
  );

  static const _why =
      'The web build does not use the passkeys plugin. It calls the '
      "browser's own WebAuthn through passkey_web.dart. See "
      'app/packages/passkeys_web/lib/passkeys_web.dart.';
}
