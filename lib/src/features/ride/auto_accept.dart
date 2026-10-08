import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Rides whose rider switched on "Auto-accept offer of RM x" when booking,
/// with that amount: the searching screen takes an offer at or under it
/// without asking (`shouldAutoAccept`).
final autoAcceptProvider = NotifierProvider<AutoAcceptRides, Map<String, double>>(AutoAcceptRides.new);

class AutoAcceptRides extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => const {};

  void set(String rideId, double limit) => state = {...state, rideId: limit};

  /// Switched off on the search sheet.
  void clear(String rideId) => state = {...state}..remove(rideId);
}
