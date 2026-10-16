/// A passkey ceremony that failed for a reason worth saying out loud.
///
/// The platform files answer `null` when somebody dismissed the prompt,
/// because changing your mind is not a fault and a snackbar about it is
/// the app arguing with you. But not every unhappy ending is a
/// dismissal, and the two must not be collapsed.
///
/// On a phone the common one is a domain that is not associated with
/// the app — no `assetlinks.json` on Android, no
/// `apple-app-site-association` on iOS, or one that does not name this
/// build. The system then refuses the ceremony outright, and it looks
/// from the outside exactly like a button that does nothing. That is
/// the worst possible presentation of a build-configuration mistake:
/// silent, on the sign-in screen, for everyone.
///
/// So the mobile implementation throws this instead, and
/// `signInWithPasskey` turns it into a message. In a browser a dismissal
/// and most refusals are the same `NotAllowedError`, deliberately, so
/// that a page cannot learn which it was; those stay silent. The other
/// errors a browser raises do name a reason ([webPasskeyRefusal]), and
/// the web implementation throws this with it.
library;

/// Thrown by a platform implementation when the ceremony failed for a
/// stated reason.
class PasskeyFailure implements Exception {
  /// Constructs a failure carrying the sentence to show.
  const PasskeyFailure(this.message);

  /// What to put in front of the person, already in plain language.
  final String message;

  @override
  String toString() => 'PasskeyFailure: $message';
}

/// The sentence for a domain the app is not associated with.
///
/// A CONSTANT rather than a literal in `passkey_native.dart`, because
/// two things now need to agree on it: the platform file that raises it
/// and [passkeyNotSetUpHere], which the two cards use to decide whether
/// they are looking at a broken device or an unconfigured site. A
/// classifier that matched on a re-typed copy of the words would drift
/// the first time somebody improved the wording, and drift silently --
/// the box would simply go back to being red.
const passkeyDomainNotAssociated =
    'This app is not set up for passkeys on this system yet. It is a '
    'setting on the site rather than anything you have done — '
    'please tell GET.ride support, and sign in with your PIN '
    'for now.';

/// The sentence for a browser that refused because the site's passkey
/// setting (Supabase → Authentication → Passkeys, Relying Party ID) does
/// not match the page's address: a `SecurityError`.
const passkeySiteMismatch =
    "Your browser refused the passkey: this site's passkey setting doesn't match "
    'its address. It is a setting on the site rather than anything you have done — '
    'please tell GET.ride support, and sign in with your PIN for now.';

/// What to say when a browser's WebAuthn call failed with the
/// `DOMException` [name]; null for a dismissal or a timeout, which say
/// nothing. [creating] is saving a passkey rather than using one.
String? webPasskeyRefusal(String name, {required bool creating}) => switch (name) {
  'NotAllowedError' || 'AbortError' || '' => null,
  'SecurityError' => passkeySiteMismatch,
  'InvalidStateError' when creating => 'A passkey for this account is already saved on this device.',
  'NotSupportedError' =>
    "This browser can't ${creating ? 'save' : 'use'} a passkey. Try another browser, or sign in with your PIN.",
  'ConstraintError' =>
    "This device can't ${creating ? 'save' : 'use'} a passkey without a screen lock. "
        'Turn on a screen lock or fingerprint, then try again.',
  _ =>
    'Your browser refused the passkey ($name). '
        '${creating ? 'Try again, or sign in with your PIN.' : 'Sign in with your PIN instead.'}',
};

/// Whether a failure is the SITE not being configured.
///
/// This is worth telling apart from every other refusal, because it is
/// the only one where nothing is wrong with the device, the account or
/// the person reading it. Two files have to be served from
/// `/.well-known/` on the same origin -- `assetlinks.json` on Android
/// and `apple-app-site-association` on iOS -- and neither can be
/// written without the Play App Signing certificate and the Apple team
/// ID respectively. `docs/passkeys.md` says why a placeholder is worse
/// than nothing.
///
/// Until they are there, every passkey press on a phone ends here. A
/// red banner is the wrong register for that: it reads as a fault, it
/// appears in the middle of a card offering a feature, and it says it
/// again on every press. The cards draw a plain note instead and stop
/// offering the button, which is what an unconfigured feature should
/// look like.
bool passkeyNotSetUpHere(String? message) => message == passkeyDomainNotAssociated || message == passkeySiteMismatch;
