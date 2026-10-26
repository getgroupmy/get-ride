/// The rider's home page as sections (Admin → Display Settings → Home page):
/// what shows under the map, in which order, and which are switched on. A
/// master layout, and any country, state, city or suburb with its own; a
/// place without one follows the nearest place above it that has one, else
/// the master. Pure.
library;

import 'partner_type_rules.dart' show RegionScope;
import 'ride_option_places.dart' show OptionPlaceScope;

/// The kinds of section. The built-in ones are the parts the home screen
/// had before sections: each is there exactly once, can be moved and
/// switched off, never removed.
enum HomeSectionType {
  search('search', 'Search bar'),
  vehicles('vehicles', 'Vehicle bar'),
  pickup('pickup', 'Pickup row'),
  upcoming('upcoming', 'Upcoming ride'),
  recent('recent', 'Recent places'),
  boxes('boxes', 'Service boxes'),
  fold('fold', 'Sheet fold');

  const HomeSectionType(this.key, this.label);
  final String key;
  final String label;

  static HomeSectionType? of(Object? key) {
    for (final t in values) {
      if (t.key == key) return t;
    }
    return null;
  }
}

/// What the search bar says unless the admin words it.
const homeSearchDefaultText = 'Where to & for how much?';
const homeSearchMaxText = 60;

/// Recent places with the sheet all the way down: 0 to 4, 2 unless set.
const homeRecentAtRestDefault = 2;
const homeRecentAtRestMax = 4;

class HomeSection {
  const HomeSection(this.raw);

  /// The stored map, kept whole so keys this version doesn't know survive a
  /// save from it.
  final Map<String, dynamic> raw;

  factory HomeSection.of(HomeSectionType type, {bool on = true, Map<String, dynamic> extra = const {}}) =>
      HomeSection({'id': type.key, 'type': type.key, 'on': on, ...extra});

  /// Null for a kind this version doesn't know (a newer app's): kept, not shown.
  HomeSectionType? get type => HomeSectionType.of(raw['type']);
  String get id => '${raw['id'] ?? raw['type'] ?? ''}';

  /// The fold is a line, not a part: it is always "on".
  bool get on => type == HomeSectionType.fold || raw['on'] != false;

  /// The search bar's words.
  String get text {
    final t = '${raw['text'] ?? ''}'.trim();
    if (t.isEmpty) return homeSearchDefaultText;
    return t.length > homeSearchMaxText ? t.substring(0, homeSearchMaxText) : t;
  }

  /// How many recent places show with the sheet down.
  int get atRest {
    final v = raw['atRest'];
    final n = v is num ? v.round() : int.tryParse('$v');
    return (n ?? homeRecentAtRestDefault).clamp(0, homeRecentAtRestMax);
  }

  /// Whether the rest of the recent places show with the sheet up.
  bool get more => raw['more'] != false;

  HomeSection copyWith(Map<String, dynamic> patch) => HomeSection({...raw, ...patch});

  Map<String, dynamic> toJson() => raw;
}

class HomeLayout {
  const HomeLayout(this.sections);

  final List<HomeSection> sections;

  /// Today's home screen as the old Display Settings switches have it:
  /// search bar, vehicle bar, the pickup row (only with the map's pickup
  /// box off), upcoming ride, recent places, service boxes, then the fold.
  factory HomeLayout.legacy(Map<String, dynamic> settings) {
    bool flag(String k, bool d) {
      final v = settings[k];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final t = v.trim().toLowerCase();
        if (t == 'false' || t == '0' || t == 'off') return false;
        if (t == 'true' || t == '1' || t == 'on') return true;
      }
      return d;
    }

    return HomeLayout([
      HomeSection.of(HomeSectionType.search, on: flag('searchBar', true)),
      HomeSection.of(HomeSectionType.vehicles, on: flag('rideTypes', true)),
      HomeSection.of(HomeSectionType.pickup, on: !flag('addressBar', true)),
      HomeSection.of(HomeSectionType.upcoming),
      HomeSection.of(HomeSectionType.recent, on: flag('recentLocations', true)),
      HomeSection.of(HomeSectionType.boxes, on: flag('serviceCategories', false)),
      HomeSection.of(HomeSectionType.fold),
    ]);
  }

  /// A stored layout made whole: every built-in part once (a missing one
  /// takes its place from [base], switched as there), duplicates dropped,
  /// sections this version doesn't know kept where they are.
  factory HomeLayout.fromJson(Object? raw, {required HomeLayout base}) {
    final list = raw is Map ? raw['sections'] : null;
    final out = <HomeSection>[];
    final seen = <HomeSectionType>{};
    if (list is List) {
      for (final s in list) {
        if (s is! Map) continue;
        final section = HomeSection(Map<String, dynamic>.from(s));
        final t = section.type;
        if (t != null && !seen.add(t)) continue;
        out.add(section);
      }
    }
    // Missing built-ins go back where the base has them: after the section
    // the base puts before them.
    for (var i = 0; i < base.sections.length; i++) {
      final b = base.sections[i];
      final t = b.type;
      if (t == null || seen.contains(t)) continue;
      seen.add(t);
      final before = i == 0 ? null : base.sections[i - 1].type;
      final at = before == null ? 0 : out.indexWhere((s) => s.type == before) + 1;
      out.insert(at.clamp(0, out.length), b);
    }
    return HomeLayout(out);
  }

  Map<String, dynamic> toJson() => {'sections': [for (final s in sections) s.toJson()]};

  HomeSection? of(HomeSectionType t) => sections.where((s) => s.type == t).firstOrNull;

  /// Whether [t] shows (the fold always "shows").
  bool shows(HomeSectionType t) => of(t)?.on ?? false;

  /// The sections that draw, in order (switched on, of a kind this version
  /// knows), with the fold among them.
  List<HomeSection> get shown => [for (final s in sections) if (s.type != null && s.on) s];

  HomeLayout moved(int from, int to) {
    final list = [...sections];
    if (from < 0 || from >= list.length || to < 0 || to >= list.length) return this;
    list.insert(to, list.removeAt(from));
    return HomeLayout(list);
  }

  HomeLayout edited(String id, Map<String, dynamic> patch) =>
      HomeLayout([for (final s in sections) s.id == id ? s.copyWith(patch) : s]);
}

/// Blob keys (`admin_display_settings`, row global).
const homeLayoutKey = 'homeLayout';
const homeLayoutPlacesKey = 'homeLayoutPlaces';

/// The master layout and the places with their own.
class HomeLayouts {
  const HomeLayouts({required this.master, this.places = const {}, this.masterSaved = false});

  /// What the old switches give when the admin never saved a layout.
  final HomeLayout master;

  /// Whether [master] was saved (else it is read off the old switches).
  final bool masterSaved;

  /// By [RegionScope.key]: the place and its layout.
  final Map<String, ({RegionScope place, HomeLayout layout})> places;

  factory HomeLayouts.fromSettings(Map<String, dynamic> settings) {
    final legacy = HomeLayout.legacy(settings);
    final rawMaster = settings[homeLayoutKey];
    final master = rawMaster is Map ? HomeLayout.fromJson(rawMaster, base: legacy) : legacy;
    final out = <String, ({RegionScope place, HomeLayout layout})>{};
    final list = settings[homeLayoutPlacesKey];
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue;
        final place = RegionScope.fromJson(e['place']);
        if (place.isAll || out.containsKey(place.key)) continue;
        out[place.key] = (place: place, layout: HomeLayout.fromJson(e['layout'], base: master));
      }
    }
    return HomeLayouts(master: master, places: out, masterSaved: rawMaster is Map);
  }

  /// The place whose layout [place] uses: its own, else the nearest place
  /// above it with one; null for the master.
  RegionScope? sourceFor(RegionScope? place) {
    for (final s in (place ?? RegionScope.all).chain) {
      if (s.isAll) break;
      if (places.containsKey(s.key)) return places[s.key]!.place;
    }
    return null;
  }

  /// The layout a rider at [place] sees.
  HomeLayout layoutFor(RegionScope? place) {
    final s = sourceFor(place);
    return s == null ? master : places[s.key]!.layout;
  }

  /// The layout being edited for [place] (null: the master); null when the
  /// place has none of its own.
  HomeLayout? ownLayout(RegionScope? place) =>
      place == null || place.isAll ? master : places[place.key]?.layout;
}

/// Display settings with [layout] as the master.
Map<String, dynamic> withMasterHomeLayout(Map<String, dynamic> s, HomeLayout layout) =>
    {...s, homeLayoutKey: layout.toJson()};

/// Display settings with [place]'s own layout set to [layout], or dropped
/// (it follows again) when null.
Map<String, dynamic> withPlaceHomeLayout(Map<String, dynamic> s, RegionScope place, HomeLayout? layout) {
  final list = s[homeLayoutPlacesKey];
  final kept = [
    if (list is List)
      for (final e in list)
        if (e is Map && RegionScope.fromJson(e['place']).key != place.key) e,
  ];
  return {
    ...s,
    homeLayoutPlacesKey: [
      ...kept,
      if (layout != null) {'place': place.toJson(), 'layout': layout.toJson()},
    ],
  };
}
