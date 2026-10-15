// EV support on screen (migration 0202): an electric car read through its
// EV profile on the OBD-II reader page (and the driver choosing when two
// fit), Record for support, and Admin → EV profiles (editor and captures),
// each in light and dark.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/meterapp/ev_profiles_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/meterapp_module.dart';
import 'package:get_ride/src/core/ev_profile.dart';
import 'package:get_ride/src/core/obd_adapters.dart';
import 'package:get_ride/src/data/ev_profile_repository.dart';
import 'package:get_ride/src/data/obd/obd_session.dart';
import 'package:get_ride/src/data/obd/obd_transport.dart';
import 'package:get_ride/src/features/meter/ev_capture_sheet.dart';
import 'package:get_ride/src/features/meter/obd_reader_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepo implements EvProfileRepository {
  _FakeRepo({this.profiles = const [], this.captures = const [], this.evSettings = const EvSettings()});
  EvSettings evSettings;
  final savedSettings = <EvSettings>[];
  List<EvProfile> profiles;
  List<EvCapture> captures;
  final saved = <EvProfile>[];
  final uploaded = <EvCapture>[];

  @override
  Future<List<EvProfile>> forApp() async => profiles;

  @override
  Future<List<EvProfile>> adminList() async => profiles;

  @override
  Future<List<EvCapture>> adminCaptures({int limit = 200}) async => captures;

  @override
  Future<EvProfile> save(EvProfile p) async {
    saved.add(p);
    return p;
  }

  @override
  Future<void> uploadCapture(EvCapture c) async => uploaded.add(c);

  @override
  Future<EvSettings> settings() async => evSettings;

  @override
  Future<EvSettings> saveSettings(EvSettings s) async {
    savedSettings.add(s);
    return evSettings = s;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An electric car behind a Wi-Fi ELM327: standard OBD-II finds no
/// protocol; its battery ECU (7E4) answers the profile's requests once the
/// protocol and header are set.
class _EvCar implements ObdTransport {
  String header = '';
  String protocol = '0';

  /// Switched off: the battery ECU stops answering.
  bool answering = true;
  final written = <String>[];
  final _data = StreamController<String>.broadcast();

  String _reply(String cmd) {
    if (cmd == 'ATZ') return 'ELM327 v1.5';
    if (cmd == 'ATD') {
      header = '';
      protocol = '0';
    } else if (cmd.startsWith('ATSH')) {
      header = cmd.substring(4);
    } else if (cmd.startsWith('ATSP')) {
      protocol = cmd.substring(4);
    }
    if (cmd == 'ATDPN') return protocol;
    if (cmd.startsWith('AT') || cmd.isEmpty) return 'OK';
    if (protocol == '0') return 'SEARCHING...\rUNABLE TO CONNECT';
    if (!answering) return 'NO DATA';
    return switch ('$header|$cmd') {
      '7E4|22F190' => '62F1904C4A',
      // soc 0xA0 × 0.5, range 0x01F4 × 0.5, odometer 0x001122 × 0.1.
      '7E4|220105' => '00A\r0:62010501F4A0\r1:00112233445566',
      '7E4|220101' => '6201012A',
      _ => 'NO DATA',
    };
  }

  @override
  String get kind => 'wifi';

  @override
  Stream<String> get data => _data.stream;

  @override
  Future<String> connect() async => '192.168.0.10:35000';

  @override
  Future<void> write(String command) async {
    written.add(command);
    final reply = '${_reply(command)}\r\r>';
    scheduleMicrotask(() => _data.add(reply));
  }

  @override
  Future<void> disconnect() async {}
}

const _signals = [
  EvSignal(key: 'soc', header: '7E4', request: '220105', start: 2, length: 1, scale: 0.5),
  EvSignal(key: 'range_km', header: '7E4', request: '220105', start: 0, length: 2, scale: 0.5),
  EvSignal(key: 'odometer_km', header: '7E4', request: '220105', start: 3, length: 3, scale: 0.1),
  EvSignal(key: 'speed_kmh', header: '7E4', request: '220101', start: 0, length: 1),
];

const _alpha = EvProfile(
  id: 'p1',
  make: 'Testmake',
  model: 'Alpha',
  years: '2024',
  active: true,
  verified: true,
  init: ['ATSP6'],
  detect: EvDetect(request: '22F190', header: '7E4'),
  signals: _signals,
);

const _saved = SavedObdAdapter(
  id: 'a1',
  name: 'Cab dongle',
  transport: 'wifi',
  host: '192.168.0.10',
  port: 35000,
  createdAt: '2026-10-01T00:00:00Z',
);

Map<String, Object> _savedPrefs() => {
  ObdAdapterStore.listKey: jsonEncode([_saved.toJson()]),
  ObdAdapterStore.selectedKey: 'a1',
};

class _LinkedSession extends ObdSession {
  @override
  ObdSessionState build() => const ObdSessionState(phase: ObdPhase.online, adapter: _saved);
}

/// A car for the capture: header-aware, answers one identifier.
class _CaptureCar {
  String header = '';
  final sent = <String>[];
  Duration? delay;

  Future<String> send(String c) async {
    if (delay != null) await Future<void>.delayed(delay!);
    sent.add(c);
    if (c == 'ATI') return 'ELM327 v1.5\r\r>';
    if (c.startsWith('ATSH')) header = c.substring(4);
    if (c.startsWith('AT')) return 'OK\r\r>';
    if (header == '7E4' && c == '22F190') return '7EC 05 62 F1 90 4C 4A\r\r>';
    return 'NO DATA\r\r>';
  }
}

void main() {
  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    ThemeData theme() => dark ? ThemeData.dark() : ThemeData.light();

    testWidgets('an electric car is read through its EV profile on the reader page ($mode)', (tester) async {
      SharedPreferences.setMockInitialValues(_savedPrefs());
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final car = _EvCar();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            obdTransportFactoryProvider.overrideWithValue((_) => car),
            evProfileRepositoryProvider.overrideWithValue(_FakeRepo(profiles: [_alpha])),
          ],
          child: MaterialApp(theme: theme(), home: const ObdReaderScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Connected'), findsOneWidget);
      expect(find.byKey(const ValueKey('ev-snapshot')), findsOneWidget);
      expect(find.text('Testmake Alpha (2024)'), findsOneWidget);
      expect(find.text('80 %'), findsOneWidget);
      expect(find.text('250 km'), findsOneWidget);
      expect(find.text('438.6 km'), findsOneWidget);
      expect(find.byKey(const ValueKey('obd-vehicle-silent')), findsNothing, reason: 'the car is being read');
      // A verified profile's speed is the vehicle speed.
      expect(find.text('42 km/h'), findsNWidgets(2), reason: 'on the EV values and as the live vehicle speed');
      expect(find.text('Vehicle speed'), findsOneWidget);
      expect(car.written, containsAllInOrder(['ATSP6', 'ATSH7E4', '22F190', '220105', '220101']));
      expect(find.byKey(const ValueKey('record-for-support')), findsOneWidget);

      // Switched off: after a few empty passes the profile is let go, the
      // reader gets its own settings back, and the car is said to be silent.
      car.answering = false;
      car.written.clear();
      await tester.pump(const Duration(seconds: 12));
      expect(find.byKey(const ValueKey('ev-snapshot')), findsNothing);
      expect(find.byKey(const ValueKey('obd-vehicle-silent')), findsOneWidget);
      expect(car.written, containsAllInOrder(evRestoreCommands));
      expect(find.text('Connected'), findsOneWidget);
      await tester.tap(find.text('Disconnect'));
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('two profiles fit: the driver chooses, and the choice is kept ($mode)', (tester) async {
      SharedPreferences.setMockInitialValues(_savedPrefs());
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final beta = _alpha.copyWith(id: () => 'p2', model: 'Beta', verified: false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            obdTransportFactoryProvider.overrideWithValue((_) => _EvCar()),
            evProfileRepositoryProvider.overrideWithValue(_FakeRepo(profiles: [_alpha, beta])),
          ],
          child: MaterialApp(theme: theme(), home: const ObdReaderScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('ev-choose')), findsOneWidget);
      expect(find.byKey(const ValueKey('ev-snapshot')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ev-choose-p2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('ev-snapshot')), findsOneWidget);
      expect(find.text('Testmake Beta (2024)'), findsOneWidget);
      expect(find.textContaining('still being checked'), findsOneWidget);
      expect(find.text('80 %'), findsOneWidget);
      expect(find.text('42 km/h'), findsOneWidget, reason: 'on the EV values only');
      expect(find.text('Vehicle speed'), findsNothing, reason: 'an unverified profile does not give the billing speed');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(EvChoiceStore.keyFor('a1', ['p1', 'p2'])), 'p2');
      await tester.tap(find.text('Disconnect'));
      await tester.pump(const Duration(milliseconds: 10));
    });

    Future<(_FakeRepo, _CaptureCar)> pumpSheet(WidgetTester tester, {Duration? delay}) async {
      final repo = _FakeRepo();
      final car = _CaptureCar()..delay = delay;
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            obdSessionProvider.overrideWith(_LinkedSession.new),
            evProfileRepositoryProvider.overrideWithValue(repo),
            evCaptureLinkProvider.overrideWithValue(<T>(Future<T> Function(EvSend send) job) => job(car.send)),
          ],
          child: MaterialApp(
            theme: theme(),
            home: const Scaffold(body: EvCaptureSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (repo, car);
    }

    testWidgets('Record for support: asks, records, summarises and sends ($mode)', (tester) async {
      final (repo, car) = await pumpSheet(tester);
      expect(find.textContaining('Ready, as for driving'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ev-capture-start')));
      await tester.pump();
      expect(find.text('Enter the make, model and year.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('ev-capture-vehicle')), 'Testmake Alpha 2024');
      await tester.enterText(find.byKey(const ValueKey('ev-capture-battery')), '180');
      await tester.tap(find.byKey(const ValueKey('ev-capture-start')));
      await tester.pump();
      expect(find.text('Enter the battery as a number from 0 to 100.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('ev-capture-battery')), '80');
      await tester.tap(find.byKey(const ValueKey('ev-capture-start')));
      await tester.pumpAndSettle();
      expect(find.text('Done.'), findsOneWidget);
      expect(find.text('1 answered, 0 refused by the car, 59 with no answer.'), findsOneWidget);
      expect(find.text('Reader: ELM327 v1.5'), findsOneWidget);
      expect(car.sent.last, 'ATSP0', reason: "the reader's settings are given back");

      await tester.tap(find.byKey(const ValueKey('ev-capture-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ev-capture-sent')), findsOneWidget);
      final c = repo.uploaded.single;
      expect(c.vehicle, 'Testmake Alpha 2024');
      expect(c.batteryHint, '80%');
      expect(c.reader, 'ELM327 v1.5');
      expect(c.entries.length, 60);
      expect(c.entries.where((e) => e.answered).single.request, '22F190');
    });

    testWidgets('Record for support: progress, then cancelled part-way ($mode)', (tester) async {
      final (repo, _) = await pumpSheet(tester, delay: const Duration(milliseconds: 20));
      await tester.enterText(find.byKey(const ValueKey('ev-capture-vehicle')), 'Testmake Beta 2025');
      await tester.tap(find.byKey(const ValueKey('ev-capture-start')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('ev-capture-progress')), findsOneWidget);
      expect(find.textContaining('asking'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ev-capture-cancel')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('Stopped.'), findsOneWidget);
      expect(repo.uploaded, isEmpty);
    });

    testWidgets('Admin → EV profiles: a new profile is checked, then saved ($mode)', (tester) async {
      final repo = _FakeRepo();
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: true)])),
            evProfileRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(theme: theme(), home: const AdminEvProfilesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No profiles yet'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ev-profile-new')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ev-profile-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ev-editor-problems')), findsOneWidget);
      expect(find.text('• Enter the make.'), findsOneWidget);
      expect(find.text('• Enter the model.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('ev-make')), 'Testmake');
      await tester.enterText(find.byKey(const ValueKey('ev-model')), 'Alpha');
      await tester.enterText(find.byKey(const ValueKey('ev-years')), '2024-2025');
      await tester.enterText(find.byKey(const ValueKey('ev-init')), 'atsp6, ATSH7E4; ATZZ!');
      await tester.tap(find.byKey(const ValueKey('ev-active')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ev-signal-add')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('ev-signal-header-0')), '7e4');
      await tester.enterText(find.byKey(const ValueKey('ev-signal-request-0')), '22 01 05');
      await tester.enterText(find.byKey(const ValueKey('ev-signal-start-0')), 'x');
      await tester.tap(find.byKey(const ValueKey('ev-profile-save')));
      await tester.pumpAndSettle();
      expect(find.text('• An active profile needs a detect request.'), findsOneWidget);
      expect(find.text('• Signal 1: the start byte must be a whole number.'), findsOneWidget);
      expect(find.text('• "ATZZ!" is not an AT command (e.g. ATSP6) or a hex request.'), findsOneWidget);
      expect(repo.saved, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('ev-init')), 'atsp6, ATSH7E4');
      await tester.enterText(find.byKey(const ValueKey('ev-detect-request')), '22F190');
      await tester.enterText(find.byKey(const ValueKey('ev-detect-header')), '7E4');
      await tester.enterText(find.byKey(const ValueKey('ev-signal-start-0')), '2');
      await tester.enterText(find.byKey(const ValueKey('ev-signal-scale-0')), '0.5');
      await tester.tap(find.byKey(const ValueKey('ev-profile-save')));
      await tester.pumpAndSettle();
      final p = repo.saved.single;
      expect(p.make, 'Testmake');
      expect(p.years, '2024-2025');
      expect(p.active, isTrue);
      expect(p.verified, isFalse);
      expect(p.init, ['ATSP6', 'ATSH7E4']);
      expect(p.detect, const EvDetect(request: '22F190', header: '7E4'));
      expect(p.signals.single, const EvSignal(key: 'soc', header: '7E4', request: '220105', start: 2, scale: 0.5));
      expect(find.byKey(const ValueKey('ev-profile-save')), findsNothing, reason: 'back on the list');
    });

    testWidgets('Admin → EV profiles: a capture is viewed and copied as JSON ($mode)', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      const capture = EvCapture(
        id: 'c1',
        vehicle: 'Testmake Alpha 2024',
        batteryHint: '80%',
        reader: 'ELM327 v1.5',
        createdAt: '2026-10-15T08:00:00Z',
        entries: [
          EvCaptureEntry(header: '7DF', request: '0100', reply: 'NO DATA', ms: 90),
          EvCaptureEntry(header: '7E4', request: '22F190', reply: '7EC 05 62 F1 90 4C 4A', ms: 60),
        ],
      );
      await tester.binding.setSurfaceSize(const Size(1000, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: true)])),
            evProfileRepositoryProvider.overrideWithValue(_FakeRepo(profiles: [_alpha], captures: [capture])),
          ],
          child: MaterialApp(theme: theme(), home: const AdminEvProfilesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Testmake Alpha (2024)'), findsOneWidget);
      await tester.tap(find.text('OBD captures'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 asked, 1 answered'), findsOneWidget);
      await tester.tap(find.text('Testmake Alpha 2024'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('obd-capture-table')), findsOneWidget);
      expect(find.text('7EC 05 62 F1 90 4C 4A'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('obd-capture-copy')));
      await tester.pumpAndSettle();
      expect(find.text('Copied as JSON'), findsOneWidget);
      final json = jsonDecode(copied!) as Map;
      expect(json['vehicle'], 'Testmake Alpha 2024');
      expect((json['entries'] as List).length, 2);
    });
  }

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    testWidgets('billing on EV speed switched off: the car is read, its speed is not billed on ($mode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(_savedPrefs());
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            obdTransportFactoryProvider.overrideWithValue((_) => _EvCar()),
            evProfileRepositoryProvider.overrideWithValue(
              _FakeRepo(profiles: [_alpha], evSettings: const EvSettings(billingSpeed: false)),
            ),
          ],
          child: MaterialApp(theme: dark ? ThemeData.dark() : ThemeData.light(), home: const ObdReaderScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const ValueKey('ev-snapshot')), findsOneWidget);
      expect(find.text('42 km/h'), findsOneWidget, reason: 'on the EV values only');
      expect(find.text('Vehicle speed'), findsNothing, reason: 'the admin has turned billing on EV speed off');
      await tester.tap(find.text('Disconnect'));
      await tester.pump(const Duration(milliseconds: 10));
    });

    for (final edit in [true, false]) {
      testWidgets('Admin → EV profiles: the billing switch, ${edit ? 'saved' : 'read-only'} ($mode)', (tester) async {
        final repo = _FakeRepo();
        await tester.binding.setSurfaceSize(const Size(1000, 2000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
              evProfileRepositoryProvider.overrideWithValue(repo),
            ],
            child: MaterialApp(theme: dark ? ThemeData.dark() : ThemeData.light(), home: const AdminEvProfilesScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Use EV speed for meter billing (verified profiles only)'), findsOneWidget);
        SwitchListTile tile() => tester.widget<SwitchListTile>(
          find.descendant(of: find.byKey(const ValueKey('ev-billing-speed')), matching: find.byType(SwitchListTile)),
        );
        expect(tile().value, isTrue, reason: 'on by default');
        if (!edit) {
          expect(tile().onChanged, isNull);
          expect(find.text('Changing this needs edit rights on EV profiles.'), findsOneWidget);
          return;
        }
        await tester.tap(find.byKey(const ValueKey('ev-billing-speed')));
        await tester.pumpAndSettle();
        expect(repo.savedSettings, [const EvSettings(billingSpeed: false)]);
        expect(tile().value, isFalse);
        expect(find.text('Meter billing no longer uses EV speed.'), findsOneWidget);
      });
    }
  }

  test('the page is listed under Meter & app with its own page key', () {
    final entry = meterappEntries.firstWhere((e) => e.path == '/admin/m/ev-profiles');
    expect(entry.pages, [evProfilesPage]);
    expect(evProfilesPage, 'admin-settings-ev-profiles');
  });
}
