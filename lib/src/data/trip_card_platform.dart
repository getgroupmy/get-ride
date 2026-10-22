// The phone's side of the trip card (core/trip_card.dart), over the
// MethodChannel `getride/trip_card`:
//   * Android: a pinned notification with a progress bar on its own
//     "Trip progress" channel (android/.../TripCardNotifier.kt);
//   * iPhone: a Live Activity, once its widget extension is in the app
//     (docs/trip_card_ios.md); until then the iPhone answers false.
// Nothing on the web or a desktop.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract class TripCardPlatform {
  /// Whether this phone can show a trip card at all.
  bool get supported;

  /// Shows the card [card] (TripCard.toPlatform); false when the phone
  /// can't (notifications off, no Live Activities).
  Future<bool> start(Map<String, Object?> card);

  /// Redraws the card already showing; false when it isn't.
  Future<bool> update(Map<String, Object?> card);

  /// Takes the card of [rideId] away.
  Future<void> end(String rideId);
}

const tripCardChannel = MethodChannel('getride/trip_card');

class MethodChannelTripCardPlatform implements TripCardPlatform {
  const MethodChannelTripCardPlatform();

  /// A phone, and not a test run (whose screens get a fake when they want one).
  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) &&
      !Platform.environment.containsKey('FLUTTER_TEST');

  Future<bool> _call(String method, Object? args) async {
    if (!supported) return false;
    try {
      return await tripCardChannel.invokeMethod<bool>(method, args) ?? false;
    } catch (e) {
      // An older build without the channel, or the phone said no.
      debugPrint('[trip card] $method: $e');
      return false;
    }
  }

  @override
  Future<bool> start(Map<String, Object?> card) => _call('start', card);

  @override
  Future<bool> update(Map<String, Object?> card) => _call('update', card);

  @override
  Future<void> end(String rideId) => _call('end', {'rideId': rideId});
}

final tripCardPlatformProvider = Provider<TripCardPlatform>((ref) => const MethodChannelTripCardPlatform());
