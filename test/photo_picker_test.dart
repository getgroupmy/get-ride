import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/pick_image.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/image_crop.dart';
import 'package:get_ride/src/features/auth/signup_photo_screen.dart';
import 'package:get_ride/src/features/partner/partner_onboarding_screen.dart';
import 'package:image/image.dart' as img;

void main() {
  test('the camera is offered on phones and tablets only', () {
    expect(offersCamera(web: false, platform: TargetPlatform.android), isTrue);
    expect(offersCamera(web: false, platform: TargetPlatform.iOS), isTrue);
    expect(offersCamera(web: true, platform: TargetPlatform.android), isFalse);
    expect(offersCamera(web: true, platform: TargetPlatform.iOS), isFalse);
    expect(offersCamera(web: false, platform: TargetPlatform.macOS), isFalse);
    expect(offersCamera(web: false, platform: TargetPlatform.windows), isFalse);
    expect(offersCamera(web: false, platform: TargetPlatform.linux), isFalse);
  });

  for (final b in Brightness.values) {
    testWidgets('the source sheet offers camera and gallery (${b.name})', (tester) async {
      PhotoSource? chosen;
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(b),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  chosen = await choosePhotoSource(context);
                  closed = true;
                },
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(find.text('Take photo'), findsOneWidget);
      expect(find.text('Choose from gallery'), findsOneWidget);
      await tester.tap(find.text('Take photo'));
      await tester.pumpAndSettle();
      expect(chosen, PhotoSource.camera);

      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('photo-source-gallery')));
      await tester.pumpAndSettle();
      expect(chosen, PhotoSource.gallery);

      closed = false;
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(chosen, isNull, reason: 'dismissing picks nothing');
    });
  }

  group('square profile photo', () {
    PickedImage photo(Uint8List bytes, [String name = 'me.png']) =>
        (bytes: bytes, name: name, ext: imageExt(name), contentType: imageContentType(imageExt(name)));

    test('is cut to its centred square and saved as a JPEG', () async {
      final wide = img.encodePng(img.Image(width: 300, height: 200));
      final out = await squarePickedImage(photo(wide), crop: (b) async => squareCropImage(b));
      expect(out.name, 'me.jpg');
      expect(out.ext, 'jpg');
      expect(out.contentType, 'image/jpeg');
      final decoded = img.decodeJpg(out.bytes)!;
      expect((decoded.width, decoded.height), (200, 200));
    });

    test('a photo that cannot be cut is uploaded as it is', () async {
      final original = photo(Uint8List.fromList([1, 2, 3]), 'odd.heic');
      expect(await squarePickedImage(original, crop: (b) async => null), same(original));
      expect(await squarePickedImage(original, crop: (b) async => throw StateError('decode')), same(original));
    });

    test('the partner and sign-up avatar pickers cut square', () {
      expect(identical(const PartnerOnboardingScreen().pickAvatar, pickAvatarImage), isTrue);
      expect(identical(const SignupPhotoScreen(next: '/').pickPhoto, pickAvatarImage), isTrue);
      expect(identical(const PartnerOnboardingScreen().pickPhoto, pickImage), isTrue, reason: 'the ID is not squared');
    });
  });
}
