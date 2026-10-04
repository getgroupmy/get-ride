/// Meter Digital rate cards — the pure half, ported from the Expo
/// `utils/meterSettings.ts`, `utils/meterLeave.ts`, `utils/meterLeaveApps.ts`
/// and the rate-card part of `utils/taxiMeter.ts`.
///
/// The table (`meter_digital_settings`) is shared with the Expo app, so the
/// row shape, the coercion defaults and the validation rules here match the
/// TypeScript one for one. A configured value is used only when it is usable;
/// anything missing or out of range falls back to the built-in TEKSI default.
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Built-in tariff (taxiMeter.ts)
// ---------------------------------------------------------------------------

const flagFall = 4.0;
const flagFallDistanceM = 1000;
const incrementCharge = 0.35;
const incrementDistanceM = 200;
const incrementTimeMs = 36000;
const newTariffPerKm = 1.0;
const newTariffPerMin = 0.3;
const nightStartHour = 0;
const nightEndHour = 6;
const nightMultiplierDefault = 1.5;
const extraStepDefault = 0.5;
const maxExtraDefault = 99.5;

/// Everything a fare depends on, in one card (`MeterRates`).
class MeterRates {
  const MeterRates({
    required this.flagFare,
    required this.flagDistanceM,
    required this.minimumFare,
    required this.distanceMode,
    required this.distanceBlockM,
    required this.distanceBlockCharge,
    required this.perKmCharge,
    required this.timeMode,
    required this.timeBlockS,
    required this.timeBlockCharge,
    required this.perMinuteCharge,
    required this.perSecondCharge,
    required this.chargeMode,
    required this.chargeFrom,
  });

  final double flagFare;
  final int flagDistanceM;
  final double minimumFare;

  /// `block` | `per_km` | `off`.
  final String distanceMode;
  final int distanceBlockM;
  final double distanceBlockCharge;
  final double perKmCharge;

  /// `block` | `per_minute` | `per_second` | `off`.
  final String timeMode;
  final int timeBlockS;
  final double timeBlockCharge;
  final double perMinuteCharge;
  final double perSecondCharge;

  /// `max` | `sum`.
  final String chargeMode;

  /// `flag` | `start`.
  final String chargeFrom;

  MeterRates copyWith({
    double? flagFare,
    int? flagDistanceM,
    double? minimumFare,
    String? distanceMode,
    int? distanceBlockM,
    double? distanceBlockCharge,
    double? perKmCharge,
    String? timeMode,
    int? timeBlockS,
    double? timeBlockCharge,
    double? perMinuteCharge,
    double? perSecondCharge,
    String? chargeMode,
    String? chargeFrom,
  }) =>
      MeterRates(
        flagFare: flagFare ?? this.flagFare,
        flagDistanceM: flagDistanceM ?? this.flagDistanceM,
        minimumFare: minimumFare ?? this.minimumFare,
        distanceMode: distanceMode ?? this.distanceMode,
        distanceBlockM: distanceBlockM ?? this.distanceBlockM,
        distanceBlockCharge: distanceBlockCharge ?? this.distanceBlockCharge,
        perKmCharge: perKmCharge ?? this.perKmCharge,
        timeMode: timeMode ?? this.timeMode,
        timeBlockS: timeBlockS ?? this.timeBlockS,
        timeBlockCharge: timeBlockCharge ?? this.timeBlockCharge,
        perMinuteCharge: perMinuteCharge ?? this.perMinuteCharge,
        perSecondCharge: perSecondCharge ?? this.perSecondCharge,
        chargeMode: chargeMode ?? this.chargeMode,
        chargeFrom: chargeFrom ?? this.chargeFrom,
      );

  @override
  bool operator ==(Object other) =>
      other is MeterRates &&
      other.flagFare == flagFare &&
      other.flagDistanceM == flagDistanceM &&
      other.minimumFare == minimumFare &&
      other.distanceMode == distanceMode &&
      other.distanceBlockM == distanceBlockM &&
      other.distanceBlockCharge == distanceBlockCharge &&
      other.perKmCharge == perKmCharge &&
      other.timeMode == timeMode &&
      other.timeBlockS == timeBlockS &&
      other.timeBlockCharge == timeBlockCharge &&
      other.perMinuteCharge == perMinuteCharge &&
      other.perSecondCharge == perSecondCharge &&
      other.chargeMode == chargeMode &&
      other.chargeFrom == chargeFrom;

  @override
  int get hashCode => Object.hash(flagFare, flagDistanceM, minimumFare, distanceMode, distanceBlockM,
      distanceBlockCharge, perKmCharge, timeMode, timeBlockS, timeBlockCharge, perMinuteCharge,
      perSecondCharge, chargeMode, chargeFrom);
}

/// The two built-in TEKSI tariffs, as rate cards.
const tariffRates = <String, MeterRates>{
  'old': MeterRates(
    flagFare: flagFall,
    flagDistanceM: flagFallDistanceM,
    minimumFare: 0,
    distanceMode: 'block',
    distanceBlockM: incrementDistanceM,
    distanceBlockCharge: incrementCharge,
    perKmCharge: newTariffPerKm,
    timeMode: 'block',
    timeBlockS: incrementTimeMs ~/ 1000,
    timeBlockCharge: incrementCharge,
    perMinuteCharge: newTariffPerMin,
    perSecondCharge: 0,
    chargeMode: 'max',
    chargeFrom: 'flag',
  ),
  'new': MeterRates(
    flagFare: flagFall,
    flagDistanceM: flagFallDistanceM,
    minimumFare: 0,
    distanceMode: 'per_km',
    distanceBlockM: incrementDistanceM,
    distanceBlockCharge: incrementCharge,
    perKmCharge: newTariffPerKm,
    timeMode: 'per_minute',
    timeBlockS: incrementTimeMs ~/ 1000,
    timeBlockCharge: incrementCharge,
    perMinuteCharge: newTariffPerMin,
    perSecondCharge: 0,
    chargeMode: 'sum',
    chargeFrom: 'start',
  ),
};

double _round2(double n) => (n * 100).round() / 100;
double _positive(num v, num fallback) => v.isFinite && v > 0 ? v.toDouble() : fallback.toDouble();
double _charge(num v) => v.isFinite && v > 0 ? v.toDouble() : 0;

/// The metered fare for a hire's totals (`computeMeterFare`, total only).
///
/// [chargeableMs] is the running time accrued past the flag distance (what a
/// `flag` card bills its time on); a `start` card bills [elapsedMs].
double computeMeterFareTotal(
  MeterRates rates, {
  required double distanceM,
  int elapsedMs = 0,
  int chargeableMs = 0,
  double multiplier = 1,
}) {
  final d = math.max(0.0, distanceM);
  final elapsed = math.max(0, elapsedMs);
  final billedM = rates.chargeFrom == 'start' ? d : math.max(0.0, d - math.max(0, rates.flagDistanceM));
  final billedMs = rates.chargeFrom == 'start' ? elapsed : math.max(0, chargeableMs);

  var distanceCharge = 0.0;
  if (rates.distanceMode == 'block') {
    final units = (billedM / _positive(rates.distanceBlockM, incrementDistanceM)).ceil();
    distanceCharge = units * _charge(rates.distanceBlockCharge);
  } else if (rates.distanceMode == 'per_km') {
    distanceCharge = (billedM / 1000) * _charge(rates.perKmCharge);
  }

  var timeCharge = 0.0;
  if (rates.timeMode == 'block') {
    final units = (billedMs / (_positive(rates.timeBlockS, 36) * 1000)).ceil();
    timeCharge = units * _charge(rates.timeBlockCharge);
  } else if (rates.timeMode == 'per_minute') {
    timeCharge = (billedMs / 60000) * _charge(rates.perMinuteCharge);
  } else if (rates.timeMode == 'per_second') {
    timeCharge = (billedMs / 1000) * _charge(rates.perSecondCharge);
  }

  final variable = rates.chargeMode == 'sum' ? distanceCharge + timeCharge : math.max(distanceCharge, timeCharge);
  final metered = math.max(_charge(rates.flagFare) + variable, _charge(rates.minimumFare));
  return _round2(metered * multiplier);
}

// ---------------------------------------------------------------------------
// Dispatch-app catalogue (meterLeaveApps.ts) — facts only
// ---------------------------------------------------------------------------

/// `ios` | `android` | `huawei`.
const storePlatforms = ['ios', 'android', 'huawei'];

const storeLabels = {'ios': 'App Store', 'android': 'Google Play', 'huawei': 'Huawei AppGallery'};

class MeterLeaveApp {
  const MeterLeaveApp({
    required this.id,
    required this.name,
    this.iosScheme,
    this.iosLink,
    this.androidPackage,
    this.storeIos,
    this.storeHuawei,
  });

  final String id;
  final String name;
  final String? iosScheme;

  /// A universal link the app claims (never an App Store page).
  final String? iosLink;
  final String? androidPackage;
  final String? storeIos;
  final String? storeHuawei;

  MeterLeaveApp copyWith({String? iosScheme}) => MeterLeaveApp(
        id: id,
        name: name,
        iosScheme: iosScheme ?? this.iosScheme,
        iosLink: iosLink,
        androidPackage: androidPackage,
        storeIos: storeIos,
        storeHuawei: storeHuawei,
      );
}

const meterLeaveApps = <MeterLeaveApp>[
  MeterLeaveApp(
    id: 'gvride',
    name: 'GVRIDE',
    iosLink: 'https://ride.gvmalaysia.com/app/',
    androidPackage: 'com.jobtepi.app',
    storeIos: 'https://apps.apple.com/my/app/gvride/id6651835302',
  ),
  MeterLeaveApp(id: 'grab-driver', name: 'Grab Driver', androidPackage: 'com.grabtaxi.driver2'),
  MeterLeaveApp(id: 'uber-driver', name: 'Uber Driver', androidPackage: 'com.ubercab.driver'),
  MeterLeaveApp(id: 'bolt-driver', name: 'Bolt Driver', androidPackage: 'ee.mtakso.driver'),
  MeterLeaveApp(id: 'maxim-driver', name: 'Maxim Driver', androidPackage: 'com.taxsee.driver'),
];

MeterLeaveApp? meterLeaveAppById(String? id) {
  final key = id?.trim() ?? '';
  if (key.isEmpty) return null;
  return meterLeaveApps.where((a) => a.id == key).firstOrNull;
}

/// The link that opens [app] on [platform], or null where none is known.
String? meterLeaveAppLink(MeterLeaveApp? app, String platform) {
  if (app == null) return null;
  if (platform == 'ios') return app.iosScheme ?? app.iosLink;
  if (app.androidPackage == null) return null;
  return 'intent://#Intent;package=${app.androidPackage};end';
}

/// The link detection may probe (never a universal link).
String? meterLeaveAppProbe(MeterLeaveApp? app, String platform) {
  if (app == null) return null;
  if (platform == 'ios') return app.iosScheme;
  return meterLeaveAppLink(app, platform);
}

/// The store page for a device without the app. Only Play is derivable.
String? meterLeaveAppStore(MeterLeaveApp? app, String platform) {
  if (app == null) return null;
  if (platform == 'ios') return app.storeIos;
  if (platform == 'huawei') return app.storeHuawei;
  if (app.androidPackage == null) return null;
  return 'https://play.google.com/store/apps/details?id=${app.androidPackage}';
}

String storePlatformFor(String os, [String? manufacturer]) {
  if (os == 'ios') return 'ios';
  final maker = (manufacturer ?? '').trim().toLowerCase();
  if (maker == 'huawei' || maker == 'honor') return 'huawei';
  return 'android';
}

/// `present` | `not-detected` | `unknown`.
String describeAppPresence(String presence) => switch (presence) {
      'present' => 'On this device',
      'not-detected' => 'Not detected here',
      _ => "Can't check here",
    };

String describeAppIosRoute(MeterLeaveApp app) {
  if (app.iosScheme != null) return 'iPhone: opens the app';
  if (app.iosLink != null) return 'iPhone: opens the app, or the website without it';
  return 'iPhone: needs a link or the App Store page';
}

bool meterLeaveAppNeedsLink(MeterLeaveApp? app, String platform) =>
    app != null && meterLeaveAppLink(app, platform) == null;

// ---------------------------------------------------------------------------
// Leaving the meter (meterLeave.ts)
// ---------------------------------------------------------------------------

class MeterLeaveStores {
  const MeterLeaveStores({this.ios, this.android, this.huawei});
  final String? ios;
  final String? android;
  final String? huawei;

  String? operator [](String platform) => switch (platform) {
        'ios' => ios,
        'android' => android,
        'huawei' => huawei,
        _ => null,
      };

  MeterLeaveStores withPlatform(String platform, String? value) => MeterLeaveStores(
        ios: platform == 'ios' ? value : ios,
        android: platform == 'android' ? value : android,
        huawei: platform == 'huawei' ? value : huawei,
      );

  @override
  bool operator ==(Object other) =>
      other is MeterLeaveStores && other.ios == ios && other.android == android && other.huawei == huawei;

  @override
  int get hashCode => Object.hash(ios, android, huawei);
}

/// The leave-the-meter half of a rate card. Fields may hold raw (typed) text
/// while a card is being edited; [normalizeMeterLeave] narrows them.
class MeterLeaveConfig {
  const MeterLeaveConfig({
    this.passenger = 'passenger',
    this.ehailing = 'app',
    this.ehailingUrl,
    this.ehailingLabel,
    this.ehailingAppId,
    this.ehailingStores = const MeterLeaveStores(),
  });

  /// `passenger` | `exit`.
  final String passenger;

  /// `app` | `link`.
  final String ehailing;
  final String? ehailingUrl;
  final String? ehailingLabel;
  final String? ehailingAppId;
  final MeterLeaveStores ehailingStores;

  MeterLeaveConfig copyWith({
    String? passenger,
    String? ehailing,
    String? Function()? ehailingUrl,
    String? Function()? ehailingLabel,
    String? Function()? ehailingAppId,
    MeterLeaveStores? ehailingStores,
  }) =>
      MeterLeaveConfig(
        passenger: passenger ?? this.passenger,
        ehailing: ehailing ?? this.ehailing,
        ehailingUrl: ehailingUrl != null ? ehailingUrl() : this.ehailingUrl,
        ehailingLabel: ehailingLabel != null ? ehailingLabel() : this.ehailingLabel,
        ehailingAppId: ehailingAppId != null ? ehailingAppId() : this.ehailingAppId,
        ehailingStores: ehailingStores ?? this.ehailingStores,
      );

  @override
  bool operator ==(Object other) =>
      other is MeterLeaveConfig &&
      other.passenger == passenger &&
      other.ehailing == ehailing &&
      other.ehailingUrl == ehailingUrl &&
      other.ehailingLabel == ehailingLabel &&
      other.ehailingAppId == ehailingAppId &&
      other.ehailingStores == ehailingStores;

  @override
  int get hashCode => Object.hash(passenger, ehailing, ehailingUrl, ehailingLabel, ehailingAppId, ehailingStores);
}

const defaultMeterLeave = MeterLeaveConfig();

const _blockedSchemes = ['javascript', 'data', 'file', 'blob', 'vbscript', 'about'];
const _maxUrlLength = 512;
const meterLeaveMaxLabelLength = 22;

/// The link as the console would open it, or null when it could not.
String? normalizeMeterLeaveUrl(Object? raw) {
  if (raw is! String) return null;
  final url = raw.trim();
  if (url.isEmpty || url.length > _maxUrlLength) return null;
  if (RegExp(r'\s').hasMatch(url)) return null;
  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*):').firstMatch(url)?.group(1)?.toLowerCase();
  if (scheme == null) return null;
  if (_blockedSchemes.contains(scheme)) return null;
  return url;
}

String? normalizeMeterLeaveLabel(Object? raw) {
  if (raw is! String) return null;
  final label = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (label.isEmpty) return null;
  return label.length > meterLeaveMaxLabelLength ? label.substring(0, meterLeaveMaxLabelLength) : label;
}

String normalizeMeterLeavePassenger(Object? raw) =>
    raw is String && raw.trim().toLowerCase() == 'exit' ? 'exit' : 'passenger';

String normalizeMeterLeaveEhailing(Object? raw) =>
    raw is String && raw.trim().toLowerCase() == 'link' ? 'link' : 'app';

MeterLeaveConfig normalizeMeterLeave(MeterLeaveConfig? raw) {
  final c = raw ?? defaultMeterLeave;
  return MeterLeaveConfig(
    passenger: normalizeMeterLeavePassenger(c.passenger),
    ehailing: normalizeMeterLeaveEhailing(c.ehailing),
    ehailingUrl: normalizeMeterLeaveUrl(c.ehailingUrl),
    ehailingLabel: normalizeMeterLeaveLabel(c.ehailingLabel),
    ehailingAppId: meterLeaveAppById(c.ehailingAppId)?.id,
    ehailingStores: MeterLeaveStores(
      ios: normalizeMeterLeaveUrl(c.ehailingStores.ios),
      android: normalizeMeterLeaveUrl(c.ehailingStores.android),
      huawei: normalizeMeterLeaveUrl(c.ehailingStores.huawei),
    ),
  );
}

/// One key of the leave popup, resolved for a device.
class MeterLeaveOption {
  const MeterLeaveOption({
    required this.key,
    required this.action,
    this.route,
    this.url,
    this.store,
    required this.label,
    required this.hint,
  });

  final String key;

  /// `route` | `exit` | `link`.
  final String action;
  final String? route;
  final String? url;
  final String? store;
  final String label;
  final String hint;
}

/// The two keys of the leave popup. [platform] null previews the card (only
/// the typed link counts), as the admin editor does.
({MeterLeaveOption passenger, MeterLeaveOption ehailing}) resolveMeterLeave(MeterLeaveConfig? raw,
    [String? platform]) {
  final config = normalizeMeterLeave(raw);
  final passenger = config.passenger == 'exit'
      ? const MeterLeaveOption(
          key: 'passenger', action: 'exit', label: 'EXIT', hint: 'Close the app — you stay signed in')
      : const MeterLeaveOption(
          key: 'passenger', action: 'route', route: '/', label: 'PASSENGER MODE', hint: 'Book a ride as a passenger');

  final app = meterLeaveAppById(config.ehailingAppId);
  final named = normalizeMeterLeaveLabel(config.ehailingLabel) ?? app?.name;

  String? url;
  String? store;
  if (config.ehailing == 'link') {
    url = (platform != null ? meterLeaveAppLink(app, platform) : null) ?? normalizeMeterLeaveUrl(config.ehailingUrl);
    store = platform != null ? (config.ehailingStores[platform] ?? meterLeaveAppStore(app, platform)) : null;
  }

  final ehailing = (url != null || store != null)
      ? MeterLeaveOption(
          key: 'ehailing',
          action: 'link',
          url: url,
          store: store,
          label: (named ?? 'E-HAILING APP').toUpperCase(),
          hint: url != null
              ? 'Open the dispatch app — the meter stays open behind it'
              : 'Install ${named ?? 'the dispatch app'} to take jobs',
        )
      : MeterLeaveOption(
          key: 'ehailing',
          action: 'route',
          route: '/partner-ehailing',
          label: (named ?? 'E-HAILING').toUpperCase(),
          hint: 'Take e-hailing jobs in this app',
        );
  return (passenger: passenger, ehailing: ehailing);
}

/// Whether the console can close the app on [os], and what it tells drivers.
({bool supported, String note}) describeMeterExit(String os, [bool? canExit]) {
  final can = canExit ?? os == 'android';
  if (can && os != 'web') {
    return (
      supported: true,
      note: 'The app closes and you are back on the home screen. You stay signed in — reopening comes '
          'straight back here.',
    );
  }
  if (os == 'web') {
    return (
      supported: false,
      note: 'A browser tab cannot close itself. Close this tab to leave — you stay signed in, so reopening '
          'comes straight back here.',
    );
  }
  if (os == 'ios') {
    return (
      supported: false,
      note: 'iOS does not let an app close itself. Swipe up from the bottom of the screen to leave — you '
          'stay signed in, so reopening comes straight back here.',
    );
  }
  return (
    supported: false,
    note: 'This platform does not let an app close itself. Leave the app the usual way — you stay signed '
        'in, so reopening comes straight back here.',
  );
}

String describeMeterLinkFailure(String url) =>
    'The meter could not open $url. Check that app is installed on this device, or ask an administrator '
    'to check the link on the rate card.';

String? validateMeterLeave(MeterLeaveConfig? config) {
  if (normalizeMeterLeaveEhailing(config?.ehailing) != 'link') return null;
  if (meterLeaveAppById(config?.ehailingAppId) != null) return null;
  if (normalizeMeterLeaveUrl(config?.ehailingUrl) == null) {
    return 'Choose the dispatch app from the list, or enter its app link — it has to start with a scheme, '
        'e.g. driverapp:// or https://.';
  }
  return null;
}

List<String> describeMeterLeave(MeterLeaveConfig? config) {
  final n = normalizeMeterLeave(config);
  final app = meterLeaveAppById(n.ehailingAppId);
  final lines = <String>[];
  if (n.passenger == 'exit') lines.add('Leave key closes the app');
  if (n.ehailing == 'link') {
    final target = app?.name ?? n.ehailingUrl;
    if (target != null) lines.add('E-hailing opens $target');
  }
  return lines;
}

// ---------------------------------------------------------------------------
// Rate cards (meterSettings.ts)
// ---------------------------------------------------------------------------

/// Resolution order, highest priority first.
const meterSettingsPriority = ['suburb', 'city', 'state', 'country', 'master'];
const meterSettingsLevels = ['master', 'country', 'state', 'city', 'suburb'];
const meterSourceModes = ['gps', 'gps+obd', 'obd'];
const meterDistanceModes = ['block', 'per_km', 'off'];
const meterTimeModes = ['block', 'per_minute', 'per_second', 'off'];
const meterChargeModes = ['max', 'sum'];
const meterChargeFroms = ['flag', 'start'];

/// The five console panels, in tab order.
const meterPanelIds = ['meter', 'trips', 'printer', 'obd', 'settings'];

const meterPanelLabels = {
  'meter': 'Meter',
  'trips': 'Trip log',
  'printer': 'Printer Connection Status',
  'obd': 'OBD Connection Status',
  'settings': 'Settings',
};

class MeterPanelAccess {
  const MeterPanelAccess({this.show = true, this.tap = true});
  final bool show;
  final bool tap;

  @override
  bool operator ==(Object other) => other is MeterPanelAccess && other.show == show && other.tap == tap;

  @override
  int get hashCode => Object.hash(show, tap);

  @override
  String toString() => '{show: $show, tap: $tap}';
}

typedef MeterPanels = Map<String, MeterPanelAccess>;

MeterPanels allPanelsOn() => {for (final id in meterPanelIds) id: const MeterPanelAccess()};

/// One rate card.
class MeterProfile {
  const MeterProfile({
    required this.id,
    required this.level,
    this.country,
    this.state,
    this.city,
    this.suburb,
    this.label,
    required this.sourceMode,
    required this.allowStartWithoutOdometer,
    required this.readOdometer,
    required this.autoLaunch,
    required this.leave,
    required this.panels,
    required this.currency,
    required this.rates,
    required this.nightMultiplier,
    required this.nightStartHour,
    required this.nightEndHour,
    required this.extraLuggageCharge,
    required this.freeLuggage,
    required this.extraPassengerCharge,
    required this.freePassengers,
    required this.extraStep,
    required this.maxExtra,
    required this.active,
    this.updatedAt,
  });

  final String id;
  final String level;
  final String? country;
  final String? state;
  final String? city;
  final String? suburb;
  final String? label;
  final String sourceMode;
  final bool allowStartWithoutOdometer;
  final bool readOdometer;
  final bool autoLaunch;
  final MeterLeaveConfig leave;
  final MeterPanels panels;
  final String currency;
  final MeterRates rates;
  final double nightMultiplier;
  final int nightStartHour;
  final int nightEndHour;
  final double extraLuggageCharge;
  final int freeLuggage;
  final double extraPassengerCharge;
  final int freePassengers;
  final double extraStep;
  final double maxExtra;
  final bool active;
  final String? updatedAt;

  MeterProfile copyWith({
    String? id,
    String? level,
    String? Function()? country,
    String? Function()? state,
    String? Function()? city,
    String? Function()? suburb,
    String? Function()? label,
    String? sourceMode,
    bool? allowStartWithoutOdometer,
    bool? readOdometer,
    bool? autoLaunch,
    MeterLeaveConfig? leave,
    MeterPanels? panels,
    String? currency,
    MeterRates? rates,
    double? nightMultiplier,
    int? nightStartHour,
    int? nightEndHour,
    double? extraLuggageCharge,
    int? freeLuggage,
    double? extraPassengerCharge,
    int? freePassengers,
    double? extraStep,
    double? maxExtra,
    bool? active,
  }) =>
      MeterProfile(
        id: id ?? this.id,
        level: level ?? this.level,
        country: country != null ? country() : this.country,
        state: state != null ? state() : this.state,
        city: city != null ? city() : this.city,
        suburb: suburb != null ? suburb() : this.suburb,
        label: label != null ? label() : this.label,
        sourceMode: sourceMode ?? this.sourceMode,
        allowStartWithoutOdometer: allowStartWithoutOdometer ?? this.allowStartWithoutOdometer,
        readOdometer: readOdometer ?? this.readOdometer,
        autoLaunch: autoLaunch ?? this.autoLaunch,
        leave: leave ?? this.leave,
        panels: panels ?? this.panels,
        currency: currency ?? this.currency,
        rates: rates ?? this.rates,
        nightMultiplier: nightMultiplier ?? this.nightMultiplier,
        nightStartHour: nightStartHour ?? this.nightStartHour,
        nightEndHour: nightEndHour ?? this.nightEndHour,
        extraLuggageCharge: extraLuggageCharge ?? this.extraLuggageCharge,
        freeLuggage: freeLuggage ?? this.freeLuggage,
        extraPassengerCharge: extraPassengerCharge ?? this.extraPassengerCharge,
        freePassengers: freePassengers ?? this.freePassengers,
        extraStep: extraStep ?? this.extraStep,
        maxExtra: maxExtra ?? this.maxExtra,
        active: active ?? this.active,
        updatedAt: updatedAt,
      );
}

/// What the meter bills on when nothing is configured: the built-in "old"
/// TEKSI tariff, every panel on, both sensors allowed.
final defaultMeterProfile = MeterProfile(
  id: 'default',
  level: 'master',
  label: 'Built-in TEKSI tariff',
  sourceMode: 'gps+obd',
  allowStartWithoutOdometer: true,
  readOdometer: true,
  autoLaunch: false,
  leave: defaultMeterLeave,
  panels: allPanelsOn(),
  currency: 'MYR',
  rates: tariffRates['old']!,
  nightMultiplier: nightMultiplierDefault,
  nightStartHour: nightStartHour,
  nightEndHour: nightEndHour,
  extraLuggageCharge: 0,
  freeLuggage: 0,
  extraPassengerCharge: 0,
  freePassengers: 1,
  extraStep: extraStepDefault,
  maxExtra: maxExtraDefault,
  active: true,
);

/// A blank card at [level], seeded from the built-in defaults.
MeterProfile createMeterProfileDraft(String level) => defaultMeterProfile.copyWith(
      id: '',
      level: level,
      label: () => null,
      panels: allPanelsOn(),
    );

// --- Optional column groups (added by later migrations) ---------------------

class MeterOptionalColumnGroup {
  const MeterOptionalColumnGroup(this.id, this.migration, this.label, this.columns);
  final String id;
  final String migration;
  final String label;
  final List<String> columns;
}

const meterLeaveColumns = [
  'leave_passenger_action',
  'leave_ehailing_action',
  'leave_ehailing_url',
  'leave_ehailing_label',
];
const meterLeaveAppColumns = [
  'leave_ehailing_app_id',
  'leave_ehailing_store_ios',
  'leave_ehailing_store_android',
  'leave_ehailing_store_huawei',
];

const meterOptionalColumnGroups = [
  MeterOptionalColumnGroup('auto_launch', '0084', 'Open the meter on launch', ['auto_launch']),
  MeterOptionalColumnGroup('leave', '0085', 'Leave the meter', meterLeaveColumns),
  MeterOptionalColumnGroup('leave_app', '0086', 'Dispatch app & store links', meterLeaveAppColumns),
];

String? describeMissingMeterColumns(List<String> groupIds) {
  final groups = meterOptionalColumnGroups.where((g) => groupIds.contains(g.id)).toList();
  if (groups.isEmpty) return null;
  final named = groups.map((g) => '“${g.label}” (migration ${g.migration})').join(groups.length == 2 ? ' and ' : ', ');
  return 'The live database has no columns for $named. Those settings cannot be saved yet — every '
      "driver's console uses the built-in default until the migration is applied in Supabase. Every other "
      'setting on the card saves normally.';
}

const _panelColumns = [
  'show_meter', 'show_trips', 'show_printer', 'show_obd', 'show_settings',
  'tap_meter', 'tap_trips', 'tap_printer', 'tap_obd', 'tap_settings',
];

const meterSettingsColumnList = [
  'id', 'level', 'country', 'state', 'city', 'suburb', 'label', 'source_mode',
  'allow_start_without_odometer', 'read_odometer', 'auto_launch',
  ...meterLeaveColumns, ...meterLeaveAppColumns, ..._panelColumns,
  'currency', 'flag_fare', 'flag_distance_m', 'minimum_fare', 'distance_mode', 'distance_block_m',
  'distance_block_charge', 'per_km_charge', 'time_mode', 'time_block_s', 'time_block_charge',
  'per_minute_charge', 'per_second_charge', 'charge_mode', 'charge_from', 'night_multiplier',
  'night_start_hour', 'night_end_hour', 'extra_luggage_charge', 'free_luggage', 'extra_passenger_charge',
  'free_passengers', 'extra_step', 'max_extra', 'active', 'updated_at',
];

Set<String> _droppedColumns(List<String> missing) => {
      for (final g in meterOptionalColumnGroups)
        if (missing.contains(g.id)) ...g.columns,
    };

/// The columns a read asks for, minus any group this database has refused.
String meterSettingsColumns([List<String> missingGroups = const []]) {
  final dropped = _droppedColumns(missingGroups);
  return meterSettingsColumnList.where((c) => !dropped.contains(c)).join(', ');
}

/// A write payload shaped for a database missing these groups.
Map<String, dynamic> meterRowWithoutGroups(Map<String, dynamic> row, List<String> missingGroups) {
  if (missingGroups.isEmpty) return row;
  final dropped = _droppedColumns(missingGroups);
  return {for (final e in row.entries) if (!dropped.contains(e.key)) e.key: e.value};
}

/// Which optional group a "column does not exist" message names, if any.
MeterOptionalColumnGroup? meterOptionalGroupNamed(String message) =>
    meterOptionalColumnGroups.where((g) => g.columns.any(message.contains)).firstOrNull;

// --- Coercion -----------------------------------------------------------------

double _num(Object? value, double fallback, {double min = 0, double max = double.infinity}) {
  final double? n = switch (value) {
    num v => v.toDouble(),
    String s => double.tryParse(s.trim()),
    _ => null,
  };
  if (n == null || !n.isFinite) return fallback;
  if (n < min || n > max) return fallback;
  return n;
}

/// JS `Math.round` (half up), so fractional ints round like the Expo app.
int _jsRound(double n) => (n + 0.5).floor();

int _int(Object? value, int fallback, {double min = 0, double max = double.infinity}) =>
    _jsRound(_num(value, fallback.toDouble(), min: min, max: max));

bool _bool(Object? value, bool fallback) => value is bool ? value : fallback;

String? _text(Object? value) {
  final t = value is String ? value.trim() : '';
  return t.isEmpty ? null : t;
}

String _oneOf(Object? value, List<String> allowed, String fallback) {
  final t = value is String ? value.trim().toLowerCase() : '';
  return allowed.contains(t) ? t : fallback;
}

const _stateLevels = ['state', 'city', 'suburb'];
const _cityLevels = ['city', 'suburb'];

/// Turns a stored row into a card, defaulting anything unusable; null when
/// the row has no id.
MeterProfile? normalizeMeterProfile(Object? raw) {
  if (raw is! Map) return null;
  final r = raw;
  final id = r['id'];
  if (id is! String || id.trim().isEmpty) return null;
  final d = defaultMeterProfile;
  final level = _oneOf(r['level'], meterSettingsLevels, 'master');
  final dr = d.rates;

  return MeterProfile(
    id: id,
    level: level,
    country: level == 'master' ? null : _text(r['country']),
    state: _stateLevels.contains(level) ? _text(r['state']) : null,
    city: _cityLevels.contains(level) ? _text(r['city']) : null,
    suburb: level == 'suburb' ? _text(r['suburb']) : null,
    label: _text(r['label']),
    sourceMode: _oneOf(r['source_mode'], meterSourceModes, d.sourceMode),
    allowStartWithoutOdometer: _bool(r['allow_start_without_odometer'], d.allowStartWithoutOdometer),
    readOdometer: _bool(r['read_odometer'], d.readOdometer),
    autoLaunch: _bool(r['auto_launch'], d.autoLaunch),
    leave: normalizeMeterLeave(MeterLeaveConfig(
      passenger: '${r['leave_passenger_action'] ?? ''}',
      ehailing: '${r['leave_ehailing_action'] ?? ''}',
      ehailingUrl: r['leave_ehailing_url'] as String?,
      ehailingLabel: r['leave_ehailing_label'] as String?,
      ehailingAppId: r['leave_ehailing_app_id'] as String?,
      ehailingStores: MeterLeaveStores(
        ios: r['leave_ehailing_store_ios'] as String?,
        android: r['leave_ehailing_store_android'] as String?,
        huawei: r['leave_ehailing_store_huawei'] as String?,
      ),
    )),
    panels: {
      for (final p in meterPanelIds)
        p: MeterPanelAccess(show: _bool(r['show_$p'], true), tap: _bool(r['tap_$p'], true)),
    },
    currency: _text(r['currency']) ?? d.currency,
    rates: MeterRates(
      flagFare: _num(r['flag_fare'], dr.flagFare),
      flagDistanceM: _int(r['flag_distance_m'], dr.flagDistanceM),
      minimumFare: _num(r['minimum_fare'], dr.minimumFare),
      distanceMode: _oneOf(r['distance_mode'], meterDistanceModes, dr.distanceMode),
      distanceBlockM: _int(r['distance_block_m'], dr.distanceBlockM, min: 1),
      distanceBlockCharge: _num(r['distance_block_charge'], dr.distanceBlockCharge),
      perKmCharge: _num(r['per_km_charge'], dr.perKmCharge),
      timeMode: _oneOf(r['time_mode'], meterTimeModes, dr.timeMode),
      timeBlockS: _int(r['time_block_s'], dr.timeBlockS, min: 1),
      timeBlockCharge: _num(r['time_block_charge'], dr.timeBlockCharge),
      perMinuteCharge: _num(r['per_minute_charge'], dr.perMinuteCharge),
      perSecondCharge: _num(r['per_second_charge'], dr.perSecondCharge),
      chargeMode: _oneOf(r['charge_mode'], meterChargeModes, dr.chargeMode),
      chargeFrom: _oneOf(r['charge_from'], meterChargeFroms, dr.chargeFrom),
    ),
    nightMultiplier: _num(r['night_multiplier'], d.nightMultiplier, min: 1),
    nightStartHour: _int(r['night_start_hour'], d.nightStartHour, min: 0, max: 23),
    nightEndHour: _int(r['night_end_hour'], d.nightEndHour, min: 0, max: 24),
    extraLuggageCharge: _num(r['extra_luggage_charge'], d.extraLuggageCharge),
    freeLuggage: _int(r['free_luggage'], d.freeLuggage),
    extraPassengerCharge: _num(r['extra_passenger_charge'], d.extraPassengerCharge),
    freePassengers: _int(r['free_passengers'], d.freePassengers),
    extraStep: _num(r['extra_step'], d.extraStep, min: 0.01),
    maxExtra: _num(r['max_extra'], d.maxExtra, min: 0),
    active: _bool(r['active'], true),
    updatedAt: _text(r['updated_at']),
  );
}

/// The ten panel columns — the narrow write a live Show/Tap toggle sends.
Map<String, dynamic> meterPanelsToRow(MeterPanels panels) => {
      for (final p in meterPanelIds) 'show_$p': panels[p]?.show ?? true,
      for (final p in meterPanelIds) 'tap_$p': panels[p]?.tap ?? true,
    };

/// A card as the row stores it (no `id` / `updated_at`).
Map<String, dynamic> meterProfileToRow(MeterProfile p) {
  final leave = normalizeMeterLeave(p.leave);
  final r = p.rates;
  final level = p.level;
  return {
    'level': level,
    'country': level == 'master' ? null : p.country,
    'state': _stateLevels.contains(level) ? p.state : null,
    'city': _cityLevels.contains(level) ? p.city : null,
    'suburb': level == 'suburb' ? p.suburb : null,
    'label': p.label,
    'source_mode': p.sourceMode,
    'allow_start_without_odometer': p.allowStartWithoutOdometer,
    'read_odometer': p.readOdometer,
    'auto_launch': p.autoLaunch,
    'leave_passenger_action': leave.passenger,
    'leave_ehailing_action': leave.ehailing,
    'leave_ehailing_url': leave.ehailingUrl,
    'leave_ehailing_label': leave.ehailingLabel,
    'leave_ehailing_app_id': leave.ehailingAppId,
    'leave_ehailing_store_ios': leave.ehailingStores.ios,
    'leave_ehailing_store_android': leave.ehailingStores.android,
    'leave_ehailing_store_huawei': leave.ehailingStores.huawei,
    ...meterPanelsToRow(p.panels),
    'currency': p.currency,
    'flag_fare': r.flagFare,
    'flag_distance_m': r.flagDistanceM,
    'minimum_fare': r.minimumFare,
    'distance_mode': r.distanceMode,
    'distance_block_m': r.distanceBlockM,
    'distance_block_charge': r.distanceBlockCharge,
    'per_km_charge': r.perKmCharge,
    'time_mode': r.timeMode,
    'time_block_s': r.timeBlockS,
    'time_block_charge': r.timeBlockCharge,
    'per_minute_charge': r.perMinuteCharge,
    'per_second_charge': r.perSecondCharge,
    'charge_mode': r.chargeMode,
    'charge_from': r.chargeFrom,
    'night_multiplier': p.nightMultiplier,
    'night_start_hour': p.nightStartHour,
    'night_end_hour': p.nightEndHour,
    'extra_luggage_charge': p.extraLuggageCharge,
    'free_luggage': p.freeLuggage,
    'extra_passenger_charge': p.extraPassengerCharge,
    'free_passengers': p.freePassengers,
    'extra_step': p.extraStep,
    'max_extra': p.maxExtra,
    'active': p.active,
  };
}

// --- Panel toggles ------------------------------------------------------------

/// Flips one panel's Show or Tap flag: the meter panel is pinned on, hiding
/// takes the tap with it, and making a panel tappable shows it. Returns a new
/// map; the caller's is never mutated.
MeterPanels setMeterPanelAccess(MeterPanels panels, String id, {bool? show, bool? tap}) {
  final next = {for (final p in meterPanelIds) p: panels[p] ?? const MeterPanelAccess()};
  if (id == 'meter') {
    next['meter'] = const MeterPanelAccess();
    return next;
  }
  var s = next[id]!.show;
  var t = next[id]!.tap;
  if (show != null) {
    s = show;
    if (!s) t = false;
  }
  if (tap != null) {
    t = tap;
    if (t) s = true;
  }
  next[id] = MeterPanelAccess(show: s, tap: t);
  return next;
}

/// A stored card, or the global one (upserted as the single master row), can
/// take a panel toggle on its own; a brand-new override card cannot.
bool canApplyMeterPanelLive(MeterProfile p) => p.id.trim().isNotEmpty || p.level == 'master';

// --- Resolution -----------------------------------------------------------------

bool _eqi(String? a, String? b) => (a ?? '').trim().toLowerCase() == (b ?? '').trim().toLowerCase();

bool _parentsMatch(MeterProfile p, String? country, String? state, String? city) {
  if (p.country != null && country != null && !_eqi(p.country, country)) return false;
  if (p.state != null && state != null && !_eqi(p.state, state)) return false;
  if (p.city != null && city != null && !_eqi(p.city, city)) return false;
  return true;
}

class ResolvedMeterProfile {
  const ResolvedMeterProfile(this.profile, this.level, this.scope);
  final MeterProfile profile;

  /// The level that supplied it, or `default`.
  final String level;
  final String scope;
}

/// The card a hire is priced on: suburb → city → state → country → master →
/// the built-in tariff. Inactive cards are skipped.
ResolvedMeterProfile resolveMeterProfile(
  List<MeterProfile> profiles, {
  String? country,
  String? state,
  String? city,
  String? suburb,
}) {
  final active = profiles.where((p) => p.active).toList();
  MeterProfile? find(bool Function(MeterProfile) f) => active.where(f).firstOrNull;

  final sub = _text(suburb);
  if (sub != null) {
    final hit = find((p) => p.level == 'suburb' && _eqi(p.suburb, sub) && _parentsMatch(p, country, state, city));
    if (hit != null) return ResolvedMeterProfile(hit, 'suburb', 'Suburb: ${hit.suburb}');
  }
  final c = _text(city);
  if (c != null) {
    final hit = find((p) => p.level == 'city' && _eqi(p.city, c) && _parentsMatch(p, country, state, city));
    if (hit != null) return ResolvedMeterProfile(hit, 'city', 'City: ${hit.city}');
  }
  final s = _text(state);
  if (s != null) {
    final hit = find((p) => p.level == 'state' && _eqi(p.state, s) && _parentsMatch(p, country, state, city));
    if (hit != null) return ResolvedMeterProfile(hit, 'state', 'State: ${hit.state}');
  }
  final co = _text(country);
  if (co != null) {
    final hit = find((p) => p.level == 'country' && _eqi(p.country, co));
    if (hit != null) return ResolvedMeterProfile(hit, 'country', 'Country: ${hit.country}');
  }
  final master = find((p) => p.level == 'master');
  if (master != null) return ResolvedMeterProfile(master, 'master', 'Global rate card');
  return ResolvedMeterProfile(defaultMeterProfile, 'default', 'Built-in tariff');
}

// --- What a card means to the meter -------------------------------------------

({bool obd, bool gps}) allowedMeterSources(String mode) => (obd: mode != 'gps', gps: mode != 'obd');

bool meterReadsOdometer(MeterProfile p) => p.readOdometer && allowedMeterSources(p.sourceMode).obd;

bool meterReadsOdometerBeforeStart(MeterProfile p, bool obdLinked) {
  if (!meterReadsOdometer(p)) return false;
  return obdLinked || !p.allowStartWithoutOdometer;
}

({bool canStart, String? reason}) meterOdometerGate(MeterProfile p, double? odometerKm, [bool obdLinked = false]) {
  if (!meterReadsOdometer(p)) return (canStart: true, reason: null);
  final has = odometerKm != null && odometerKm.isFinite && odometerKm >= 0;
  if (has) return (canStart: true, reason: null);
  if (obdLinked) {
    return (
      canStart: false,
      reason: "The reader is connected but did not return the vehicle's odometer (mode-01 PID A6), and a hire "
          'opened on a live reader must be stamped with it. Check the reader and try again — if this vehicle '
          'does not publish the odometer at all, an administrator can turn the odometer read off for this '
          'rate card.',
    );
  }
  if (p.allowStartWithoutOdometer) return (canStart: true, reason: null);
  return (
    canStart: false,
    reason: "This rate card requires the vehicle's odometer before a hire may open, and the reader has not "
        'returned one (mode-01 PID A6). Connect the reader, or ask an administrator to allow starting without it.',
  );
}

double meterExtraSurcharge(MeterProfile p, {num? luggage, num? passengers}) {
  final bags = math.max(0, _num(luggage, 0, min: double.negativeInfinity).floor());
  final seats = math.max(0, _num(passengers, 0, min: double.negativeInfinity).floor());
  final billedBags = math.max(0, bags - math.max(0, p.freeLuggage));
  final billedSeats = math.max(0, seats - math.max(0, p.freePassengers));
  final total = billedBags * math.max(0.0, p.extraLuggageCharge) + billedSeats * math.max(0.0, p.extraPassengerCharge);
  return _round2(total.toDouble());
}

bool hasMeterSurcharges(MeterProfile p) => p.extraLuggageCharge > 0 || p.extraPassengerCharge > 0;

String _money(double n, String currency) => '$currency ${n.toStringAsFixed(2)}';

/// The rate card in words — only the charges it actually bills.
List<String> describeMeterRates(MeterProfile p) {
  final r = p.rates;
  final c = p.currency;
  final lines = <String>[];
  if (r.flagDistanceM > 0 && r.chargeFrom == 'flag') {
    final dist = r.flagDistanceM >= 1000
        ? '${(r.flagDistanceM / 1000).toStringAsFixed(r.flagDistanceM % 1000 == 0 ? 0 : 2)} km'
        : '${r.flagDistanceM} m';
    lines.add('${_money(r.flagFare, c)} flag fare, first $dist');
  } else {
    lines.add('${_money(r.flagFare, c)} flag fare');
  }
  if (r.distanceMode == 'block') {
    lines.add('${_money(r.distanceBlockCharge, c)} per started ${r.distanceBlockM} m');
  } else if (r.distanceMode == 'per_km') {
    lines.add('${_money(r.perKmCharge, c)} per km');
  }
  if (r.timeMode == 'block') {
    lines.add('${_money(r.timeBlockCharge, c)} per started ${r.timeBlockS} s');
  } else if (r.timeMode == 'per_minute') {
    lines.add('${_money(r.perMinuteCharge, c)} per minute');
  } else if (r.timeMode == 'per_second') {
    lines.add('${_money(r.perSecondCharge, c)} per second');
  }
  if (r.distanceMode != 'off' && r.timeMode != 'off') {
    lines.add(r.chargeMode == 'max' ? 'Distance or time — whichever is greater' : 'Distance and time added together');
  }
  if (r.minimumFare > 0) lines.add('${_money(r.minimumFare, c)} minimum fare');
  if (p.nightMultiplier > 1) {
    final m = p.nightMultiplier.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    String two(int h) => h.toString().padLeft(2, '0');
    lines.add('Night ×$m (${two(p.nightStartHour)}:00–${two(p.nightEndHour)}:00)');
  }
  if (p.extraLuggageCharge > 0) {
    lines.add('${_money(p.extraLuggageCharge, c)} per bag${p.freeLuggage > 0 ? ' after ${p.freeLuggage} free' : ''}');
  }
  if (p.extraPassengerCharge > 0) {
    lines.add('${_money(p.extraPassengerCharge, c)} per passenger'
        '${p.freePassengers > 0 ? ' after ${p.freePassengers}' : ''}');
  }
  return lines;
}

String meterProfileScopeLabel(MeterProfile p) {
  String join(List<String?> parts) {
    final s = parts.whereType<String>().where((x) => x.isNotEmpty).join(', ');
    return s.isEmpty ? '—' : s;
  }

  return switch (p.level) {
    'country' => p.country ?? '—',
    'state' => join([p.state, p.country]),
    'city' => join([p.city, p.state]),
    'suburb' => join([p.suburb, p.city]),
    _ => 'Global (all regions)',
  };
}

/// Whether a card can be saved, and what is wrong when it cannot.
String? validateMeterProfile(MeterProfile p) {
  final needs = switch (p.level) {
    'country' => 1,
    'state' => 2,
    'city' => 3,
    'suburb' => 4,
    _ => 0,
  };
  if (needs >= 1 && _text(p.country) == null) return 'Select a country.';
  if (needs >= 2 && _text(p.state) == null) return 'Select a state.';
  if (needs >= 3 && _text(p.city) == null) return 'Enter a city.';
  if (needs >= 4 && _text(p.suburb) == null) return 'Enter a suburb.';

  final r = p.rates;
  if (!(r.flagFare >= 0)) return 'Flag fare cannot be negative.';
  if (r.distanceMode == 'block' && !(r.distanceBlockM > 0)) return 'A distance block must be longer than 0 m.';
  if (r.timeMode == 'block' && !(r.timeBlockS > 0)) return 'A time block must be longer than 0 s.';
  final bills = r.flagFare > 0 ||
      r.minimumFare > 0 ||
      (r.distanceMode == 'block' && r.distanceBlockCharge > 0) ||
      (r.distanceMode == 'per_km' && r.perKmCharge > 0) ||
      (r.timeMode == 'block' && r.timeBlockCharge > 0) ||
      (r.timeMode == 'per_minute' && r.perMinuteCharge > 0) ||
      (r.timeMode == 'per_second' && r.perSecondCharge > 0);
  if (!bills) return 'This card charges nothing — every hire would meter at zero.';

  final badLeave = validateMeterLeave(p.leave);
  if (badLeave != null) return badLeave;

  if (!(p.panels['meter']?.show ?? true)) return 'The meter panel cannot be hidden.';
  if (!(p.panels['meter']?.tap ?? true)) return 'The meter panel cannot be locked.';
  return null;
}

// --- The editor's number fields ---------------------------------------------------

/// Reads a typed number (comma decimal allowed), falling back to [fallback]
/// for anything blank, invalid or negative — the editor's `readNumber`.
double readMeterNumber(String raw, num fallback) {
  final n = double.tryParse(raw.trim().replaceFirst(',', '.'));
  return n != null && n.isFinite && n >= 0 ? n : fallback.toDouble();
}

int clampHour(double value, int max) => math.min(max, math.max(0, _jsRound(value)));

/// Text for a number field: integers without a trailing `.0`, like JS `String(n)`.
String meterFieldText(num n) => n == n.roundToDouble() ? n.round().toString() : n.toString();

/// Folds the editor's typed number fields back onto [draft] — the card as it
/// would save (`mergedDraft` in the Expo editor).
MeterProfile mergeMeterFields(MeterProfile draft, Map<String, String> f) {
  final d = defaultMeterProfile;
  final dr = d.rates;
  String v(String k) => f[k] ?? '';
  return draft.copyWith(
    rates: draft.rates.copyWith(
      flagFare: readMeterNumber(v('flagFare'), dr.flagFare),
      flagDistanceM: _jsRound(readMeterNumber(v('flagDistanceM'), dr.flagDistanceM)),
      minimumFare: readMeterNumber(v('minimumFare'), dr.minimumFare),
      distanceBlockM: _jsRound(readMeterNumber(v('distanceBlockM'), dr.distanceBlockM)),
      distanceBlockCharge: readMeterNumber(v('distanceBlockCharge'), dr.distanceBlockCharge),
      perKmCharge: readMeterNumber(v('perKmCharge'), dr.perKmCharge),
      timeBlockS: _jsRound(readMeterNumber(v('timeBlockS'), dr.timeBlockS)),
      timeBlockCharge: readMeterNumber(v('timeBlockCharge'), dr.timeBlockCharge),
      perMinuteCharge: readMeterNumber(v('perMinuteCharge'), dr.perMinuteCharge),
      perSecondCharge: readMeterNumber(v('perSecondCharge'), dr.perSecondCharge),
    ),
    nightMultiplier: math.max(1.0, readMeterNumber(v('nightMultiplier'), d.nightMultiplier)),
    nightStartHour: clampHour(readMeterNumber(v('nightStartHour'), d.nightStartHour), 23),
    nightEndHour: clampHour(readMeterNumber(v('nightEndHour'), d.nightEndHour), 24),
    extraLuggageCharge: readMeterNumber(v('extraLuggageCharge'), d.extraLuggageCharge),
    freeLuggage: _jsRound(readMeterNumber(v('freeLuggage'), d.freeLuggage)),
    extraPassengerCharge: readMeterNumber(v('extraPassengerCharge'), d.extraPassengerCharge),
    freePassengers: _jsRound(readMeterNumber(v('freePassengers'), d.freePassengers)),
    extraStep: math.max(0.01, readMeterNumber(v('extraStep'), d.extraStep)),
    maxExtra: readMeterNumber(v('maxExtra'), d.maxExtra),
  );
}

/// The numeric fields of a card as the text the editor edits.
Map<String, String> meterFieldsOf(MeterProfile p) {
  final r = p.rates;
  return {
    'flagFare': meterFieldText(r.flagFare),
    'flagDistanceM': meterFieldText(r.flagDistanceM),
    'minimumFare': meterFieldText(r.minimumFare),
    'distanceBlockM': meterFieldText(r.distanceBlockM),
    'distanceBlockCharge': meterFieldText(r.distanceBlockCharge),
    'perKmCharge': meterFieldText(r.perKmCharge),
    'timeBlockS': meterFieldText(r.timeBlockS),
    'timeBlockCharge': meterFieldText(r.timeBlockCharge),
    'perMinuteCharge': meterFieldText(r.perMinuteCharge),
    'perSecondCharge': meterFieldText(r.perSecondCharge),
    'nightMultiplier': meterFieldText(p.nightMultiplier),
    'nightStartHour': meterFieldText(p.nightStartHour),
    'nightEndHour': meterFieldText(p.nightEndHour),
    'extraLuggageCharge': meterFieldText(p.extraLuggageCharge),
    'freeLuggage': meterFieldText(p.freeLuggage),
    'extraPassengerCharge': meterFieldText(p.extraPassengerCharge),
    'freePassengers': meterFieldText(p.freePassengers),
    'extraStep': meterFieldText(p.extraStep),
    'maxExtra': meterFieldText(p.maxExtra),
  };
}

/// Points a card at a catalogue app (null = "Other app"), filling in the
/// store pages the catalogue knows without overwriting ones already entered.
MeterLeaveConfig pickMeterLeaveApp(MeterLeaveConfig leave, String? appId) {
  final app = meterLeaveAppById(appId);
  String? keep(String? existing, String platform) =>
      (existing != null && existing.isNotEmpty) ? existing : meterLeaveAppStore(app, platform);
  return leave.copyWith(
    ehailingAppId: () => app?.id,
    ehailingStores: MeterLeaveStores(
      ios: keep(leave.ehailingStores.ios, 'ios'),
      android: keep(leave.ehailingStores.android, 'android'),
      huawei: keep(leave.ehailingStores.huawei, 'huawei'),
    ),
  );
}
