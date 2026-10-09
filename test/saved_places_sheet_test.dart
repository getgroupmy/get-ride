// The route sheet's Saved tab, the map picker and the saved-place form
// (inDrive's "Enter your route" → Saved, the map with Done, "Editing Home").
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/saved_places.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/saved_places_repository.dart';
import 'package:get_ride/src/features/ride/map_place_picker.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/features/ride/saved_place_form.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

const _eco = LatLng(2.9300, 101.8300);
const _home = SavedPlace(
  id: 'h1',
  kind: SavedPlaceKind.home,
  name: 'Home',
  address: '25, Jalan Eco Majestic 1/2C',
  point: _eco,
  entrance: 'Gate B',
);
const _klcc = SavedPlace(id: 'o1', kind: SavedPlaceKind.other, name: 'KLCC', address: 'KLCC', point: LatLng(3.158, 101.712));

class _Repo implements SavedPlacesRepository {
  final saved = <SavedPlace>[];
  final deleted = <String>[];

  @override
  Future<SavedPlace?> save(SavedPlace p) async {
    saved.add(p);
    return p;
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// A geocoder that names every point "Spot".
class _Geo extends GeoService {
  _Geo() : super(client: MockClient((_) async => http.Response('', 500)));

  @override
  Future<Place> reverse(LatLng p) async => Place(name: 'Spot', address: 'Spot, Semenyih', point: p);
}

Future<void> _open(
  WidgetTester tester, {
  required List<SavedPlace> places,
  String? uid = 'me',
  _Repo? repo,
  void Function(PlacePick?)? onPick,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(500, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        recentPlacesProvider.overrideWith((ref) async => const []),
        savedPlacesProvider.overrideWith((ref) async => places),
        currentUserIdProvider.overrideWithValue(uid),
        savedPlacesRepositoryProvider.overrideWithValue(repo ?? _Repo()),
        geoServiceProvider.overrideWithValue(_Geo()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final pick = await showPlaceSearch(
                  context,
                  title: 'Enter your route',
                  near: _eco,
                  from: const Place(name: 'Eco Majestic', address: '', point: _eco),
                );
                onPick?.call(pick);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('From above the field; Saved lists Home, Add Work, Another place and the others', (tester) async {
    await _open(tester, places: const [_klcc, _home]);
    expect(find.byKey(const ValueKey('place-search-from')), findsOneWidget);
    expect(find.text('Eco Majestic'), findsOneWidget);
    expect(find.byKey(const ValueKey('place-search-map')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('place-tab-saved')));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('0km'), findsOneWidget);
    expect(find.byKey(const ValueKey('saved-add-home')), findsNothing);
    expect(find.byKey(const ValueKey('saved-add-work')), findsOneWidget);
    expect(find.byKey(const ValueKey('saved-add-other')), findsOneWidget);
    expect(find.text('KLCC'), findsWidgets);
    expect(find.byKey(const ValueKey('saved-edit-o1')), findsOneWidget);
  });

  testWidgets('a saved place is picked with its entrance', (tester) async {
    PlacePick? picked;
    await _open(tester, places: const [_home], onPick: (p) => picked = p);
    await tester.tap(find.byKey(const ValueKey('place-tab-saved')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(picked?.place?.name, 'Home');
    expect(picked?.place?.address, '25, Jalan Eco Majestic 1/2C');
    expect(picked?.entrance, 'Gate B');
  });

  testWidgets('signed out, Saved asks to sign in', (tester) async {
    await _open(tester, places: const [], uid: null);
    await tester.tap(find.byKey(const ValueKey('place-tab-saved')));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to save your places'), findsOneWidget);
  });

  testWidgets('the map picker names the spot, then Done hands it back', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.reset);
    Place? got;
    await tester.pumpWidget(ProviderScope(
      overrides: [geoServiceProvider.overrideWithValue(_Geo())],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => got = await pickPlaceOnMap(context, start: _eco),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('map-picker-name')), findsOneWidget);
    expect(find.text('Spot'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('map-picker-done')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(got?.name, 'Spot');
    expect(got?.point, _eco);
  });

  testWidgets('a new other place needs a name; saving stores the entrance', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.reset);
    final repo = _Repo();
    await tester.pumpWidget(ProviderScope(
      overrides: [savedPlacesRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSavedPlaceForm(
              context,
              const SavedPlace(kind: SavedPlaceKind.other, name: '', address: 'KLCC', point: LatLng(3.158, 101.712)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Save place'), findsWidgets);
    FilledButton save() => tester.widget<FilledButton>(find.byKey(const ValueKey('saved-place-save')));
    expect(save().onPressed, isNull, reason: 'no name yet');
    await tester.enterText(find.byKey(const ValueKey('saved-place-name')), 'KLCC');
    await tester.enterText(find.byKey(const ValueKey('saved-place-entrance')), 'Lobby');
    await tester.pump();
    expect(save().onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('saved-place-save')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(repo.saved.single.name, 'KLCC');
    expect(repo.saved.single.entrance, 'Lobby');
  });

  testWidgets('editing Home: the entrance changes, and the place can be deleted', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.reset);
    final repo = _Repo();
    await tester.pumpWidget(ProviderScope(
      overrides: [savedPlacesRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Builder(
          builder: (context) =>
              TextButton(onPressed: () => showSavedPlaceForm(context, _home), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Editing Home'), findsOneWidget);
    expect(find.byKey(const ValueKey('saved-place-name')), findsNothing, reason: 'Home has no name of its own');
    await tester.tap(find.byKey(const ValueKey('saved-place-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('saved-place-delete-confirm')));
    await tester.pumpAndSettle();
    expect(repo.deleted, ['h1']);
  });
}
