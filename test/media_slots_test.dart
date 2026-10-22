// Every admin icon or picture slot takes a Media Gallery pick: what each
// slot stores, how the app draws a built-in name or an upload
// (MediaIcon / MediaImage, a skeleton while an upload is looked up), the
// shared MediaPickerSheet, and that the usage index sees each slot.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/media_picker_sheet.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/config.dart';
import 'package:get_ride/src/core/media_assets.dart';
import 'package:get_ride/src/core/media_usage.dart';
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/ride_assistance.dart';
import 'package:get_ride/src/core/ride_option_settings.dart';
import 'package:get_ride/src/core/side_menu.dart';
import 'package:get_ride/src/data/media_repository.dart';
import 'package:get_ride/src/features/ride/home_parts.dart' show loadsOverNetwork, uriImage;
import 'package:get_ride/src/widgets/media_image.dart';
import 'package:get_ride/src/widgets/net_image.dart';
import 'package:get_ride/src/widgets/side_menu_tiles.dart';

const _id = '11111111-1111-1111-1111-111111111111';
const _tinted = '22222222-2222-2222-2222-222222222222';
final _assets = [
  MediaAsset(id: _id, kind: MediaKind.icon, name: 'Durian', path: 'icon/$_id.png', createdAt: DateTime(2026, 10, 1)),
  MediaAsset(id: _tinted, kind: MediaKind.icon, name: 'Cross', path: 'icon/$_tinted.png', tint: true),
  const MediaAsset(id: 'img-1', kind: MediaKind.image, name: 'Banner', path: 'image/img-1.webp'),
];

Widget _app(Widget child, {List<MediaAsset>? assets, Future<List<MediaAsset>>? pending}) => ProviderScope(
  overrides: [
    mediaAssetsProvider.overrideWith((ref) => pending ?? Future.value(assets ?? _assets)),
  ],
  child: MaterialApp(theme: appTheme(Brightness.light), home: Scaffold(body: Center(child: child))),
);

void main() {
  group('what the slots store', () {
    test('side menus: a built-in item keeps an override, a custom item its icon', () {
      var s = defaultDisplaySettings();
      s = setMenuItemIcon(s, 'user', 'freight', 'media:$_id');
      expect(menuOf(s, 'user')['icons'], {'freight': 'media:$_id'});
      final freight = resolveSideMenu(s, 'user').firstWhere((e) => e.id == 'freight');
      expect(freight.iconName, 'media:$_id');
      s = setMenuItemIcon(s, 'user', 'freight', '');
      expect(menuOf(s, 'user')['icons'], isEmpty, reason: 'Default puts its own icon back');
      expect(resolveSideMenu(s, 'user').firstWhere((e) => e.id == 'freight').iconName, isNull);

      s = addCustomMenuItem(s, 'user', 'Durian', 'Star', null, id: 'custom-1');
      s = setMenuItemIcon(s, 'user', 'custom-1', 'media:$_id');
      expect(resolveSideMenu(s, 'user').firstWhere((e) => e.id == 'custom-1').iconName, 'media:$_id');
      s = setMenuItemIcon(s, 'user', 'custom-1', '');
      expect(resolveSideMenu(s, 'user').firstWhere((e) => e.id == 'custom-1').iconName, 'Star');
    });

    test('Ride Options: a picture per option, kept and cleared', () {
      var s = setRideOptionImage(defaultDisplaySettings(), RideOptionKind.pet, 'media:img-1');
      expect(RideOptionsConfig.fromSettings(s).images, {RideOptionKind.pet: 'media:img-1'});
      expect((s['rideOptions'] as Map)['images'], {'pet': 'media:img-1'});
      s = setRideOptionImage(s, RideOptionKind.pet, '');
      expect(RideOptionsConfig.fromSettings(s).images, isEmpty);
      expect((s['rideOptions'] as Map).containsKey('images'), isFalse, reason: 'nothing stored when none');
    });

    test('assistance items: an icon in place of the emoji', () {
      const item = AssistanceItem(id: 'x', name: 'Wheelchair', emoji: '♿', icon: 'media:abc');
      expect(item.toJson()['icon'], 'media:abc');
      expect(AssistanceItem.fromJson(item.toJson()), item);
      expect(const AssistanceItem(id: 'x', name: 'W').toJson().containsKey('icon'), isFalse);
    });

    test('payment types: the admin icon, else the kind\'s', () {
      final c = paymentChoicesFrom([
        {'name': 'Cash', 'icon': 'Banknote'},
        {'name': 'Card', 'icon': 'media:$_id'},
        {'name': 'Bank'},
      ]);
      expect(c.map((x) => x.icon), ['Banknote', 'media:$_id', null]);
    });

    test('an upload loads over the network, so the vehicle bar waits for it', () {
      expect(loadsOverNetwork('media:$_id'), isTrue);
      expect(loadsOverNetwork('Truck'), isFalse);
    });
  });

  group('the usage index sees every slot', () {
    final u = mediaUsageIndex(MediaUsageInput(
      assets: _assets,
      display: {
        'partnerMenu': {
          'icons': {'earnings': 'media:$_id'},
        },
        'assistanceCatalogue': [
          {'id': 'wheelchair', 'name': 'Wheelchair user', 'emoji': '♿', 'icon': 'media:$_tinted'},
          {'id': 'deaf', 'name': 'Deaf', 'emoji': '🧏', 'icon': 'Heart'},
        ],
        'rideOptions': {
          'images': {'child-seat': 'media:img-1'},
        },
      },
      entries: [
        {'id': 'p1', 'category': 'payment-type', 'values': {'name': 'Card', 'icon': 'media:$_id'}},
        {'id': 'p2', 'category': 'payment-type', 'values': {'name': 'Cash', 'icon': 'Banknote'}},
      ],
      catalogue: [
        {'table': 'ev_vehicle_details', 'id': 'ev1', 'values': {'name': 'BYD Atto 3', 'imageUri': 'media:img-1'}},
        {
          'table': 'vehicle_make_models',
          'id': 'mm1',
          'make': 'Perodua',
          'model': 'Myvi',
          'icon_uri': '${AppConfig.supabaseUrl}/storage/v1/object/public/media/icon/$_tinted.png',
        },
      ],
    ));
    List<String> labels(String k) => [for (final x in u[k] ?? const <MediaUse>[]) x.label];

    test('menus, payment types, assistance, Ride Options, EV vehicles and makes', () {
      expect(labels('media:$_id'), ['Side menu (driver) › Earnings', 'Payment Type › Card']);
      expect(labels('media:$_tinted'),
          ['Ride Options › Assistance › Wheelchair user', 'Vehicle Make & Model › Perodua Myvi']);
      expect(labels('media:img-1'), ['Ride Options › Child safety seat', 'EV Vehicle Details › BYD Atto 3']);
      expect(labels('icon:Heart'), contains('Ride Options › Assistance › Deaf'));
      expect(labels('icon:Banknote'), contains('Payment Type › Cash'));
      expect(labels('icon:Wallet'), isNot(contains('Side menu (driver) › Earnings')), reason: 'overridden');
      expect(u['media:img-1']!.last.location, '/admin/m/ev-vehicle-details?highlight=ev1');
    });
  });

  group('MediaIcon', () {
    testWidgets('a built-in name: its Material icon; empty: the fallback', (tester) async {
      await tester.pumpWidget(_app(const Row(children: [
        MediaIcon('Truck', fallback: Icons.apps),
        MediaIcon('', fallback: Icons.apps),
        MediaIcon('NoSuchIcon', fallback: Icons.home),
      ])));
      expect(find.byIcon(Icons.local_shipping_outlined), findsOneWidget);
      expect(find.byIcon(Icons.apps), findsOneWidget);
      expect(find.byIcon(Icons.home), findsOneWidget);
    });

    testWidgets('an upload: a skeleton while it is looked up, then its file', (tester) async {
      final pending = Completer<List<MediaAsset>>();
      await tester.pumpWidget(_app(const MediaIcon('media:$_id', fallback: Icons.apps), pending: pending.future));
      expect(find.byType(ImageBone), findsOneWidget);
      expect(find.byIcon(Icons.apps), findsNothing, reason: 'no fallback icon while loading');
      pending.complete(_assets);
      await tester.pump();
      final img = tester.widget<NetImage>(find.byType(NetImage));
      expect(img.url, endsWith('/storage/v1/object/public/media/icon/$_id.png'));
      expect(find.byType(ColorFiltered), findsNothing);
    });

    testWidgets('"Follow the theme colour": drawn in the icon colour', (tester) async {
      await tester.pumpWidget(_app(const MediaIcon('media:$_tinted', fallback: Icons.apps, color: Colors.red)));
      await tester.pump();
      expect(find.byType(ColorFiltered), findsOneWidget);
    });

    testWidgets('an SVG upload: drawn as SVG, in the icon colour when it follows the theme', (tester) async {
      svgHttpClient = MockClient((_) async => http.Response(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>',
        200,
      ));
      addTearDown(() => svgHttpClient = null);
      const svg = '33333333-3333-3333-3333-333333333333';
      final assets = [
        const MediaAsset(id: svg, kind: MediaKind.icon, name: 'Leaf', path: 'icon/$svg.svg', mime: 'image/svg+xml', tint: true),
      ];
      await tester.pumpWidget(_app(const MediaIcon('media:$svg', fallback: Icons.apps, color: Colors.red), assets: assets));
      await tester.pump();
      final filter = tester.widget<SvgPicture>(find.byType(SvgPicture)).colorFilter;
      await tester.pumpWidget(_app(const MediaImage('https://example.com/a/logo.svg?v=2', width: 40, height: 40)));
      await tester.pump();
      final address = find.byType(SvgPicture).evaluate().length;
      expect(filter, const ColorFilter.mode(Colors.red, BlendMode.srcIn));
      expect(address, 1, reason: 'an SVG address too');
    });

    testWidgets('an upload that is gone: the fallback', (tester) async {
      await tester.pumpWidget(_app(const MediaIcon('media:gone', fallback: Icons.apps)));
      await tester.pump();
      expect(find.byIcon(Icons.apps), findsOneWidget);
    });

    testWidgets('a side menu row draws its own icon or upload', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        menuIconWidget(const MenuEntry(id: 'freight', label: 'Freight', custom: false)),
        menuIconWidget(const MenuEntry(id: 'freight', label: 'Freight', custom: false, iconName: 'Gift')),
        menuIconWidget(const MenuEntry(id: 'c1', label: 'Durian', custom: true, iconName: 'media:$_id')),
      ])));
      await tester.pump();
      expect(find.byIcon(Icons.local_shipping_outlined), findsOneWidget, reason: 'its icon in code');
      expect(find.byIcon(Icons.card_giftcard), findsOneWidget, reason: "the admin's built-in name");
      expect(find.byType(NetImage), findsOneWidget, reason: 'an upload');
    });

    testWidgets('uriImage draws an upload through MediaImage', (tester) async {
      await tester.pumpWidget(_app(uriImage('media:img-1', width: 40, height: 30)));
      expect(find.byType(MediaImage), findsOneWidget);
    });
  });

  group('MediaPickerSheet', () {
    Future<String?> open(WidgetTester tester, {required MediaKind kind, String? current, MediaStore store = MediaStore.ref}) async {
      String? result = 'unset';
      await tester.pumpWidget(_app(Builder(
        builder: (c) => TextButton(
          onPressed: () async => result = await showMediaPicker(c, kind: kind, current: current, store: store),
          child: const Text('pick'),
        ),
      )));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('icons: the built-ins and the uploads, search, a pick, Default', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester, kind: MediaKind.icon, current: 'Truck');
      expect(find.byKey(const ValueKey('media-picker-icon:Truck')), findsOneWidget);
      expect(find.byKey(const ValueKey('media-picker-media:$_id')), findsOneWidget);
      expect(find.byKey(const ValueKey('media-picker-media:img-1')), findsNothing, reason: 'an image, not an icon');
      expect(find.byKey(const ValueKey('media-picker-upload')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('media-picker-search')), 'durian');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-picker-icon:Truck')), findsNothing);
      String? picked;
      final c = tester.element(find.byKey(const ValueKey('media-picker-media:$_id')));
      Navigator.of(c).popUntil((r) => r.isFirst);
      await tester.pumpAndSettle();

      // Again, and pick it.
      await tester.pumpWidget(_app(Builder(
        builder: (c) => TextButton(
          onPressed: () async => picked = await showMediaPicker(c, kind: MediaKind.icon),
          child: const Text('pick2'),
        ),
      )));
      await tester.tap(find.text('pick2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('media-picker-media:$_id')));
      await tester.pumpAndSettle();
      expect(picked, 'media:$_id');

      await tester.tap(find.text('pick2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('media-picker-default')));
      await tester.pumpAndSettle();
      expect(picked, '', reason: 'Default clears the override');

      await tester.tap(find.text('pick2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('media-picker-icon:Gift')));
      await tester.pumpAndSettle();
      expect(picked, 'Gift', reason: 'a built-in keeps its name');
    });

    testWidgets("a slot read as a web address gets the file's address", (tester) async {
      String? picked;
      await tester.pumpWidget(_app(Builder(
        builder: (c) => TextButton(
          onPressed: () async =>
              picked = await showMediaPicker(c, kind: MediaKind.image, store: MediaStore.url, offerDefault: false),
          child: const Text('pick'),
        ),
      )));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-picker-default')), findsNothing);
      expect(find.byKey(const ValueKey('media-picker-icon:Truck')), findsNothing, reason: 'no built-in icons for a picture');
      await tester.tap(find.byKey(const ValueKey('media-picker-media:img-1')));
      await tester.pumpAndSettle();
      expect(picked, mediaPublicUrl(AppConfig.supabaseUrl, 'image/img-1.webp'));
    });
  });
}
