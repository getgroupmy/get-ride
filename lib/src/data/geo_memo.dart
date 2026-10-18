import 'package:latlong2/latlong.dart';

/// Address lookups (location → address) this app session has already had
/// answered, by ~11 m cell: lat and lng rounded to 4 decimals, plus the
/// language and what was asked ([GeoService.reverse] or
/// [GeoService.reverseArea]). Whichever provider answered, the next fix in
/// the same cell takes the answer instead of another round trip.
///
/// Held in memory only, at most [size] cells for at most [keepFor] each,
/// so nothing a provider says is stored on the phone or shared (Google's
/// terms forbid keeping its answers; the server does not cache them
/// either). Calls for a cell already being looked up share that one
/// lookup; a lookup that fails or finds nothing is dropped so the next
/// call asks again.
class GeoMemo {
  GeoMemo({this.size = 200, this.keepFor = const Duration(minutes: 30), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final int size;
  final Duration keepFor;
  final DateTime Function() _now;

  /// Oldest-used first (a map literal keeps insertion order).
  final _cells = <String, _Cell>{};

  int get length => _cells.length;

  /// The cell [p] is in, as kept: `lat,lng` at 4 decimals.
  static String cellOf(LatLng p) => '${(p.latitude * 1e4).round()},${(p.longitude * 1e4).round()}';

  /// [ask]'s answer for [p]'s cell, from memory when this session had one
  /// within [keepFor]. A failure is thrown again to every caller waiting on
  /// it, and nothing is kept.
  Future<T?> get<T extends Object>(String kind, LatLng p, String lang, Future<T?> Function() ask) {
    final key = '$kind|${cellOf(p)}|$lang';
    final now = _now();
    final hit = _cells.remove(key);
    if (hit != null && now.difference(hit.at) < keepFor) {
      _cells[key] = hit; // most recently used
      return hit.answer.then((v) => v as T?);
    }
    final cell = _Cell(now, Future<Object?>.sync(ask));
    _cells[key] = cell;
    while (_cells.length > size) {
      _cells.remove(_cells.keys.first);
    }
    void drop() {
      if (identical(_cells[key], cell)) _cells.remove(key);
    }

    cell.answer.then((v) {
      if (v == null) drop();
    }, onError: (Object _) => drop());
    return cell.answer.then((v) => v as T?);
  }

  void clear() => _cells.clear();
}

class _Cell {
  _Cell(this.at, this.answer);
  final DateTime at;
  final Future<Object?> answer;
}
