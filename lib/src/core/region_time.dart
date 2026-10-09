// A region's wall-clock time: the time in its Time zone field (Admin →
// Country / States / Cities), whatever zone the phone is set to. Used for
// its scheduled rules, and to show a ride's times as the clocks where it
// happened showed them (the zone is stamped on the ride at booking). Falls
// back to the phone's own time without one.
//
// The full database: the trimmed ones drop tzdata's link names, and many
// zones admins pick are links now (Asia/Kuala_Lumpur → Asia/Singapore).
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _loaded = false;

/// The IANA [zone], or null when it is empty or unknown.
tz.Location? _location(String? zone) {
  final z = zone?.trim() ?? '';
  if (z.isEmpty) return null;
  try {
    if (!_loaded) {
      tzdata.initializeTimeZones();
      _loaded = true;
    }
    return tz.getLocation(z);
  } catch (_) {
    return null;
  }
}

/// [nowUtc] as a wall-clock time in the IANA [zone] (`Asia/Kuala_Lumpur`).
DateTime regionLocalTime(String? zone, DateTime nowUtc) {
  final loc = _location(zone);
  if (loc == null) return nowUtc.toLocal();
  final t = tz.TZDateTime.from(nowUtc.toUtc(), loc);
  return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

/// [zone]'s offset from UTC at [at], or null for an empty or unknown zone.
Duration? zoneOffset(String? zone, DateTime at) {
  final loc = _location(zone);
  return loc == null ? null : tz.TZDateTime.from(at.toUtc(), loc).timeZoneOffset;
}

/// "GMT+8", "GMT+5:30", "GMT-3", "GMT".
String gmtLabel(Duration offset) {
  if (offset == Duration.zero) return 'GMT';
  final sign = offset.isNegative ? '-' : '+';
  final m = offset.inMinutes.abs();
  return 'GMT$sign${m ~/ 60}${m % 60 == 0 ? '' : ':${(m % 60).toString().padLeft(2, '0')}'}';
}

/// [at] as the clocks in [zone] showed it, in [pattern]. Where the zone is
/// not the phone's at that moment ([deviceOffset], the phone's own by
/// default) its offset follows ("11:00 PM GMT+8"), so a time is never read
/// as the rider's own when it isn't. No zone, or an unknown one: the phone's
/// time, unlabelled, as before.
String formatInZone(DateTime? at, String? zone, {String pattern = 'd MMM yyyy, h:mm a', Duration? deviceOffset}) {
  if (at == null) return '—';
  final offset = zoneOffset(zone, at);
  if (offset == null) return DateFormat(pattern).format(at.toLocal());
  final local = regionLocalTime(zone, at);
  final text = DateFormat(pattern).format(local);
  final mine = deviceOffset ?? at.toLocal().timeZoneOffset;
  return offset == mine ? text : '$text ${gmtLabel(offset)}';
}
