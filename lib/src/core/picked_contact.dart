// A contact picked from the phone's address book (Expo
// `emergency-contact-edit`'s "Contacts" button), reduced to what an
// emergency contact stores.

/// The name and phone number to fill in from a picked contact: the number
/// the person chose, else the contact's first, cleaned to `+` and digits.
/// The name is trimmed; either is null when the contact had none.
({String? name, String? phone}) pickedContact({String? fullName, String? selected, List<String>? numbers}) {
  String? clean(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().replaceAll(RegExp(r'[^\d+]'), '');
    final plus = s.startsWith('+');
    final digits = s.replaceAll('+', '');
    return digits.isEmpty ? null : '${plus ? '+' : ''}$digits';
  }

  final phone = clean(selected) ?? (numbers ?? const []).map(clean).whereType<String>().firstOrNull;
  final name = fullName?.trim();
  return (name: name == null || name.isEmpty ? null : name, phone: phone);
}
