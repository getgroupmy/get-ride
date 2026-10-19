// Asking the phone again for location or notifications, and what to say
// when it won't show its question any more. Android stops asking after two
// refusals ("Don't allow"), iOS after the first, and the browser once the
// site is blocked: from then on only Settings can switch it back on. Pure;
// the flow with its dialog is in features/permissions/permission_actions.dart.

/// What is asked for.
enum AskKind { location, notifications }

/// How asking went.
enum AskAnswer {
  /// Allowed (location: while in use or always).
  granted,

  /// Refused in the phone's own question; it can be asked again.
  denied,

  /// Refused for good: the phone no longer shows its question.
  blocked,

  /// The phone's Location is switched off altogether.
  serviceOff,

  /// Nothing to ask here (no push on this build, a phone that can't say).
  unsupported,
}

/// One ask: the answer, and whether the phone showed its question.
class AskResult {
  const AskResult(this.answer, {this.prompted = true});
  final AskAnswer answer;
  final bool prompted;

  @override
  bool operator ==(Object other) => other is AskResult && other.answer == answer && other.prompted == prompted;

  @override
  int get hashCode => Object.hash(answer, prompted);

  @override
  String toString() => 'AskResult($answer, prompted: $prompted)';
}

/// A refusal answered faster than this was the phone's, not a person's: no
/// question was shown, so it won't be shown again.
const askNoDialogUnder = Duration(milliseconds: 450);

/// A request that came back refused, read as [AskAnswer.denied] when the
/// question was shown and [AskAnswer.blocked] when it wasn't ([took] under
/// [askNoDialogUnder]) or the plugin said so ([forever]).
AskResult refusal({required bool forever, required Duration took}) {
  final prompted = took >= askNoDialogUnder;
  return AskResult(forever || !prompted ? AskAnswer.blocked : AskAnswer.denied, prompted: prompted);
}

/// The explanation's title.
String askBlockedTitle(AskKind kind, {bool serviceOff = false}) => switch (kind) {
  _ when serviceOff => 'Location is off on this phone',
  AskKind.location => 'Location is turned off for GET.ride',
  AskKind.notifications => 'Notifications are turned off for GET.ride',
};

/// What to do, for a phone ([web] false) or the browser.
String askBlockedMessage(AskKind kind, {bool serviceOff = false, bool web = false, bool ios = false}) {
  if (serviceOff) {
    return "Your phone's Location is switched off, so GET.ride can't find your pickup. Open Location settings and "
        'turn it on.';
  }
  if (web) {
    final what = kind == AskKind.location ? 'Location' : 'Notifications';
    return 'Your browser is blocking ${what.toLowerCase()} for this site. Tap the lock icon next to the address, '
        'set $what to Allow, then reload the page.';
  }
  return switch (kind) {
    AskKind.location when ios =>
      'Location is turned off for GET.ride. Open Settings → Location and choose While Using the App.',
    AskKind.location =>
      'Location is turned off for GET.ride. Open Settings → Permissions → Location and choose Allow while using '
          'the app.',
    AskKind.notifications when ios =>
      'Notifications are turned off for GET.ride. Open Settings → Notifications and turn on Allow Notifications.',
    AskKind.notifications =>
      'Notifications are turned off for GET.ride. Open Settings → Notifications and turn on All GET.ride '
          'notifications.',
  };
}

/// The one-line hint under a card's button once only Settings can help.
String askBlockedHint(AskKind kind, {bool web = false}) => web
    ? 'Blocked by your browser: use the lock icon next to the address.'
    : kind == AskKind.location
    ? 'Refused before, so your phone won\'t ask again. Allow it in Settings.'
    : 'Refused before, so your phone won\'t ask again. Turn them on in Settings.';
