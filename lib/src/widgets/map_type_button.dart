import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the maps show satellite imagery (Expo's map-type toggle). One
/// choice for the session, so the driver or rider who switched it on the
/// home map still sees it on the trip; a relaunch starts on the street map,
/// as Expo does.
class MapSatellite extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final mapSatelliteProvider = NotifierProvider<MapSatellite, bool>(MapSatellite.new);

/// The round map-type button: street map ⇄ satellite, highlighted while
/// satellite is on.
class MapTypeButton extends ConsumerWidget {
  const MapTypeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(mapSatelliteProvider);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: on,
      child: FloatingActionButton.small(
        key: const ValueKey('map-type'),
        heroTag: null,
        tooltip: on ? 'Standard map' : 'Satellite view',
        backgroundColor: on ? scheme.primary : null,
        foregroundColor: on ? scheme.onPrimary : null,
        onPressed: ref.read(mapSatelliteProvider.notifier).toggle,
        child: const Icon(Icons.layers_outlined),
      ),
    );
  }
}
