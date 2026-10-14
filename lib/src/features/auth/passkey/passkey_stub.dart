/// No platform authenticator this build can reach.
///
/// Android and iOS. The passkey APIs exist on both, and reaching them
/// needs a plugin this app does not carry yet — `passkeys` and its two
/// platform implementations, which is twelve dependencies and its own
/// decision. Until then a phone signs in with a password, which is
/// what it did before passkeys existed.
///
/// Said out loud rather than left as a silent false: `PasskeyButton`
/// asks [passkeysAvailable] and draws nothing when it is false, so the
/// button is absent on a phone rather than present and broken.
library;

/// Whether this build can ask for a passkey at all.
bool get passkeysAvailable => false;

/// Whether the platform has a user-verifying authenticator to hand.
///
/// Never reached on a build where [passkeysAvailable] is false; it is
/// the compile-time other half of the conditional import.
Future<bool> passkeysUsable() async => false;

/// Obtain an assertion for a sign-in. Never called here.
Future<Map<String, dynamic>?> getPasskeyAssertion(Map<String, dynamic> options) async => null;

/// Create a credential for an enrolment. Never called here.
Future<Map<String, dynamic>?> createPasskeyCredential(Map<String, dynamic> options) async => null;
