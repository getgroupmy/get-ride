/// The parts of the admin display settings (Admin → Display, row `global` of
/// `admin_display_settings`) that change how the rider app behaves, as Expo's
/// `DisplaySettingsContext` applies them. Expo's pixel offsets and side-menu
/// layout belong to its own screens and have no meaning here.
library;

class AppDisplay {
  const AppDisplay({
    this.serviceEnabled = true,
    this.registrationEnabled = true,
    this.passengerRegistrationEnabled = true,
    this.driverRegistrationEnabled = true,
    this.showSignInLogo = true,
    this.showAiTollCharges = true,
    this.showAiTollBooths = true,
    this.recenterButton = true,
    this.connectedPopup = true,
    this.connectionFailedPopup = true,
    this.recentLocations = true,
    this.recentLocationsCount = 4,
  });

  /// Master service switch. Off: booking shows "coming soon" instead of
  /// placing a request.
  final bool serviceEnabled;

  /// The switch from before the per-role ones (`registrationEnabled`):
  /// off closes both. The admin now writes it as "either role is open", so
  /// app versions that only know it still close when both are off.
  final bool registrationEnabled;

  /// Admin → Display → Sign-in Screen → New passenger sign-up
  /// (`passengerRegistrationEnabled`). Off: sign-up offers Driver only.
  final bool passengerRegistrationEnabled;

  /// … → New driver (partner) sign-up (`driverRegistrationEnabled`). Off:
  /// sign-up offers Passenger only, and a passenger without a partner
  /// application can't start one. The server refuses the same
  /// (`registration_open`, migration 0287).
  final bool driverRegistrationEnabled;

  /// A new passenger account may be made.
  bool get passengerSignUpOpen => registrationEnabled && passengerRegistrationEnabled;

  /// A new driver account, or a new partner application, may be made.
  bool get driverSignUpOpen => registrationEnabled && driverRegistrationEnabled;

  /// Either: a phone number with no account is offered sign-up (an SMS
  /// code). Both closed: it is told there is no account, and no code is
  /// sent.
  bool get anySignUpOpen => passengerSignUpOpen || driverSignUpOpen;

  /// Whether the sign-in screen shows the GET.ride logo.
  final bool showSignInLogo;

  /// Whether the AI route estimate's toll charges are shown on the booking
  /// panel.
  final bool showAiTollCharges;

  /// Whether the toll booths on the AI route estimate are marked on the map.
  final bool showAiTollBooths;

  /// Whether the home map shows its recenter (my location) button.
  final bool recenterButton;

  /// Whether launch shows the "Connected" popup when the backend answers, and
  /// the "Not Connected" one when it does not.
  final bool connectedPopup;
  final bool connectionFailedPopup;

  /// Whether the place picker lists the rider's recent destinations, and how
  /// many (Admin → Display → Recent Locations, 0–8).
  final bool recentLocations;
  final int recentLocationsCount;

  /// Reads the stored blob. Anything missing or unreadable keeps its default,
  /// so a half-written or older row never switches the service off.
  static AppDisplay fromSettings(Object? raw) {
    if (raw is! Map) return const AppDisplay();
    bool flag(String key) {
      final v = raw[key];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        if (s == 'false' || s == '0' || s == 'off') return false;
        if (s == 'true' || s == '1' || s == 'on') return true;
      }
      return true;
    }

    return AppDisplay(
      serviceEnabled: flag('serviceEnabled'),
      registrationEnabled: flag('registrationEnabled'),
      passengerRegistrationEnabled: flag('passengerRegistrationEnabled'),
      driverRegistrationEnabled: flag('driverRegistrationEnabled'),
      showSignInLogo: flag('signInLogo'),
      showAiTollCharges: flag('showAiTollCharges'),
      showAiTollBooths: flag('showAiTollBooths'),
      recenterButton: flag('recenterButton'),
      connectedPopup: flag('connectedPopupEnabled'),
      connectionFailedPopup: flag('connectionFailedPopupEnabled'),
      recentLocations: flag('recentLocations'),
      recentLocationsCount: _count(raw['recentLocationsCount']),
    );
  }
}

int _count(Object? v) {
  final n = v is num ? v : num.tryParse('${v ?? ''}');
  if (n == null) return 4;
  return n.round().clamp(0, 8);
}

/// Shown instead of a booking while the service switch is off (Expo's
/// "Coming Soon" popup).
const serviceComingSoonMessage = "This service isn't available yet. Please check back later.";

/// Shown to a number with no account while registration is closed (Expo's
/// "contact Administrator" popup), on a page of its own.
const registrationClosedTitle = 'New registrations are closed';
const registrationClosedMessage = 'This number has no account. For new registration please contact Administrator.';

/// The same page opened again with no number to name (a reload, a bare
/// link): what closed means, without "this number".
const registrationClosedNoNumberMessage =
    "New accounts can't be made right now. If you already have an account, "
    'sign in with its number. For a new account, please contact Administrator.';

/// Whether [hasAccount] may continue to sign in or sign up.
bool mayContinueSignIn({required bool hasAccount, required AppDisplay display}) =>
    hasAccount || display.anySignUpOpen;

/// The phone screen's modal for a number with no account while both
/// passenger and driver sign-up are closed (no SMS code is sent).
const noAccountTitle = 'No account found';
const noAccountMessage = 'There is no account for this number, and new sign-ups are closed right now.';

/// Under the Passenger / Driver choice when one of them is closed.
const passengerSignUpPausedNote = 'New passenger accounts are paused. You can sign up as a driver.';
const driverSignUpPausedNote = 'New driver accounts are paused. You can sign up as a passenger.';

/// A passenger opening partner registration while driver sign-up is
/// closed (applications already started may still be finished).
const partnerRegistrationPausedTitle = 'New partner registration is paused';
const partnerRegistrationPausedMessage =
    "We aren't taking new partner applications right now. Please check back later.";

/// The server's refusal (`REGISTRATION_CLOSED`, migration 0287), from the
/// SMS code, the PIN or the partner row: whether [message] is one.
bool isRegistrationClosed(String? message) => (message ?? '').contains('REGISTRATION_CLOSED');

/// What Set PIN says when the server refused the new account's [role].
String registrationClosedPinMessage(String? role) => switch (role) {
      'driver' => 'New driver accounts are paused right now. Please try again later.',
      'passenger' => 'New passenger accounts are paused right now. Please try again later.',
      _ => 'New accounts are paused right now. Please try again later.',
    };
