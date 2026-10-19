// PERF-67: document and vehicle photos are scaled down before upload, get a
// small thumbnail beside them for the lists, and are cached for a year
// (lib/src/core/doc_photo.dart, lib/src/data/doc_photos.dart).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/pick_image.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/core/doc_photo.dart';
import 'package:get_ride/src/data/doc_photos.dart';
import 'package:get_ride/src/data/partner_onboarding_repository.dart';
import 'package:get_ride/src/data/storage_links.dart';
import 'package:get_ride/src/data/vehicle_onboarding_repository.dart';
import 'package:get_ride/src/widgets/net_image.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

const _base = 'http://localhost/storage/v1/object/public';

/// A photo with some detail in it (a flat colour compresses to nothing):
/// gradients, a grid of edges like printed text, and a little grain.
img.Image _photo(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    final edge = (p.x ~/ 24 + p.y ~/ 24).isEven ? 60 : 0;
    final grain = (p.x * 31 + p.y * 17) % 13;
    p
      ..r = (p.x * 255 ~/ w + edge + grain).clamp(0, 255)
      ..g = (p.y * 255 ~/ h + grain).clamp(0, 255)
      ..b = (128 + edge - grain).clamp(0, 255);
  }
  return im;
}

/// The quantisation tables (DQT segments) of a JPEG: they depend only on the
/// quality it was written at.
List<int> _dqt(Uint8List jpg) {
  final out = <int>[];
  var i = 2;
  while (i + 4 <= jpg.length && jpg[i] == 0xFF) {
    final marker = jpg[i + 1];
    final len = (jpg[i + 2] << 8) | jpg[i + 3];
    if (marker == 0xDB) out.addAll(jpg.sublist(i + 4, i + 2 + len));
    if (marker == 0xDA) break;
    i += 2 + len;
  }
  return out;
}

List<int> _dqtAt(int quality) => _dqt(img.encodeJpg(_photo(16, 16), quality: quality));

/// A Supabase client whose every request is answered by [handler].
SupabaseClient _client(Future<http.Response> Function(http.Request r) handler) {
  final db = SupabaseClient(
    'http://localhost',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(handler),
  );
  addTearDown(db.dispose);
  return db;
}

/// The uploads [db] made: object path → (cacheControl field, content type).
typedef _Upload = ({String path, String cacheControl, String contentType, int bytes});

_Upload _parseUpload(http.Request r) {
  final body = latin1.decode(r.bodyBytes);
  final cache = RegExp(r'name="cacheControl"\r\n\r\n([^\r]*)').firstMatch(body)?.group(1) ?? '';
  final type = RegExp(r'content-type: ([^\r]*)', caseSensitive: false).firstMatch(body)?.group(1) ?? '';
  final path = Uri.decodeComponent(r.url.path.split('/storage/v1/object/').last);
  return (path: path, cacheControl: cache, contentType: type, bytes: r.bodyBytes.length);
}

void main() {
  group('scaling a document photo down', () {
    test('a large photo is at most 1600 px long, JPEG quality 80', () {
      final out = shrinkDocPhoto(img.encodeJpg(_photo(2400, 1800)))!;
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (1600, 1200));
      expect(_dqt(out), _dqtAt(80));
      expect(_dqt(out), isNot(_dqtAt(90)));
    });

    test('a tall photo is limited on its height', () {
      final decoded = img.decodeJpg(shrinkDocPhoto(img.encodeJpg(_photo(600, 1920)))!)!;
      expect((decoded.width, decoded.height), (500, 1600));
    });

    test('a small photo is not scaled up, only re-encoded', () {
      final decoded = img.decodeJpg(shrinkDocPhoto(img.encodePng(_photo(800, 600)))!)!;
      expect((decoded.width, decoded.height), (800, 600));
    });

    test('a phone photo stored sideways comes out upright, without the EXIF turn', () {
      final sideways = _photo(300, 100)..exif.imageIfd.orientation = 6;
      final jpg = img.encodeJpg(sideways);
      expect(img.decodeJpgExif(jpg)!.imageIfd.orientation, 6, reason: 'the test photo says "turn me"');
      final out = shrinkDocPhoto(jpg)!;
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (100, 300));
      expect(img.decodeJpgExif(out)?.imageIfd.orientation ?? 1, 1, reason: 'no second turn by a viewer');
      // A PNG has no EXIF turn of its own here; its pixels are kept as they are.
      final png = img.decodeJpg(shrinkDocPhoto(img.encodePng(_photo(300, 100)))!)!;
      expect((png.width, png.height), (300, 100));
    });

    test('transparency becomes white, not black', () {
      final clear = img.Image(width: 40, height: 40, numChannels: 4);
      final out = img.decodeJpg(shrinkDocPhoto(img.encodePng(clear))!)!;
      final p = out.getPixel(20, 20);
      expect(p.r, greaterThan(240));
      expect(p.g, greaterThan(240));
      expect(p.b, greaterThan(240));
    });

    test('a PDF or anything unreadable is left alone', () {
      final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\n1 0 obj\n'));
      expect(looksLikePdf(pdf), isTrue);
      expect(shrinkDocPhoto(pdf), isNull);
      expect(docThumbnail(pdf), isNull);
      expect(shrinkDocPhoto(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('the picked file is renamed .jpg; one that cannot be read is kept as it is', () async {
      PickedImage pick(Uint8List b, String name) =>
          (bytes: b, name: name, ext: imageExt(name), contentType: imageContentType(imageExt(name)));
      final out = await shrinkPickedDocImage(pick(img.encodePng(_photo(2000, 1000)), 'licence.png'),
          shrink: (b) async => shrinkDocPhoto(b));
      expect((out.name, out.ext, out.contentType), ('licence.jpg', 'jpg', 'image/jpeg'));
      expect(img.decodeJpg(out.bytes)!.width, 1600);

      final pdf = pick(Uint8List.fromList(utf8.encode('%PDF-1.4')), 'scan.pdf');
      expect(await shrinkPickedDocImage(pdf, shrink: (b) async => shrinkDocPhoto(b)), same(pdf));
      expect(await shrinkPickedDocImage(pdf, shrink: (b) async => throw StateError('decode')), same(pdf));
    });

    test('off the UI thread: the isolate path gives the same result', () async {
      final out = await shrinkDocPhotoBytes(img.encodeJpg(_photo(2000, 1500)));
      expect(img.decodeJpg(out!)!.width, 1600);
      expect(await shrinkDocPhotoBytes(Uint8List.fromList(utf8.encode('%PDF-1.4'))), isNull);
    });

    test('a large photo comes out several times smaller; its thumbnail far smaller still', () {
      final original = img.encodeJpg(_photo(3200, 2400), quality: 92);
      final shrunk = shrinkDocPhoto(original)!;
      final thumb = docThumbnail(shrunk)!;
      expect(shrunk.length, lessThan(original.length ~/ 3));
      expect(thumb.length, lessThan(shrunk.length ~/ 10));
    });
  });

  group('thumbnails', () {
    test('are 320 px on the long side', () {
      final t = img.decodeJpg(docThumbnail(img.encodeJpg(_photo(1600, 1200)))!)!;
      expect((t.width, t.height), (320, 240));
    });

    test('sit beside the file at <path>.thumb.jpg', () {
      expect(docThumbPath('v1/photos/front-1.jpg'), 'v1/photos/front-1.jpg.thumb.jpg');
      expect(docThumbUrl('$_base/vehicle-documents/v1/photos/front-1.jpg'),
          '$_base/vehicle-documents/v1/photos/front-1.jpg.thumb.jpg');
      expect(docThumbUrl('$_base/provider-documents/p1/d1/front-1.png?x=1'),
          '$_base/provider-documents/p1/d1/front-1.png.thumb.jpg?x=1');
      expect(docThumbUrl('$_base/ID_Image/u1/id_1.jpg'), '$_base/ID_Image/u1/id_1.jpg.thumb.jpg');
    });

    test('a PDF, a thumbnail, another bucket or a foreign link has none', () {
      expect(docThumbUrl('$_base/provider-documents/p1/d1/front-1.pdf'), isNull);
      expect(docThumbUrl('$_base/vehicle-documents/v1/a.jpg.thumb.jpg'), isNull);
      expect(docThumbUrl('$_base/avatars/u1/avatar_1.jpg'), isNull);
      expect(docThumbUrl('$_base/support-media/t1/a.jpg'), isNull);
      expect(docThumbUrl('https://example.com/a.jpg'), isNull);
      expect(docThumbUrl(null), isNull);
    });

    test('a small box is drawn from the thumbnail, a large one from the file', () {
      expect(thumbIsEnough(width: 56, height: 40, dpr: 3), isTrue);
      expect(thumbIsEnough(width: 80, height: 80, dpr: 3), isTrue);
      expect(thumbIsEnough(width: 300, height: 220, dpr: 2), isFalse);
      expect(thumbIsEnough(width: null, height: 40, dpr: 1), isFalse);
    });

    test('the signed thumbnail link, or null (and asked once) for an upload without one', () async {
      var signs = 0;
      final db = _client((r) async {
        signs++;
        if (r.url.path.contains('missing')) {
          return http.Response('{"statusCode":"404","error":"not_found","message":"Object not found"}', 400,
              request: r);
        }
        return http.Response('{"signedURL":"/object/sign/vehicle-documents/v1/a.jpg.thumb.jpg?token=t"}', 200,
            request: r);
      });
      final url = await signedThumbUrl('$_base/vehicle-documents/v1/a.jpg', client: db);
      expect(url, contains('a.jpg.thumb.jpg?token=t'));

      final old = '$_base/vehicle-documents/v1/missing.jpg';
      expect(await signedThumbUrl(old, client: db), isNull);
      final before = signs;
      expect(await signedThumbUrl(old, client: db), isNull);
      expect(signs, before, reason: 'a missing thumbnail is not asked for again');

      expect(await signedThumbUrl('$_base/vehicle-documents/v1/a.pdf', client: db), isNull);
    });

    for (final b in Brightness.values) {
      testWidgets('without a thumbnail the slot shows the file itself (${b.name})', (tester) async {
        const url = '$_base/vehicle-documents/v1/photos/front-1.jpg';
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: b),
          home: const Scaffold(body: NetImage(url, width: 56, height: 40)),
        ));
        await tester.pump();
        await tester.pump();
        final image = tester.widget<Image>(find.byType(Image));
        // No Supabase here: neither link can be signed, so the stored link
        // itself is used, never the thumbnail's.
        expect((image.image as ResizeImage).imageProvider, isA<NetworkImage>());
        expect(((image.image as ResizeImage).imageProvider as NetworkImage).url, url);
      });
    }
  });

  group('uploads', () {
    Future<List<_Upload>> run(Future<void> Function(SupabaseClient db) upload) async {
      final seen = <_Upload>[];
      final db = _client((r) async {
        seen.add(_parseUpload(r));
        return http.Response('{"Key":"k"}', 200, request: r);
      });
      await upload(db);
      return seen;
    }

    Future<Uint8List?> fakeThumb(Uint8List b) async => Uint8List.fromList([0xFF, 0xD8, 1]);

    test('an image goes up with a year of cache and its thumbnail beside it', () async {
      final seen = await run((db) => uploadStoredFile(db.storage.from('vehicle-documents'), 'v1/photos/front-1.jpg',
          Uint8List.fromList([1, 2, 3]),
          contentType: 'image/jpeg', thumbnail: fakeThumb));
      expect(seen.map((u) => u.path), ['vehicle-documents/v1/photos/front-1.jpg', 'vehicle-documents/v1/photos/front-1.jpg.thumb.jpg']);
      for (final u in seen) {
        expect(u.cacheControl, '31536000');
      }
      expect(seen.last.contentType, 'image/jpeg');
    });

    test('a PDF, another bucket, or no thumbnail: the file alone', () async {
      Future<Uint8List?> none(Uint8List b) async => null;
      final pdf = await run((db) => uploadStoredFile(db.storage.from('provider-documents'), 'p1/d1/front-1.pdf',
          Uint8List.fromList([1]),
          contentType: 'application/pdf', thumbnail: fakeThumb));
      expect(pdf.map((u) => u.path), ['provider-documents/p1/d1/front-1.pdf']);
      final avatar = await run((db) => uploadStoredFile(db.storage.from('avatars'), 'u1/avatar_1.jpg',
          Uint8List.fromList([1]),
          contentType: 'image/jpeg', thumbnail: fakeThumb));
      expect(avatar, hasLength(1));
      expect(avatar.single.cacheControl, '31536000');
      final unreadable = await run((db) => uploadStoredFile(db.storage.from('vehicle-documents'), 'v1/x-1.png',
          Uint8List.fromList([1]),
          contentType: 'image/png', thumbnail: none));
      expect(unreadable, hasLength(1));
    });

    test('a failed thumbnail does not fail the upload', () async {
      final seen = await run((db) => uploadStoredFile(db.storage.from('ID_Image'), 'u1/id_1.jpg',
          Uint8List.fromList([1]),
          contentType: 'image/jpeg', thumbnail: (_) async => throw StateError('decode')));
      expect(seen.map((u) => u.path), ['ID_Image/u1/id_1.jpg']);
    });

    test('the admin, vehicle and partner onboarding uploads all add the thumbnail', () async {
      final people = await run((db) =>
          PeopleRepository(db, thumbnail: fakeThumb).upload('provider-documents', 'p1/d1/front-9.jpg', (bytes: Uint8List(3), name: 'a.jpg')));
      expect(people.map((u) => u.path), ['provider-documents/p1/d1/front-9.jpg', 'provider-documents/p1/d1/front-9.jpg.thumb.jpg']);
      expect(people.every((u) => u.cacheControl == docUploadCacheControl), isTrue);

      final vehicle = await run((db) =>
          VehicleOnboardingRepository(db, thumbnail: fakeThumb).uploadPhoto('v1', 'front', Uint8List(3), 'front.jpg'));
      expect(vehicle, hasLength(2));
      expect(vehicle.last.path, endsWith('.jpg.thumb.jpg'));
      expect(vehicle.first.path, startsWith('vehicle-documents/v1/photos/front-'));

      // Partner onboarding needs a signed-in user for its paths; its upload
      // goes through the same helper.
      expect(PartnerOnboardingRepository(_client((r) async => http.Response('', 200, request: r)), thumbnail: fakeThumb).thumbnail,
          isNotNull);
    });
  });
}
