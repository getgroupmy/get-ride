/// The options GoTrue sends, made safe for the plugin that reads them.
///
/// Reported as: a phone with a working passkey, pressing "Save another
/// passkey", and getting "this system sent something this app could not
/// read". Signing in worked. Saving the FIRST passkey had worked. Only
/// the second enrolment failed.
///
/// ## What is different about the second one
///
/// `excludeCredentials`. It is the list of credentials the account
/// already holds, so the authenticator can refuse to enrol the same one
/// twice — and on a first enrolment it is empty or absent, so nothing
/// reads it. On the second there is an entry in it, and the plugin
/// parses that entry with generated code:
///
///     CredentialType(
///       type: json['type'] as String,
///       id: json['id'] as String,
///       transports: (json['transports'] as List<dynamic>)
///           .map((e) => e as String).toList(),
///     );
///
/// (`passkeys_platform_interface-2.8.0/lib/types/credential.g.dart`.)
///
/// Neither `type` nor `transports` is nullable there. In the WebAuthn
/// specification both are optional on a `PublicKeyCredentialDescriptor`
/// — `transports` is a HINT, and a server that does not know how the
/// credential is reached is supposed to leave it out. So a perfectly
/// correct set of options throws a `TypeError` on the cast, which
/// `createPasskeyCredential` catches and reports as a server that sent
/// something unreadable.
///
/// The sign-in path has the same parser and the same hole:
/// `AuthenticateRequestType.fromJson` reads `allowCredentials` through
/// the same `CredentialType.fromJson`. It has not fired yet because
/// GoTrue's sign-in options use discoverable credentials and send no
/// list. It is the same defect and it is fixed here too, rather than
/// waiting for the day somebody turns that on.
///
/// ## And the other way the same press fails
///
/// Before the platform is called at all, the plugin validates three
/// fields against `^[A-Za-z0-9\-_]+$` — the challenge, the user id, and
/// every credential id — and throws `MalformedBase64Url*` for anything
/// else. Standard base64 (`+`, `/`, `=`) is the same bytes in the wrong
/// alphabet, so it is converted here rather than refused: a credential
/// id is opaque, and re-encoding one cannot change what it identifies.
///
/// An id that is still not base64url after that is DROPPED, with a note
/// saying so, and the list goes on without it. That is a deliberate
/// trade and it only goes one way: `excludeCredentials` is an
/// optimisation — losing an entry risks a second credential for the
/// same authenticator, which is a nuisance somebody can delete — while
/// keeping it loses the entire ceremony, which is a feature nobody can
/// use. `allowCredentials` narrows what a sign-in offers, and an empty
/// list means "offer anything this account holds", which is what the
/// sign-in button already does.
///
/// The challenge and the user id are NOT dropped or invented: they are
/// converted and then left alone, so that a server sending something
/// genuinely unusable still raises the plugin's own precise exception
/// rather than a ceremony that quietly signs the wrong bytes.
///
/// ## Scope
///
/// Native only. The browser parses these structures itself and has no
/// equivalent of this parser, so `passkey_web.dart` passes the options
/// through untouched — normalising there would be changing a shape
/// nothing has complained about.
library;

/// The plugin's own test, which is the one that has to be satisfied.
///
/// `passkeys-2.21.1/lib/authenticator.dart` validates against
/// `^[A-Za-z0-9\-_]+$`, with up to two `=` allowed on the user id and
/// nowhere else. Note that it requires at least one character: an
/// EMPTY string fails it, which is worth knowing because an empty
/// string is what a missing field becomes elsewhere in the same file.
bool isPasskeyBase64Url(String value, {bool allowPadding = false}) {
  var input = value;
  if (allowPadding) {
    var stripped = 0;
    while (input.endsWith('=') && stripped < 3) {
      input = input.substring(0, input.length - 1);
      stripped++;
    }
    if (stripped == 3) return false;
  }
  return RegExp(r'^[A-Za-z0-9\-_]+$').hasMatch(input);
}

/// The same bytes in the alphabet the plugin insists on.
///
/// Only the three characters that differ between the two alphabets are
/// touched, and padding is removed. A string already in base64url comes
/// back unchanged — the transformation is the identity on
/// `[A-Za-z0-9\-_]`, which is what makes it safe to run over every
/// field unconditionally.
String asPasskeyBase64Url(String value) {
  var out = value.replaceAll('+', '-').replaceAll('/', '_');
  while (out.endsWith('=')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// Options the plugin will parse, and what had to be done to get there.
///
/// [notes] is empty on the ordinary path. It carries a line per repair
/// so that a debug build can print exactly which field was wrong,
/// which is the diagnosis this whole file exists because nobody had.
typedef PasskeyOptions = ({Map<String, dynamic> options, List<String> notes});

/// Repair a set of WebAuthn options for the plugin's parser.
///
/// Handles both directions: `excludeCredentials` on enrolment and
/// `allowCredentials` on sign-in are the same structure and the same
/// parser. The input is not modified — the caller holds a response
/// object, and a function that rewrote it would make a retry behave
/// differently from the first attempt for no visible reason.
PasskeyOptions passkeyOptionsForPlugin(Map<String, dynamic> raw) {
  final notes = <String>[];
  final out = Map<String, dynamic>.from(raw);

  final challenge = out['challenge'];
  if (challenge is String) {
    final fixed = asPasskeyBase64Url(challenge);
    if (fixed != challenge) {
      notes.add('the challenge was not base64url and was converted');
    }
    out['challenge'] = fixed;
  }

  final user = out['user'];
  if (user is Map) {
    final copy = Map<String, dynamic>.from(user);
    final id = copy['id'];
    if (id is String) {
      final fixed = asPasskeyBase64Url(id);
      if (fixed != id) {
        notes.add('the user id was not base64url and was converted');
      }
      copy['id'] = fixed;
    }
    out['user'] = copy;
  }

  for (final key in const ['excludeCredentials', 'allowCredentials']) {
    final list = out[key];
    if (list is! List) continue;

    final kept = <Map<String, dynamic>>[];
    for (final entry in list) {
      if (entry is! Map) {
        notes.add('$key held something that is not an object; dropped');
        continue;
      }
      final copy = Map<String, dynamic>.from(entry);

      final id = copy['id'];
      if (id is! String) {
        notes.add('$key held an entry with no id; dropped');
        continue;
      }
      final fixedId = asPasskeyBase64Url(id);
      if (!isPasskeyBase64Url(fixedId)) {
        // Not salvageable. See the trade in the library comment: the
        // list is an optimisation and the ceremony is the feature.
        notes.add('$key held an id that is not base64url; dropped');
        continue;
      }
      if (fixedId != id) {
        notes.add('an id in $key was not base64url and was converted');
      }
      copy['id'] = fixedId;

      // `public-key` is the only credential type WebAuthn defines, so
      // supplying it where a server left it out is not a guess.
      if (copy['type'] is! String) {
        notes.add('an entry in $key had no type; assumed public-key');
        copy['type'] = 'public-key';
      }

      // An absent `transports` means "not known", and an empty list is
      // how that is said to a parser which will not take its absence.
      final transports = copy['transports'];
      if (transports is List) {
        copy['transports'] = transports.whereType<String>().toList();
      } else {
        notes.add('an entry in $key had no transports; sent an empty list');
        copy['transports'] = <String>[];
      }

      kept.add(copy);
    }

    if (kept.isEmpty) {
      // Absent rather than empty. Both parsers treat an empty list as
      // no list, and leaving the key out keeps the two states from
      // having to be told apart anywhere downstream.
      out.remove(key);
    } else {
      out[key] = kept;
    }
  }

  return (options: out, notes: notes);
}
