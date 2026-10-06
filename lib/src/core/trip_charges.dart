/// Tolls and other charges the driver declares when completing a trip (Expo
/// ride-running's tolls popup). Stored on the ride (`toll_charges`,
/// `other_charges`, `other_charges_note`; guarded by migration 0099) so the
/// rider sees them line by line, and kept out of the fare the commission is
/// charged on.
library;

/// Largest single charge accepted (migration 0099's check).
const tripChargeMax = 10000.0;

/// Longest note accepted with "other charges".
const tripChargeNoteMax = 200;

class TripCharges {
  const TripCharges({this.tolls = 0, this.other = 0, this.note});
  final double tolls;
  final double other;
  final String? note;

  static const none = TripCharges();

  double get total => tolls + other;
  bool get isEmpty => tolls <= 0 && other <= 0;

  /// The ride columns. Nothing declared writes zeros, so a re-completed ride
  /// never keeps stale charges.
  Map<String, Object?> toPatch() => {
    'toll_charges': tolls,
    'other_charges': other,
    'other_charges_note': other > 0 ? note : null,
  };
}

/// A typed amount ("5", "5.5", "5,50", "RM 12") as money, or null when it
/// isn't one. Blank is zero.
double? parseChargeAmount(String raw) {
  final s = raw.trim().replaceAll(RegExp(r'[^0-9.,]'), '').replaceAll(',', '.');
  if (s.isEmpty) return raw.trim().isEmpty ? 0 : null;
  if ('.'.allMatches(s).length > 1) return null;
  final n = double.tryParse(s);
  if (n == null || !n.isFinite) return null;
  return (n * 100).roundToDouble() / 100;
}

/// The declared charges, or why they can't be saved.
({TripCharges? charges, String? problem}) resolveTripCharges({
  required String tolls,
  required String other,
  required String note,
}) {
  final t = parseChargeAmount(tolls), o = parseChargeAmount(other);
  if (t == null) return (charges: null, problem: 'Enter the tolls as an amount, e.g. 5.50.');
  if (o == null) return (charges: null, problem: 'Enter the other charges as an amount, e.g. 3.00.');
  if (t > tripChargeMax || o > tripChargeMax) {
    return (charges: null, problem: 'A charge can be at most ${tripChargeMax.toStringAsFixed(0)}.');
  }
  final n = note.trim();
  if (o > 0 && n.isEmpty) return (charges: null, problem: 'Say what the other charges are for.');
  if (n.length > tripChargeNoteMax) {
    return (charges: null, problem: 'Keep the note under $tripChargeNoteMax characters.');
  }
  return (charges: TripCharges(tolls: t, other: o, note: n.isEmpty ? null : n), problem: null);
}
