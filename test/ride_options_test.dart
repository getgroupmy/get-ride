// Ride Options (Admin → Display Settings) and "Assistance required"
// (migration 0248): the admin's category (show, rename, reorder, the child
// seat most, pet types, the assistance catalogue, charges), the rider's
// assistance sheet and Options rows, what the options add to the fare, and
// a custom pet type and help item as the driver sees them — in light and
// dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_store.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/option_charge.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/core/ride_assistance.dart';
import 'package:get_ride/src/core/ride_confirm.dart';
import 'package:get_ride/src/core/ride_option_charges.dart';
import 'package:get_ride/src/core/ride_option_settings.dart';
import 'package:get_ride/src/core/ride_pets.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_pet_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/features/ride/assistance_parts.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart' show showRideOptionsSheet;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// The settings row kept in memory, edits applied as the real store does.
class _FakeStore implements DisplaySettingsStore {
  _FakeStore(Map<String, dynamic> raw) : blob = mergeDisplaySettings(raw);
  Map<String, dynamic> blob;

  @override
  Future<Map<String, dynamic>> fetch() async => blob;

  @override
  Future<Map<String, dynamic>> update(DisplayEdit edit) async => blob = edit(blob);

  @override
  Future<List<Map<String, dynamic>>> entries(String category) async => const [];
}

class _Rides implements RideRepository {
  @override
  Future<RequestViewers> viewers(String requestId) async => RequestViewers.none;

  @override
  Future<void> markViewed(String requestId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AssistanceItem _item(String id) => defaultAssistanceItems.firstWhere((i) => i.id == id);

/// Lets a tap, a sheet or a dialog finish (the admin's busy spinners and
/// live connection never settle).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await _settle(tester);
  await tester.tap(f);
  await _settle(tester);
}

Future<void> _tapKey(WidgetTester tester, String key) => _tap(tester, find.byKey(ValueKey(key)));

void main() {
  group('pure', () {
    test('the options config: order, hidden, names, the child seat most; what is still offered', () {
      expect(RideOptionsConfig.fromSettings(const {}).order, RideOptionKind.values);
      final c = RideOptionsConfig.fromSettings({
        RideOptionsConfig.key: {
          'order': ['assistance', 'pet', 'junk', 'pet'],
          'hidden': ['more-passengers'],
          'labels': {'pet': 'Bringing a pet', 'child-seat': 'Child safety seat', 'assistance': ''},
          'childSeatMax': 9,
        },
      });
      expect(c.order, [
        RideOptionKind.assistance,
        RideOptionKind.pet,
        RideOptionKind.childSeat,
        RideOptionKind.morePassengers,
        // The Freight page's (0267) follow, never on a ride's sheet.
        ...RideOptionKind.freightKinds,
      ]);
      expect(c.shown(), [RideOptionKind.assistance, RideOptionKind.pet, RideOptionKind.childSeat]);
      expect(c.freightShown, RideOptionKind.freightKinds);
      expect(c.labelOf(RideOptionKind.pet), 'Bringing a pet');
      expect(c.labelOf(RideOptionKind.childSeat), 'Child safety seat');
      expect(c.labels.keys, [RideOptionKind.pet], reason: 'the built-in name and blanks are not kept');
      expect(c.childSeatMax, RideOptionsConfig.childSeatLimit);
      expect(RideOptionsConfig.fromSettings(c.toSettings()).toJson(), c.toJson(), reason: 'written back as read');
      // Hidden options are off when booking; the seats stay within the most.
      const o = RideOptions(childSeat: true, childSeats: 3, morePassengers: true);
      final allowed = c.copyWith(childSeatMax: 2).allowed(o);
      expect(allowed.morePassengers, isFalse);
      expect(allowed.childSeats, 2);
      // "Assistance required" needs something in the catalogue to pick.
      expect(c.shown(catalogue: const AssistanceCatalogue(items: [])), [RideOptionKind.pet, RideOptionKind.childSeat]);
      final none = c.copyWith(hidden: {...RideOptionKind.values});
      expect(none.anyShown(), isFalse);
    });

    test("the admin's names reach the driver's note, and are stamped as booked", () {
      const c = RideOptionsConfig(
        labels: {RideOptionKind.pet: 'Bringing a pet', RideOptionKind.childSeat: 'Baby seat', RideOptionKind.assistance: 'Special help'},
      );
      final o = RideOptions(
        childSeat: true,
        childSeats: 2,
        morePassengers: true,
        pet: true,
        pets: const [RidePet(type: 'Dog', size: 'M')],
        assistance: RideAssistance(items: [AssistancePick.of(_item('pregnant'))]),
      );
      expect(driverNote(options: o, names: c.renamed, note: 'Gate B'),
          'Baby seat: 2 · More than 4 passengers · Bringing a pet: 1 dog (M) · Special help: Pregnant · Gate B');
      expect(driverNote(options: o.copyWith(childSeats: 1), names: c.renamed)!.split(' · ').first, 'Baby seat');
      expect(driverNote(options: o), startsWith('2 child safety seats · More than 4 passengers · Pet with me: 1 dog (M) · '
          'Assistance: Pregnant'), reason: 'the built-in wording without renames');
      expect(c.namesFor(o), {
        'child-seat': 'Baby seat',
        'more-passengers': 'More than 4 passengers',
        'pet': 'Bringing a pet',
        'assistance': 'Special help',
      });
      expect(c.namesFor(const RideOptions(pet: true)), {'pet': 'Bringing a pet'});
      final r = RideRequest(const {'id': 'r', 'option_names': {'pet': 'Bringing a pet', 'assistance': 'Assistance required'}});
      expect(r.renamedOption(RideOptionKind.pet), 'Bringing a pet');
      expect(r.renamedOption(RideOptionKind.assistance), isNull, reason: 'the built-in name');
      expect(RideRequest(const {'id': 'r'}).renamedOption(RideOptionKind.pet), isNull);
    });

    test('commission and promo codes on the option charges: both by default, each its own switch', () {
      expect(OptionChargeRules.fromSettings(const {}).commission, isTrue);
      expect(OptionChargeRules.fromSettings(const {}).promo, isTrue);
      var s = mergeDisplaySettings(const {});
      s = setOptionChargeRules(s, commission: false);
      expect(OptionChargeRules.fromSettings(s).commission, isFalse);
      expect(OptionChargeRules.fromSettings(s).promo, isTrue);
      s = setOptionChargeRules(s, promo: false);
      expect(s[OptionChargeRules.key], {'commission': false, 'promo': false});
    });

    test('the catalogue: the starting list, a stored one, groups and a broken entry', () {
      final d = AssistanceCatalogue.fromSettings(const {});
      expect(d.items, hasLength(15));
      expect(d.groups, assistanceDefaultGroups);
      expect(d.byId('wheelchair')!.choices, hasLength(3));
      expect(d.byId('medical')!.choices, ['Portable oxygen', 'Mobility scooter', 'Other']);
      expect(d.byId(guideDogAssistanceId)!.emoji, '🦮');
      final s = AssistanceCatalogue.fromSettings({
        AssistanceCatalogue.key: [
          {'id': 'sign', 'name': ' Sign language ', 'emoji': '🤟', 'group': 'Talking', 'choices': ['BIM', 'BIM', ' ']},
          {'id': 'sign', 'name': 'Twice'},
          {'name': 'No id'},
          {'id': 'guide-dog', 'name': 'Guide dog', 'group': 'Mobility', 'charge': {'kind': 'fixed', 'value': 9}},
          {'id': 'x', 'name': 'Hidden one', 'hidden': true, 'charge': {'kind': 'percent', 'value': 500}},
        ],
      });
      expect([for (final i in s.items) i.id], ['sign', 'guide-dog', 'x']);
      expect(s.byId('sign')!.name, 'Sign language');
      expect(s.byId('sign')!.choices, ['BIM']);
      expect(s.groups, ['Mobility', 'Talking'], reason: 'the starting groups first, then the admin\'s own');
      expect(s.byId('guide-dog')!.charge, OptionCharge.none, reason: 'a guide dog is always free');
      expect(s.byId('x')!.charge.value, 100, reason: 'a percentage is at most 100');
      expect(s.visible.map((i) => i.id), ['sign', 'guide-dog']);
      expect(AssistanceCatalogue.fromSettings(s.toSettings()).items, s.items);
      expect(AssistanceCatalogue.fromSettings(const {AssistanceCatalogue.key: []}).items, isEmpty);
    });

    test('the summary, the note label, and what Done waits for', () {
      final c = const AssistanceCatalogue();
      final wheel = AssistancePick.of(_item('wheelchair'));
      expect(assistanceComplete(const [], c), isFalse);
      expect(assistanceMissingText(const [], c), 'Pick at least one.');
      expect(assistanceComplete([wheel], c), isFalse, reason: 'the wheelchair needs a choice');
      expect(assistanceMissingText([wheel], c), 'Choose an option for Wheelchair user.');
      final picked = wheel.withChoice('Electric / heavy');
      expect(assistanceComplete([picked], c), isTrue);
      final more = [picked, AssistancePick.of(_item('pregnant')), AssistancePick.of(_item('quiet')), AssistancePick.of(_item('pram'))];
      expect(assistanceSummary(more.take(1).toList()), 'Wheelchair user');
      expect(assistanceSummary(more.take(2).toList()), 'Wheelchair user, Pregnant');
      expect(assistanceSummary(more), 'Wheelchair user, Pregnant +2 more');
      expect(assistanceNoteLabel(more.take(2).toList()), 'Assistance: Wheelchair user (Electric / heavy), Pregnant');
      // On the booking: names and emoji copied in, the note beside them.
      final a = RideAssistance(items: [picked], note: ' Ring twice ');
      expect(a.toJson(), {
        'items': [
          {'id': 'wheelchair', 'name': 'Wheelchair user', 'emoji': '♿', 'choice': 'Electric / heavy'},
        ],
        'note': 'Ring twice',
      });
      expect(RideAssistance.fromJson(a.toJson()), RideAssistance(items: [picked], note: 'Ring twice'));
      expect(RideAssistance.fromJson({'items': []}), isNull);
      // The rider's note never goes in the note label: it is for the driver who takes the ride.
      final o = RideOptions(assistance: a);
      expect(driverNote(options: o), 'Assistance: Wheelchair user (Electric / heavy)');
      expect(o.any, isTrue);
      expect(o.copyWith(clearAssistance: true).any, isFalse);
      expect(driverNote(options: const RideOptions(childSeat: true, childSeats: 2)), '2 child safety seats');
    });

    test('the charge maths: per pet, per ride, size extras, a percentage; assistance fixed and %', () {
      const pets = PetConfig(
        charges: {
          'Dog': PetCharge(charge: OptionCharge(value: 5)),
          'Cat': PetCharge(charge: OptionCharge(kind: OptionChargeKind.percent, value: 10), perPet: false),
        },
        sizeExtras: {'L': 2, 'XL': 2},
      );
      const list = [
        RidePet(type: 'Dog', size: 'M'),
        RidePet(type: 'Dog', size: 'L'),
        RidePet(type: 'Cat', size: 'S'),
        RidePet(type: 'Cat', size: 'XL'),
      ];
      // Dogs: 5 each (10) + L 2; cats: 10% of 40 once (4) + XL 2.
      expect(petChargeFor(list, 40, pets), 18);
      expect(petChargeFor(const [RidePet(type: 'Rabbit', size: 'S')], 40, pets), 0, reason: 'no charge set');
      expect(petChargeFor(list, 40, const PetConfig()), 0, reason: 'nothing until the admin sets it');

      final help = AssistanceCatalogue(items: [
        _item('wheelchair').copyWith(charge: const OptionCharge(value: 3)),
        _item('quiet').copyWith(charge: const OptionCharge(kind: OptionChargeKind.percent, value: 5)),
        _item(guideDogAssistanceId).copyWith(charge: const OptionCharge(value: 9)),
      ]);
      final picks = [
        AssistancePick.of(_item('wheelchair'), choice: 'Electric / heavy'),
        AssistancePick.of(_item('quiet')),
        AssistancePick.of(_item(guideDogAssistanceId)),
        const AssistancePick(id: 'gone', name: 'Removed since'),
      ];
      expect(assistanceChargeFor(picks, 40, help), 5, reason: '3 + 5% of 40; the guide dog is free');

      final lines = rideOptionCharges(
        RideOptions(pet: true, pets: list, assistance: RideAssistance(items: picks)),
        40,
        pets: pets,
        assistance: help,
      );
      expect(lines, const [
        OptionChargeLine(kind: 'pet', name: 'Pet charge', amount: 18),
        OptionChargeLine(kind: 'assistance', name: 'Assistance charge', amount: 5),
      ]);
      expect(optionChargesTotal(lines), 23);
      expect(optionChargesText(lines, (v) => 'RM${trimNumber(v)}'), 'Pet charge RM18 · Assistance charge RM5');
      expect(parseOptionCharges([for (final l in lines) l.toJson()]), lines);
      expect(rideOptionCharges(const RideOptions(), 40, pets: pets, assistance: help), isEmpty);
      // The ride row reads them back.
      final r = RideRequest({'id': 'r', 'option_charges': [for (final l in lines) l.toJson()]});
      expect(r.optionCharges, lines);
    });

    test('pet types: names only, edited in the blob, the charges with them', () {
      expect(cleanPetTypeName(' 🐦 Bird  of prey '), 'Bird of prey');
      var s = mergeDisplaySettings(const {});
      s = addPetType(s, 'Iguana 🦎', charge: const PetCharge(charge: OptionCharge(value: 4), perPet: false));
      expect(petConfigOf(s).types.last, 'Iguana');
      expect(petConfigOf(s).chargeFor('Iguana'), const PetCharge(charge: OptionCharge(value: 4), perPet: false));
      expect(addPetType(s, 'dog'), s, reason: 'already on the list');
      s = updatePetType(s, 'Iguana', name: 'Lizard');
      expect(petConfigOf(s).types.last, 'Lizard');
      expect(petConfigOf(s).chargeFor('Lizard').charge.value, 4, reason: 'the charge goes with the name');
      s = movePetType(s, 'Lizard', -1);
      expect(petConfigOf(s).types, ['Dog', 'Cat', 'Rabbit', 'Guinea pig', 'Lizard', 'Hamster']);
      s = removePetType(s, 'Lizard');
      expect(petConfigOf(s).types, PetConfig.defaultTypes);
      expect(petConfigOf(s).charges, isEmpty);
      s = setPetSizeOffered(s, 'XS', false);
      s = setPetSizeExtra(s, 'L', 2);
      s = setPetMaxPerType(s, 99);
      expect(petConfigOf(s).sizes, ['S', 'M', 'L', 'XL']);
      expect(petConfigOf(s).sizeExtras, {'L': 2});
      expect(petConfigOf(s).maxPerType, 10);
    });
  });

  for (final b in Brightness.values) {
    final mode = b == Brightness.dark ? ' (dark)' : '';

    group('Admin: Ride Options$mode', () {
      Future<_FakeStore> pump(WidgetTester tester, [Map<String, dynamic> raw = const {}]) async {
        tester.view.physicalSize = const Size(900, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final store = _FakeStore(raw);
        await tester.pumpWidget(ProviderScope(
          retry: (_, _) => null,
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
            displayStoreProvider.overrideWithValue(store),
            regionsProvider.overrideWith(
              (ref) async => [
                RegionEntry(id: 'my', values: const {'country': 'Malaysia', 'currencyName': 'MYR'}),
                RegionEntry(id: 'sg', values: const {'country': 'Singapore', 'currencyName': 'SGD'}),
              ],
            ),
          ],
          child: MaterialApp(theme: appTheme(b), home: const AdminDisplaySettingsScreen()),
        ));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('ride-options-card')));
        await tester.pumpAndSettle();
        return store;
      }

      Future<void> unmount(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 1));
      }

      testWidgets('show or hide, rename, reorder; the child seat most', (tester) async {
        final store = await pump(tester);
        expect(find.text('Ride Options'), findsOneWidget);
        for (final k in RideOptionKind.values) {
          expect(find.byKey(ValueKey('ride-option-${k.id}')), findsOneWidget);
        }
        expect(find.text('Assistance required'), findsOneWidget);

        await _tapKey(tester, 'ride-option-shown-more-passengers');
        expect(rideOptionsOf(store.blob).hidden, {RideOptionKind.morePassengers});

        await _tapKey(tester, 'ride-option-rename-pet');
        expect(find.text('Rename option'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('text-dialog-field')), 'Bringing a pet');
        await _tapKey(tester, 'text-dialog-save');
        expect(rideOptionsOf(store.blob).labelOf(RideOptionKind.pet), 'Bringing a pet');
        expect(find.text('Bringing a pet'), findsOneWidget);
        expect(find.text('Built-in name: Pet with me'), findsOneWidget);

        await _tapKey(tester, 'ride-option-assistance-up');
        expect(rideOptionsOf(store.blob).order.indexOf(RideOptionKind.assistance), 2);

        final most = find.byKey(const ValueKey('child-seat-max'));
        await _tap(tester, find.descendant(of: most, matching: find.byTooltip('Increase')));
        await _tap(tester, find.descendant(of: most, matching: find.byTooltip('Increase')));
        expect(rideOptionsOf(store.blob).childSeatMax, 3);

        // Comments always stays: no switch to hide it.
        final comments = find.byKey(const ValueKey('ride-option-comments'));
        expect(comments, findsOneWidget);
        expect(find.descendant(of: comments, matching: find.byType(Switch)), findsNothing);
        expect(find.text('Always shown: riders can always leave the driver a note'), findsOneWidget);

        // Commission and promo codes on the option charges, each its own switch.
        await _tapKey(tester, 'option-charges-commission');
        expect(OptionChargeRules.fromSettings(store.blob).commission, isFalse);
        expect(OptionChargeRules.fromSettings(store.blob).promo, isTrue);
        await _tapKey(tester, 'option-charges-promo');
        expect(OptionChargeRules.fromSettings(store.blob).promo, isFalse);
        expect(
          tester.widget<IconButton>(find.descendant(of: most, matching: find.byType(IconButton)).last).onPressed,
          isNull,
          reason: 'at most 3',
        );
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });

      testWidgets('pet types added, renamed, removed; the sizes, the most and the photo; charges by place',
          (tester) async {
        final store = await pump(tester);
        await _tapKey(tester, 'ride-option-pet-settings');
        expect(find.text('Pet types'), findsOneWidget);
        // The charges moved to Charges and where offered.
        expect(find.byKey(const ValueKey('charges-by-place')), findsOneWidget);
        expect(find.byKey(const ValueKey('pet-size-extra-L')), findsNothing);

        await _tapKey(tester, 'pet-type-add');
        expect(find.byKey(const ValueKey('pet-type-charge')), findsNothing);
        await tester.enterText(find.byKey(const ValueKey('pet-type-name')), 'Iguana');
        await _tapKey(tester, 'pet-type-save');
        var c = petConfigOf(store.blob);
        expect(c.types.last, 'Iguana');

        // A duplicate name is refused in the dialog.
        await _tapKey(tester, 'pet-type-add');
        await tester.enterText(find.byKey(const ValueKey('pet-type-name')), 'cat');
        await _tapKey(tester, 'pet-type-save');
        expect(find.text('cat is already on the list.'), findsOneWidget);
        await _tap(tester, find.text('Cancel'));

        await _tapKey(tester, 'pet-type-remove-Hamster');
        await _tap(tester, find.text('Remove').last);
        c = petConfigOf(store.blob);
        expect(c.types, ['Dog', 'Cat', 'Rabbit', 'Guinea pig', 'Iguana']);

        await _tapKey(tester, 'pet-size-offered-XS');
        expect(petConfigOf(store.blob).sizes, ['S', 'M', 'L', 'XL']);
        await _tap(tester, find.descendant(of: find.byKey(const ValueKey('pet-max-per-type')), matching: find.byTooltip('Increase')));
        expect(petConfigOf(store.blob).maxPerType, 6);
        await _tapKey(tester, 'pet-photo-required');
        expect(petConfigOf(store.blob).photoRequired, isFalse);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });

      testWidgets('the assistance catalogue: add with choices, edit, hide, reorder, remove',
          (tester) async {
        final store = await pump(tester);
        await _tapKey(tester, 'ride-option-assistance-settings');
        expect(find.text('Mobility'), findsOneWidget);
        expect(find.byKey(const ValueKey('assist-admin-wheelchair')), findsOneWidget);

        await _tap(tester, find.text('Add help'));
        await tester.enterText(find.byKey(const ValueKey('assist-emoji')), '🤟');
        await tester.enterText(find.byKey(const ValueKey('assist-name')), 'Sign language');
        await tester.enterText(find.byKey(const ValueKey('assist-description')), 'I sign; please be patient');
        await _tapKey(tester, 'assist-group-new');
        await tester.enterText(find.byKey(const ValueKey('assist-group-name')), 'Talking');
        await _tapKey(tester, 'assist-choice-add');
        await _tapKey(tester, 'assist-choice-add');
        await tester.enterText(find.byKey(const ValueKey('assist-choice-field-0')), 'BIM');
        await tester.enterText(find.byKey(const ValueKey('assist-choice-field-1')), 'ASL');
        // Its charge is set by place now.
        expect(find.byKey(const ValueKey('assist-charge')), findsNothing);
        expect(find.byKey(const ValueKey('assist-charge-by-place')), findsOneWidget);
        await _tapKey(tester, 'assist-save');
        var c = assistanceOf(store.blob);
        final sign = c.items.last;
        expect(sign.name, 'Sign language');
        expect(sign.emoji, '🤟');
        expect(sign.group, 'Talking');
        expect(sign.choices, ['BIM', 'ASL']);
        expect(sign.charge, OptionCharge.none);
        expect(sign.id, startsWith('custom-'));
        expect(find.text('Talking'), findsOneWidget);

        // Edited: renamed, a choice gone.
        await _tapKey(tester, 'assist-admin-edit-${sign.id}');
        await tester.enterText(find.byKey(const ValueKey('assist-name')), 'Sign language (BIM)');
        await _tapKey(tester, 'assist-choice-remove-1');
        await _tapKey(tester, 'assist-save');
        c = assistanceOf(store.blob);
        expect(c.byId(sign.id)!.name, 'Sign language (BIM)');
        expect(c.byId(sign.id)!.choices, ['BIM']);

        // The guide dog can't be charged.
        await _tapKey(tester, 'assist-admin-edit-$guideDogAssistanceId');
        expect(find.byKey(const ValueKey('assist-always-free')), findsOneWidget);
        expect(find.byKey(const ValueKey('assist-charge')), findsNothing);
        await _tap(tester, find.text('Cancel'));

        await _tapKey(tester, 'assist-admin-shown-pregnant');
        expect(assistanceOf(store.blob).byId('pregnant')!.hidden, isTrue);
        await _tapKey(tester, 'assist-admin-down-wheelchair');
        expect(assistanceOf(store.blob).items[1].id, 'wheelchair');
        await _tapKey(tester, 'assist-admin-remove-elderly');
        await _tap(tester, find.text('Remove').last);
        expect(assistanceOf(store.blob).byId('elderly'), isNull);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    });

    group('Rider: the assistance sheet and the Options rows$mode', () {
      late RideOptions saved;

      Future<void> open(
        WidgetTester tester, {
        RideOptions start = const RideOptions(),
        RideOptionsConfig config = const RideOptionsConfig(),
        AssistanceCatalogue catalogue = const AssistanceCatalogue(),
      }) async {
        tester.view.physicalSize = const Size(420, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        saved = start;
        final note = TextEditingController();
        addTearDown(note.dispose);
        await tester.pumpWidget(
          ProviderScope(
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
                        config: config,
                        assistance: catalogue,
                      ),
                      child: const Text('Options'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await _tapKey(tester, 'open-options');
      }

      bool doneOn(WidgetTester tester) =>
          tester.widget<FilledButton>(find.byKey(const ValueKey('assist-done'))).onPressed != null;
      String hint(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('assist-missing'))).data!;

      testWidgets('pick items, a choice where asked, the note; Done rules; the summary; Cancel keeps; off clears',
          (tester) async {
        await open(tester);
        expect(find.text('Assistance required'), findsOneWidget);
        // The rows as they were: no emoji on them.
        expect(find.descendant(of: find.byKey(const ValueKey('ride-options')), matching: find.text('♿')), findsNothing);
        await _tapKey(tester, 'option-assistance');
        expect(find.byKey(const ValueKey('ride-assistance')), findsOneWidget);
        expect(find.text('What help do you need?'), findsOneWidget);
        expect(find.text('Mobility'), findsOneWidget);
        expect(find.text('♿'), findsOneWidget, reason: 'the sheet shows each item\'s emoji');
        expect(doneOn(tester), isFalse);
        expect(hint(tester), 'Pick at least one.');

        await _tapKey(tester, 'assist-item-wheelchair');
        expect(find.byKey(const ValueKey('assist-choice-wheelchair-0')), findsOneWidget);
        expect(doneOn(tester), isFalse, reason: 'the wheelchair needs a choice');
        expect(hint(tester), 'Choose an option for Wheelchair user.');
        await _tapKey(tester, 'assist-choice-wheelchair-1');
        expect(doneOn(tester), isTrue);
        await _tapKey(tester, 'assist-item-hearing');
        await _tapKey(tester, 'assist-item-pram');
        await _tapKey(tester, 'assist-item-medical');
        expect(doneOn(tester), isFalse);
        await _tapKey(tester, 'assist-choice-medical-0');
        await tester.enterText(find.byKey(const ValueKey('assist-note')), 'Ring the bell twice');
        await _tapKey(tester, 'assist-done');

        expect(find.byKey(const ValueKey('ride-assistance')), findsNothing);
        expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('option-assistance'))).value, isTrue);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('option-assistance-summary'))).data,
          'Wheelchair user, Deaf or hard of hearing +2 more',
        );
        final help = saved.assistance!;
        expect([for (final i in help.items) i.id], ['wheelchair', 'hearing', 'pram', 'medical']);
        expect(help.items.first.choice, 'Stays in the wheelchair (accessible car with ramp)');
        expect(help.items.last.choice, 'Portable oxygen');
        expect(help.note, 'Ring the bell twice');
        expect(driverNote(options: saved), contains('Assistance: Wheelchair user (Stays in the wheelchair'));
        expect(driverNote(options: saved), isNot(contains('Ring the bell')));

        // Edit, then Cancel and a tap on the scrim keep what was saved.
        await _tapKey(tester, 'option-assistance-edit');
        expect(tester.widget<Checkbox>(find.descendant(
          of: find.byKey(const ValueKey('assist-item-pram')),
          matching: find.byType(Checkbox),
        )).value, isTrue);
        await _tapKey(tester, 'assist-item-pram');
        await _tapKey(tester, 'assist-cancel');
        expect(saved.assistance!.items, hasLength(4));
        await _tapKey(tester, 'option-assistance-edit');
        await _tapKey(tester, 'assist-item-hearing');
        await tester.tapAt(const Offset(200, 10));
        await _settle(tester);
        expect(find.byKey(const ValueKey('ride-assistance')), findsNothing);
        expect(saved.assistance!.items, hasLength(4));

        // Off clears it, with no sheet.
        await _tapKey(tester, 'option-assistance');
        expect(find.byKey(const ValueKey('ride-assistance')), findsNothing);
        expect(saved.assistance, isNull);
        expect(find.byKey(const ValueKey('option-assistance-summary')), findsNothing);
      });

      testWidgets('cancelled with nothing saved, it stays off', (tester) async {
        await open(tester);
        await _tapKey(tester, 'option-assistance');
        await _tapKey(tester, 'assist-item-pregnant');
        await _tapKey(tester, 'assist-cancel');
        expect(saved.assistance, isNull);
        expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('option-assistance'))).value, isFalse);
      });

      testWidgets("the admin's order, names and hidden options; seats as a number", (tester) async {
        await open(
          tester,
          config: const RideOptionsConfig(
            order: [RideOptionKind.assistance, RideOptionKind.childSeat, RideOptionKind.pet, RideOptionKind.morePassengers],
            hidden: {RideOptionKind.morePassengers},
            labels: {RideOptionKind.pet: 'Bringing a pet'},
            childSeatMax: 2,
          ),
        );
        expect(find.byKey(const ValueKey('option-more-passengers')), findsNothing);
        expect(find.text('Bringing a pet'), findsOneWidget);
        final y = [
          for (final k in ['option-assistance', 'option-child-seat', 'option-pet'])
            tester.getTopLeft(find.byKey(ValueKey(k))).dy,
        ];
        expect(y, orderedEquals([...y]..sort()));
        expect(tester.widget<Text>(find.byKey(const ValueKey('option-child-seat-count'))).data, '0');
        await _tapKey(tester, 'option-child-seat-plus');
        await _tapKey(tester, 'option-child-seat-plus');
        expect(tester.widget<IconButton>(find.byKey(const ValueKey('option-child-seat-plus'))).onPressed, isNull);
        expect(saved.childSeat, isTrue);
        expect(saved.childSeats, 2);
        expect(saved.labels.first, '2 child safety seats');
        await _tapKey(tester, 'option-child-seat-minus');
        await _tapKey(tester, 'option-child-seat-minus');
        expect(saved.childSeat, isFalse);
      });

      testWidgets("a custom help item from the admin's catalogue", (tester) async {
        await open(
          tester,
          catalogue: const AssistanceCatalogue(items: [
            AssistanceItem(id: 'custom-1', name: 'Sign language', emoji: '🤟', group: 'Talking', choices: ['BIM', 'ASL']),
          ]),
        );
        await _tapKey(tester, 'option-assistance');
        expect(find.text('Talking'), findsOneWidget);
        await _tapKey(tester, 'assist-item-custom-1');
        expect(doneOn(tester), isFalse);
        await _tapKey(tester, 'assist-choice-custom-1-1');
        await _tapKey(tester, 'assist-done');
        expect(saved.assistance!.items.single, const AssistancePick(id: 'custom-1', name: 'Sign language', emoji: '🤟', choice: 'ASL'));
      });
    });

    group('Driver: a custom pet type and help item, and the charges$mode', () {
      final overrides = [
        rideRepositoryProvider.overrideWithValue(_Rides()),
        ridePetPhotoUrlProvider.overrideWith((ref, path) async => 'https://example.invalid/$path'),
      ];
      Map<String, dynamic> row(String status, {bool note = false}) => {
        'id': 'r1',
        'rider_id': 'u1',
        'status': status,
        'fare': 40,
        'currency': 'MYR',
        'pickup_name': 'KLCC',
        'drop_name': 'KL Sentral',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'pets': [
          {'type': 'Iguana', 'size': 'M'},
        ],
        'assistance': {
          'items': [
            {'id': 'custom-1', 'name': 'Sign language', 'emoji': '🤟', 'choice': 'ASL'},
            {'id': 'wheelchair', 'name': 'Wheelchair user', 'emoji': '♿', 'choice': 'Electric / heavy'},
          ],
          if (note) 'note': 'Ring the bell twice',
        },
        'option_charges': [
          {'kind': 'pet', 'name': 'Pet charge', 'amount': 10},
          {'kind': 'assistance', 'name': 'Assistance charge', 'amount': 5},
        ],
      };

      Future<void> sheet(WidgetTester tester, RideRequest r) async {
        tester.view.physicalSize = const Size(420, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
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
      }

      testWidgets('an open request: the flag, each item with its emoji and choice; the note after accepting',
          (tester) async {
        await sheet(tester, RideRequest(row('open')));
        expect(find.text('1 iguana (M)'), findsOneWidget);
        expect(find.text('Iguana · M'), findsOneWidget);
        expect(find.text('Rider needs assistance'), findsOneWidget);
        expect(find.text('🤟'), findsOneWidget);
        expect(find.text('Sign language'), findsOneWidget);
        expect(find.text('ASL'), findsOneWidget);
        expect(find.text('♿'), findsOneWidget);
        expect(find.byKey(const ValueKey('assist-note-after-accept')), findsOneWidget);
        expect(find.byKey(const ValueKey('assist-view-note')), findsNothing);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('option-charges-line'))).data,
          'Fare includes Pet charge RM10.00 · Assistance charge RM5.00',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets("the admin's names, as the ride was booked", (tester) async {
        await sheet(tester, RideRequest({
          ...row('open'),
          'option_names': {'pet': 'Bringing a pet', 'assistance': 'Special help'},
        }));
        expect(find.text('Bringing a pet'), findsOneWidget);
        expect(find.text('Special help'), findsOneWidget);
        expect(find.text('Rider needs assistance'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('a taken ride shows the note', (tester) async {
        await sheet(tester, RideRequest(row('accepted', note: true)));
        expect(find.byKey(const ValueKey('assist-note-after-accept')), findsNothing);
        expect(find.text('“Ring the bell twice”'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('the help on its own, as the trip screen and admins show it', (tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: appTheme(b),
          home: Scaffold(body: RideAssistanceView(assistance: RideRequest(row('on_trip', note: true)).assistance!)),
        ));
        expect(find.text('Rider needs assistance'), findsOneWidget);
        expect(find.text('Electric / heavy'), findsOneWidget);
        expect(find.text('“Ring the bell twice”'), findsOneWidget);
      });
    });
  }
}
