// The home-screen icons the app can switch to: the standard one, seasonal
// ones, the double-date sales and two brand marks. Each is built into the app
// (scripts/seasonal_icons.py: an iOS icon set and an Android activity-alias
// per icon, light and dark), so a new icon needs a new build; the admin
// chooses among these (app_settings 'app_icon').
//
// Which icon shows: the passenger's own choice in Settings → App icon when
// the admin allows choosing; else the admin's fixed icon; else the admin's
// schedule (the first window in the list that covers today wins).

/// One icon. [id] names its iOS icon set (`AppIcon-<id>`), its Android
/// alias (`AppIcon_<id>`) and its previews (`assets/app_icons/<id>.webp`).
class AppIconDef {
  const AppIconDef(this.id, this.name, this.group);

  final String id;
  final String name;
  final AppIconGroup group;

  String preview({required bool dark}) => 'assets/app_icons/$id${dark ? '_dark' : ''}.webp';
}

enum AppIconGroup { brand, festival, sale }

const standardAppIcon = 'standard';

/// The Settings value for "follow the admin's schedule".
const automaticAppIcon = 'automatic';

const appIcons = [
  AppIconDef(standardAppIcon, 'Standard', AppIconGroup.brand),
  AppIconDef('g_dot', 'G.', AppIconGroup.brand),
  AppIconDef('get_dot', 'GET.', AppIconGroup.brand),
  AppIconDef('chinese_new_year', 'Chinese New Year', AppIconGroup.festival),
  AppIconDef('thaipusam', 'Thaipusam', AppIconGroup.festival),
  AppIconDef('ramadan', 'Ramadan', AppIconGroup.festival),
  AppIconDef('hari_raya', 'Hari Raya Aidilfitri', AppIconGroup.festival),
  AppIconDef('harvest', 'Gawai & Kaamatan', AppIconGroup.festival),
  AppIconDef('merdeka', 'Merdeka & Malaysia Day', AppIconGroup.festival),
  AppIconDef('mid_autumn', 'Mid-Autumn', AppIconGroup.festival),
  AppIconDef('deepavali', 'Deepavali', AppIconGroup.festival),
  AppIconDef('christmas', 'Christmas', AppIconGroup.festival),
  AppIconDef('new_year', 'New Year', AppIconGroup.festival),
  AppIconDef('monsoon', 'Monsoon', AppIconGroup.festival),
  AppIconDef('payday', 'Payday', AppIconGroup.sale),
  AppIconDef('sale_9_9', '9.9', AppIconGroup.sale),
  AppIconDef('sale_10_10', '10.10', AppIconGroup.sale),
  AppIconDef('sale_11_11', '11.11', AppIconGroup.sale),
  AppIconDef('sale_12_12', '12.12', AppIconGroup.sale),
];

AppIconDef? appIconById(String? id) {
  for (final i in appIcons) {
    if (i.id == id) return i;
  }
  return null;
}

/// How a window repeats: every year (MM-DD), once (YYYY-MM-DD, for festivals
/// on the lunar or Hindu calendar) or every month (day numbers).
enum IconWindowKind { annual, dated, monthly }

/// When an icon shows: from [start] to [end], both days included; an annual
/// or monthly window may run over the year's or month's end (12-27 to 01-02,
/// 25 to 1). Only in [regions] (state or country names) when any are given.
class IconWindow {
  const IconWindow({
    required this.icon,
    required this.kind,
    required this.start,
    required this.end,
    this.regions = const [],
    this.enabled = true,
  });

  final String icon;
  final IconWindowKind kind;
  final String start;
  final String end;
  final List<String> regions;
  final bool enabled;

  static IconWindow? fromJson(Object? v) {
    if (v is! Map) return null;
    final icon = v['icon'];
    final kind = IconWindowKind.values.where((k) => k.name == v['kind']).firstOrNull;
    final w = IconWindow(
      icon: icon is String ? icon : '',
      kind: kind ?? IconWindowKind.annual,
      start: '${v['start'] ?? ''}',
      end: '${v['end'] ?? ''}',
      regions: [
        for (final r in v['regions'] is List ? v['regions'] as List : const [])
          if ('$r'.trim().isNotEmpty) '$r'.trim(),
      ],
      enabled: v['enabled'] != false,
    );
    return appIconById(w.icon) != null && kind != null && w.valid ? w : null;
  }

  Map<String, Object> toJson() => {
    'icon': icon,
    'kind': kind.name,
    'start': start,
    'end': end,
    if (regions.isNotEmpty) 'regions': regions,
    if (!enabled) 'enabled': false,
  };

  IconWindow copyWith({String? start, String? end, List<String>? regions, bool? enabled}) => IconWindow(
    icon: icon,
    kind: kind,
    start: start ?? this.start,
    end: end ?? this.end,
    regions: regions ?? this.regions,
    enabled: enabled ?? this.enabled,
  );

  bool get valid => _key(start) != null && _key(end) != null;

  /// Comparable form of a bound: yyyymmdd, mmdd or dd.
  int? _key(String s) {
    final t = s.trim();
    final m = switch (kind) {
      IconWindowKind.dated => RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(t),
      IconWindowKind.annual => RegExp(r'^(\d{2})-(\d{2})$').firstMatch(t),
      IconWindowKind.monthly => RegExp(r'^(\d{1,2})$').firstMatch(t),
    };
    if (m == null) return null;
    final parts = [for (var i = 1; i <= m.groupCount; i++) int.parse(m.group(i)!)];
    final day = parts.last;
    if (day < 1 || day > 31) return null;
    if (parts.length >= 2 && (parts[parts.length - 2] < 1 || parts[parts.length - 2] > 12)) return null;
    return parts.fold<int>(0, (a, p) => a * 100 + p);
  }

  /// Whether [day] (a local date) falls in the window.
  bool covers(DateTime day) {
    final a = _key(start), b = _key(end);
    if (a == null || b == null) return false;
    final t = switch (kind) {
      IconWindowKind.dated => day.year * 10000 + day.month * 100 + day.day,
      IconWindowKind.annual => day.month * 100 + day.day,
      IconWindowKind.monthly => day.day,
    };
    if (kind == IconWindowKind.dated || a <= b) return t >= a && t <= b;
    return t >= a || t <= b; // over the year's or month's end
  }

  bool appliesIn(Set<String> where) {
    if (regions.isEmpty) return true;
    final lower = {for (final w in where) w.toLowerCase()};
    return regions.any((r) => lower.contains(r.toLowerCase()));
  }

  /// "25 – 1 every month", "12-27 – 01-02 every year", "2027-02-06 – …".
  String get describe => switch (kind) {
    IconWindowKind.annual => '$start – $end every year',
    IconWindowKind.dated => '$start – $end',
    IconWindowKind.monthly => '$start – $end every month',
  };
}

/// The admin's settings (Admin → App Settings → App icon).
class AppIconConfig {
  const AppIconConfig({
    this.automatic = true,
    this.fixedIcon = standardAppIcon,
    this.showInSettings = true,
    this.allowUserChoice = true,
    this.schedule = defaultIconSchedule,
  });

  /// Follow [schedule]; off, everyone gets [fixedIcon].
  final bool automatic;
  final String fixedIcon;

  /// Whether Settings shows the App icon row at all. Hidden, a choice
  /// made there before no longer counts.
  final bool showInSettings;

  /// Whether passengers and drivers may pick their own in Settings.
  final bool allowUserChoice;

  /// Whether a passenger's or driver's own pick counts.
  bool get userChoiceApplies => showInSettings && allowUserChoice;

  /// In priority order: the first window covering today wins.
  final List<IconWindow> schedule;

  static const standard = AppIconConfig();

  static AppIconConfig fromJson(Object? v) {
    if (v is! Map) return standard;
    final fixed = v['fixed_icon'];
    final list = v['schedule'];
    return AppIconConfig(
      automatic: v['automatic'] != false,
      fixedIcon: appIconById(fixed is String ? fixed : null)?.id ?? standardAppIcon,
      showInSettings: v['show_in_settings'] != false,
      allowUserChoice: v['allow_user_choice'] != false,
      schedule: list is List ? [for (final w in list) ?IconWindow.fromJson(w)] : defaultIconSchedule,
    );
  }

  Map<String, Object> toJson() => {
    'automatic': automatic,
    'fixed_icon': fixedIcon,
    'show_in_settings': showInSettings,
    'allow_user_choice': allowUserChoice,
    'schedule': [for (final w in schedule) w.toJson()],
  };

  AppIconConfig copyWith({
    bool? automatic,
    String? fixedIcon,
    bool? showInSettings,
    bool? allowUserChoice,
    List<IconWindow>? schedule,
  }) => AppIconConfig(
    automatic: automatic ?? this.automatic,
    fixedIcon: fixedIcon ?? this.fixedIcon,
    showInSettings: showInSettings ?? this.showInSettings,
    allowUserChoice: allowUserChoice ?? this.allowUserChoice,
    schedule: schedule ?? this.schedule,
  );
}

const appIconSettingKey = 'app_icon';

/// The icon the schedule gives [now] in [regions] (the phone's state,
/// country), the standard one outside every window.
String scheduledAppIcon(AppIconConfig config, DateTime now, {Set<String> regions = const {}}) {
  for (final w in config.schedule) {
    if (w.enabled && w.covers(now) && w.appliesIn(regions)) return w.icon;
  }
  return standardAppIcon;
}

/// The icon this phone should show.
String chosenAppIcon(
  AppIconConfig config,
  DateTime now, {
  String userChoice = automaticAppIcon,
  Set<String> regions = const {},
}) {
  if (config.userChoiceApplies && userChoice != automaticAppIcon && appIconById(userChoice) != null) {
    return userChoice;
  }
  if (!config.automatic) return config.fixedIcon;
  return scheduledAppIcon(config, now, regions: regions);
}

/// The standard schedule, until an admin edits it. Lunar and Hindu calendar
/// festivals are dated per year (Malaysian public holiday dates; check them
/// when each year's are announced); the rest repeat.
const defaultIconSchedule = [
  IconWindow(icon: 'sale_9_9', kind: IconWindowKind.annual, start: '09-08', end: '09-09'),
  IconWindow(icon: 'sale_10_10', kind: IconWindowKind.annual, start: '10-09', end: '10-10'),
  IconWindow(icon: 'sale_11_11', kind: IconWindowKind.annual, start: '11-10', end: '11-11'),
  IconWindow(icon: 'sale_12_12', kind: IconWindowKind.annual, start: '12-11', end: '12-12'),
  IconWindow(icon: 'thaipusam', kind: IconWindowKind.dated, start: '2027-01-20', end: '2027-01-22'),
  IconWindow(icon: 'thaipusam', kind: IconWindowKind.dated, start: '2028-02-08', end: '2028-02-10'),
  IconWindow(icon: 'deepavali', kind: IconWindowKind.dated, start: '2026-11-02', end: '2026-11-09'),
  IconWindow(icon: 'deepavali', kind: IconWindowKind.dated, start: '2027-10-22', end: '2027-10-29'),
  IconWindow(icon: 'deepavali', kind: IconWindowKind.dated, start: '2028-10-10', end: '2028-10-17'),
  IconWindow(icon: 'chinese_new_year', kind: IconWindowKind.dated, start: '2027-01-30', end: '2027-02-20'),
  IconWindow(icon: 'chinese_new_year', kind: IconWindowKind.dated, start: '2028-01-19', end: '2028-02-09'),
  IconWindow(icon: 'hari_raya', kind: IconWindowKind.dated, start: '2027-03-10', end: '2027-03-24'),
  IconWindow(icon: 'hari_raya', kind: IconWindowKind.dated, start: '2028-02-27', end: '2028-03-12'),
  IconWindow(icon: 'ramadan', kind: IconWindowKind.dated, start: '2027-02-08', end: '2027-03-09'),
  IconWindow(icon: 'ramadan', kind: IconWindowKind.dated, start: '2028-01-28', end: '2028-02-26'),
  IconWindow(icon: 'christmas', kind: IconWindowKind.annual, start: '12-15', end: '12-26'),
  IconWindow(icon: 'new_year', kind: IconWindowKind.annual, start: '12-27', end: '01-02'),
  IconWindow(icon: 'merdeka', kind: IconWindowKind.annual, start: '08-24', end: '09-01'),
  IconWindow(icon: 'merdeka', kind: IconWindowKind.annual, start: '09-12', end: '09-16'),
  IconWindow(icon: 'mid_autumn', kind: IconWindowKind.dated, start: '2027-09-05', end: '2027-09-15'),
  IconWindow(icon: 'mid_autumn', kind: IconWindowKind.dated, start: '2028-09-23', end: '2028-10-03'),
  IconWindow(icon: 'harvest', kind: IconWindowKind.annual, start: '05-25', end: '06-02', regions: ['Sarawak', 'Sabah']),
  IconWindow(icon: 'payday', kind: IconWindowKind.monthly, start: '25', end: '1'),
  IconWindow(icon: 'monsoon', kind: IconWindowKind.annual, start: '11-15', end: '02-28', enabled: false),
];
