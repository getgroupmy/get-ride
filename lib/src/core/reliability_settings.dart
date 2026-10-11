// Admin → SMS / WhatsApp → Reliability: the switches for the parts of the app
// that keep working without a connection (reliability Phase C). One global
// settings_entries row, readable by every app; anything missing or unreadable
// counts as on, so an outage never turns a safety net off. Pure.

const reliabilityCategory = 'reliability-messaging';

/// The one row this category has.
const reliabilityRowId = '72656c69-6162-4c69-8000-000000000001';

class ReliabilitySettings {
  const ReliabilitySettings({
    this.chatOutbox = true,
    this.rideCache = true,
    this.backgroundAck = true,
    this.readAloud = true,
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

  static const keys = ['chat_outbox', 'ride_cache', 'background_ack', 'read_aloud'];

  factory ReliabilitySettings.fromValues(Map<String, dynamic>? v) => ReliabilitySettings(
    chatOutbox: _on(v?['chat_outbox']),
    rideCache: _on(v?['ride_cache']),
    backgroundAck: _on(v?['background_ack']),
    readAloud: _on(v?['read_aloud']),
  );

  Map<String, dynamic> toValues() => {
    'chat_outbox': chatOutbox,
    'ride_cache': rideCache,
    'background_ack': backgroundAck,
    'read_aloud': readAloud,
  };

  /// This with the switch [key] (one of [keys]) set to [on].
  ReliabilitySettings withSwitch(String key, bool on) =>
      ReliabilitySettings.fromValues({...toValues(), if (keys.contains(key)) key: on});

  bool operator [](String key) => toValues()[key] as bool? ?? true;

  @override
  bool operator ==(Object other) =>
      other is ReliabilitySettings &&
      other.chatOutbox == chatOutbox &&
      other.rideCache == rideCache &&
      other.backgroundAck == backgroundAck &&
      other.readAloud == readAloud;

  @override
  int get hashCode => Object.hash(chatOutbox, rideCache, backgroundAck, readAloud);
}

/// Only an explicit "off" turns a switch off.
bool _on(Object? v) => switch (v) {
  false || 'false' || 0 || '0' || 'off' => false,
  _ => true,
};
