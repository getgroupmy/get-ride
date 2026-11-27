// GET.eKYC (migration 0439): our own eKYC server runs the whole ID check in
// its page, shown inside the app. These are the admin's switches and the
// words for how a check ended. Pure, so it is tested without a phone.
library;

import 'package:get_ekyc/get_ekyc.dart' show EkycOutcome;

/// Where GET.eKYC may run: the rider ID check before booking (0342) and the
/// ID step of the dispatch sign-in checks (0281). Purposes as the server
/// names them: 'rider_gate', 'first'.
class EkycConfig {
  const EkycConfig({
    this.on = false,
    this.riderGate = false,
    this.dispatchId = false,
    this.test = false,
    this.serverKey,
    this.webhookKey,
  });

  factory EkycConfig.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    bool b(String k) => m[k] == true;
    bool? k(String key) => m[key] is bool ? m[key] as bool : null;
    return EkycConfig(
      on: b('on'),
      riderGate: b('riderGate'),
      dispatchId: b('dispatchId'),
      test: b('test'),
      serverKey: k('serverKey'),
      webhookKey: k('webhookKey'),
    );
  }

  static const off = EkycConfig();

  final bool on;
  final bool riderGate;
  final bool dispatchId;
  final bool test;

  /// Only admins are told whether the keys are in Admin → API Keys.
  final bool? serverKey;
  final bool? webhookKey;

  bool uses(String purpose) => on && (purpose == 'rider_gate' ? riderGate : purpose == 'first' && dispatchId);

  /// What is missing for it to work, for the admin; null when ready.
  String? get missingKeys {
    final missing = [
      if (serverKey == false) 'the server address and API key',
      if (webhookKey == false) 'the webhook secret',
    ];
    return missing.isEmpty ? null : 'Add ${missing.join(' and ')} in Admin, API Keys, GET.eKYC.';
  }

  Map<String, Object> toJson() => {'on': on, 'riderGate': riderGate, 'dispatchId': dispatchId, 'test': test};
}

/// The one-time page ekyc-start returned, or null when the answer is unusable.
({String url, String sessionId})? parseEkycStart(Object? data) {
  if (data is! Map) return null;
  final url = data['url'], id = data['session_id'];
  if (url is! String || id is! String || !url.startsWith('https://')) return null;
  return (url: url, sessionId: id);
}

/// Why ekyc-start refused, in the user's words.
String ekycStartError(Object error) {
  final s = '$error';
  if (s.contains('ekyc_off')) return 'Identity checks are not available right now. Please try again later.';
  if (s.contains('not_signed_in')) return 'Please sign in again.';
  return "We couldn't start the identity check. Check your connection and try again.";
}

/// What the person is told when the check's page closes. null: say nothing
/// (they cancelled). [verified]: the server already verified them.
String? ekycEndMessage(EkycOutcome outcome, {required bool verified}) {
  if (verified) return 'Identity verified.';
  return switch (outcome) {
    EkycOutcome.approved ||
    EkycOutcome.review ||
    EkycOutcome.rejected ||
    EkycOutcome.submitted => 'Thanks. Your ID is being reviewed; we will let you know shortly.',
    EkycOutcome.expired => 'The identity check timed out. Please start again.',
    EkycOutcome.invalid || EkycOutcome.error => "The identity check didn't finish. Please try again.",
    EkycOutcome.cancelled => null,
  };
}

/// GET.eKYC's own verdict on a check, for the admin reviewing it: what it
/// decided and why ("Needs review: face match uncertain, name mismatch").
String? ekycVerdictText(Object? status, Object? reasons) {
  final word = switch (status) {
    'approved' => 'Approved',
    'review' => 'Needs review',
    'rejected' => 'Not accepted',
    _ => null,
  };
  if (word == null) return null;
  final why = (reasons is List ? reasons : const [])
      .whereType<String>()
      .map((r) => r.replaceAll('_', ' '))
      .toList();
  return why.isEmpty ? word : '$word: ${why.join(', ')}';
}
