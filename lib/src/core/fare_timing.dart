/// Fare time limits (Admin › Settings › Fare AI provider › Time limits),
/// the Dart side of `supabase/functions/_shared/fare_timing.ts`.
///
/// The server steps are saved in the admin-only `fare_ai_provider` setting
/// (`timing`); what the apps need — how long the rider app waits, and
/// whether and how long an iPhone asks Apple Maps itself — in the readable
/// `fare_timing` setting, which every signed-in app reads and only admins
/// write.
library;

import 'dart:math' as math;

const fareTimingSettingKey = 'fare_timing';

class FareTiming {
  const FareTiming({
    this.liveSeconds = 3,
    this.appleSeconds = 1.5,
    this.aiSeconds = 5,
    this.osrmSeconds = 3,
    this.appWaitSeconds = 5,
    this.deviceApple = true,
    this.deviceAppleSeconds = 1.5,
  });

  static const defaults = FareTiming();

  /// The bounds an admin may set, in seconds (as `TIMING_BOUNDS`).
  static const bounds = <String, (double, double)>{
    'liveSeconds': (0.5, 15),
    'appleSeconds': (0.5, 10),
    'aiSeconds': (1, 30),
    'osrmSeconds': (0.5, 10),
    'appWaitSeconds': (2, 30),
    'deviceAppleSeconds': (0.5, 10),
  };

  /// Waze and Google Maps together, shared.
  final double liveSeconds;

  /// The Apple Maps server step.
  final double appleSeconds;

  /// Each AI call.
  final double aiSeconds;

  /// The office NAS OSRM.
  final double osrmSeconds;

  /// How long the rider app waits for an estimate in all.
  final double appWaitSeconds;

  /// iPhones ask Apple Maps themselves (MapKit, on the phone).
  final bool deviceApple;

  /// How long an iPhone waits for Apple Maps.
  final double deviceAppleSeconds;

  static double _sec(Object? v, String name, double fallback) {
    if (v is! num || !v.isFinite) return fallback;
    final (lo, hi) = bounds[name]!;
    return (math.min(hi, math.max(lo, v.toDouble())) * 10).round() / 10;
  }

  /// From the two settings: [server] is `fare_ai_provider.timing`, [app] the
  /// `fare_timing` row. Missing or bad values are the defaults.
  factory FareTiming.fromJson({Object? server, Object? app}) {
    final s = server is Map ? server : const {};
    final a = app is Map ? app : const {};
    const d = defaults;
    return FareTiming(
      liveSeconds: _sec(s['liveSeconds'], 'liveSeconds', d.liveSeconds),
      appleSeconds: _sec(s['appleSeconds'], 'appleSeconds', d.appleSeconds),
      aiSeconds: _sec(s['aiSeconds'], 'aiSeconds', d.aiSeconds),
      osrmSeconds: _sec(s['osrmSeconds'], 'osrmSeconds', d.osrmSeconds),
      appWaitSeconds: _sec(a['appWaitSeconds'], 'appWaitSeconds', d.appWaitSeconds),
      deviceApple: a['deviceApple'] != false,
      deviceAppleSeconds: _sec(a['deviceAppleSeconds'], 'deviceAppleSeconds', d.deviceAppleSeconds),
    );
  }

  Map<String, dynamic> serverJson() =>
      {'liveSeconds': liveSeconds, 'appleSeconds': appleSeconds, 'aiSeconds': aiSeconds, 'osrmSeconds': osrmSeconds};

  Map<String, dynamic> appJson() =>
      {'appWaitSeconds': appWaitSeconds, 'deviceApple': deviceApple, 'deviceAppleSeconds': deviceAppleSeconds};

  Duration get appWait => Duration(milliseconds: (appWaitSeconds * 1000).round());
  Duration get deviceAppleWait => Duration(milliseconds: (deviceAppleSeconds * 1000).round());

  FareTiming copyWith({
    double? liveSeconds,
    double? appleSeconds,
    double? aiSeconds,
    double? osrmSeconds,
    double? appWaitSeconds,
    bool? deviceApple,
    double? deviceAppleSeconds,
  }) =>
      FareTiming(
        liveSeconds: liveSeconds ?? this.liveSeconds,
        appleSeconds: appleSeconds ?? this.appleSeconds,
        aiSeconds: aiSeconds ?? this.aiSeconds,
        osrmSeconds: osrmSeconds ?? this.osrmSeconds,
        appWaitSeconds: appWaitSeconds ?? this.appWaitSeconds,
        deviceApple: deviceApple ?? this.deviceApple,
        deviceAppleSeconds: deviceAppleSeconds ?? this.deviceAppleSeconds,
      );

  @override
  bool operator ==(Object other) =>
      other is FareTiming &&
      other.liveSeconds == liveSeconds &&
      other.appleSeconds == appleSeconds &&
      other.aiSeconds == aiSeconds &&
      other.osrmSeconds == osrmSeconds &&
      other.appWaitSeconds == appWaitSeconds &&
      other.deviceApple == deviceApple &&
      other.deviceAppleSeconds == deviceAppleSeconds;

  @override
  int get hashCode =>
      Object.hash(liveSeconds, appleSeconds, aiSeconds, osrmSeconds, appWaitSeconds, deviceApple, deviceAppleSeconds);
}
