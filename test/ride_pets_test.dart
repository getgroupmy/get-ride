// "Pet with me" (migration 0247): the Your pets sheet the Options switch
// opens, the summary on the Options row and in the driver's note, and the
// pets as the driver sees them — in light and dark.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/core/ride_confirm.dart';
import 'package:get_ride/src/core/ride_pets.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/photo_picker.dart';
import 'package:get_ride/src/data/ride_pet_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart' show showRideOptionsSheet;
import 'package:get_ride/src/features/ride/pet_parts.dart';
import 'package:get_ride/src/providers.dart';

const _uid = '00000000-0000-0000-0000-00000000a247';

/// A 1 x 1 picture, for the picked photo.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _Rides implements RideRepository {
  @override
  Future<RequestViewers> viewers(String requestId) async => RequestViewers.none;

  @override
  Future<void> markViewed(String requestId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('pure', () {
    const dogM = RidePet(type: 'Dog', size: 'M', photoPath: '$_uid/a.jpg');
    const dogL = RidePet(type: 'Dog', size: 'L', photoPath: '$_uid/b.jpg');
    const catS = RidePet(type: 'Cat', size: 'S', photoPath: '$_uid/c.jpg');

    test('the summary counts each type with its sizes', () {
      expect(petSummary(const [dogM, dogL, catS]), '2 dogs (M, L), 1 cat (S)');
      expect(petSummary(const [RidePet(type: 'Guinea pig', size: 'XS')]), '1 guinea pig (XS)');
      expect(petSummary(const [RidePet(type: 'Guinea pig'), RidePet(type: 'Guinea pig')]), '2 guinea pigs');
      expect(petSummary(const []), '');
      expect(petTypeTitle('Hamster'), 'Hamsters');
      expect(dogM.label, 'Dog · M');
      expect(const RidePet(type: 'Cat').label, 'Cat');
    });

    test('Done waits for a size and a photo of every pet', () {
      const c = PetConfig();
      expect(petsMissingText(const [], c), 'Pick at least one pet type.');
      expect(petsComplete(const [], c), isFalse);
      const bare = [RidePet(type: 'Dog'), RidePet(type: 'Dog'), RidePet(type: 'Cat', size: 'S')];
      expect(petsMissingText(bare, c), 'Still needed: 2 sizes and 3 photos.');
      expect(petsMissingText(const [RidePet(type: 'Dog', size: 'M')], c), 'Still needed: 1 photo.');
      expect(petsMissingText(const [RidePet(type: 'Dog', photoPath: 'x/y.jpg')], c), 'Still needed: 1 size.');
      expect(petsMissingText(const [dogM, catS], c), isNull);
      expect(petsComplete(const [dogM, catS], c), isTrue);
      // An admin who doesn't ask for photos.
      const noPhoto = PetConfig(photoRequired: false);
      expect(petsMissingText(const [RidePet(type: 'Dog', size: 'M')], noPhoto), isNull);
    });

    test('the config comes from the display settings, with the defaults', () {
      final d = PetConfig.fromSettings(const {});
      expect(d.types, ['Dog', 'Cat', 'Rabbit', 'Guinea pig', 'Hamster']);
      expect(d.sizes, ['XS', 'S', 'M', 'L', 'XL']);
      expect(d.maxPerType, 5);
      expect(d.photoRequired, isTrue);
      final s = PetConfig.fromSettings({
        'petTypes': ['Dog', ' dog ', 'Bird', ''],
        'petSizes': 'Small, Large',
        'petMaxPerType': '99',
        'petPhotoRequired': 'off',
      });
      expect(s.types, ['Dog', 'Bird']);
      expect(s.sizes, ['Small', 'Large']);
      expect(s.maxPerType, PetConfig.maxPerTypeLimit);
      expect(s.photoRequired, isFalse);
      expect(PetConfig.fromSettings(s.toSettings()).types, s.types, reason: 'written back as read');
    });

    test('the pets go on the row and in the note; a row reads them back', () {
      const o = RideOptions(pet: true, pets: [dogM, catS]);
      expect(driverNote(options: o, note: 'Blue gate'), 'Pet with me: 1 dog (M), 1 cat (S) · Blue gate');
      expect(driverNote(options: const RideOptions(pet: true)), 'Pet with me');
      expect(dogM.toJson(), {'type': 'Dog', 'size': 'M', 'photo_path': '$_uid/a.jpg'});
      expect(const RidePet(type: 'Cat').toJson(), {'type': 'Cat'});
      final r = RideRequest({
        'id': 'r',
        'pets': [dogM.toJson(), {'type': 'Cat', 'size': 'S'}, 'junk', {'size': 'M'}],
      });
      expect(r.pets, const [dogM, RidePet(type: 'Cat', size: 'S')]);
      expect(RideRequest(const {'id': 'r'}).pets, isEmpty);
      expect(o, const RideOptions(pet: true, pets: [dogM, catS]));
      expect(o == const RideOptions(pet: true, pets: [dogM]), isFalse);
      expect(o.copyWith(pet: false, pets: const []).labels, isEmpty);
      expect(ridePetPhotoPath(_uid, 'abc', 'JPG'), '$_uid/pet-abc.jpg');
    });
  });

  for (final b in Brightness.values) {
    final mode = b == Brightness.dark ? ' (dark)' : '';

    group('the Your pets sheet$mode', () {
      late RideOptions saved;
      late int uploads;

      Future<void> open(WidgetTester tester, {RideOptions start = const RideOptions()}) async {
        tester.view.physicalSize = const Size(420, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        saved = start;
        uploads = 0;
        final note = TextEditingController();
        addTearDown(note.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              photoCameraAvailableProvider.overrideWithValue(false),
              photoPickerProvider.overrideWithValue(
                (source) async => (bytes: _png, name: 'pet.png'),
              ),
              ridePetPhotoUploadProvider.overrideWithValue((bytes, name) async => '$_uid/pet-${uploads++}.jpg'),
            ],
            child: MaterialApp(
              theme: appTheme(b),
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      key: const ValueKey('open-options'),
                      onPressed: () => showRideOptionsSheet(
                        context,
                        options: saved,
                        onChanged: (o) => saved = o,
                        note: note,
                      ),
                      child: const Text('Options'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open-options')));
        await tester.pumpAndSettle();
      }

      Future<void> tap(WidgetTester tester, String key) async {
        final f = find.byKey(ValueKey(key));
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      String hint(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('pets-missing'))).data!;
      bool doneOn(WidgetTester tester) =>
          tester.widget<FilledButton>(find.byKey(const ValueKey('pets-done'))).onPressed != null;

      testWidgets('two types, counts and sizes; Done waits for the photos; the summary', (tester) async {
        await open(tester);
        await tap(tester, 'option-pet');
        expect(find.byKey(const ValueKey('ride-pets')), findsOneWidget);
        expect(find.text('Your pets'), findsOneWidget);
        expect(hint(tester), 'Pick at least one pet type.');
        expect(doneOn(tester), isFalse);

        await tap(tester, 'pets-type-Dog');
        await tap(tester, 'pets-type-Cat');
        expect(find.text('Dogs'), findsOneWidget);
        expect(find.text('Cats'), findsOneWidget);
        await tap(tester, 'pets-plus-Dog');
        expect(tester.widget<Text>(find.byKey(const ValueKey('pets-count-Dog'))).data, '2');
        expect(hint(tester), 'Still needed: 3 sizes and 3 photos.');

        await tap(tester, 'pet-size-Dog-0-M');
        await tap(tester, 'pet-size-Dog-1-L');
        await tap(tester, 'pet-size-Cat-0-S');
        expect(hint(tester), 'Still needed: 3 photos.');
        expect(doneOn(tester), isFalse, reason: 'every pet needs a photo');

        await tap(tester, 'pet-photo-Dog-0');
        await tap(tester, 'pet-photo-Dog-1');
        expect(hint(tester), 'Still needed: 1 photo.');
        expect(doneOn(tester), isFalse);
        await tap(tester, 'pet-photo-Cat-0');
        expect(uploads, 3);
        expect(doneOn(tester), isTrue);

        await tap(tester, 'pets-done');
        expect(find.byKey(const ValueKey('ride-pets')), findsNothing);
        expect(tester.widget<Text>(find.byKey(const ValueKey('option-pet-summary'))).data, '2 dogs (M, L), 1 cat (S)');
        expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('option-pet'))).value, isTrue);
        expect(saved.pet, isTrue);
        expect([for (final p in saved.pets) p.toJson()], [
          {'type': 'Dog', 'size': 'M', 'photo_path': '$_uid/pet-0.jpg'},
          {'type': 'Dog', 'size': 'L', 'photo_path': '$_uid/pet-1.jpg'},
          {'type': 'Cat', 'size': 'S', 'photo_path': '$_uid/pet-2.jpg'},
        ]);
        expect(driverNote(options: saved), 'Pet with me: 2 dogs (M, L), 1 cat (S)');

        // Edit reopens them; Cancel and the scrim keep what was saved.
        await tap(tester, 'option-pet-edit');
        expect(tester.widget<Text>(find.byKey(const ValueKey('pets-count-Dog'))).data, '2');
        await tap(tester, 'pets-minus-Dog');
        await tap(tester, 'pets-cancel');
        expect(saved.pets, hasLength(3));
        await tap(tester, 'option-pet-edit');
        await tap(tester, 'pets-type-Cat');
        await tester.tapAt(const Offset(200, 10));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ride-pets')), findsNothing);
        expect(saved.pets, hasLength(3));
        expect(tester.widget<Text>(find.byKey(const ValueKey('option-pet-summary'))).data, '2 dogs (M, L), 1 cat (S)');
      });

      testWidgets('turning the option off clears the pets', (tester) async {
        await open(
          tester,
          start: const RideOptions(pet: true, pets: [RidePet(type: 'Rabbit', size: 'XS', photoPath: '$_uid/r.jpg')]),
        );
        expect(tester.widget<Text>(find.byKey(const ValueKey('option-pet-summary'))).data, '1 rabbit (XS)');
        await tap(tester, 'option-pet');
        expect(find.byKey(const ValueKey('ride-pets')), findsNothing, reason: 'off needs no sheet');
        expect(saved.pet, isFalse);
        expect(saved.pets, isEmpty);
        expect(find.byKey(const ValueKey('option-pet-edit')), findsNothing);
        expect(find.byKey(const ValueKey('option-pet-summary')), findsNothing, reason: 'the row as it was');
      });

      testWidgets('cancelled with no pets saved, the option stays off', (tester) async {
        await open(tester);
        await tap(tester, 'option-pet');
        await tap(tester, 'pets-type-Hamster');
        await tap(tester, 'pets-cancel');
        expect(saved.pet, isFalse);
        expect(saved.pets, isEmpty);
        expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('option-pet'))).value, isFalse);
      });
    });

    group('the driver sees the pets$mode', () {
      final pets = [
        const RidePet(type: 'Dog', size: 'M', photoPath: '$_uid/a.jpg'),
        const RidePet(type: 'Cat', size: 'S', photoPath: '$_uid/b.jpg'),
      ];
      final overrides = [
        rideRepositoryProvider.overrideWithValue(_Rides()),
        ridePetPhotoUrlProvider.overrideWith((ref, path) async => 'https://example.invalid/$path'),
      ];

      testWidgets('a taken ride: the summary, a thumbnail per pet, a larger look', (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: overrides,
            child: MaterialApp(
              theme: appTheme(b),
              home: Scaffold(body: RidePetsView(pets: pets, title: 'Pets riding along')),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Pets riding along'), findsOneWidget);
        expect(find.text('1 dog (M), 1 cat (S)'), findsOneWidget);
        expect(find.byKey(const ValueKey('pet-thumb-0')), findsOneWidget);
        expect(find.byKey(const ValueKey('pet-thumb-1')), findsOneWidget);
        expect(find.text('Dog · M'), findsOneWidget);
        expect(find.text('Cat · S'), findsOneWidget);
        expect(find.byType(RidePetPhoto), findsNWidgets(2));
        expect(find.byKey(const ValueKey('pets-photos-after-accept')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('pet-thumb-1')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('pet-photo-dialog')), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(const ValueKey('pet-photo-label'))).data, 'Cat · S');
        await tester.tap(find.byKey(const ValueKey('pet-photo-close')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('pet-photo-dialog')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('an open request on the request sheet: the pets, the photos after accepting', (tester) async {
        final r = RideRequest({
          'id': 'r1',
          'rider_id': _uid,
          'status': 'open',
          'fare': 20,
          'currency': 'MYR',
          'pickup_name': 'KLCC',
          'drop_name': 'KL Sentral',
          'created_at': DateTime.now().toUtc().toIso8601String(),
          // As 0247 leaves an open row: types and sizes, no photos.
          'pets': [
            {'type': 'Dog', 'size': 'M'},
            {'type': 'Dog', 'size': 'L'},
          ],
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: overrides,
            child: MaterialApp(
              theme: appTheme(b),
              home: Scaffold(
                body: RideRequestSheet(
                  request: r,
                  shown: Duration.zero,
                  now: DateTime.now(),
                  onAccept: () async {},
                  onSkip: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('2 dogs (M, L)'), findsOneWidget);
        expect(find.text('Dog · M'), findsOneWidget);
        expect(find.text('Dog · L'), findsOneWidget);
        expect(find.byKey(const ValueKey('pets-photos-after-accept')), findsOneWidget);
        expect(find.byType(RidePetPhoto), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    });
  }
}
