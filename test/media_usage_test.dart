// The Media Gallery's usage index (core/media_usage.dart): every place the
// settings point at an icon, image or logo, with the admin page that sets
// it, from sample rows; and the gallery's tiles, filters and search.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/media_assets.dart';
import 'package:get_ride/src/core/media_usage.dart';

const _upload = '11111111-1111-1111-1111-111111111111';
const _logo = '22222222-2222-2222-2222-222222222222';
const _unused = '33333333-3333-3333-3333-333333333333';
const _base = 'https://proj.supabase.co/storage/v1/object/public';

final _assets = [
  MediaAsset(id: _upload, kind: MediaKind.icon, name: 'Durian', path: 'icon/$_upload.png', createdAt: DateTime(2026, 10, 1)),
  MediaAsset(id: _logo, kind: MediaKind.logo, name: 'Partner bank', path: 'logo/$_logo.png', darkPath: 'logo/$_logo-dark.png',
      createdAt: DateTime(2026, 10, 2)),
  MediaAsset(id: _unused, kind: MediaKind.image, name: 'Old banner', path: 'image/$_unused.webp', createdAt: DateTime(2026, 10, 3)),
];

final _input = MediaUsageInput(
  assets: _assets,
  display: {
    'signInLogo': true,
    'userMenu': {
      'renames': {'freight': 'Freight & moving'},
      'hidden': ['pharmacy'],
      'customItems': [
        {'id': 'custom-1', 'label': 'Buy durian', 'iconName': 'media:$_upload'},
        {'id': 'custom-2', 'label': 'Promo', 'iconName': 'Gift'},
      ],
    },
    'partnerMenu': {
      // An icon the admin gave a built-in item.
      'icons': {'earnings': 'Banknote'},
    },
    'serviceBoxes': [
      {'id': 'box-0', 'iconName': 'ShoppingBag', 'name': 'Shop'},
      {'id': 'box-1', 'iconName': 'Car', 'imageUri': 'data:image/png;base64,AAAA'},
      {'id': 'box-2', 'iconName': 'Building2', 'imageUri': 'media:$_upload', 'serviceId': 'svc-1'},
    ],
    'rideOptions': {
      'labels': {'pet': 'Pets welcome'},
      'images': {'pet': 'media:$_upload'},
    },
    // A key this app does not know, holding a picture.
    'promoBanner': {'image': '$_base/app-branding/promo.png'},
  },
  entries: [
    {'id': 'svc-1', 'category': 'service-settings', 'values': {'name': 'Mall run', 'iconUri': ''}},
    {
      'id': 'vs-1',
      'category': 'vehicle-services',
      'values': {'name': 'Van 1-tonne', 'iconUri': 'media:$_upload', 'heroImageUri': 'https://cdn.example.com/van.webp'},
    },
    {
      'id': 'b-1',
      'category': 'advertisement-banners',
      // The logo by its file's address, not its reference.
      'values': {'title': 'Bank promo', 'url': '$_base/media/logo/$_logo.png', 'link': 'https://bank.example.com'},
    },
    {'id': 'pt-1', 'category': 'partner-type', 'values': {'name': 'Taxi', 'iconUrl': 'https://cdn.example.com/taxi.png'}},
    {'id': 'x-1', 'category': 'social-links', 'values': {'platform': 'Facebook', 'icon': 'media:$_logo'}},
  ],
  appSettings: [
    {
      'key': 'app_icon',
      'value': {'automatic': false, 'fixed_icon': 'christmas'},
    },
    {
      'key': 'page_style:route:/',
      'value': {'backgroundImage': 'media:$_upload', 'textScale': 1.1},
    },
    {'key': 'api_providers', 'value': {'secret': 'not a picture'}},
  ],
  branding: {'splash_image_url': '$_base/app-branding/splash-1.png', 'app_icon_url': null},
);

void main() {
  final usage = mediaUsageIndex(_input);
  List<String> labels(String key) => [for (final u in usage[key] ?? const <MediaUse>[]) u.label];

  group('mediaKeyOf', () {
    test('references, addresses and names', () {
      expect(mediaKeyOf('media:abc'), 'media:abc');
      expect(mediaKeyOf('data:image/png;base64,AA'), 'url:data:image/png;base64,AA');
      expect(mediaKeyOf('https://x/y/pic.JPG?x=1'), 'url:https://x/y/pic.JPG?x=1');
      expect(mediaKeyOf('$_base/media/icon/a.png', idByPath: {'icon/a.png': 'a'}), 'media:a');
      expect(mediaKeyOf('https://bank.example.com'), isNull, reason: 'a link, not a picture');
      expect(mediaKeyOf('Truck'), isNull);
      expect(mediaKeyOf(3), isNull);
    });
  });

  group('the index', () {
    test('an upload: each place it is used, with its page and the item to pick out', () {
      expect(usage['media:$_upload'], [
        const MediaUse('Side menu (rider) › Buy durian', '/admin/m/display/side-menu/user',
            highlightId: 'custom-1', slot: MediaKind.icon),
        const MediaUse('Home box 3 › Mall run', '/admin/m/display', highlightId: 'service-box-2'),
        const MediaUse('Ride Options › Pets welcome', '/admin/m/display', highlightId: 'ride-option-pet'),
        const MediaUse('Vehicle Services › Van 1-tonne (Vehicle icon)', '/admin/m/vehicle-services',
            highlightId: 'vs-1', slot: MediaKind.icon),
        const MediaUse('App Page Settings › Home', '/admin/m/page-settings', highlightId: 'route:/'),
      ]);
      expect(usage['media:$_upload']!.first.location, '/admin/m/display/side-menu/user?highlight=custom-1');
    });

    test("a logo kept by its file's address counts for the upload", () {
      expect(labels('media:$_logo'), ['Advertisement Banners › Bank promo', 'Social links › Facebook']);
      expect(usage['media:$_logo']!.first.adminRoute, '/admin/settings/advertisement-banners');
      expect(usage['media:$_logo']!.last.adminRoute, '/admin/settings/social-links');
    });

    test('an unused upload has no entry', () {
      expect(usage.containsKey('media:$_unused'), isFalse);
    });

    test("built-in icons: the menus' own (renamed, hidden, overridden) and custom items', the boxes without a picture", () {
      expect(labels('icon:Truck'), contains('Side menu (rider) › Freight & moving'));
      expect(labels('icon:Pill'), ['Side menu (rider) › Pharmacy (hidden)']);
      expect(labels('icon:Gift'), containsAll(['Side menu (rider) › Promo', 'Side menu (rider) › Invite friends']));
      expect(labels('icon:Banknote'), contains('Side menu (driver) › Earnings'));
      expect(labels('icon:Wallet'), isNot(contains('Side menu (driver) › Earnings')), reason: 'overridden');
      expect(labels('icon:ShoppingBag'), contains('Home box 1 › Shop'));
      expect(labels('icon:Car'), isNot(contains(startsWith('Home box 2'))), reason: 'its picture shows instead');
      // Box 4 and 5 keep their default icons.
      expect(labels('icon:Package'), contains('Home box 4 › Couriers'));
      expect(labels('icon:Truck'), contains('Home box 5 › Freight'));
    });

    test('pictures set on their own pages, by address', () {
      expect(labels('url:data:image/png;base64,AAAA'), ['Home box 2 › City rides']);
      expect(labels('url:https://cdn.example.com/van.webp'), ['Vehicle Services › Van 1-tonne (Hero image)']);
      expect(labels('url:https://cdn.example.com/taxi.png'), ['Partner Type › Taxi']);
      expect(labels('url:$_base/app-branding/splash-1.png'), ['App Settings › Splash picture']);
      expect(labels('url:$_base/app-branding/promo.png'), ['Display Settings › promoBanner.image']);
      expect(usage.keys.where((k) => k.contains('bank.example.com')), isEmpty);
    });

    test('the home-screen icon and the wordmark', () {
      expect(labels('appicon:christmas'), ['App Settings › Home-screen icon (for everyone)']);
      expect(usage.containsKey('appicon:standard'), isFalse, reason: 'a fixed icon, no schedule');
      expect(labels(wordmarkKey), ['Sign-in screen › Logo']);
      final scheduled = mediaUsageIndex(const MediaUsageInput(display: {'signInLogo': false}));
      expect(scheduled.containsKey(wordmarkKey), isFalse);
      expect(scheduled[appIconKey('standard')], isNotEmpty, reason: 'outside the default schedule');
      expect(scheduled[appIconKey('sale_11_11')], isNotEmpty);
    });

    test('empty settings: the defaults still count', () {
      final u = mediaUsageIndex(const MediaUsageInput());
      expect(u['icon:Truck'], isNotEmpty);
      expect(u.keys.where((k) => k.startsWith('media:')), isEmpty);
    });
  });

  group('the gallery', () {
    final items = galleryItems(builtInIcons: const ['Truck', 'Pill', 'ShoppingBag', 'Plane'], assets: _assets, usage: usage);

    test('uploads newest first, then pictures found in settings, then the built-ins', () {
      expect(items.take(3).map((i) => i.name), ['Old banner', 'Partner bank', 'Durian']);
      expect(items[3].source, MediaSource.found);
      expect(items.where((i) => i.source == MediaSource.builtIn && i.kind == MediaKind.icon).map((i) => i.name),
          ['Truck', 'Pill', 'Shopping bag', 'Plane']);
      expect(items.any((i) => i.key == wordmarkKey && i.kind == MediaKind.logo), isTrue);
      expect(items.firstWhere((i) => i.key == 'appicon:g_dot').kind, MediaKind.logo);
      expect(items.firstWhere((i) => i.key == 'appicon:christmas').kind, MediaKind.image);
    });

    test('only an upload nothing uses can be deleted', () {
      expect(items.firstWhere((i) => i.name == 'Old banner').deletable, isTrue);
      expect(items.firstWhere((i) => i.name == 'Durian').deletable, isFalse);
      expect(items.firstWhere((i) => i.name == 'Plane').deletable, isFalse, reason: 'built in');
      expect(mediaAssetInUse(_assets.first, usage), isTrue);
      expect(mediaAssetInUse(_assets.last, usage), isFalse);
    });

    test('filters and search', () {
      List<String> names(MediaKind k, GalleryFilter f, [String q = '']) =>
          [for (final i in filterGallery(items, kind: k, filter: f, query: q)) i.name];
      expect(names(MediaKind.icon, GalleryFilter.uploaded), ['Durian']);
      expect(names(MediaKind.icon, GalleryFilter.notUsed), contains('Plane'));
      expect(names(MediaKind.icon, GalleryFilter.inUse), containsAll(['Durian', 'Truck', 'Pill']));
      expect(names(MediaKind.icon, GalleryFilter.all, 'freight &'), ['Truck'], reason: 'by where it is used');
      expect(names(MediaKind.icon, GalleryFilter.all, 'shoppingbag'), ['Shopping bag'], reason: 'by its name');
      expect(names(MediaKind.image, GalleryFilter.uploaded), ['Old banner']);
      expect(names(MediaKind.logo, GalleryFilter.uploaded), ['Partner bank']);
    });
  });

  test('icon names read as words', () {
    expect(iconDisplayName('ShoppingBag'), 'Shopping bag');
    expect(iconDisplayName('Building2'), 'Building 2');
    expect(iconDisplayName('HelpCircle'), 'Help circle');
  });
}
