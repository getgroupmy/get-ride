/// WebAuthn in a browser, in the shape GoTrue asks for.
///
/// `auth.passkey.startAuthentication()` hands back an `options` object
/// in the W3C `PublicKeyCredentialRequestOptionsJSON` form, and
/// `verifyAuthentication` wants the assertion back as
/// `AuthenticationResponseJSON`. Between those two the browser has to
/// be asked, and that is all this file does.
///
/// ## Why `js_interop_unsafe` and not `package:web`
///
/// `package:web` 1.1.1 binds `PublicKeyCredential` but not the two
/// static methods that make this tractable —
/// `parseRequestOptionsFromJSON` and `parseCreationOptionsFromJSON` —
/// nor the instance `toJSON()`. Those are what convert between the
/// JSON GoTrue speaks and the ArrayBuffers the browser wants.
///
/// Doing it without them means hand-rolling base64url to ArrayBuffer
/// in both directions over a structure with optional nested fields,
/// which is a lot of code to get subtly wrong in a place where "subtly
/// wrong" means a signature that will not verify. Calling the browser's
/// own converters through `js_interop_unsafe` is the smaller risk, and
/// it is the same approach `captcha_web.dart` and
/// `text_reader_web.dart` already take here.
///
/// ## What happens on a browser too old to have them
///
/// [passkeysUsable] returns false and the button is not drawn. Those
/// methods shipped in Chrome 119, Safari 17.4 and Firefox 119, so this
/// is a genuinely old browser — and one that cannot be supported
/// silently, because a half-working passkey is worse than an absent
/// one: it fails at the moment somebody is trying to get in.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// The browser can be asked. Whether it will succeed is
/// [passkeysUsable].
bool get passkeysAvailable => true;

/// The `PublicKeyCredential` constructor, or null where there is none.
JSObject? get _pkc {
  final o = web.window.getProperty<JSAny?>('PublicKeyCredential'.toJS);
  return o.isA<JSObject>() ? o as JSObject : null;
}

bool _has(JSObject o, String name) => o.getProperty<JSAny?>(name.toJS) != null;

/// Whether this browser can actually complete a passkey ceremony.
///
/// Three questions, and all three have to be yes:
///
///   * `PublicKeyCredential` exists at all — no WebAuthn otherwise;
///   * it carries the JSON converters this file depends on.
///
/// ## What this deliberately does NOT ask
///
/// It used to also require
/// `isUserVerifyingPlatformAuthenticatorAvailable()` — "is there a
/// fingerprint reader, a face camera or a device PIN ON THIS MACHINE".
/// That was wrong, and wrong in the direction that hurts: it is the
/// question about the machine you happen to be sitting at, and a
/// passkey does not have to live there.
///
/// A browser with no platform authenticator can still offer, and every
/// one of these was hidden by that check:
///
///   * **iCloud Keychain / Apple Passwords**, on a Mac without Touch ID
///     and on any Mac where the passkey is meant to sync rather than
///     stay on the machine;
///   * **Google Password Manager**, which is where an Android user's
///     passkeys belong and which is reachable from a desktop browser;
///   * **a phone, by QR code** — the cross-device flow, which is the
///     whole answer for a shared or locked-down desktop;
///   * **a security key** on USB or NFC, which needs nothing built into
///     the machine at all.
///
/// So the question is only whether the browser can run the ceremony.
/// Whether there is anywhere to put the result is the BROWSER'S
/// chooser to present, and it knows about all four; this code does not,
/// and guessing on its behalf is what removed the options.
///
/// The cost of the looser test is a prompt somebody can cancel on a
/// machine with genuinely nothing available. That is a far smaller harm
/// than silently hiding the feature from everybody with an iPhone.
Future<bool> passkeysUsable() async {
  final pkc = _pkc;
  if (pkc == null) return false;
  if (!_has(pkc, 'parseRequestOptionsFromJSON')) return false;
  if (!_has(pkc, 'parseCreationOptionsFromJSON')) return false;
  return true;
}

/// Ask the browser for an assertion, for signing in.
///
/// Returns the `AuthenticationResponseJSON` GoTrue's
/// `verifyAuthentication` wants, or null when the person dismissed the
/// prompt — which is not an error and must not be reported as one.
Future<Map<String, dynamic>?> getPasskeyAssertion(Map<String, dynamic> options) => _ceremony(options, creating: false);

/// Ask the browser to create a credential, for enrolling one.
///
/// Returns the `RegistrationResponseJSON` `verifyRegistration` wants,
/// or null when the person dismissed the prompt.
Future<Map<String, dynamic>?> createPasskeyCredential(Map<String, dynamic> options) =>
    _ceremony(options, creating: true);

/// The two ceremonies differ in three names and nothing else.
///
/// One function rather than two near-copies: the conversion in and out
/// is where this can go wrong, and it should go wrong in one place or
/// not at all.
Future<Map<String, dynamic>?> _ceremony(Map<String, dynamic> options, {required bool creating}) async {
  final pkc = _pkc;
  if (pkc == null) return null;

  final parse = creating ? 'parseCreationOptionsFromJSON' : 'parseRequestOptionsFromJSON';
  if (!_has(pkc, parse)) return null;

  final parsed = pkc.callMethod<JSObject>(parse.toJS, options.jsify() as JSObject);

  final request = JSObject()..setProperty('publicKey'.toJS, parsed);

  final JSAny? credential;
  try {
    credential = creating
        ? await web.window.navigator.credentials.create(request as web.CredentialCreationOptions).toDart
        : await web.window.navigator.credentials.get(request as web.CredentialRequestOptions).toDart;
  } catch (_) {
    // `NotAllowedError` is what a dismissed prompt and a timeout both
    // raise, and neither is a fault worth putting in front of somebody
    // who simply changed their mind. The caller says "that did not
    // work" once, for every reason.
    return null;
  }

  if (credential == null || !credential.isA<JSObject>()) return null;
  final obj = credential as JSObject;
  if (!_has(obj, 'toJSON')) return null;

  final json = obj.callMethod<JSObject>('toJSON'.toJS);
  final out = json.dartify();
  return out is Map ? Map<String, dynamic>.from(out) : null;
}
