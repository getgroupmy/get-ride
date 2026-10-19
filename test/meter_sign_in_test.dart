import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_digital_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_store.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/launch_destination.dart';
import 'package:get_ride/src/core/meter_sign_in.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/meter_launch_store.dart';
import 'package:get_ride/src/data/meter_session_store.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/meter/meter_providers.dart';
import 'package:get_ride/src/features/meter/meter_session_toggle.dart';
import 'package:get_ride/src/features/partner/partner_menu.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

MeterProfile _card({String level = 'master', String? city, String mode = 'off', String id = 'm'}) =>
    defaultMeterProfile.copyWith(id: id, level: level, city: () => city, meterAtSignIn: mode);

const _teksi = ['teksi'];
const _klang = (country: 'Malaysia', state: 'Selangor', city: 'Klang', suburb: null);

Partner _partner({List<String> types = _teksi}) =>
    Partner({'id': 'p1', 'name': 'Aina', 'status': 'approved', 'partner_types': types});

/// The fake sign-in: an account and when it signed in.
class _User extends Notifier<String?> {
  @override
  String? build() => 'u1|09:00';
  void set(String? session) => state = session;
}

final _user = NotifierProvider<_User, String?>(_User.new);

class _Home extends ConsumerStatefulWidget {
  const _Home();

  @override
  ConsumerState<_Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<_Home> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeAutoLaunchMeter(context, ref);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('HOME'));
}

class _FakeStore extends MeterSettingsStore {
  _FakeStore() : super(SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)));
  MeterProfile? saved;

  @override
  Future<void> save(MeterProfile profile) async => saved = profile;
}

void main() {
  group('the decision', () {
    test('Off leaves it to Open the meter on launch, whatever was chosen', () {
      for (final choice in [null, true, false]) {
        expect(resolveMeterSignIn(mode: 'off', choice: choice), MeterSignInAction.autoLaunch);
      }
    });

    test('Ask the driver: asks once per sign-in, then the answer holds', () {
      expect(resolveMeterSignIn(mode: 'ask', choice: null), MeterSignInAction.ask);
      expect(resolveMeterSignIn(mode: 'ask', choice: true), MeterSignInAction.autoLaunch,
          reason: 'on: the launch rules apply for the sign-in');
      expect(resolveMeterSignIn(mode: 'ask', choice: false), MeterSignInAction.stayOff,
          reason: 'not now: no auto-open on reopen');
    });

    test('Always on: on at sign-in without a question; the driver can still turn it off', () {
      expect(resolveMeterSignIn(mode: 'always', choice: null), MeterSignInAction.meterOn);
      expect(resolveMeterSignIn(mode: 'always', choice: true), MeterSignInAction.autoLaunch);
      expect(resolveMeterSignIn(mode: 'always', choice: false), MeterSignInAction.stayOff);
    });

    test('an unknown choice reads Off', () {
      expect(meterAtSignInMode('sometimes'), 'off');
      expect(meterAtSignInMode(null), 'off');
      expect(resolveMeterSignIn(mode: 'sometimes', choice: null), MeterSignInAction.autoLaunch);
    });

    test('the Meter on/off switch shows only for Ask and Always', () {
      expect(showMeterSessionToggle('off'), isFalse);
      expect(showMeterSessionToggle('ask'), isTrue);
      expect(showMeterSessionToggle('always'), isTrue);
    });

    test('only a TEKSI partner cleared to drive gets the card\'s choice; the card for the geography decides', () {
      final cards = [_card(mode: 'always'), _card(id: 'k', level: 'city', city: 'Klang', mode: 'ask')];
      expect(resolveMeterAtSignIn(profiles: cards, partnerTypes: _teksi, canDrive: true), 'always');
      expect(resolveMeterAtSignIn(profiles: cards, partnerTypes: _teksi, canDrive: true, geo: _klang), 'ask');
      expect(resolveMeterAtSignIn(profiles: cards, partnerTypes: ['ehailing'], canDrive: true), 'off');
      expect(resolveMeterAtSignIn(profiles: cards, partnerTypes: _teksi, canDrive: false), 'off');
      expect(resolveMeterAtSignIn(profiles: const [], partnerTypes: _teksi, canDrive: true), 'off');
    });
  });

  group('the card', () {
    Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) =>
        {...meterProfileToRow(defaultMeterProfile), 'id': 'm', ...extra};

    test('stored as meter_at_sign_in, Off by default', () {
      expect(defaultMeterProfile.meterAtSignIn, 'off');
      expect(meterProfileToRow(_card(mode: 'ask'))['meter_at_sign_in'], 'ask');
      expect(normalizeMeterProfile(row({'meter_at_sign_in': 'always'}))!.meterAtSignIn, 'always');
      expect(normalizeMeterProfile(row()..remove('meter_at_sign_in'))!.meterAtSignIn, 'off');
      expect(normalizeMeterProfile(row({'meter_at_sign_in': 'bogus'}))!.meterAtSignIn, 'off');
    });

    test('an optional column group (0243): a database without it still reads and saves cards', () {
      expect(meterSettingsColumns(), contains('meter_at_sign_in'));
      expect(meterSettingsColumns(['meter_at_sign_in']), isNot(contains('meter_at_sign_in')));
      expect(meterOptionalGroupNamed('column meter_digital_settings.meter_at_sign_in does not exist')?.migration, '0243');
      expect(describeMissingMeterColumns(['meter_at_sign_in']), contains('Meter at sign-in'));
      expect(meterRowWithoutGroups(row(), ['meter_at_sign_in']).containsKey('meter_at_sign_in'), isFalse);
    });

    test('kept with the cards on the device', () async {
      SharedPreferences.setMockInitialValues({});
      await MeterLaunchStore().saveCards([_card(mode: 'ask')]);
      expect((await MeterLaunchStore().readCards()).single.meterAtSignIn, 'ask');
    });
  });

  group('the answer on the device', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('holds for its sign-in only, and signing out forgets it', () async {
      final store = MeterSessionStore();
      expect(await store.read('u1|09:00'), isNull);
      await store.save('u1|09:00', false);
      expect(await store.read('u1|09:00'), isFalse);
      expect(await store.read('u1|10:00'), isNull, reason: 'a new sign-in');
      expect(await store.read('u2|09:00'), isNull, reason: 'another account');
      await store.save('u1|09:00', true);
      expect(await store.read('u1|09:00'), isTrue);
      await MeterSessionStore.clear();
      expect(await store.read('u1|09:00'), isNull);
    });
  });

  group('the card for this driver', () {
    ProviderContainer container({Partner? partner, List<MeterProfile>? cards}) {
      final c = ProviderContainer(overrides: [
        partnerProvider.overrideWith((_) async => partner),
        meterCardsProvider.overrideWith((_) async => cards ?? [_card(mode: 'ask')]),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a TEKSI partner gets the card\'s choice, anyone else Off', () async {
      expect(await container(partner: _partner()).read(meterAtSignInProvider.future), 'ask');
      expect(await container(partner: _partner(types: ['ehailing'])).read(meterAtSignInProvider.future), 'off');
      expect(await container().read(meterAtSignInProvider.future), 'off');
    });

    test('uses the geography the meter last ran in', () async {
      await MeterLaunchStore().saveGeo(_klang);
      final cards = [_card(), _card(id: 'k', level: 'city', city: 'Klang', mode: 'always')];
      expect(await container(partner: _partner(), cards: cards).read(meterAtSignInProvider.future), 'always');
    });
  });

  for (final b in Brightness.values) {
    group('at sign-in (${b.name})', () {
      late int autoLaunchAsked;

      setUp(() {
        AppLaunch.firstAppLocation = null;
        SharedPreferences.setMockInitialValues({});
      });
      tearDown(() => AppLaunch.firstAppLocation = null);

      /// One launch of the app: a fresh provider scope over the same device.
      Future<void> launch(
        WidgetTester tester, {
        required String mode,
        bool autoLaunch = false,
        String session = 'u1|09:00',
        ({bool rider, String? partnerTripId}) ongoing = (rider: false, partnerTripId: null),
      }) async {
        autoLaunchAsked = 0;
        AppLaunch.firstAppLocation = null;
        await tester.pumpWidget(const SizedBox());
        final router = GoRouter(routes: [
          GoRoute(path: '/', builder: (_, _) => const _Home()),
          GoRoute(path: '/meter', builder: (_, _) => const Scaffold(body: Text('METER'))),
          GoRoute(path: '/drive/trip/:id', builder: (_, s) => Scaffold(body: Text('TRIP ${s.pathParameters['id']}'))),
        ]);
        addTearDown(router.dispose);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            meterLaunchSessionProvider.overrideWithValue(session),
            ongoingRidesProvider.overrideWith((_) async => ongoing),
            meterAtSignInProvider.overrideWith((_) async => mode),
            meterAutoLaunchProvider.overrideWith((_) async {
              autoLaunchAsked++;
              return autoLaunch;
            }),
            partnerProvider.overrideWith((_) async => null),
          ],
          child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
        ));
        await tester.pumpAndSettle();
      }

      final prompt = find.byKey(const ValueKey('meter-sign-in-prompt'));

      testWidgets('Off: nothing new, Open the meter on launch alone decides', (tester) async {
        // An answer left from when the card asked does not count once it is Off.
        await MeterSessionStore().save('u1|09:00', false);
        await launch(tester, mode: 'off', autoLaunch: true);
        expect(prompt, findsNothing);
        expect(find.text('METER'), findsOneWidget);
        await launch(tester, mode: 'off');
        expect(prompt, findsNothing);
        expect(find.text('HOME'), findsOneWidget);
        expect(autoLaunchAsked, 1);
      });

      testWidgets('Ask, Turn the meter on: lands on the meter, then the launch rules apply', (tester) async {
        await launch(tester, mode: 'ask');
        expect(prompt, findsOneWidget);
        expect(find.text('Turn the meter on?'), findsOneWidget);
        expect(autoLaunchAsked, 0);
        await tester.tap(find.byKey(const ValueKey('meter-sign-in-on')));
        await tester.pumpAndSettle();
        expect(find.text('METER'), findsOneWidget);
        expect(await MeterSessionStore().read('u1|09:00'), isTrue);

        // Reopened in the same sign-in: no question, Open the meter on launch decides.
        await launch(tester, mode: 'ask', autoLaunch: true);
        expect(prompt, findsNothing);
        expect(find.text('METER'), findsOneWidget);
        await launch(tester, mode: 'ask');
        expect(prompt, findsNothing);
        expect(find.text('HOME'), findsOneWidget);
      });

      testWidgets('Ask, Not now: the app as usual, and reopening does not open the meter', (tester) async {
        await launch(tester, mode: 'ask', autoLaunch: true);
        await tester.tap(find.byKey(const ValueKey('meter-sign-in-not-now')));
        await tester.pumpAndSettle();
        expect(find.text('HOME'), findsOneWidget);
        expect(find.text('METER'), findsNothing);
        expect(await MeterSessionStore().read('u1|09:00'), isFalse);

        await launch(tester, mode: 'ask', autoLaunch: true);
        expect(prompt, findsNothing);
        expect(find.text('HOME'), findsOneWidget);
        expect(autoLaunchAsked, 0, reason: 'turned off for the sign-in');

        // Signing in again asks again.
        await launch(tester, mode: 'ask', autoLaunch: true, session: 'u1|18:00');
        expect(prompt, findsOneWidget);
      });

      testWidgets('Ask waits while a trip is in progress', (tester) async {
        await launch(tester, mode: 'ask', ongoing: (rider: false, partnerTripId: 'r9'));
        expect(prompt, findsNothing);
        expect(find.text('TRIP r9'), findsOneWidget);
        expect(await MeterSessionStore().read('u1|09:00'), isNull);
      });

      testWidgets('Always on: the meter at sign-in, only at sign-in', (tester) async {
        await launch(tester, mode: 'always');
        expect(prompt, findsNothing);
        expect(find.text('METER'), findsOneWidget);
        expect(await MeterSessionStore().read('u1|09:00'), isTrue);

        // A reopen follows Open the meter on launch (off here).
        await launch(tester, mode: 'always');
        expect(find.text('HOME'), findsOneWidget);
        expect(autoLaunchAsked, 1);
      });

      testWidgets('Always on, mid-trip: back to the trip, and the meter is on for the sign-in', (tester) async {
        await launch(tester, mode: 'always', ongoing: (rider: false, partnerTripId: 'r9'));
        expect(find.text('TRIP r9'), findsOneWidget);
        expect(await MeterSessionStore().read('u1|09:00'), isTrue);
      });
    });

    group('Meter on/off in the driver menu (${b.name})', () {
      setUp(() => SharedPreferences.setMockInitialValues({}));

      Future<void> pump(WidgetTester tester, String mode, {bool? choice}) async {
        if (choice != null) await MeterSessionStore().save('u1|09:00', choice);
        tester.view.physicalSize = const Size(400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final router = GoRouter(routes: [
          GoRoute(
            path: '/',
            builder: (c, _) => Scaffold(
              body: Center(
                child: TextButton(onPressed: () => showPartnerMenu(c), child: const Text('MENU')),
              ),
            ),
          ),
          GoRoute(path: '/meter', builder: (_, _) => const Scaffold(body: Text('METER'))),
        ]);
        addTearDown(router.dispose);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            meterLaunchSessionProvider.overrideWith((ref) => ref.watch(_user)),
            meterAtSignInProvider.overrideWith((_) async => mode),
            partnerProvider.overrideWith((_) async => _partner()),
            displaySettingsBlobProvider.overrideWith((_) async => const <String, dynamic>{}),
          ],
          child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('MENU'));
        await tester.pumpAndSettle();
      }

      final toggle = find.byKey(const ValueKey('meter-session-toggle'));

      testWidgets('turning it on opens the meter and keeps it on for the sign-in', (tester) async {
        await pump(tester, 'ask', choice: false);
        expect(toggle, findsOneWidget);
        expect(find.text('Meter on/off'), findsOneWidget);
        expect(find.text('Off for this sign-in'), findsOneWidget);
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('METER'), findsOneWidget);
        expect(await MeterSessionStore().read('u1|09:00'), isTrue);
      });

      testWidgets('turning it off keeps the menu and turns the meter off for the sign-in', (tester) async {
        await pump(tester, 'always', choice: true);
        expect(find.text('On for this sign-in'), findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('Off for this sign-in'), findsOneWidget);
        expect(find.text('METER'), findsNothing);
        expect(await MeterSessionStore().read('u1|09:00'), isFalse);
      });

      testWidgets('not there when the card is Off', (tester) async {
        await pump(tester, 'off');
        expect(find.byKey(const ValueKey('partner-menu')), findsOneWidget);
        expect(toggle, findsNothing);
      });
    });

    testWidgets('the switch on its own reads the theme (${b.name})', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(ProviderScope(
        overrides: [
          meterLaunchSessionProvider.overrideWithValue('u1|09:00'),
          meterAtSignInProvider.overrideWith((_) async => 'ask'),
        ],
        child: MaterialApp(theme: appTheme(b), home: const Scaffold(body: MeterSessionToggle())),
      ));
      await tester.pumpAndSettle();
      final title = tester.widget<Text>(find.text('Meter on/off'));
      final ctx = tester.element(find.text('Meter on/off'));
      expect(Theme.of(ctx).brightness, b);
      expect(title.style, isNull, reason: 'the list tile styles it from the theme');
    });

    group('Admin: Meter at sign-in (${b.name})', () {
      Future<_FakeStore> pump(WidgetTester tester, {MeterProfile? card, AccessLevel access = AccessLevel.edit}) async {
        tester.view.physicalSize = const Size(900, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final store = _FakeStore();
        await tester.pumpWidget(ProviderScope(
          overrides: [
            meterStoreProvider.overrideWithValue(store),
            pageAccessProvider.overrideWith((ref, page) => access),
          ],
          child: MaterialApp(
            theme: appTheme(b),
            home: Builder(
              builder: (c) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(c).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => MeterCardEditor(initial: card ?? _card(), stored: [card ?? _card()]),
                    ),
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('OPEN'));
        await tester.pumpAndSettle();
        final control = find.byKey(const ValueKey('meter-at-sign-in'));
        await tester.scrollUntilVisible(control, 300, scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        return store;
      }

      Finder chip(String label) => find.descendant(
            of: find.byKey(const ValueKey('meter-at-sign-in')),
            matching: find.widgetWithText(ChoiceChip, label),
          );

      testWidgets('next to Open the meter on launch, with Off, Ask the driver and Always on', (tester) async {
        await pump(tester);
        expect(find.text('Open the meter on launch'), findsOneWidget);
        expect(find.text('Meter at sign-in'), findsOneWidget);
        final launchSwitch = tester.getRect(find.text('Open the meter on launch'));
        final control = tester.getRect(find.byKey(const ValueKey('meter-at-sign-in')));
        expect(control.top, greaterThan(launchSwitch.top), reason: 'right under it, in Driver launch');
        for (final l in ['Off', 'Ask the driver', 'Always on']) {
          expect(chip(l), findsOneWidget);
        }
        expect(tester.widget<ChoiceChip>(chip('Off')).selected, isTrue);
      });

      testWidgets('saves the choice on the card', (tester) async {
        final store = await pump(tester);
        await tester.tap(chip('Ask the driver'));
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(chip('Ask the driver')).selected, isTrue);
        expect(find.textContaining('choose “Turn the meter on” or “Not now”'), findsOneWidget);
        await tester.tap(chip('Always on'));
        await tester.pumpAndSettle();
        // The bar's Save and the sticky one below both save; tap the first.
        await tester.tap(find.text('Save rate card').first);
        await tester.pumpAndSettle();
        expect(store.saved?.meterAtSignIn, 'always');
      });

      testWidgets('shows a stored card\'s choice, and is read-only without edit access', (tester) async {
        await pump(tester, card: _card(mode: 'ask'), access: AccessLevel.read);
        expect(tester.widget<ChoiceChip>(chip('Ask the driver')).selected, isTrue);
        expect(tester.widget<ChoiceChip>(chip('Always on')).onSelected, isNull);
      });
    });
  }
}
