/// How the user's session ended, as the app sees it.
///
/// This is a hint for which screen to show next. The decision itself reaches
/// your server by the signed webhook (or GET /v1/verifications/{id} with your
/// API key): never approve a user on this value alone.
enum EkycOutcome {
  /// Checked and approved.
  approved,

  /// A person will decide; usually within the working day.
  review,

  /// Checked and not accepted.
  rejected,

  /// Sent; the check is still running. Wait for the webhook.
  submitted,

  /// The user left before sending.
  cancelled,

  /// The link expired before the user finished.
  expired,

  /// The link was not valid (wrong, replaced, or deleted).
  invalid,

  /// Something failed (network, camera...). See [EkycResult.error].
  error,
}

class EkycResult {
  const EkycResult(this.outcome, {this.verificationId, this.error});

  final EkycOutcome outcome;
  final String? verificationId;
  final Object? error;

  bool get sent => const {EkycOutcome.approved, EkycOutcome.review, EkycOutcome.rejected, EkycOutcome.submitted}
      .contains(outcome);

  static EkycOutcome outcomeOf(String? s) => switch (s) {
        'approved' => EkycOutcome.approved,
        'review' => EkycOutcome.review,
        'rejected' => EkycOutcome.rejected,
        'submitted' || 'processing' => EkycOutcome.submitted,
        'cancelled' || 'created' => EkycOutcome.cancelled,
        'expired' => EkycOutcome.expired,
        'invalid' || 'deleted' => EkycOutcome.invalid,
        _ => EkycOutcome.error,
      };

  /// The return link the hosted page sends the user back to
  /// (`your-redirect?verification_id=…&status=…`). Returns null when the link
  /// is not a GET eKYC return.
  static EkycResult? fromReturnUri(Uri uri) {
    final q = uri.queryParameters;
    if (!q.containsKey('verification_id') || !q.containsKey('status')) return null;
    return EkycResult(outcomeOf(q['status']), verificationId: q['verification_id']);
  }

  /// A message from the hosted page's bridge: {"event":"ekyc.finished", ...}.
  static EkycResult? fromBridge(Map<String, dynamic> m) {
    if (m['event'] != 'ekyc.finished') return null;
    return EkycResult(outcomeOf(m['status'] as String?), verificationId: m['verification_id'] as String?);
  }

  @override
  String toString() => 'EkycResult($outcome, $verificationId${error != null ? ', $error' : ''})';
}
