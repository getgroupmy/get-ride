// Document links that need a signed URL once their bucket is private
// (lib/src/core/storage_links.dart, lib/src/data/storage_links.dart).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/storage_links.dart';
import 'package:get_ride/src/data/storage_links.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const base = 'https://rqlavogkgywxspuxgiwk.supabase.co/storage/v1/object';

/// A client whose storage answers createSignedUrls like the server does
/// (a per-path error for a file whose name holds "missing", and for the
/// thumbnail of one whose name holds "nothumb"), noting each
/// call's bucket and paths in [calls].
SupabaseClient _signingClient(List<({String bucket, List<String> paths})> calls) {
  final db = SupabaseClient(
    'http://localhost',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((r) async {
      final bucket = r.url.pathSegments.last;
      final paths = ((jsonDecode(r.body) as Map)['paths'] as List).cast<String>();
      calls.add((bucket: bucket, paths: paths));
      return http.Response(
        jsonEncode([
          for (final p in paths)
            p.contains('missing') || (p.contains('nothumb') && p.endsWith('.thumb.jpg'))
                ? {'path': p, 'error': 'Either the object does not exist or you do not have access to it', 'signedURL': null}
                : {'path': p, 'signedURL': '/object/sign/$bucket/$p?token=t'},
        ]),
        200,
        request: r,
      );
    }),
  );
  addTearDown(db.dispose);
  return db;
}

void main() {
  group('privateStorageRef', () {
    test('reads the bucket and path of a public document link', () {
      expect(privateStorageRef('$base/public/vehicle-documents/v1/photos/front-1.jpg'), (
        bucket: 'vehicle-documents',
        path: 'v1/photos/front-1.jpg',
      ));
      expect(privateStorageRef('$base/public/ID_Image/u1/MY_0123_01012026.png'), (
        bucket: 'ID_Image',
        path: 'u1/MY_0123_01012026.png',
      ));
    });

    test('also a signed or authenticated link, without its token', () {
      expect(privateStorageRef('$base/sign/support-media/t1/image-1-ab.jpg?token=abc'), (
        bucket: 'support-media',
        path: 't1/image-1-ab.jpg',
      ));
      expect(privateStorageRef('$base/authenticated/provider-documents/p1/d1/front-1.pdf'), (
        bucket: 'provider-documents',
        path: 'p1/d1/front-1.pdf',
      ));
    });

    test('decodes an encoded path', () {
      expect(privateStorageRef('$base/public/ID_Image/u1/My%20Card.jpg')?.path, 'u1/My Card.jpg');
    });

    test('leaves everything else alone', () {
      expect(privateStorageRef('$base/public/avatars/u1/me.jpg'), isNull, reason: 'avatars stay public');
      expect(privateStorageRef('$base/public/ride-chat-media/r1/a.jpg'), isNull);
      expect(privateStorageRef('https://example.com/ID_Image/u1/a.jpg'), isNull);
      expect(privateStorageRef('$base/public/ID_Image/'), isNull);
      expect(privateStorageRef('data:image/png;base64,AAAA'), isNull);
      expect(privateStorageRef(''), isNull);
      expect(privateStorageRef(null), isNull);
    });
  });

  group('cachedSignedLink', () {
    test('callers at once share one signing call, and the link is reused until near expiry', () async {
      var signs = 0;
      final gate = Completer<void>();
      Future<String> sign() async {
        signs++;
        await gate.future;
        return 'signed-$signs';
      }

      final t0 = DateTime(2026, 10, 18, 9);
      const ttl = Duration(hours: 1);
      final a = cachedSignedLink('k-share', ttl: ttl, sign: sign, now: t0);
      final b = cachedSignedLink('k-share', ttl: ttl, sign: sign, now: t0);
      gate.complete();
      expect(await a, 'signed-1');
      expect(await b, 'signed-1');
      expect(await cachedSignedLink('k-share', ttl: ttl, sign: sign, now: t0.add(const Duration(minutes: 49))), 'signed-1');
      expect(signs, 1);
      expect(await cachedSignedLink('k-share', ttl: ttl, sign: sign, now: t0.add(const Duration(minutes: 50))), 'signed-2');
    });

    test('a failed signing is not kept', () async {
      const ttl = Duration(hours: 1);
      await expectLater(cachedSignedLink('k-fail', ttl: ttl, sign: () async => throw StateError('no')), throwsStateError);
      expect(await cachedSignedLink('k-fail', ttl: ttl, sign: () async => 'ok'), 'ok');
    });
  });

  group('signedStorageUrl', () {
    test('a link outside the private buckets comes back as it is', () async {
      expect(await signedStorageUrl('https://example.com/a.png'), 'https://example.com/a.png');
    });

    test('with no client to sign it, the stored link is used (it opens while the bucket is public)', () async {
      const url = '$base/public/ID_Image/u1/a.jpg';
      expect(await signedStorageUrl(url), url);
    });
  });

  group('batched signing (PERF-75)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('the links asked for in one frame go out as one call per bucket', () async {
      final calls = <({String bucket, List<String> paths})>[];
      final db = _signingClient(calls);
      final urls = [for (var i = 0; i < 25; i++) '$base/public/vehicle-documents/b1/v$i/front.jpg'];
      final links = await Future.wait([
        for (final u in urls) signedThumbUrl(u, client: db),
        signedStorageUrl('$base/public/ID_Image/b1/u1/id.jpg', client: db),
      ]);
      expect(calls, hasLength(2));
      final vehicle = calls.firstWhere((c) => c.bucket == 'vehicle-documents');
      expect(vehicle.paths, [for (var i = 0; i < 25; i++) 'b1/v$i/front.jpg.thumb.jpg']);
      expect(links.first, endsWith('/object/sign/vehicle-documents/b1/v0/front.jpg.thumb.jpg?token=t'));
      expect(links.last, endsWith('/object/sign/ID_Image/b1/u1/id.jpg?token=t'));
    });

    test('a missing thumbnail falls back to the file in one more batch, and is not asked for again', () async {
      final calls = <({String bucket, List<String> paths})>[];
      final db = _signingClient(calls);
      final urls = [
        '$base/public/vehicle-documents/b2/a.jpg',
        '$base/public/vehicle-documents/b2/nothumb-1.jpg',
        '$base/public/vehicle-documents/b2/nothumb-2.jpg',
      ];
      // As StorageImage does: the thumbnail, else the file.
      Future<String> show(String u) async => await signedThumbUrl(u, client: db) ?? await signedStorageUrl(u, client: db);
      final shown = await Future.wait(urls.map(show));
      expect(calls.map((c) => c.paths), [
        ['b2/a.jpg.thumb.jpg', 'b2/nothumb-1.jpg.thumb.jpg', 'b2/nothumb-2.jpg.thumb.jpg'],
        ['b2/nothumb-1.jpg', 'b2/nothumb-2.jpg'],
      ]);
      expect(shown[0], contains('a.jpg.thumb.jpg?token=t'));
      expect(shown[1], endsWith('/vehicle-documents/b2/nothumb-1.jpg?token=t'));
      calls.clear();
      expect(await signedThumbUrl(urls[1], client: db), isNull);
      expect(calls, isEmpty);
    });

    test('a link already made is handed out without the network', () async {
      final calls = <({String bucket, List<String> paths})>[];
      final db = _signingClient(calls);
      const u = '$base/public/provider-documents/b3/p1/front.jpg';
      final first = await signedStorageUrl(u, client: db);
      expect(calls, hasLength(1));
      expect(await signedStorageUrl(u, client: db), first);
      expect(calls, hasLength(1));
    });

    test('a file storage will not sign keeps its stored link', () async {
      final db = _signingClient([]);
      const u = '$base/public/ID_Image/b4/missing.jpg';
      expect(await signedStorageUrl(u, client: db), u);
    });
  });

  group('links kept on the device (PERF-75)', () {
    late DateTime now;
    late String? user;
    late int signs;

    StorageLinkBatcher open() => StorageLinkBatcher(
      (bucket, paths) async {
        signs++;
        return {for (final p in paths) p: 'https://s/$bucket/$p?token=$signs'};
      },
      user: () => user,
      clock: () => now,
      prefs: SharedPreferences.getInstance,
    );

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      now = DateTime(2026, 10, 19, 9);
      user = 'u1';
      signs = 0;
    });

    test('a restart reuses the link until shortly before it expires', () async {
      final a = await open().link('ID_Image', 'u1/id.jpg');
      expect(a?.url, 'https://s/ID_Image/u1/id.jpg?token=1');
      expect(a?.until, now.add(documentLinkTtl - signedLinkRenewBefore));

      // A new process, the same device store.
      now = now.add(const Duration(minutes: 30));
      final b = await open().link('ID_Image', 'u1/id.jpg');
      expect(b?.url, a?.url);
      expect(signs, 1);

      now = now.add(const Duration(minutes: 20)); // 50 min: inside the margin
      final c = await open().link('ID_Image', 'u1/id.jpg');
      expect(c?.url, 'https://s/ID_Image/u1/id.jpg?token=2');
    });

    test('another account never gets the kept links', () async {
      await open().link('ID_Image', 'u1/id.jpg');
      user = 'u2';
      final b = await open().link('ID_Image', 'u1/id.jpg');
      expect(b?.url, endsWith('token=2'));
      expect((await SharedPreferences.getInstance()).getString(signedLinksPrefsKey), contains('"user":"u2"'));
    });

    test('signing out wipes them', () async {
      final batcher = open();
      await batcher.link('ID_Image', 'u1/id.jpg');
      expect((await SharedPreferences.getInstance()).getString(signedLinksPrefsKey), isNotNull);
      await batcher.clear();
      expect((await SharedPreferences.getInstance()).getString(signedLinksPrefsKey), isNull);
      // And nobody signed in keeps nothing either.
      user = null;
      await open().link('ID_Image', 'u1/id.jpg');
      expect((await SharedPreferences.getInstance()).getString(signedLinksPrefsKey), isNull);
    });

    test('at most $signedLinksKeepMax are kept, the oldest dropped', () async {
      final batcher = open();
      await batcher.link('ID_Image', 'old/0.jpg');
      await Future.wait([for (var i = 1; i < signedLinksKeepMax; i++) batcher.link('ID_Image', 'old/$i.jpg')]);
      await batcher.link('ID_Image', 'new.jpg');
      final raw = (await SharedPreferences.getInstance()).getString(signedLinksPrefsKey)!;
      final links = (jsonDecode(raw) as Map)['links'] as Map;
      expect(links, hasLength(signedLinksKeepMax));
      expect(links.containsKey('ID_Image/old/0.jpg'), isFalse);
      expect(links.containsKey('ID_Image/new.jpg'), isTrue);
    });
  });
}
