import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether this account is online as a driver (the Drive tab's switch).
/// While it is, the Ride tab is greyed out: a driver taking requests
/// can't book a ride as a passenger at the same time.
final driverOnlineProvider = NotifierProvider<DriverOnline, bool>(DriverOnline.new);

class DriverOnline extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool online) {
    // The screen clears it as it goes; the whole app may be going with it.
    if (ref.mounted) state = online;
  }
}
