// Multi-angle map icons (0336) in the app: the Upload dialog's multi-angle
// flow (a ZIP, then slots one at a time, the spin preview, Save) in light
// and dark mode, and the map's car showing the frame for its heading
// without turning it, while a single icon still turns.
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/map_icon_angles_editor.dart';
import 'package:get_ride/src/admin/screens/meterapp/media_upload_dialog.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/background_removal.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/media_assets.dart';
import 'package:get_ride/src/data/app_display_repository.dart' show rideServicesProvider;
import 'package:get_ride/src/data/media_repository.dart';
import 'package:get_ride/src/widgets/map_vehicle_icon.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

/// A small car-ish picture: a dark block on a white background.
Uint8List _png([int shade = 40]) {
  final im = img.Image(width: 24, height: 24, numChannels: 4);
  for (final p in im) {
    final inside = p.x >= 6 && p.x < 18 && p.y >= 4 && p.y < 20;
    p
      ..r = inside ? shade : 255
      ..g = inside ? shade : 255
      ..b = inside ? shade : 255
      ..a = 255;
  }
  return img.encodePng(im);
}

Uint8List _zip(Map<String, List<int>> files) {
  final a = Archive();
  for (final e in files.entries) {
    a.addFile(ArchiveFile.bytes(e.key, Uint8List.fromList(e.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

/// Keeps what Save sends instead of uploading it.
class _Repo extends MediaRepository {
  _Repo() : super(SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)));

  String? name;
  List<({int deg, ProcessedMedia media})>? frames;

  @override
  Future<MediaAsset> saveMultiAngle({required String name, required List<({int deg, ProcessedMedia media})> frames}) async {
    this.name = name;
    this.frames = frames;
    return MediaAsset(
      id: 'x',
      kind: MediaKind.mapIcon,
      name: name,
      angles: [for (final f in frames) MediaAngle(f.deg, 'map_icon/x/${f.deg.toString().padLeft(3, '0')}.png')],
    );
  }
}

void main() {
  group('Upload dialog, multi-angle', () {
    for (final b in Brightness.values) {
      testWidgets('a ZIP, slots one at a time, the spin preview and Save (${b.name})', (tester) async {
        tester.view.physicalSize = const Size(1000, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final repo = _Repo();
        var zip = _zip({
          'blue taxi/car_000.png': _png(),
          'blue taxi/car_090.png': _png(60),
          'blue taxi/car_180.png': _png(80),
          'blue taxi/car_270.png': _png(100),
          '__MACOSX/blue taxi/._car_000.png': [0, 1],
          'blue taxi/.DS_Store': [0],
        });
        var single = (bytes: _png(120), name: 'side.png');
        final jobs = <MediaJob>[];
        MediaAsset? saved;
        await tester.pumpWidget(ProviderScope(
          overrides: [
            mediaRepositoryProvider.overrideWithValue(repo),
            mediaZipPickerProvider.overrideWithValue(() async => (bytes: zip, name: 'blue_taxi.zip')),
            mediaFilePickerProvider.overrideWithValue(() async => single),
            mediaProcessorProvider.overrideWithValue((job) async {
              jobs.add(job);
              return processMediaJob(job);
            }),
          ],
          child: MaterialApp(
            theme: appTheme(b),
            home: Builder(
              builder: (c) => TextButton(
                onPressed: () async => saved = await showMediaUploadDialog(c, kind: MediaKind.mapIcon, lockKind: true),
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        // Single picture first, as before.
        expect(_key('media-choose'), findsOneWidget);
        await tester.tap(_key('media-map-multi'));
        await tester.pumpAndSettle();
        expect(_key('media-choose'), findsNothing);
        expect(_key('media-map-angles'), findsOneWidget);
        expect(tester.widget<ChoiceChip>(_key('map-angles-count-16')).selected, isTrue, reason: '16 to start');
        expect(_key('map-angle-slot-23'), findsOneWidget, reason: '22.5° kept as 23');
        expect(find.text('22.5°'), findsOneWidget);
        expect(_key('map-angle-missing-0'), findsOneWidget);
        expect(tester.widget<FilledButton>(_key('media-upload-save')).onPressed, isNull);

        // 8 angles, then the ZIP: its four headings, junk left out.
        await tester.tap(_key('map-angles-count-8'));
        await tester.pumpAndSettle();
        expect(_key('map-angle-slot-45'), findsOneWidget);
        expect(_key('map-angle-slot-23'), findsNothing);
        await tester.tap(_key('map-angles-zip'));
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(_key('map-angles-count-zip')).selected, isTrue);
        expect(tester.widget<Text>(_key('map-angles-note')).data, '4 angles read from the ZIP, each from the number in its name.');
        for (final d in [0, 90, 180, 270]) {
          expect(_key('map-angle-image-$d'), findsOneWidget);
        }
        expect(_key('map-angle-slot-45'), findsNothing);
        expect(tester.widget<TextField>(_key('media-upload-name')).controller!.text, 'blue taxi');
        expect(tester.widget<FilledButton>(_key('media-upload-save')).onPressed, isNotNull);

        // The spin preview picks the nearest frame.
        expect(tester.widget<Text>(_key('map-icon-spin-label')).data, 'Heading 0° shows the 0° picture');
        final slider = tester.widget<Slider>(_key('map-icon-spin-heading'));
        slider.onChanged!(100);
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(_key('map-icon-spin-label')).data, 'Heading 100° shows the 90° picture');
        expect(_key('map-icon-spin-frame-90'), findsOneWidget);
        slider.onChanged!(330);
        await tester.pumpAndSettle();
        expect(_key('map-icon-spin-frame-0'), findsOneWidget, reason: 'wraps round 360');

        // Clear one: marked missing; upload it again one at a time.
        await tester.tap(_key('map-angle-clear-180'));
        await tester.pumpAndSettle();
        expect(_key('map-angle-missing-180'), findsOneWidget);
        expect(tester.widget<Text>(_key('map-angles-count')).data, startsWith('3 of 4 angles.'));
        await tester.tap(_key('map-angle-upload-180'));
        await tester.pumpAndSettle();
        expect(_key('map-angle-image-180'), findsOneWidget);
        expect(find.descendant(of: _key('map-angle-slot-180'), matching: find.text('Replace')), findsOneWidget);

        // A file that isn't a picture is refused, in plain words.
        single = (bytes: Uint8List.fromList([1, 2, 3]), name: 'notes.txt');
        await tester.tap(_key('map-angle-upload-90'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(_key('map-angles-error')).data, '"notes.txt" is not a PNG, JPG or WebP picture.');
        expect(_key('map-angle-image-90'), findsOneWidget, reason: 'the old frame kept');

        // A ZIP with too many pictures is refused, the frames kept.
        zip = _zip({for (var i = 0; i < 73; i++) 'f_$i.png': _png()});
        await tester.tap(_key('map-angles-zip'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(_key('map-angles-error')).data, 'The ZIP has 73 pictures. A map icon takes at most 72 angles.');
        expect(tester.widget<Text>(_key('map-angles-count')).data, startsWith('4 of 4 angles.'));
        expect(tester.takeException(), isNull);

        // Save: every frame processed at one scale, then saved by heading.
        await tester.tap(_key('media-upload-save'));
        await tester.pumpAndSettle();
        expect(jobs, hasLength(4));
        expect(jobs.every((j) => j.kind == MediaKind.mapIcon && !j.trim && j.removeBackground), isTrue);
        expect(repo.name, 'blue taxi');
        expect([for (final f in repo.frames!) f.deg], [0, 90, 180, 270]);
        expect(repo.frames!.every((f) => f.media.mime == 'image/png' && f.media.width == iconSide), isTrue);
        expect(saved?.isMultiAngle, isTrue);
        expect(_key('media-map-angles'), findsNothing, reason: 'the dialog closed');
      });
    }
  });

  group('the car on the map', () {
    const id = '55555555-5555-5555-5555-555555555555';
    const single = '66666666-6666-6666-6666-666666666666';
    final assets = [
      MediaAsset(
        id: id,
        kind: MediaKind.mapIcon,
        name: 'Taxi',
        path: 'map_icon/$id/000.png',
        angles: [for (final d in [0, 90, 180, 270]) MediaAngle(d, 'map_icon/$id/${d.toString().padLeft(3, '0')}.png')],
      ),
      const MediaAsset(id: single, kind: MediaKind.mapIcon, name: 'Arrow', path: 'map_icon/$single.png'),
    ];

    Future<void> pump(WidgetTester tester, Brightness b, String? icon, double? heading) async {
      resetMapIconPrecache();
      await tester.pumpWidget(ProviderScope(
        overrides: [mediaAssetsProvider.overrideWith((ref) async => assets)],
        child: MaterialApp(
          theme: appTheme(b),
          home: Center(
            child: MapVehicleIcon(
              icon: icon,
              heading: heading,
              size: 40,
              fallback: const Icon(Icons.navigation, key: ValueKey('built-in')),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    for (final b in Brightness.values) {
      testWidgets('a multi-angle icon: the frame for the heading, never turned (${b.name})', (tester) async {
        for (final (heading, deg) in [(0.0, 0), (80.0, 90), (190.0, 180), (300.0, 270), (350.0, 0), (-100.0, 270)]) {
          await pump(tester, b, 'media:$id', heading);
          expect(_key('map-icon-frame-$deg'), findsOneWidget, reason: 'heading $heading');
          expect(find.ancestor(of: _key('map-icon-frame-$deg'), matching: find.byType(Transform)).evaluate()
              .where((e) => (e.widget as Transform).transform.getRotation().entry(0, 1) != 0), isEmpty,
              reason: 'not turned');
          final image = tester.widget<Image>(find.descendant(of: _key('map-icon-frame-$deg'), matching: find.byType(Image)));
          expect((image.image as NetworkImage).url, endsWith('map_icon/$id/${deg.toString().padLeft(3, '0')}.png'));
          expect(image.gaplessPlayback, isTrue, reason: 'no flicker between frames');
        }
        // No heading yet: the 0° frame.
        await pump(tester, b, 'media:$id', null);
        expect(_key('map-icon-frame-0'), findsOneWidget);
      });

      testWidgets('a single icon still turns; no icon keeps the built-in car (${b.name})', (tester) async {
        await pump(tester, b, 'media:$single', 90);
        expect(_key('map-icon-single'), findsOneWidget);
        final turn = tester.widget<Transform>(find.ancestor(of: _key('map-icon-single'), matching: find.byType(Transform)).first);
        expect(turn.transform.getRotation().entry(1, 0), closeTo(1, 1e-6), reason: 'turned 90°');
        await pump(tester, b, null, 90);
        expect(_key('built-in'), findsOneWidget);
        await pump(tester, b, 'media:unknown', 90);
        expect(_key('built-in'), findsOneWidget);
      });
    }

    test("a service's Map Icon is found by its name", () async {
      final c = ProviderContainer(overrides: [
        rideServicesProvider.overrideWith((ref) async => const [
          RideService('Teksi', 'Metered taxi', 1, 4, mapIcon: 'media:$id'),
          RideService('Ride', 'Everyday', 1, 4),
        ]),
      ]);
      addTearDown(c.dispose);
      await c.read(rideServicesProvider.future);
      expect(c.read(serviceMapIconProvider('Teksi')), 'media:$id');
      expect(c.read(serviceMapIconProvider('Ride')), isNull);
      expect(c.read(serviceMapIconProvider(null)), isNull);
    });
  });
}
