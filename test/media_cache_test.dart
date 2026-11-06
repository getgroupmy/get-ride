// The pure planning of the on-device media cache (data/media_cache.dart):
// what a sync downloads and removes, and how an asset's files are fingerprinted
// so a re-upload (changed bytes) re-downloads.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/media_assets.dart';
import 'package:get_ride/src/data/media_cache.dart';

void main() {
  group('mediaCachePlan', () {
    test('downloads what is new or changed, removes what is gone', () {
      final wanted = {'a': 'v1', 'b': 'v2', 'c': 'v1'};
      final have = {'a': 'v1', 'b': 'v1', 'd': 'v1'};
      final plan = mediaCachePlan(wanted, have);
      expect(plan.download, {'b', 'c'}); // b changed, c new; a is unchanged
      expect(plan.remove, {'d'}); // d is no longer wanted
    });

    test('nothing to do when the set matches', () {
      final m = {'a': 'v1', 'b': 'v2'};
      final plan = mediaCachePlan(m, Map.of(m));
      expect(plan.download, isEmpty);
      expect(plan.remove, isEmpty);
    });

    test('an empty wanted set removes everything cached', () {
      final plan = mediaCachePlan({}, {'a': 'v1', 'b': 'v1'});
      expect(plan.download, isEmpty);
      expect(plan.remove, {'a', 'b'});
    });
  });

  group('mediaCacheWanted', () {
    test('every file of an asset shares its fingerprint', () {
      final logo = MediaAsset(
        id: 'L', kind: MediaKind.logo, name: 'logo',
        path: 'logo/L.png', darkPath: 'logo/L-dark.png', mime: 'image/png', bytes: 100,
      );
      final w = mediaCacheWanted([logo]);
      expect(w.keys, containsAll(['logo/L.png', 'logo/L-dark.png']));
      expect(w['logo/L.png'], w['logo/L-dark.png']);
    });

    test('a re-upload (changed bytes) changes the fingerprint', () {
      MediaAsset at(int bytes) => MediaAsset(
            id: 'I', kind: MediaKind.icon, name: 'i', path: 'icon/I.png', mime: 'image/png', bytes: bytes,
          );
      final before = mediaCacheWanted([at(100)]);
      final after = mediaCacheWanted([at(200)]);
      expect(after['icon/I.png'], isNot(before['icon/I.png']));
    });

    test('ignores an asset with no files', () {
      const empty = MediaAsset(id: 'E', kind: MediaKind.icon, name: 'e');
      expect(mediaCacheWanted([empty]), isEmpty);
    });
  });
}
