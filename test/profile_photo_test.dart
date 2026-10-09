import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/pick_image.dart';
import 'package:get_ride/src/core/avatar.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/profile/edit_profile_screen.dart';
import 'package:get_ride/src/providers.dart';

class _FakeAccount implements AccountRepository {
  final uploads = <({int bytes, String ext, String type})>[];

  @override
  Future<String> uploadAvatar(Uint8List bytes, {required String ext, required String contentType}) async {
    uploads.add((bytes: bytes.length, ext: ext, type: contentType));
    return 'https://example.test/avatars/me/avatar_1.$ext';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PickedImage _photo(int size, {String ext = 'jpg'}) =>
    (bytes: Uint8List(size), name: 'me.$ext', ext: ext, contentType: imageContentType(ext));

void main() {
  test('path is in the account folder and unique per upload', () {
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    expect(avatarStoragePath('u-1', 'jpg', at), 'u-1/avatar_1700000000000.jpg');
  });

  test('size limits', () {
    expect(avatarProblem(0), isNotNull);
    expect(avatarProblem(1024), isNull);
    expect(avatarProblem(avatarMaxBytes), isNull);
    expect(avatarProblem(avatarMaxBytes + 1), 'Choose a photo under 5 MB.');
  });

  Future<_FakeAccount> pump(WidgetTester tester, PickedImage? photo) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1200);
    addTearDown(tester.view.reset);
    final account = _FakeAccount();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(account),
          profileProvider.overrideWith((ref) async => Profile({'id': 'me', 'name': 'Ali', 'phone': '60123456789'})),
        ],
        child: MaterialApp(home: EditProfileScreen(pickPhoto: (_) async => photo)),
      ),
    );
    await tester.pumpAndSettle();
    return account;
  }

  testWidgets('a picked photo is uploaded straight away', (tester) async {
    final account = await pump(tester, _photo(2048));
    expect(find.text('Add photo'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-photo-change')));
    await tester.pumpAndSettle();
    expect(account.uploads.single, (bytes: 2048, ext: 'jpg', type: 'image/jpeg'));
    expect(find.text('Profile photo updated'), findsOneWidget);
  });

  testWidgets('an oversized photo is refused before upload', (tester) async {
    final account = await pump(tester, _photo(avatarMaxBytes + 1));
    await tester.tap(find.byKey(const ValueKey('profile-photo-change')));
    await tester.pumpAndSettle();
    expect(account.uploads, isEmpty);
    expect(find.text('Choose a photo under 5 MB.'), findsOneWidget);
  });

  testWidgets('cancelling the picker does nothing', (tester) async {
    final account = await pump(tester, null);
    await tester.tap(find.byKey(const ValueKey('profile-photo-change')));
    await tester.pumpAndSettle();
    expect(account.uploads, isEmpty);
  });
}
