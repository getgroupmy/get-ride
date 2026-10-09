/// The steps of changing (or first setting) the sign-in PIN from Settings
/// (Expo `change-pin.tsx`): prove who you are, choose a new PIN, type it
/// again. Pure, so the screen only draws the step it is told to.
library;

import 'auth_utils.dart';

enum PinChangeStep {
  /// Type the current PIN.
  verify,

  /// Forgot it: type the SMS code sent to the account's own number.
  code,

  /// Choose the new PIN.
  create,

  /// Type the new PIN again.
  confirm,
}

/// The step an account starts on: one without a PIN has nothing to prove
/// and goes straight to choosing one.
PinChangeStep firstPinChangeStep({required bool hasPin}) => hasPin ? PinChangeStep.verify : PinChangeStep.create;

/// The step back from [step] (null: leave the screen). The code step goes
/// back to the current PIN, as does choosing after proving it.
PinChangeStep? previousPinChangeStep(PinChangeStep step, {required bool hasPin}) => switch (step) {
  PinChangeStep.verify => null,
  PinChangeStep.code => PinChangeStep.verify,
  PinChangeStep.create => hasPin ? PinChangeStep.verify : null,
  PinChangeStep.confirm => PinChangeStep.create,
};

/// Expo's step titles and lines.
({String title, String subtitle}) pinChangeCopy(PinChangeStep step, {required bool hasPin, String? phone}) =>
    switch (step) {
      PinChangeStep.verify => (title: 'Enter your current PIN', subtitle: 'Verify your identity to change your PIN'),
      PinChangeStep.code => (title: 'Enter the code', subtitle: 'We sent a 6-digit code to ${phone ?? 'your phone'}'),
      PinChangeStep.create => (
        title: hasPin ? 'Create your new PIN' : 'Create your PIN',
        subtitle: 'Choose a 6-digit PIN to sign in with',
      ),
      PinChangeStep.confirm => (title: 'Confirm your new PIN', subtitle: 'Almost done! Enter it once more'),
    };

/// Why the confirmed [pin] can't be saved, or null when it can. [current]
/// is the PIN proven on the first step (null when it was skipped).
String? newPinProblem(String pin, String confirm, {String? current}) {
  if (!isValidPin(pin)) return 'PIN must be 6 digits.';
  if (pin != confirm) return 'PINs do not match. Please try again.';
  if (current != null && pin == current) return 'New PIN must be different from current PIN.';
  return null;
}
