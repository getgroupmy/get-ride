import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'geo_service.dart';

/// The partner's destination and whether destination mode is on, kept on the
/// device (as Expo kept its destinations).
typedef DestinationMode = ({Place? place, bool on});

class DestinationModeNotifier extends Notifier<DestinationMode> {
  static const _key = 'partner_destination';

  @override
  DestinationMode build() {
    SharedPreferences.getInstance().then((p) {
      final raw = p.getString(_key);
      if (raw == null) return;
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final place = Place(
          name: '${m['name']}',
          address: '${m['address'] ?? ''}',
          point: LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
        );
        state = (place: place, on: m['on'] == true);
      } catch (_) {}
    });
    return (place: null, on: false);
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    final place = state.place;
    if (place == null) {
      await p.remove(_key);
      return;
    }
    await p.setString(
      _key,
      jsonEncode({
        'name': place.name,
        'address': place.address,
        'lat': place.point.latitude,
        'lng': place.point.longitude,
        'on': state.on,
      }),
    );
  }

  /// Sets the destination and switches the mode on.
  Future<void> setPlace(Place place) async {
    state = (place: place, on: true);
    await _save();
  }

  Future<void> setOn(bool on) async {
    if (state.place == null) return;
    state = (place: state.place, on: on);
    await _save();
  }

  Future<void> clear() async {
    state = (place: null, on: false);
    await _save();
  }
}

final destinationModeProvider = NotifierProvider<DestinationModeNotifier, DestinationMode>(DestinationModeNotifier.new);
