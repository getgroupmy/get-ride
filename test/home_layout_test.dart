import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart' show sheetItemEstimates;
import 'package:get_ride/src/admin/screens/meterapp/home_layout_screen.dart';
import 'package:get_ride/src/core/home_layout.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/sheet_min_height.dart' show homeSheetMinAdjustKey;

List<String> order(HomeLayout l) => [for (final s in l.sections) s.id];
List<String> shown(HomeLayout l) => [for (final s in l.shown) s.id];

void main() {
  const kl = RegionScope(country: 'Malaysia', state: 'Kuala Lumpur');
  const penang = RegionScope(country: 'Malaysia', state: 'Penang');
  const georgeTown = RegionScope(country: 'Malaysia', state: 'Penang', city: 'George Town');

  test("with nothing saved, today's home screen as the old switches have it", () {
    final l = HomeLayouts.fromSettings(const {}).master;
    expect(order(l), ['search', 'vehicles', 'pickup', 'upcoming', 'recent', 'boxes', 'fold']);
    // The pickup row only with the map's pickup box off; the boxes start off.
    expect(shown(l), ['search', 'vehicles', 'upcoming', 'recent', 'fold']);
    final off = HomeLayouts.fromSettings({'rideTypes': false, 'addressBar': false, 'serviceCategories': true}).master;
    expect(shown(off), ['search', 'pickup', 'upcoming', 'recent', 'boxes', 'fold']);
    expect(HomeLayouts.fromSettings(const {}).masterSaved, isFalse);
  });

  test('a saved layout is made whole: each part once, missing ones back in place, unknown kept', () {
    final l = HomeLayouts.fromSettings({
      'serviceCategories': true,
      homeLayoutKey: {
        'sections': [
          {'id': 'boxes', 'type': 'boxes', 'on': true},
          {'id': 'search', 'type': 'search', 'text': 'Ke mana?'},
          {'id': 'search2', 'type': 'search'},
          {'id': 'fold', 'type': 'fold', 'on': false},
          {'id': 'x', 'type': 'hologram', 'title': 'From a newer app'},
          'junk',
        ],
      },
    }).master;
    expect(order(l), ['boxes', 'search', 'vehicles', 'pickup', 'upcoming', 'recent', 'fold', 'x']);
    expect(l.of(HomeSectionType.search)!.text, 'Ke mana?');
    // The fold always counts as shown; a kind this version doesn't know never draws.
    expect(l.shows(HomeSectionType.fold), isTrue);
    expect(shown(l), isNot(contains('x')));
    expect(l.toJson()['sections'], contains(containsPair('title', 'From a newer app')));
  });

  test('section values: the search words and recent places counts', () {
    expect(HomeSection.of(HomeSectionType.search).text, homeSearchDefaultText);
    expect(HomeSection.of(HomeSectionType.search, extra: {'text': '  '}).text, homeSearchDefaultText);
    expect(HomeSection.of(HomeSectionType.search, extra: {'text': 'x' * 90}).text.length, homeSearchMaxText);
    final r = HomeSection.of(HomeSectionType.recent);
    expect((r.atRest, r.more), (2, true));
    expect(HomeSection.of(HomeSectionType.recent, extra: {'atRest': 9, 'more': false}).atRest, homeRecentAtRestMax);
    expect(HomeSection.of(HomeSectionType.recent, extra: {'atRest': '-1'}).atRest, 0);
  });

  test('moving and editing', () {
    final l = HomeLayouts.fromSettings(const {}).master;
    expect(order(l.moved(5, 0)).first, 'boxes');
    expect(identical(l.moved(0, 99), l), isTrue);
    expect(l.edited('search', {'on': false}).shows(HomeSectionType.search), isFalse);
  });

  test("a place uses its own layout, else the nearest above it, else the master", () {
    var s = <String, dynamic>{};
    final master = HomeLayouts.fromSettings(s).master;
    s = withPlaceHomeLayout(s, penang, master.edited('boxes', {'on': true}));
    final ls = HomeLayouts.fromSettings(s);
    expect(ls.sourceFor(georgeTown), penang);
    expect(ls.layoutFor(georgeTown).shows(HomeSectionType.boxes), isTrue);
    expect(ls.sourceFor(kl), isNull);
    expect(ls.layoutFor(kl).shows(HomeSectionType.boxes), isFalse);
    expect(ls.layoutFor(null).shows(HomeSectionType.boxes), isFalse);
    expect(ls.ownLayout(georgeTown), isNull);
    expect(ls.ownLayout(RegionScope.all), isNotNull);

    // Going back to following drops the place's own; the rest stay.
    s = withPlaceHomeLayout(s, kl, master);
    s = withPlaceHomeLayout(s, penang, null);
    final after = HomeLayouts.fromSettings(s);
    expect(after.places.keys, [kl.key]);
    expect(after.sourceFor(georgeTown), isNull);

    // The master once saved no longer reads the old switches.
    s = withMasterHomeLayout({...s, 'rideTypes': true}, master.edited('vehicles', {'on': false}));
    expect(HomeLayouts.fromSettings({...s, 'rideTypes': true}).master.shows(HomeSectionType.vehicles), isFalse);
  });

  test('admin: places to pick and the names shown', () {
    final ls = HomeLayouts.fromSettings(withPlaceHomeLayout(const {}, georgeTown, HomeLayout.legacy(const {})));
    final choices = homeLayoutPlaceChoices(const [], ls);
    expect(choices.first, RegionScope.all);
    expect(choices, contains(georgeTown));
    expect(homeLayoutPlaceName(null), 'Master');
    expect(homeLayoutPlaceName(georgeTown), 'George Town');
    expect(homeSectionHelp(HomeSection.of(HomeSectionType.search, on: false)), contains('Ride'));
    expect(homeSectionHelp(HomeSection.of(HomeSectionType.recent, extra: {'atRest': 3, 'more': false})),
        '3 with the sheet down');
  });

  test('the sheet height estimate follows the master layout down to the fold', () {
    final saved = withMasterHomeLayout(
      const {},
      HomeLayouts.fromSettings(const {'serviceCategories': true}).master.moved(5, 0).moved(6, 1),
    );
    // boxes, fold, search, ...: only the boxes are above the fold.
    expect([for (final e in sheetItemEstimates(homeSheetMinAdjustKey, saved)) e.label], ['Service Categories']);
    expect([for (final e in sheetItemEstimates(homeSheetMinAdjustKey, const {})) e.label],
        ['Search Bar', 'Vehicle Types Bar', 'Recent Locations']);
  });
}
