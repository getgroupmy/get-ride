import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers.dart';

/// Whether this account is online as a driver (the Drive tab's switch).
/// While it is, the Ride tab is greyed out: a driver taking requests
/// can't book a ride as a passenger at the same time.
///
/// It is the driver's own choice and outlives the Drive screen: a trip that
/// ends (completed or cancelled) brings the driver back online, ready for
/// the next request. It outlives the app too: a driver online when the app
/// closed is put back online when the Drive screen opens again
/// ([DriverOnline.wasOnline]). Only the switch, or signing out (a different
/// account), takes it off.
final driverOnlineProvider = NotifierProvider<DriverOnline, bool>(DriverOnline.new);

/// The phone's memory of the switch, per account.
String driverOnlineKey(String uid) => 'driver_online_$uid';

class DriverOnline extends Notifier<bool> {
  String? _uid;

  @override
  bool build() {
    // A different account (or none) starts offline.
    String? uid;
    try {
      uid = ref.watch(currentUserIdProvider);
    } catch (_) {}
    _uid = uid;
    return false;
  }

  void set(bool online) {
    // The screen clears it as it goes; the whole app may be going with it.
    if (ref.mounted) state = online;
    unawaited(_remember(online));
  }

  /// The switch as this account left it when the app last closed.
  Future<bool> wasOnline() async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      return (await SharedPreferences.getInstance()).getBool(driverOnlineKey(uid)) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _remember(bool online) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (online) {
        await prefs.setBool(driverOnlineKey(uid), true);
      } else {
        await prefs.remove(driverOnlineKey(uid));
      }
    } catch (_) {}
  }
}
