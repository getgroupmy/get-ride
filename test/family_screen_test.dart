// Family (migration 0317) on a phone, in light and dark: the host's page
// (members, what each gets, invite by phone), an invite's plain terms and
// Join, a member's page (who can see, Leave), the "Shared with family" chip
// on a trip, the driver's check of a child passenger, and Admin › People ›
// Family (values by place, the Modules and Family matrix) and Families (the
// logged God View look needs a reason).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/family/family_list_screen.dart';
import 'package:get_ride/src/admin/screens/family/family_settings_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/family.dart';
import 'package:get_ride/src/core/format.dart' show formatMoney;
import 'package:get_ride/src/data/family_repository.dart';
import 'package:get_ride/src/features/family/family_screen.dart';
import 'package:get_ride/src/features/family/family_trip_parts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _now = DateTime(2026, 10, 28, 10);

String _m(num v) => formatMoney(v);

Map<String, dynamic> _member(String id, String name,
        {String kind = 'member', String status = 'active', Map<String, dynamic> more = const {}}) =>
    {
      'id': id,
      'name': name,
      'kind': kind,
      'status': status,
      'limit': 200,
      'monthlyLimit': 200,
      'spent': 84.2,
      'left': 115.8,
      'location': 'ride',
      'locationNow': 'ride',
      ...more,
    };

const _modules = [
  {'key': 'ride', 'name': 'Ride', 'familyPays': true, 'bookForMember': true, 'childAllowed': true, 'liveShare': true},
  {'key': 'city_to_city', 'name': 'City to City', 'familyPays': true, 'bookForMember': true},
  {'key': 'courier', 'name': 'Courier', 'familyPays': true, 'bookForMember': true},
  {'key': 'freight', 'name': 'Freight'},
];

Map<String, dynamic> _hostView({int count = 3}) => {
  'role': 'host',
  'family': {'id': 'f1', 'hostName': 'Karpal Contoh', 'cap': 6, 'count': count, 'spent': 184.2},
  'members': [
    _member('m1', 'Aisha Contoh', more: {'relation': 'daughter', 'onTrip': true}),
    _member('c1', 'Iman Contoh', kind: 'child', more: {'relation': 'son', 'birthDate': '2014-05-01'}),
    _member('m2', 'Raj Contoh', status: 'invited',
        more: {'relation': 'husband', 'expiresAt': DateTime(2026, 11, 2, 12).toUtc().toIso8601String()}),
  ],
  'settings': const FamilySettings().toJson(),
  'modules': _modules,
};

class _Repo extends FamilyRepository {
  _Repo() : super(_db);

  Map<String, dynamic> view = _hostView();
  List<FamilyInvite> invited = [];
  final sent = <Map<String, dynamic>>[];
  final responded = <(String, bool)>[];
  var left = 0;
  FamilyTripStatus trip = const FamilyTripStatus();
  FamilyChildCheck? child;
  final codes = <String>[];
  List<FamilyPlaceRules> placeRows = const [
    FamilyPlaceRules(id: 'p0', place: FamilyPlace(), rules: {'maxMembers': 6, 'locationRule': 'ride'}),
  ];
  final savedPlaces = <FamilyPlaceRules>[];
  final savedRules = <FamilyModuleRule>[];
  final looks = <(String, String, String)>[];

  @override
  Future<FamilyView> mine({Geo? place}) async => FamilyView.fromJson(view);
  @override
  Future<List<FamilyInvite>> invites() async => invited;
  @override
  Future<FamilyMember> invite({
    required String phone,
    required String name,
    String? relation,
    double? monthlyLimit,
    double? perRideLimit,
    List<String>? services,
    FamilyLocationRule location = FamilyLocationRule.ride,
    Geo? place,
  }) async {
    sent.add({'phone': phone, 'name': name, 'monthly': monthlyLimit, 'perRide': perRideLimit, 'location': location});
    return FamilyMember(id: 'new', name: name, status: 'invited');
  }

  @override
  Future<void> respond(String memberId, {required bool join, List<String> shown = const []}) async {
    responded.add((memberId, join));
    invited = [];
    if (join) {
      view = {
        'role': 'member',
        'family': {'id': 'f1', 'hostName': 'Karpal Contoh', 'cap': 6, 'count': 3},
        'me': _member('m1', 'Aisha Contoh'),
        'settings': const FamilySettings().toJson(),
        'modules': _modules,
      };
    }
  }

  @override
  Future<void> leave() async {
    left++;
    view = {'role': 'none', 'settings': const FamilySettings().toJson(), 'modules': _modules};
  }

  @override
  Future<List<FamilyLiveItem>> live() async => const [];
  @override
  Future<List<FamilyViewLogEntry>> myViewLog() async => const [];
  @override
  Future<FamilyTripStatus> tripStatus(String tripId) async => trip;
  @override
  Future<FamilyChildCheck?> driverChild(String tripId) async => child;
  @override
  Future<FamilyChildCode?> childCode(String tripId) async => null;

  @override
  Future<({bool ok, int triesLeft, bool locked})> verifyPickupCode(String tripId, String code) async {
    codes.add(code);
    if (code == '4827') {
      child = FamilyChildCheck.fromJson({'name': 'Iman Contoh', 'age': 12, 'bookedBy': 'Karpal', 'verified': true});
      return (ok: true, triesLeft: 2, locked: false);
    }
    return (ok: false, triesLeft: 2, locked: false);
  }

  @override
  Future<List<FamilyPlaceRules>> places() async => placeRows;
  @override
  Future<void> savePlace(FamilyPlaceRules p) async => savedPlaces.add(p);
  @override
  Future<List<({String key, String name})>> registeredModules() async => const [
    (key: 'ride', name: 'Ride'),
    (key: 'freight', name: 'Freight'),
    (key: 'get_plus', name: 'GET.Plus'),
    (key: 'new_module', name: 'New module (example)'),
  ];
  @override
  Future<List<FamilyModuleRule>> moduleRules() async => const [
    FamilyModuleRule(place: FamilyPlace(), moduleKey: 'ride', id: 'r1', familyPays: true, bookForMember: true,
        childAllowed: true, liveShare: true),
  ];
  @override
  Future<void> saveModuleRule(FamilyModuleRule r) async => savedRules.add(r);
  @override
  Future<List<FamilyAdminRow>> adminList({String? search}) async => [
    FamilyAdminRow.fromJson({'id': 'f1', 'hostName': 'Karpal Contoh', 'hostPhone': '+60100317001', 'cap': 6,
        'count': 3, 'children': 1, 'place': {'country': 'Malaysia'}}),
  ];
  @override
  Future<List<FamilyCapRequest>> capRequests() async => const [];
  @override
  Future<List<FamilyViewLogEntry>> adminViewLog({String? familyId}) async => const [];
  @override
  Future<Map<String, dynamic>> adminView(String familyId, String kind, String reason) async {
    looks.add((familyId, kind, reason));
    return {'members': [_member('m1', 'Aisha Contoh')], 'trips': const []};
  }
}

Future<_Repo> _pump(WidgetTester tester, Widget home,
    {Brightness b = Brightness.light, _Repo? repo, Size size = const Size(420, 1000)}) async {
  final r = repo ?? _Repo();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        ...quietLiveOverrides,
        familyRepositoryProvider.overrideWithValue(r),
        familyClockProvider.overrideWithValue(() => _now),
        pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
      ],
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return r;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('the host sees members, what each gets, and invites by phone (${b.name})', (tester) async {
      final repo = await _pump(tester, const FamilyScreen(), b: b);
      expect(find.text('3 of 6 members · spent this month ${_m(184.2)} of ${_m(200)}'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Child'), findsOneWidget);
      expect(find.text('Invited'), findsOneWidget);
      expect(find.text('Invited · expires in 5 days'), findsOneWidget);
      // The first member's card: what she gets and has agreed to.
      expect(find.text('Pays with my GET.wallet'), findsOneWidget);
      expect(find.text('${_m(200)} a month · ${_m(115.8)} left'), findsOneWidget);
      expect(find.text('Who can see Aisha'), findsOneWidget);
      expect(find.text('Me (they see this list)'), findsOneWidget);
      // The child's.
      await _tap(tester, find.byKey(const ValueKey('family-member-c1')));
      expect(find.text('New 4 digits every ride'), findsOneWidget);
      expect(find.text('Women drivers (admin rule)'), findsOneWidget);
      // Invite by phone.
      await _tap(tester, find.byKey(const ValueKey('family-add')));
      await _tap(tester, find.byKey(const ValueKey('family-add-invite')));
      await tester.enterText(find.byKey(const ValueKey('family-invite-name')), 'Mak Cik');
      await tester.enterText(find.byKey(const ValueKey('family-invite-phone')), '+60 12 345 6789');
      await tester.enterText(find.byKey(const ValueKey('family-monthly')), '5000');
      await tester.pumpAndSettle();
      expect(find.text('Up to ${_m(1000)} a month.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('family-monthly')), '150');
      await _tap(tester, find.byKey(const ValueKey('family-per-ride-50')));
      await _tap(tester, find.byKey(const ValueKey('family-invite-save')));
      await closeNotice(tester);
      expect(repo.sent.single['name'], 'Mak Cik');
      expect(repo.sent.single['monthly'], 150);
      expect(repo.sent.single['perRide'], 50);
      expect(repo.sent.single['location'], FamilyLocationRule.ride);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an invitee reads the terms, joins, sees who can see them, and leaves (${b.name})', (tester) async {
      final repo = _Repo()
        ..view = {'role': 'none', 'settings': const FamilySettings().toJson(), 'modules': _modules}
        ..invited = [
          FamilyInvite.fromJson(_member('m1', 'Aisha', status: 'invited', more: {
            'hostName': 'Karpal Contoh',
            'adminLocationRule': 'ride',
            'modules': ['Ride', 'City to City', 'Courier', 'GET.Plus'],
          })),
        ];
      await _pump(tester, const FamilyScreen(), b: b, repo: repo);
      expect(find.text('Karpal Contoh added you to their family'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('family-invite-m1')));
      expect(find.text('Read what joining means. Nothing is shared until you tap Join.'), findsOneWidget);
      expect(find.textContaining('up to ${_m(200)} a month, for Ride, City to City and Courier.'), findsOneWidget);
      // GET.Plus covered by the host's membership (0323): its own line.
      expect(find.textContaining("Karpal's GET.Plus covers you too"), findsOneWidget);
      expect(find.text('You can leave at any time; sharing stops at once.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('family-join')));
      await closeNotice(tester);
      expect(repo.responded, [('m1', true)]);
      expect(find.text("You're in Karpal's family"), findsOneWidget);
      expect(find.textContaining('your location while you are on a ride the family covers'), findsOneWidget);
      expect(find.textContaining('GET.ride safety team'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('family-leave')));
      await _tap(tester, find.byKey(const ValueKey('family-leave-confirm')));
      await closeNotice(tester);
      expect(repo.left, 1);
      expect(find.text('Ride as a family'), findsOneWidget);
    });

    testWidgets('a trip shows "Shared with family" only while the host can see it (${b.name})', (tester) async {
      final repo = _Repo()..trip = FamilyTripStatus.fromJson({'family': true, 'familyPays': true, 'payer': 'Karpal'});
      await _pump(tester, const Scaffold(body: FamilyTripStrip(tripId: 't1')), b: b, repo: repo);
      expect(find.byKey(const ValueKey('family-shared-chip')), findsNothing);
      expect(find.text("Paid with Family · Karpal's GET.wallet"), findsOneWidget);

      final shared = _Repo()
        ..trip = FamilyTripStatus.fromJson({
          'family': true,
          'shared': true,
          'familyPays': true,
          'payer': 'Karpal',
          'left': 115.8,
          'viewers': [
            {'name': 'Karpal', 'what': 'Live location until drop-off'},
          ],
        });
      await _pump(tester, const Scaffold(body: FamilyTripStrip(tripId: 't2')), b: b, repo: shared);
      expect(find.byKey(const ValueKey('family-shared-chip')), findsOneWidget);
      expect(find.text('Who can see this ride'), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('family-shared-chip')));
      expect(find.text('Who can see this ride'), findsOneWidget);
      expect(find.text('Karpal (family host): live location until drop-off.'), findsOneWidget);
      expect(find.text("Paid with Family · Karpal's GET.wallet (${_m(115.8)} left this month)"), findsOneWidget);
    });

    testWidgets('the driver checks a child passenger: photo, code, tries (${b.name})', (tester) async {
      final repo = _Repo()
        ..child = FamilyChildCheck.fromJson({'name': 'Iman Contoh', 'age': 12, 'bookedBy': 'Karpal', 'triesLeft': 3});
      var verified = 0;
      await _pump(tester, Scaffold(body: ListView(children: [DriverChildCheck(tripId: 't1', onVerified: () => verified++)])),
          b: b, repo: repo);
      expect(find.text('Child passenger'), findsOneWidget);
      expect(find.textContaining('Iman Contoh, 12, booked by Karpal.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('family-driver-child-code')), '1111');
      await _tap(tester, find.byKey(const ValueKey('family-driver-child-check')));
      expect(find.text('Wrong code. 2 tries left.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('family-driver-child-code')), '4827');
      await _tap(tester, find.byKey(const ValueKey('family-driver-child-check')));
      expect(verified, 1);
      expect(find.byKey(const ValueKey('family-driver-child-ok')), findsOneWidget);
      expect(repo.codes, contains('4827'));
    });

    testWidgets('admin: values by place and the Modules and Family matrix (${b.name})', (tester) async {
      final repo = await _pump(tester, const FamilySettingsScreen(), b: b, size: const Size(1300, 1600));
      expect(find.text('Family · Default (everywhere)'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('family-value-maxMembers'))).data, '6');
      await _tap(tester, find.byKey(const ValueKey('family-up-maxMembers')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('family-value-maxMembers'))).data, '7');
      await _tap(tester, find.byKey(const ValueKey('family-values-save')));
      await closeNotice(tester);
      expect(repo.savedPlaces.single.rules['maxMembers'], 7);
      // Every registered module is listed; a new one is off.
      expect(find.text('New module (example)'), findsOneWidget);
      final box = tester.widget<Checkbox>(find.byKey(const ValueKey('family-matrix-new_module-0')));
      expect(box.value, isFalse);
      expect(tester.widget<Checkbox>(find.byKey(const ValueKey('family-matrix-ride-0'))).value, isTrue);
      await _tap(tester, find.byKey(const ValueKey('family-matrix-new_module-0')));
      expect(repo.savedRules.single.moduleKey, 'new_module');
      expect(repo.savedRules.single.familyPays, isTrue);
      // GET.Plus (0323): a real row, only "Family pays" applies, off by default.
      expect(find.text('GET.Plus'), findsOneWidget);
      expect(find.byKey(const ValueKey('family-matrix-get_plus-note')), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byKey(const ValueKey('family-matrix-get_plus-0'))).value, isFalse);
      for (var i = 1; i < 4; i++) {
        expect(find.descendant(of: find.byKey(ValueKey('family-matrix-get_plus-$i')), matching: find.byType(Checkbox)),
            findsNothing);
        expect(tester.widget<Text>(find.byKey(ValueKey('family-matrix-get_plus-$i'))).data, '–');
      }
      expect(find.text('God View access to family members'), findsOneWidget);
    });

    testWidgets('admin: the logged God View look needs a reason (${b.name})', (tester) async {
      final repo = await _pump(tester, const FamilyListScreen(), b: b, size: const Size(1000, 1200));
      expect(find.text('Karpal Contoh'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('family-admin-look-f1')));
      expect(find.text('This look is logged with your name, the time and the reason. The members can read it.'),
          findsOneWidget);
      final open = find.byKey(const ValueKey('family-reason-open'));
      expect(tester.widget<FilledButton>(open).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('family-reason-text')), 'SOS from the member at 3 pm');
      await _tap(tester, find.byKey(const ValueKey('family-reason-sos')));
      expect(tester.widget<FilledButton>(open).onPressed, isNotNull);
      await _tap(tester, open);
      expect(repo.looks.single, ('f1', 'sos', 'SOS from the member at 3 pm'));
      expect(find.byKey(const ValueKey('family-admin-view')), findsOneWidget);
    });
  }
}
