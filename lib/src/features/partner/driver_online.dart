import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';

/// Whether this account is online as a driver (the Drive tab's switch).
/// While it is, the Ride tab is greyed out: a driver taking requests
/// can't book a ride as a passenger at the same time.
///
/// It is the driver's own choice and outlives the Drive screen: a trip that
/// ends (completed or cancelled) brings the driver back online, ready for
/// the next request. Only the switch, or signing out (a different account),
/// takes it off.
final driverOnlineProvider = NotifierProvider<DriverOnline, bool>(DriverOnline.new);

class DriverOnline extends Notifier<bool> {
  @override
  bool build() {
    // A different account (or none) starts offline.
    try {
      ref.watch(currentUserIdProvider);
    } catch (_) {}
    return false;
  }

  void set(bool online) {
    // The screen clears it as it goes; the whole app may be going with it.
    if (ref.mounted) state = online;
  }
}
