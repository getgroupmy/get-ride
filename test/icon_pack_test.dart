// The built-in icon pack: every file is there, slots store `pack:<name>`,
// the gallery lists the pack and the app draws it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/icon_pack.dart';
import 'package:get_ride/src/core/media_assets.dart';
import 'package:get_ride/src/core/media_usage.dart';
import 'package:get_ride/src/widgets/media_image.dart';

void main() {
  test('every pack icon has its file, and every file is in the pack', () {
    expect(iconPack, hasLength(193));
    final files = Directory('assets/icon_pack').listSync().map((f) => f.uri.pathSegments.last).toSet();
    expect(files, {for (final n in iconPack) '$n.webp'});
    expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/icon_pack/'));
  });

  test('a slot stores pack:<name>; anything else is not a pack icon', () {
    expect(packRef('ride-04-03'), 'pack:ride-04-03');
    expect(packRefName('pack:ride-04-03'), 'ride-04-03');
    expect(packRefName('pack:nothing'), isNull);
    expect(packRefName('media:ride-04-03'), isNull);
    expect(isMediaRef('pack:ride-04-03'), isTrue, reason: 'drawn by MediaIcon / MediaImage');
    expect(mediaRefId('pack:ride-04-03'), isNull, reason: 'not an upload');
    expect(packDisplayName('ride-04-03'), 'Ride 4.3');
    expect(packDisplayName('ui-left-10-01'), 'Interface 10.1');
  });

  test('the gallery lists the pack as built-in icons, with their uses', () {
    final usage = {
      'pack:ride-04-03': [const MediaUse('Side menu › Ride', '/admin', slot: MediaKind.icon)],
    };
    expect(mediaKeyOf(' pack:ride-04-03 '), 'pack:ride-04-03');
    final items = galleryItems(builtInIcons: const [], usage: usage);
    final pack = items.where((i) => i.key.startsWith('pack:')).toList();
    expect(pack, hasLength(193));
    final ride = pack.firstWhere((i) => i.key == 'pack:ride-04-03');
    expect(ride.kind, MediaKind.icon);
    expect(ride.source, MediaSource.builtIn);
    expect(ride.deletable, isFalse);
    expect(ride.assetPath, 'assets/icon_pack/ride-04-03.webp');
    expect(ride.used, isTrue);
  });

  testWidgets('MediaIcon and MediaImage draw a pack icon from the app', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(
        home: Column(children: [
          MediaIcon('pack:ride-04-03', fallback: Icons.apps, size: 32),
          MediaImage('pack:grocery-01-01', width: 60, height: 60),
        ]),
      ),
    ));
    final images = tester.widgetList<Image>(find.byType(Image)).map((i) => (i.image as AssetImage).assetName).toList();
    expect(images, ['assets/icon_pack/ride-04-03.webp', 'assets/icon_pack/grocery-01-01.webp']);
  });
}
