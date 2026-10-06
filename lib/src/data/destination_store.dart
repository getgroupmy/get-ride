import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'geo_service.dart';

/// The partner's destination mode, kept on the device (as Expo kept its
/// destinations): up to [maxSavedDestinations] saved places, the one being
/// headed to now ([place], one of [saved]), and whether the mode is on.
typedef DestinationMode = ({Place? place, bool on, List<Place> saved});

/// How many destinations a driver can keep (Expo: "Save up to 3").
const maxSavedDestinations = 3;

const _distance = Distance();

/// Two picks of the same place: the same name within 50 m.
bool samePlace(Place a, Place b) => a.name == b.name && _distance(a.point, b.point) < 50;

/// [saved] with [place] at the front: an earlier copy of it moves up rather
/// than repeating, and the oldest drops off past [maxSavedDestinations]. Pure.
List<Place> addSavedDestination(List<Place> saved, Place place) =>
    [place, ...saved.where((p) => !samePlace(p, place))].take(maxSavedDestinations).toList();

class DestinationModeNotifier extends Notifier<DestinationMode> {
  static const _key = 'partner_destinations';

  /// The single destination builds before saved destinations used.
  static const _legacyKey = 'partner_destination';

  @override
  DestinationMode build() {
    SharedPreferences.getInstance().then((p) {
      try {
        final raw = p.getString(_key);
        if (raw != null) {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          final saved = [for (final e in (m['saved'] as List? ?? const [])) _place(e as Map<String, dynamic>)];
          final active = m['active'] as int?;
          final place = active != null && active >= 0 && active < saved.length ? saved[active] : null;
          state = (place: place, on: place != null && m['on'] == true, saved: saved);
          return;
        }
        final legacy = p.getString(_legacyKey);
        if (legacy == null) return;
        final m = jsonDecode(legacy) as Map<String, dynamic>;
        final place = _place(m);
        state = (place: place, on: m['on'] == true, saved: [place]);
      } catch (_) {}
    });
    return (place: null, on: false, saved: const []);
  }

  static Place _place(Map<String, dynamic> m) => Place(
    name: '${m['name']}',
    address: '${m['address'] ?? ''}',
    point: LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
  );

  static Map<String, dynamic> _json(Place p) => {
    'name': p.name,
    'address': p.address,
    'lat': p.point.latitude,
    'lng': p.point.longitude,
  };

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    final active = state.place;
    final index = active == null ? -1 : state.saved.indexWhere((s) => samePlace(s, active));
    await p.setString(
      _key,
      jsonEncode({
        'saved': [for (final s in state.saved) _json(s)],
        'active': index < 0 ? null : index,
        'on': state.on,
      }),
    );
    await p.remove(_legacyKey);
  }

  /// Saves [place] (first in the list) and heads there with the mode on.
  Future<void> setPlace(Place place) async {
    state = (place: place, on: true, saved: addSavedDestination(state.saved, place));
    await _save();
  }

  /// Heads to a saved destination; picking the one already active turns the
  /// mode off (Expo toggles it the same way).
  Future<void> select(Place place) async {
    final active = state.place;
    if (active != null && samePlace(active, place) && state.on) {
      state = (place: null, on: false, saved: state.saved);
    } else {
      state = (place: place, on: true, saved: state.saved);
    }
    await _save();
  }

  /// Forgets a saved destination; removing the active one turns the mode off.
  Future<void> remove(Place place) async {
    final active = state.place;
    final wasActive = active != null && samePlace(active, place);
    state = (
      place: wasActive ? null : active,
      on: wasActive ? false : state.on,
      saved: [
        for (final s in state.saved)
          if (!samePlace(s, place)) s,
      ],
    );
    await _save();
  }

  Future<void> setOn(bool on) async {
    if (state.place == null) return;
    state = (place: state.place, on: on, saved: state.saved);
    await _save();
  }

  /// Stops heading anywhere; the saved destinations stay.
  Future<void> clear() async {
    state = (place: null, on: false, saved: state.saved);
    await _save();
  }
}

final destinationModeProvider = NotifierProvider<DestinationModeNotifier, DestinationMode>(DestinationModeNotifier.new);
