import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/pick_image.dart';
import 'package:get_ride/src/core/profile_identity.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/profile/edit_profile_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

class _FakeAccount implements AccountRepository {
  final saved = <Map<String, Object?>>[];
  final idUploads = <String>[];

  @override
  Future<void> updateProfile({String? name, String? email, Map<String, String?>? identity}) async =>
      saved.add({'name': name, 'email': email, ...?identity});

  @override
  Future<String> uploadIdImage(Uint8List bytes, {required String ext, required String contentType}) async {
    idUploads.add('$ext:$contentType');
    return 'https://example.test/ID_Image/me/id_1.$ext';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('ID photos go to the account folder, unique per upload', () {
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    expect(idImageStoragePath('u-1', 'png', at), 'u-1/id_1700000000000.png');
  });

  test('ID numbers are tidied and blanks clear their column', () {
    expect(normalizeIdNumber('  a1234  567 '), 'A1234 567');
    expect(identityPatch(country: ' Malaysia ', idNumber: '900101-14-5555', address: 'Jalan 1'), {
      'nationality': 'Malaysia',
      'ic': '900101-14-5555',
      'address': 'Jalan 1',
    });
    expect(identityPatch(country: '', idNumber: '  ', address: ''), {'nationality': null, 'ic': null, 'address': null});
  });

  test('country search', () {
    expect(searchCountries('malay'), ['Malaysia']);
    expect(searchCountries('SINGA'), ['Singapore']);
    expect(searchCountries(''), contains('Indonesia'));
    expect(searchCountries('zzz'), isEmpty);
  });

  Future<_FakeAccount> pump(WidgetTester tester, Map<String, dynamic> profile) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1600);
    addTearDown(tester.view.reset);
    final account = _FakeAccount();
    final router = GoRouter(
      initialLocation: '/edit',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('home')),
        GoRoute(
          path: '/edit',
          builder: (_, _) => EditProfileScreen(
            pickPhoto: (_) async =>
                (bytes: Uint8List(2048), name: 'id.jpg', ext: 'jpg', contentType: imageContentType('jpg')),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(account),
          profileProvider.overrideWith((ref) async => Profile(profile)),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return account;
  }

  testWidgets('the identity fields load and save with the profile', (tester) async {
    final account = await pump(tester, {
      'id': 'me',
      'name': 'Ali',
      'phone': '60123456789',
      'nationality': 'Malaysia',
      'ic': '900101-14-5555',
      'address': 'Jalan 1',
    });
    expect(find.text('Malaysia'), findsOneWidget);
    expect(find.text('900101-14-5555'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('profile-country')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('country-search')), 'singa');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('country-Singapore')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('profile-id-number')), 'e1234567x');
    await tester.enterText(find.byKey(const ValueKey('profile-address')), '');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(account.saved.single, {
      'name': 'Ali',
      'email': null,
      'nationality': 'Singapore',
      'ic': 'E1234567X',
      'address': null,
    });
  });

  testWidgets('the ID photo is uploaded straight away', (tester) async {
    final account = await pump(tester, {'id': 'me', 'name': 'Ali'});
    expect(find.text('Photograph passport or ID'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('profile-id-photo')));
    await tester.tap(find.byKey(const ValueKey('profile-id-photo')));
    await tester.pumpAndSettle();
    expect(account.idUploads, ['jpg:image/jpeg']);
    expect(find.text('ID photo saved'), findsOneWidget);
  });
}
