// A region's wall-clock time, for its scheduled rules: the time in its
// Time zone field (Admin → Country / States / Cities), whatever zone the
// phone is set to. Falls back to the phone's own time without one.
//
// The full database: the trimmed ones drop tzdata's link names, and many
// zones admins pick are links now (Asia/Kuala_Lumpur → Asia/Singapore).
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _loaded = false;

/// [nowUtc] as a wall-clock time in the IANA [zone] (`Asia/Kuala_Lumpur`).
DateTime regionLocalTime(String? zone, DateTime nowUtc) {
  final z = zone?.trim() ?? '';
  if (z.isEmpty) return nowUtc.toLocal();
  try {
    if (!_loaded) {
      tzdata.initializeTimeZones();
      _loaded = true;
    }
    final t = tz.TZDateTime.from(nowUtc.toUtc(), tz.getLocation(z));
    return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
  } catch (_) {
    return nowUtc.toLocal();
  }
}
