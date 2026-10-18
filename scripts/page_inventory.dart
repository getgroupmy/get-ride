// Writes lib/src/core/page_inventory.g.dart: every page, sheet and modal in
// the app, for Admin → Settings → App Page Settings. Run after adding one:
//
//   dart run scripts/page_inventory.dart
import 'dart:io';

import 'package:get_ride/src/core/page_inventory_scan.dart';

const inventoryFile = 'lib/src/core/page_inventory.g.dart';

void main() {
  final files = <String, String>{
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart') && !f.path.endsWith('.g.dart')) f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
  };
  final surfaces = scanSurfaces(files);
  File(inventoryFile).writeAsStringSync(inventorySource(surfaces));
  stdout.writeln('${surfaces.length} pages, sheets and modals → $inventoryFile');
}
