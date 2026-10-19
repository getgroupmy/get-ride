// The map profile on a first launch (nothing kept on the device) and when
// app settings change (lib/src/data/map_profile_repository.dart, PERF-68).
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/map_profile_repository.dart';

const _set = MapProfile(search: ['google']);

class _Repo implements MapProfileRepository {
  _Repo({this.keptProfile});
  final MapProfile? keptProfile;
  int fetches = 0;
  Completer<MapProfile> answer = Completer<MapProfile>();

  @override
  Future<MapProfile> fetch(String role) {
    fetches++;
    return answer.future;
  }

  @override
  Future<MapProfile?> kept(String role) async => keptProfile;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Live extends LiveTables {
  @override
  Map<String, int> build() => const {};

  void bump(List<String> tables) => state = bumpRevisions(state, tables);
}

ProviderContainer _container(_Repo repo) => ProviderContainer(
  overrides: [
    mapProfileRepositoryProvider.overrideWithValue(repo),
    liveTablesProvider.overrideWith(_Live.new),
  ],
);

void main() {
  tearDown(() => applyMapProfile(MapProfile.builtIn));

  test('first launch: blank only briefly, then the app\'s own map, then the fetched one', () {
    fakeAsync((clock) {
      final repo = _Repo();
      final c = _container(repo);
      waitForMapProfile();
      c.listen(mapProfileProvider, (_, _) {});
      clock.flushMicrotasks();
      expect(mapProfileListenable.value, isNull);

      clock.elapse(mapProfileFirstWait);
      expect(mapProfileListenable.value, same(MapProfile.builtIn), reason: 'no 8 s blank map');

      repo.answer.complete(_set);
      clock.flushMicrotasks();
      expect(mapProfileListenable.value, same(_set));
      expect(c.read(mapProfileProvider).value, same(_set));
      c.dispose();
    });
  });

  test('first launch with a fast answer goes straight to the fetched profile', () {
    fakeAsync((clock) {
      final repo = _Repo();
      final c = _container(repo);
      waitForMapProfile();
      final seen = <MapProfile?>[];
      void record() => seen.add(mapProfileListenable.value);
      mapProfileListenable.addListener(record);
      c.listen(mapProfileProvider, (_, _) {});
      clock.elapse(const Duration(milliseconds: 300));
      repo.answer.complete(_set);
      clock.elapse(const Duration(seconds: 2));
      mapProfileListenable.removeListener(record);
      expect(seen, [same(_set)]);
      c.dispose();
    });
  });

  test('a kept profile draws at once', () {
    fakeAsync((clock) {
      const kept = MapProfile(search: ['here']);
      final repo = _Repo(keptProfile: kept);
      final c = _container(repo);
      waitForMapProfile();
      c.listen(mapProfileProvider, (_, _) {});
      clock.flushMicrotasks();
      expect(mapProfileListenable.value, same(kept));
      c.dispose();
    });
  });

  test('geo is given up on after 4 s', () {
    fakeAsync((clock) {
      final repo = _Repo();
      final c = _container(repo);
      waitForMapProfile();
      c.listen(mapProfileProvider, (_, _) {});
      clock.elapse(mapProfileFetchTimeout);
      expect(mapProfileFetchTimeout, lessThanOrEqualTo(const Duration(seconds: 4)));
      expect(c.read(mapProfileProvider).value, same(MapProfile.builtIn));
      c.dispose();
    });
  });

  test('a page-style or icon save does not ask geo again; a map settings change does', () async {
    final repo = _Repo()..answer.complete(_set);
    final c = _container(repo);
    addTearDown(c.dispose);
    c.listen(mapProfileProvider, (_, _) {});
    await c.read(mapProfileProvider.future);
    expect(repo.fetches, 1);

    final live = c.read(liveTablesProvider.notifier) as _Live;
    for (final key in ['page_style:home', 'app_icon', 'fare_ai_provider']) {
      live.bump(liveRevisionsFor('app_settings', {'key': key}, {'key': key}));
    }
    await c.read(mapProfileProvider.future);
    expect(repo.fetches, 1);

    live.bump(liveRevisionsFor('app_settings', {'key': 'map_config'}, {'key': 'map_config'}));
    await c.read(mapProfileProvider.future);
    expect(repo.fetches, 2);

    live.bump(liveRevisionsFor('app_settings', const {}, {'key': 'api_providers'}));
    await c.read(mapProfileProvider.future);
    expect(repo.fetches, 3);
  });

  group('liveRevisionsFor', () {
    test('other tables move only themselves', () {
      expect(liveRevisionsFor('app_branding', {'key': 'map_config'}, const {}), ['app_branding']);
    });
    test('every app_settings row still moves app_settings for its other readers', () {
      expect(liveRevisionsFor('app_settings', {'key': 'page_style:home'}, const {}), ['app_settings']);
      expect(liveRevisionsFor('app_settings', {'key': 'map_config'}, const {}), ['app_settings', liveMapSettings]);
      expect(liveRevisionsFor('app_settings', const {}, {'key': 'api_providers'}), ['app_settings', liveMapSettings]);
    });
    test('a row whose key is not known moves the map settings too, to be safe', () {
      expect(liveRevisionsFor('app_settings', const {}, const {}), ['app_settings', liveMapSettings]);
    });
  });
}
