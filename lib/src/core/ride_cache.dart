// The rides kept on this phone (reliability Phase C): the last row seen of
// each ride on screen, so the trip opens, and a launch finds the ride in
// progress, with no connection. What the server says always wins; this is
// only what is shown while it can't be asked. Pure.
import 'dart:convert';

/// A cached row older than this is not shown: the ride has moved on.
const rideCacheMaxAge = Duration(hours: 12);

/// At most this many rides are kept (the newest).
const rideCacheMaxRides = 10;

class CachedRide {
  const CachedRide(this.row, this.savedAt);
  final Map<String, dynamic> row;
  final DateTime savedAt;
}

/// The stored cache, without broken entries and those too old to show.
Map<String, CachedRide> decodeRideCache(String? stored, DateTime now) {
  if (stored == null || stored.isEmpty) return {};
  Object? json;
  try {
    json = jsonDecode(stored);
  } catch (_) {
    return {};
  }
  if (json is! Map) return {};
  final out = <String, CachedRide>{};
  json.forEach((id, entry) {
    if (id is! String || entry is! Map) return;
    final row = entry['row'];
    final at = DateTime.tryParse('${entry['saved_at'] ?? ''}');
    if (row is! Map || at == null || row['id'] != id) return;
    if (now.difference(at) >= rideCacheMaxAge) return;
    out[id] = CachedRide(Map<String, dynamic>.from(row), at.toLocal());
  });
  return out;
}

String encodeRideCache(Map<String, CachedRide> cache) => jsonEncode({
  for (final e in cache.entries) e.key: {'saved_at': e.value.savedAt.toUtc().toIso8601String(), 'row': e.value.row},
});

/// While a ride moves, its kept copy is rewritten at most this often (a
/// change of status is always written at once).
const rideCacheLiveGap = Duration(seconds: 30);

/// Columns that move every few seconds on a live trip (the driver's and the
/// passenger's positions): a change in these alone does not rewrite the
/// kept copy.
bool isRideLiveColumn(String column) =>
    column.startsWith('partner_live_') || column.startsWith('user_live_') || column == 'updated_at';

/// Whether [a] and [b] are the same row but for [isRideLiveColumn]s. Pure.
bool sameRideApartFromLive(Map<String, dynamic> a, Map<String, dynamic> b) {
  final keys = {...a.keys, ...b.keys}.where((k) => !isRideLiveColumn(k));
  for (final k in keys) {
    if (a.containsKey(k) != b.containsKey(k)) return false;
    final x = a[k], y = b[k];
    if (x == y) continue;
    if ((x is Map || x is List) && (y is Map || y is List) && jsonEncode(x) == jsonEncode(y)) continue;
    return false;
  }
  return true;
}

/// When to keep [row] after [last] was kept at [lastAt]: null for not at
/// all (nothing but the live columns changed), [Duration.zero] for now (a
/// new ride, a new status, or [rideCacheLiveGap] since the last write), or
/// the wait until the gap is up. Pure.
Duration? rideCacheSaveDelay({
  Map<String, dynamic>? last,
  DateTime? lastAt,
  required Map<String, dynamic> row,
  required DateTime now,
}) {
  if (last == null || lastAt == null || last['status'] != row['status']) return Duration.zero;
  if (sameRideApartFromLive(last, row)) return null;
  final since = now.difference(lastAt);
  return since >= rideCacheLiveGap ? Duration.zero : rideCacheLiveGap - since;
}

/// [cache] with [row] as the latest seen of its ride, keeping the newest
/// [rideCacheMaxRides].
Map<String, CachedRide> withCachedRide(Map<String, CachedRide> cache, Map<String, dynamic> row, DateTime now) {
  final id = row['id'];
  if (id is! String) return cache;
  final next = {...cache, id: CachedRide(row, now)};
  if (next.length <= rideCacheMaxRides) return next;
  final newest = next.entries.toList()..sort((a, b) => b.value.savedAt.compareTo(a.value.savedAt));
  return {for (final e in newest.take(rideCacheMaxRides)) e.key: e.value};
}

/// The cached rides where [column] is [uid] and the status is one of
/// [statuses], newest booking first: the rides in progress as last seen.
List<CachedRide> cachedRidesInProgress(
  Map<String, CachedRide> cache, {
  required String uid,
  required String column,
  required List<String> statuses,
}) {
  final found = [
    for (final c in cache.values)
      if (c.row[column] == uid && statuses.contains(c.row['status'])) c,
  ];
  DateTime created(CachedRide c) => DateTime.tryParse('${c.row['created_at'] ?? ''}') ?? c.savedAt;
  found.sort((a, b) => created(b).compareTo(created(a)));
  return found;
}
