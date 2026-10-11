// Document links that need a signed URL once their bucket is private
// (lib/src/core/storage_links.dart, lib/src/data/storage_links.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/storage_links.dart';
import 'package:get_ride/src/data/storage_links.dart';

const base = 'https://rqlavogkgywxspuxgiwk.supabase.co/storage/v1/object';

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

  group('signedStorageUrl', () {
    test('a link outside the private buckets comes back as it is', () async {
      expect(await signedStorageUrl('https://example.com/a.png'), 'https://example.com/a.png');
    });

    test('with no client to sign it, the stored link is used (it opens while the bucket is public)', () async {
      const url = '$base/public/ID_Image/u1/a.jpg';
      expect(await signedStorageUrl(url), url);
    });
  });
}
