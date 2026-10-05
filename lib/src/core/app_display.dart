/// The parts of the admin display settings (Admin → Display, row `global` of
/// `admin_display_settings`) that change how the rider app behaves, as Expo's
/// `DisplaySettingsContext` applies them. Expo's pixel offsets and side-menu
/// layout belong to its own screens and have no meaning here.
library;

class AppDisplay {
  const AppDisplay({this.serviceEnabled = true, this.registrationEnabled = true, this.showAiTollCharges = true});

  /// Master service switch. Off: booking shows "coming soon" instead of
  /// placing a request.
  final bool serviceEnabled;

  /// Off: a phone number with no account is not offered sign-up.
  final bool registrationEnabled;

  /// Whether the AI route estimate's toll charges are shown on the booking
  /// panel.
  final bool showAiTollCharges;

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
      showAiTollCharges: flag('showAiTollCharges'),
    );
  }
}

/// Shown instead of a booking while the service switch is off (Expo's
/// "Coming Soon" popup).
const serviceComingSoonMessage = "This service isn't available yet. Please check back later.";

/// Shown to a number with no account while registration is closed (Expo's
/// "contact Administrator" popup).
const registrationClosedMessage = 'This number has no account. For new registration please contact Administrator.';

/// Whether [hasAccount] may continue to sign in or sign up.
bool mayContinueSignIn({required bool hasAccount, required AppDisplay display}) =>
    hasAccount || display.registrationEnabled;
