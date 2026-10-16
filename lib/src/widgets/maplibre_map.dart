// A MapLibre map drawn by the browser (Admin → Settings → Maps, migration
// 0206): Amazon Location's map, whose GrabMaps tiles are vector only. The
// app's own layers sit on top. Web only; elsewhere [maplibreSupported] is
// false and the map keeps its tiles.
export 'maplibre_map_stub.dart' if (dart.library.js_interop) 'maplibre_map_web.dart';
