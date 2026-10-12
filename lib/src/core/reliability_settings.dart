// Admin → SMS / WhatsApp → Reliability: the switches for the parts of the app
// that keep working without a connection (reliability Phase C). One global
// settings_entries row, readable by every app; anything missing or unreadable
// counts as on, so an outage never turns a safety net off. The one exception
// is the server-only trip start, which is off unless turned on: it stops
// builds older than 0152 starting trips. The Bluetooth handshake's switches
// (Phase D, lib/src/core/ble_handshake.dart) live in the same row. Pure.

import 'ble_handshake.dart';
import 'trip_safety.dart';

const reliabilityCategory = 'reliability-messaging';

/// The one row this category has.
const reliabilityRowId = '72656c69-6162-4c69-8000-000000000001';

class ReliabilitySettings {
  const ReliabilitySettings({
    this.chatOutbox = true,
    this.rideCache = true,
    this.backgroundAck = true,
    this.readAloud = true,
    this.serverTripStart = false,
    this.ble = const BleSettings(),
    this.safety = const SafetySettings(),
  });

  /// Chat messages written with no connection wait on the phone and go when
  /// it is back. Off: a send with no connection fails, as before.
  final bool chatOutbox;

  /// The trip screens show the ride as last seen when the server can't be
  /// reached, and a relaunch with no signal still finds the ride.
  final bool rideCache;

  /// A push that lands while the app is closed is acknowledged from the
  /// background, so a chat message shows delivered at once.
  final bool backgroundAck;

  /// Drivers may have the passenger's messages read aloud during a trip.
  final bool readAloud;

  /// Only the server starts a trip (migration 0152): the trip code leaves the
  /// ride row and a client can't set the status itself. Off by default; turn
  /// it on once the App Version gate has every phone on a build that uses
  /// start_trip.
  final bool serverTripStart;

  /// The phones find each other at the kerb (0153); off by default.
  final BleSettings ble;

  /// Trip safety signals (0154); off by default.
  final SafetySettings safety;

  static const keys = ['chat_outbox', 'ride_cache', 'background_ack', 'read_aloud', 'server_trip_start'];

  factory ReliabilitySettings.fromValues(Map<String, dynamic>? v) => ReliabilitySettings(
    chatOutbox: _on(v?['chat_outbox']),
    rideCache: _on(v?['ride_cache']),
    backgroundAck: _on(v?['background_ack']),
    readAloud: _on(v?['read_aloud']),
    serverTripStart: _onlyIfOn(v?['server_trip_start']),
    ble: BleSettings.fromValues(v),
    safety: SafetySettings.fromValues(v),
  );

  Map<String, dynamic> toValues() => {
    'chat_outbox': chatOutbox,
    'ride_cache': rideCache,
    'background_ack': backgroundAck,
    'read_aloud': readAloud,
    'server_trip_start': serverTripStart,
    ...ble.toValues(),
    ...safety.toValues(),
  };

  /// This with the switch [key] (one of [keys]) set to [on].
  ReliabilitySettings withSwitch(String key, bool on) =>
      ReliabilitySettings.fromValues({...toValues(), if (keys.contains(key)) key: on});

  /// This with the Bluetooth switches replaced.
  ReliabilitySettings withBle(BleSettings b) => ReliabilitySettings.fromValues({...toValues(), ...b.toValues()});

  /// This with the trip safety switches replaced.
  ReliabilitySettings withSafety(SafetySettings v) => ReliabilitySettings.fromValues({...toValues(), ...v.toValues()});

  bool operator [](String key) => toValues()[key] as bool? ?? false;

  @override
  bool operator ==(Object other) =>
      other is ReliabilitySettings &&
      other.chatOutbox == chatOutbox &&
      other.rideCache == rideCache &&
      other.backgroundAck == backgroundAck &&
      other.readAloud == readAloud &&
      other.serverTripStart == serverTripStart &&
      other.ble == ble &&
      other.safety == safety;

  @override
  int get hashCode => Object.hash(chatOutbox, rideCache, backgroundAck, readAloud, serverTripStart, ble, safety);
}

/// Only an explicit "off" turns a switch off.
bool _on(Object? v) => switch (v) {
  false || 'false' || 0 || '0' || 'off' => false,
  _ => true,
};

/// Only an explicit "on" turns it on (the SQL side reads it the same way:
/// reliability_server_trip_start, 0152).
bool _onlyIfOn(Object? v) => switch (v) {
  true || 'true' || 't' || 1 || '1' || 'on' => true,
  _ => false,
};
