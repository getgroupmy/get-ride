// Admin → Display Settings → Media Gallery: the tabs, filters, search and
// tiles in light and dark mode, the details panel (side panel when wide, a
// sheet on a phone) with "Where used" and Delete only for an unused upload,
// and the Upload dialog's before/after preview.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_screen.dart' show displayPage;
import 'package:get_ride/src/admin/screens/meterapp/media_gallery_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/media_upload_dialog.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/media_assets.dart';
import 'package:get_ride/src/core/media_usage.dart';
import 'package:image/image.dart' as img;

const _used = '11111111-1111-1111-1111-111111111111';
const _free = '33333333-3333-3333-3333-333333333333';

final _assets = [
  MediaAsset(id: _used, kind: MediaKind.icon, name: 'Durian', path: 'icon/$_used.png', createdAt: DateTime(2026, 10, 1)),
  MediaAsset(id: _free, kind: MediaKind.icon, name: 'Old cart', path: 'icon/$_free.png', createdAt: DateTime(2026, 10, 3)),
];

final _data = MediaGalleryData(
  assets: _assets,
  usage: mediaUsageIndex(MediaUsageInput(
    assets: _assets,
    display: {
      'userMenu': {
        'customItems': [
          {'id': 'custom-1', 'label': 'Buy durian', 'iconName': 'media:$_used'},
        ],
      },
    },
  )),
);

Future<void> _pump(WidgetTester tester, {Brightness b = Brightness.light, double width = 1280, bool edit = true}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaGalleryProvider.overrideWith((ref) async => _data),
      adminAccessProvider.overrideWith((ref) async => AdminAccess([AdminGrant(page: displayPage, edit: edit)])),
    ],
    child: MaterialApp(theme: appTheme(b), home: const AdminMediaGalleryScreen()),
  ));
  await tester.pumpAndSettle();
}

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  for (final b in Brightness.values) {
    group('in ${b.name} mode', () {
      testWidgets('tabs, filters, search and tiles with their counts', (tester) async {
        await _pump(tester, b: b);
        expect(find.text('Media Gallery'), findsOneWidget);
        expect(_key('media-upload'), findsOneWidget);
        // Icons: the uploads and the built-ins.
        expect(_key('media-tile-media:$_used'), findsOneWidget);
        expect(_key('media-tile-icon:Truck'), findsOneWidget);
        expect(tester.widget<Text>(find.descendant(of: _key('media-tile-count-media:$_used'), matching: find.byType(Text))).data, '1');
        expect(tester.widget<Text>(_key('media-tile-state-media:$_used')).data, 'Where used');
        expect(tester.widget<Text>(_key('media-tile-state-media:$_free')).data, 'Unused');

        await tester.tap(_key('media-filter-uploaded'));
        await tester.pumpAndSettle();
        expect(_key('media-tile-icon:Truck'), findsNothing);
        expect(_key('media-tile-media:$_free'), findsOneWidget);

        await tester.tap(_key('media-filter-all'));
        await tester.enterText(_key('media-search'), 'buy durian');
        await tester.pumpAndSettle();
        expect(_key('media-tile-media:$_used'), findsOneWidget, reason: 'found by where it is used');
        expect(_key('media-tile-media:$_free'), findsNothing);

        await tester.enterText(_key('media-search'), '');
        await tester.tap(_key('media-tab-logo'));
        await tester.pumpAndSettle();
        expect(_key('media-tile-logo:wordmark'), findsOneWidget);
        expect(_key('media-tile-icon:Truck'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('an upload in use: its places, and Delete disabled with why', (tester) async {
        await _pump(tester, b: b);
        await tester.tap(_key('media-tile-media:$_used'));
        await tester.pumpAndSettle();
        expect(find.descendant(of: _key('media-side-panel'), matching: find.text('Durian')), findsOneWidget);
        expect(tester.widget<Text>(_key('media-details-uses')).data, 'Used in 1 place');
        expect(find.text('Side menu (rider) › Buy durian'), findsOneWidget);
        expect(tester.widget<ButtonStyleButton>(_key('media-delete')).onPressed, isNull);
        expect(find.text("Can't delete: it is in use. Change those places to another icon first."), findsOneWidget);
      });

      testWidgets('an unused upload can be deleted; a built-in never', (tester) async {
        await _pump(tester, b: b);
        await tester.tap(_key('media-tile-media:$_free'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(_key('media-details-uses')).data, 'Not used anywhere.');
        expect(tester.widget<ButtonStyleButton>(_key('media-delete')).onPressed, isNotNull);
        expect(_key('media-delete-blocked'), findsNothing);

        await tester.tap(_key('media-tile-icon:Truck'));
        await tester.pumpAndSettle();
        expect(_key('media-delete'), findsNothing);
        expect(find.text("Built-in icons can't be deleted."), findsOneWidget);
      });
    });
  }

  testWidgets('a read-only admin: no Upload, Delete off', (tester) async {
    await _pump(tester, edit: false);
    expect(_key('media-upload'), findsNothing);
    await tester.tap(_key('media-tile-media:$_free'));
    await tester.pumpAndSettle();
    expect(tester.widget<ButtonStyleButton>(_key('media-delete')).onPressed, isNull);
  });

  testWidgets('on a phone the details open in a sheet', (tester) async {
    await _pump(tester, width: 400);
    expect(_key('media-side-panel'), findsNothing);
    await tester.tap(_key('media-tile-media:$_used'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Side menu (rider) › Buy durian'), findsOneWidget);
    expect(_key('media-delete-blocked'), findsOneWidget);
  });

  group('Upload dialog', () {
    // A red square on a cream background.
    Uint8List sample() {
      final im = img.Image(width: 60, height: 60, numChannels: 4);
      for (final p in im) {
        final inside = p.x >= 20 && p.x < 40 && p.y >= 20 && p.y < 40;
        p
          ..r = inside ? 210 : 244
          ..g = inside ? 59 : 241
          ..b = inside ? 59 : 230
          ..a = 255;
      }
      return img.encodePng(im);
    }

    Future<void> open(WidgetTester tester, Brightness b, {String name = 'pharmacy_cross.png', int? size}) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bytes = size == null ? sample() : Uint8List(size);
      await tester.pumpWidget(ProviderScope(
        overrides: [mediaFilePickerProvider.overrideWithValue(() async => (bytes: bytes, name: name))],
        child: MaterialApp(
          theme: appTheme(b),
          home: Builder(
            builder: (c) => TextButton(onPressed: () => showMediaUploadDialog(c), child: const Text('open')),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    img.Image after(WidgetTester tester) =>
        img.decodePng((tester.widget<Image>(_key('media-after-image')).image as MemoryImage).bytes)!;

    for (final b in Brightness.values) {
      testWidgets('before and after on a checkerboard, the strength and the switch (${b.name})', (tester) async {
        await open(tester, b);
        expect(find.text('No file yet'), findsOneWidget);
        expect(tester.widget<SwitchListTile>(_key('media-remove-bg')).value, isTrue, reason: 'on for an icon');
        expect(tester.widget<FilledButton>(_key('media-upload-save')).onPressed, isNull);

        await tester.tap(_key('media-choose'));
        await tester.pumpAndSettle();
        expect(find.text('pharmacy_cross.png'), findsOneWidget);
        expect(tester.widget<TextField>(_key('media-upload-name')).controller!.text, 'pharmacy cross');
        expect(find.descendant(of: _key('media-after'), matching: find.byType(CustomPaint)), findsWidgets);
        expect(after(tester).getPixel(0, 0).a, 0, reason: 'the background taken off');
        expect(after(tester).getPixel(after(tester).width ~/ 2, after(tester).height ~/ 2).a, 255);
        expect(tester.widget<FilledButton>(_key('media-upload-save')).onPressed, isNotNull);

        await tester.tap(_key('media-remove-bg'));
        await tester.pumpAndSettle();
        expect(after(tester).getPixel(0, 0).a, 255, reason: 'switched off: as it is');
        expect(tester.widget<Slider>(_key('media-strength')).onChanged, isNull);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('an image starts with the background left alone; a logo takes a dark version too', (tester) async {
      await open(tester, Brightness.light);
      await tester.tap(_key('media-upload-kind-image'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(_key('media-remove-bg')).value, isFalse);
      expect(_key('media-tint'), findsNothing);
      await tester.tap(_key('media-upload-kind-logo'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(_key('media-remove-bg')).value, isTrue);
      expect(_key('media-choose-dark'), findsOneWidget);
      expect(find.text('Save logo'), findsOneWidget);
    });

    testWidgets('too big or the wrong type is refused', (tester) async {
      await open(tester, Brightness.light, size: 3 * 1024 * 1024);
      await tester.tap(_key('media-choose'));
      await tester.pumpAndSettle();
      expect(find.text('Over 2 MB. Pick a smaller file.'), findsOneWidget);
    });

    testWidgets('a GIF is refused', (tester) async {
      await open(tester, Brightness.light, name: 'anim.gif');
      await tester.tap(_key('media-choose'));
      await tester.pumpAndSettle();
      expect(find.text('Use a PNG, JPG, WebP or SVG file.'), findsOneWidget);
    });
  });
}
