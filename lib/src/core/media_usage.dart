/// The Media Gallery's usage index: every place the app's settings point at
/// an icon, image or logo, by media key, each with the admin page that sets
/// it. Read from the display settings blob, `settings_entries`,
/// `app_settings` (the home-screen icon, App Page Settings) and the
/// `app_branding` row. Pure: the gallery and its tests feed it rows.
///
/// Media keys:
///  * `icon:<Name>`   a built-in icon by its name (`Truck`, `ShoppingBag`);
///  * `media:<id>`    an upload (the stored reference itself);
///  * `appicon:<id>`  a built-in home-screen icon (`standard`, `christmas`);
///  * `logo:wordmark` the GET.ride wordmark;
///  * `url:<uri>`     any other picture a setting holds (an http(s) or
///    `data:` address), uploaded on its own page.
library;

import '../admin/screens/meterapp/display_logic.dart'
    show defaultMenuIconNames, defaultMenuItems, displayBool, normalizeBoxes;
import 'app_icons.dart';
import 'home_sections.dart' show serviceBoxPresets;
import 'media_assets.dart';
import 'page_inventory.g.dart';
import 'ride_option_settings.dart';

/// One place a picture is used: what it is, the admin page that sets it
/// (a path) and the item there to pick out, when the page can.
class MediaUse {
  const MediaUse(this.label, this.adminRoute, {this.highlightId, this.slot = MediaKind.image});

  /// "Side menu (rider) › Freight".
  final String label;

  /// The admin page's path (`/admin/m/display`).
  final String adminRoute;

  /// What the page highlights or opens (a menu item id, a box, an entry).
  final String? highlightId;

  /// What the place takes: an icon, an image or a logo.
  final MediaKind slot;

  /// Where tapping the use goes: [adminRoute] with `?highlight=`.
  String get location =>
      Uri(path: adminRoute, queryParameters: highlightId == null ? null : {'highlight': highlightId}).toString();

  @override
  bool operator ==(Object other) =>
      other is MediaUse &&
      other.label == label &&
      other.adminRoute == adminRoute &&
      other.highlightId == highlightId &&
      other.slot == slot;

  @override
  int get hashCode => Object.hash(label, adminRoute, highlightId, slot);

  @override
  String toString() => 'MediaUse($label, $location)';
}

String iconKey(String name) => 'icon:$name';
String appIconKey(String id) => 'appicon:$id';
String urlKey(String uri) => 'url:$uri';
const wordmarkKey = 'logo:wordmark';

/// What the index reads: the rows as the database returns them.
class MediaUsageInput {
  const MediaUsageInput({
    this.display = const {},
    this.entries = const [],
    this.appSettings = const [],
    this.branding = const {},
    this.assets = const [],
    this.catalogue = const [],
  });

  /// The `admin_display_settings` blob (`settings`), as stored.
  final Map<String, dynamic> display;

  /// `settings_entries` rows: `id`, `category`, `values`.
  final List<Map<String, dynamic>> entries;

  /// `app_settings` rows: `key`, `value`.
  final List<Map<String, dynamic>> appSettings;

  /// The `app_branding` row.
  final Map<String, dynamic> branding;

  /// The uploads, so a setting that kept an upload's public address counts
  /// for that upload.
  final List<MediaAsset> assets;

  /// Rows of the catalogue tables that hold pictures: `table`
  /// (`ev_vehicle_details`, `ev_vehicle_inventory`, `vehicle_make_models`),
  /// `id`, and `values` (the EV tables) or `make`, `model`, `icon_uri`.
  final List<Map<String, dynamic>> catalogue;
}

final _imageExt = RegExp(r'\.(png|jpe?g|webp|gif|svg|bmp|ico)(\?.*)?$', caseSensitive: false);

/// The media key of a stored [value], or null when it names no picture:
/// a `media:` reference, an upload's public address, or another picture
/// address (http(s) with a picture's extension or in a storage bucket, or
/// a `data:image/` address).
String? mediaKeyOf(Object? value, {Map<String, String> idByPath = const {}}) {
  if (value is! String) return null;
  final v = value.trim();
  if (v.isEmpty) return null;
  final id = mediaRefId(v);
  if (id != null) return mediaRef(id);
  if (v.startsWith('data:image/')) return urlKey(v);
  if (v.startsWith('http://') || v.startsWith('https://')) {
    final path = mediaPathInUrl(v);
    if (path != null && idByPath[path] != null) return mediaRef(idByPath[path]!);
    if (path != null || _imageExt.hasMatch(v.split('#').first) || v.contains('/storage/v1/object/public/')) {
      return urlKey(v);
    }
  }
  return null;
}

/// "ShoppingBag" → "Shopping bag", "Building2" → "Building 2".
String iconDisplayName(String name) {
  final words = RegExp(r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+').allMatches(name).map((m) => m.group(0)!).toList();
  if (words.isEmpty) return name;
  final s = words.map((w) => w.toLowerCase()).join(' ');
  return s[0].toUpperCase() + s.substring(1);
}

String _text(Object? v) => v is String ? v.trim() : '';

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// Where each picture is used: `{media key: [uses]}`, the places in the
/// order the admin pages list them. A key with no uses is absent.
Map<String, List<MediaUse>> mediaUsageIndex(MediaUsageInput input) {
  final out = <String, List<MediaUse>>{};
  final idByPath = <String, String>{
    for (final a in input.assets) ...{?a.path: a.id, ?a.darkPath: a.id},
  };
  void add(String? key, MediaUse use) {
    if (key == null) return;
    final list = out.putIfAbsent(key, () => []);
    if (!list.contains(use)) list.add(use);
  }

  String? keyOf(Object? v) => mediaKeyOf(v, idByPath: idByPath);

  // Any picture under [value] that the specific readers above did not name.
  void sweep(Object? value, String Function(String path) label, String route, {String? highlight, String path = ''}) {
    if (value is Map) {
      for (final e in value.entries) {
        sweep(e.value, label, route, highlight: highlight, path: path.isEmpty ? '${e.key}' : '$path.${e.key}');
      }
    } else if (value is List) {
      for (var i = 0; i < value.length; i++) {
        sweep(value[i], label, route, highlight: highlight, path: path);
      }
    } else {
      add(keyOf(value), MediaUse(label(path), route, highlightId: highlight));
    }
  }

  _display(input.display, input.entries, add, keyOf, sweep);
  _entries(input.entries, add, keyOf, sweep);
  _appSettings(input.appSettings, add, sweep);
  _catalogue(input.catalogue, add, keyOf, sweep);

  // App Settings: the splash picture and an uploaded app icon (app_branding).
  const site = '/admin/m/site';
  add(keyOf(input.branding['splash_image_url']), const MediaUse('App Settings › Splash picture', site, highlightId: 'splash'));
  add(
    keyOf(input.branding['app_icon_url']),
    const MediaUse('App Settings › App icon (uploaded)', site, highlightId: 'app-icon', slot: MediaKind.logo),
  );
  return out;
}

typedef _Add = void Function(String? key, MediaUse use);
typedef _KeyOf = String? Function(Object? v);
typedef _Sweep = void Function(Object? value, String Function(String path) label, String route,
    {String? highlight, String path});

const _displayRoute = '/admin/m/display';

/// The side menu editor's path for [menu] (`user` / `partner`).
String sideMenuRoute(String menu) => '$_displayRoute/side-menu/$menu';

void _display(
  Map<String, dynamic> s,
  List<Map<String, dynamic>> entries,
  _Add add,
  _KeyOf keyOf,
  _Sweep sweep,
) {
  // Side menus: each built-in item's icon (or the one the admin gave it),
  // each custom item's.
  for (final (menu, who) in [('user', 'rider'), ('partner', 'driver')]) {
    final cfg = _map(s[menu == 'user' ? 'userMenu' : 'partnerMenu']);
    final renames = _map(cfg['renames']);
    final icons = _map(cfg['icons']);
    final hidden = {for (final h in (cfg['hidden'] is List ? cfg['hidden'] as List : const [])) '$h'};
    final route = sideMenuRoute(menu);
    String label(String id, String name) =>
        'Side menu ($who) › $name${hidden.contains(id) ? ' (hidden)' : ''}';
    for (final (id, defaultLabel) in defaultMenuItems(menu)) {
      final name = _text(renames[id]).isEmpty ? defaultLabel : _text(renames[id]);
      final own = _text(icons[id]);
      final icon = own.isNotEmpty ? own : defaultMenuIconNames[menu]?[id];
      if (icon == null) continue;
      add(keyOf(icon) ?? iconKey(icon), MediaUse(label(id, name), route, highlightId: id, slot: MediaKind.icon));
    }
    for (final c in (cfg['customItems'] is List ? cfg['customItems'] as List : const [])) {
      if (c is! Map || c['id'] is! String) continue;
      final id = c['id'] as String;
      final icon = _text(c['iconName']).isEmpty ? 'Star' : _text(c['iconName']);
      final name = _text(c['label']).isEmpty ? 'Custom item' : _text(c['label']);
      add(keyOf(icon) ?? iconKey(icon), MediaUse(label(id, name), route, highlightId: id, slot: MediaKind.icon));
    }
  }

  // Home service boxes: the picture, else the icon.
  final services = {
    for (final e in entries)
      if (e['category'] == 'service-settings') '${e['id']}': _text(_map(e['values'])['name']),
  };
  final boxes = normalizeBoxes(s['serviceBoxes']);
  for (var i = 0; i < boxes.length; i++) {
    final b = boxes[i];
    final linked = services[b['serviceId']] ?? '';
    final title = _text(b['name']).isNotEmpty
        ? _text(b['name'])
        : linked.isNotEmpty
        ? linked
        : serviceBoxPresets[i % serviceBoxPresets.length].$1.replaceAll('\n', ' ');
    final where = 'Home box ${i + 1} › $title';
    final image = keyOf(b['imageUri']);
    if (image != null) {
      add(image, MediaUse(where, _displayRoute, highlightId: 'service-box-$i'));
    } else {
      final icon = _text(b['iconName']);
      if (icon.isNotEmpty) {
        add(keyOf(icon) ?? iconKey(icon), MediaUse(where, _displayRoute, highlightId: 'service-box-$i', slot: MediaKind.icon));
      }
    }
  }

  // Ride Options: a picture per option (`rideOptions.images`).
  final options = RideOptionsConfig.fromSettings(s);
  final images = _map(_map(s[RideOptionsConfig.key])['images']);
  for (final k in options.order) {
    add(
      keyOf(images[k.id]),
      MediaUse('Ride Options › ${options.labelOf(k)}', _displayRoute, highlightId: 'ride-option-${k.id}'),
    );
  }

  // Assistance items: an icon in place of the emoji.
  for (final item in (s['assistanceCatalogue'] is List ? s['assistanceCatalogue'] as List : const [])) {
    if (item is! Map) continue;
    final icon = _text(item['icon']);
    if (icon.isEmpty) continue;
    add(
      keyOf(icon) ?? iconKey(icon),
      MediaUse('Ride Options › Assistance › ${_text(item['name'])}', _displayRoute,
          highlightId: 'ride-option-assistance', slot: MediaKind.icon),
    );
  }

  // The GET.ride wordmark on the sign-in screen.
  if (displayBool(s, 'signInLogo')) {
    add(wordmarkKey, const MediaUse('Sign-in screen › Logo', _displayRoute, highlightId: 'sign-in-logo', slot: MediaKind.logo));
  }

  // Anything else in the blob that holds a picture.
  const covered = {'userMenu', 'partnerMenu', 'serviceBoxes', 'assistanceCatalogue'};
  for (final e in s.entries) {
    if (covered.contains(e.key)) continue;
    if (e.key == RideOptionsConfig.key) {
      final rest = {..._map(e.value)}..remove('images');
      sweep(rest, (p) => 'Display Settings › Ride Options', _displayRoute, highlight: 'ride-options');
      continue;
    }
    sweep(e.value, (p) => 'Display Settings › ${_pathLabel(e.key, p)}', _displayRoute, path: e.key);
  }
}

String _pathLabel(String key, String path) => path.isEmpty || path == key ? key : path;

/// What the admin knows each `settings_entries` category by, and its page.
const _categoryPages = <String, (String, String)>{
  'vehicle-services': ('Vehicle Services', '/admin/m/vehicle-services'),
  'service-settings': ('Service Settings', '/admin/m/service-settings'),
  'partner-type': ('Partner Type', '/admin/m/partner-type'),
  'advertisement-banners': ('Advertisement Banners', '/admin/settings/advertisement-banners'),
  'payment-type': ('Payment Type', '/admin/m/payment-type'),
};

/// The picture fields of a vehicle service, as its editor names them.
const _vehicleServiceImages = {
  'iconUri': ('Vehicle icon', MediaKind.icon),
  'heroImageUri': ('Hero image', MediaKind.image),
  'mapIconUri': ('Map icon', MediaKind.icon),
};

String _categoryTitle(String category) {
  final words = category.split(RegExp(r'[-_]+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return category;
  final s = words.join(' ');
  return s[0].toUpperCase() + s.substring(1);
}

void _entries(List<Map<String, dynamic>> entries, _Add add, _KeyOf keyOf, _Sweep sweep) {
  for (final e in entries) {
    final category = '${e['category'] ?? ''}';
    final id = '${e['id'] ?? ''}';
    final v = _map(e['values']);
    final known = _categoryPages[category];
    final title = known?.$1 ?? _categoryTitle(category);
    final route = known?.$2 ?? '/admin/settings/$category';
    final name = [v['name'], v['title'], v['label'], v['platform']]
        .map(_text)
        .firstWhere((t) => t.isNotEmpty, orElse: () => 'Untitled');
    switch (category) {
      case 'vehicle-services':
        for (final f in _vehicleServiceImages.entries) {
          add(keyOf(v[f.key]), MediaUse('$title › $name (${f.value.$1})', route, highlightId: id, slot: f.value.$2));
        }
        sweep({...v}..removeWhere((k, _) => _vehicleServiceImages.containsKey(k)), (_) => '$title › $name', route,
            highlight: id);
      case 'service-settings':
        add(keyOf(v['iconUri']), MediaUse('$title › $name', route, highlightId: id, slot: MediaKind.icon));
        sweep({...v}..remove('iconUri'), (_) => '$title › $name', route, highlight: id);
      case 'payment-type':
        final icon = _text(v['icon']);
        if (icon.isNotEmpty) {
          add(keyOf(icon) ?? iconKey(icon), MediaUse('$title › $name', route, highlightId: id, slot: MediaKind.icon));
        }
        sweep({...v}..remove('icon'), (_) => '$title › $name', route, highlight: id);
      case 'partner-type':
        add(keyOf(v['iconUrl']), MediaUse('$title › $name', route, highlightId: id, slot: MediaKind.icon));
        sweep({...v}..remove('iconUrl'), (_) => '$title › $name', route, highlight: id);
      default:
        sweep(v, (_) => '$title › $name', route, highlight: id);
    }
  }
}

/// The catalogue tables' pictures: EV vehicles and makes and models.
const _cataloguePages = <String, (String, String)>{
  'ev_vehicle_details': ('EV Vehicle Details', '/admin/m/ev-vehicle-details'),
  'ev_vehicle_inventory': ('EV Vehicle Inventory', '/admin/m/ev-vehicle-inventory'),
  'vehicle_make_models': ('Vehicle Make & Model', '/admin/m/vehicle-make-model'),
};

void _catalogue(List<Map<String, dynamic>> rows, _Add add, _KeyOf keyOf, _Sweep sweep) {
  for (final r in rows) {
    final page = _cataloguePages['${r['table']}'];
    if (page == null) continue;
    final id = '${r['id'] ?? ''}';
    if (r['table'] == 'vehicle_make_models') {
      final name = '${_text(r['make'])} ${_text(r['model'])}'.trim();
      add(keyOf(r['icon_uri']), MediaUse('${page.$1} › ${name.isEmpty ? 'Untitled' : name}', page.$2, highlightId: id));
      continue;
    }
    final v = _map(r['values']);
    final name = [v['name'], v['model'], v['title'], v['vin']]
        .map(_text)
        .firstWhere((t) => t.isNotEmpty, orElse: () => 'Untitled');
    sweep(v, (_) => '${page.$1} › $name', page.$2, highlight: id);
  }
}

void _appSettings(List<Map<String, dynamic>> rows, _Add add, _Sweep sweep) {
  final byKey = {for (final r in rows) '${r['key']}': r['value']};
  // The home-screen icon (Admin → App Settings): the fixed one, else each
  // window of the schedule and the standard icon outside them.
  const site = '/admin/m/site';
  final icons = AppIconConfig.fromJson(byKey[appIconSettingKey]);
  if (!icons.automatic) {
    add(appIconKey(icons.fixedIcon),
        const MediaUse('App Settings › Home-screen icon (for everyone)', site, highlightId: 'app-icon', slot: MediaKind.logo));
  } else {
    for (final w in icons.schedule) {
      if (!w.enabled) continue;
      add(
        appIconKey(w.icon),
        MediaUse('App Settings › Icon schedule, ${w.start} to ${w.end}', site, highlightId: 'app-icon', slot: MediaKind.logo),
      );
    }
    add(appIconKey(standardAppIcon),
        const MediaUse('App Settings › Home-screen icon (outside the schedule)', site, highlightId: 'app-icon', slot: MediaKind.logo));
  }

  final titles = {for (final s in pageInventory) s.id: s.title};
  for (final e in byKey.entries) {
    if (e.key == appIconSettingKey) continue;
    if (e.key.startsWith('page_style:')) {
      final surface = e.key.substring('page_style:'.length);
      sweep(e.value, (_) => 'App Page Settings › ${titles[surface] ?? surface}', '/admin/m/page-settings',
          highlight: surface);
    } else {
      sweep(e.value, (_) => 'App settings › ${e.key}', site);
    }
  }
}

// ---------------------------------------------------------------------------
// The gallery's items
// ---------------------------------------------------------------------------

/// Where an item comes from: built into the app, uploaded to the gallery, or
/// a picture a setting holds that was uploaded on its own page.
enum MediaSource { builtIn, uploaded, found }

/// One tile of the gallery.
class GalleryItem {
  const GalleryItem({
    required this.key,
    required this.kind,
    required this.name,
    required this.source,
    this.uses = const [],
    this.iconName,
    this.assetPath,
    this.assetDarkPath,
    this.asset,
    this.uri,
  });

  /// Its media key ([mediaUsageIndex]).
  final String key;
  final MediaKind kind;
  final String name;
  final MediaSource source;
  final List<MediaUse> uses;

  /// A built-in icon's name.
  final String? iconName;

  /// A built-in picture's file in the app (light, dark).
  final String? assetPath, assetDarkPath;

  /// An upload.
  final MediaAsset? asset;

  /// A found picture's address.
  final String? uri;

  bool get used => uses.isNotEmpty;

  /// Only an upload no setting uses can go.
  bool get deletable => source == MediaSource.uploaded && uses.isEmpty;

  /// The text the gallery's search looks in.
  String get searchText => [name, ?iconName, for (final u in uses) u.label].join(' ').toLowerCase();
}

/// The built-in home-screen icons shown as logos (the brand marks); the
/// festival and sale ones are images.
const brandAppIcons = {'standard', 'g_dot', 'get_dot'};

/// Every tile: the uploads (newest first), the pictures found in settings,
/// then the built-in icons ([builtInIcons], by name), the home-screen icons
/// and the wordmark, each with its uses from [usage].
List<GalleryItem> galleryItems({
  required Iterable<String> builtInIcons,
  List<MediaAsset> assets = const [],
  Map<String, List<MediaUse>> usage = const {},
}) {
  List<MediaUse> uses(String key) => usage[key] ?? const [];
  final sorted = [...assets]
    ..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
  final uploads = [
    for (final a in sorted)
      GalleryItem(key: a.ref, kind: a.kind, name: a.name, source: MediaSource.uploaded, uses: uses(a.ref), asset: a),
  ];
  final found = [
    for (final e in usage.entries)
      if (e.key.startsWith('url:'))
        GalleryItem(
          key: e.key,
          kind: e.value.first.slot,
          name: e.value.first.label.split(' › ').last,
          source: MediaSource.found,
          uses: e.value,
          uri: e.key.substring(4),
        ),
  ];
  final names = {...builtInIcons};
  return [
    ...uploads,
    ...found,
    for (final n in names)
      GalleryItem(
        key: iconKey(n),
        kind: MediaKind.icon,
        name: iconDisplayName(n),
        source: MediaSource.builtIn,
        uses: uses(iconKey(n)),
        iconName: n,
      ),
    GalleryItem(
      key: wordmarkKey,
      kind: MediaKind.logo,
      name: 'GET.ride wordmark',
      source: MediaSource.builtIn,
      uses: uses(wordmarkKey),
    ),
    for (final i in appIcons)
      GalleryItem(
        key: appIconKey(i.id),
        kind: brandAppIcons.contains(i.id) ? MediaKind.logo : MediaKind.image,
        name: brandAppIcons.contains(i.id) ? 'App icon: ${i.name}' : 'Home-screen icon: ${i.name}',
        source: MediaSource.builtIn,
        uses: uses(appIconKey(i.id)),
        assetPath: i.preview(dark: false),
        assetDarkPath: i.preview(dark: true),
      ),
  ];
}

/// The gallery's filter chips.
enum GalleryFilter {
  all('All'),
  inUse('In use'),
  notUsed('Not used'),
  uploaded('Uploaded');

  const GalleryFilter(this.label);
  final String label;
}

/// The tiles of [kind] that [filter] and the search [query] keep.
List<GalleryItem> filterGallery(
  List<GalleryItem> items, {
  required MediaKind kind,
  GalleryFilter filter = GalleryFilter.all,
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  return [
    for (final i in items)
      if (i.kind == kind &&
          switch (filter) {
            GalleryFilter.all => true,
            GalleryFilter.inUse => i.used,
            GalleryFilter.notUsed => !i.used,
            GalleryFilter.uploaded => i.source == MediaSource.uploaded,
          } &&
          (q.isEmpty || i.searchText.contains(q)))
        i,
  ];
}

/// Whether anything uses [asset] (its reference, or its file's address).
bool mediaAssetInUse(MediaAsset asset, Map<String, List<MediaUse>> usage) => (usage[asset.ref] ?? const []).isNotEmpty;
