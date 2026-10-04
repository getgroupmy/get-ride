// Pure logic of the Meter & app admin screens. Mirrors the Expo suites
// utils/__tests__/meterSettings.test.ts, meterLeave.test.ts,
// meterLeaveApps.test.ts and alwaysOnStore.test.ts.
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/always_on_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/meterapp_module.dart';
import 'package:get_ride/src/admin/screens/meterapp/site_logic.dart';

Map<String, dynamic> row([Map<String, dynamic> o = const {}]) => {
      'id': 'row-1',
      'level': 'master',
      'country': null,
      'state': null,
      'city': null,
      'suburb': null,
      'label': 'Global',
      'source_mode': 'gps+obd',
      'allow_start_without_odometer': true,
      'read_odometer': true,
      'auto_launch': false,
      'leave_passenger_action': 'passenger',
      'leave_ehailing_action': 'app',
      'leave_ehailing_url': null,
      'leave_ehailing_label': null,
      'leave_ehailing_app_id': null,
      'leave_ehailing_store_ios': null,
      'leave_ehailing_store_android': null,
      'leave_ehailing_store_huawei': null,
      'show_meter': true,
      'show_trips': true,
      'show_printer': true,
      'show_obd': true,
      'show_settings': true,
      'tap_meter': true,
      'tap_trips': true,
      'tap_printer': true,
      'tap_obd': true,
      'tap_settings': true,
      'currency': 'MYR',
      'flag_fare': '4.00',
      'flag_distance_m': 1000,
      'minimum_fare': '0.00',
      'distance_mode': 'block',
      'distance_block_m': 200,
      'distance_block_charge': '0.35',
      'per_km_charge': '1.00',
      'time_mode': 'block',
      'time_block_s': 36,
      'time_block_charge': '0.35',
      'per_minute_charge': '0.30',
      'per_second_charge': '0.0000',
      'charge_mode': 'max',
      'charge_from': 'flag',
      'night_multiplier': '1.500',
      'night_start_hour': 0,
      'night_end_hour': 6,
      'extra_luggage_charge': '0.00',
      'free_luggage': 0,
      'extra_passenger_charge': '0.00',
      'free_passengers': 1,
      'extra_step': '0.50',
      'max_extra': '99.50',
      'active': true,
      'updated_at': '2026-08-04T00:00:00.000Z',
      ...o,
    };

MeterProfile profile({
  String id = 'default',
  String level = 'master',
  String? country,
  String? state,
  String? city,
  String? suburb,
  String sourceMode = 'gps+obd',
  bool allowStartWithoutOdometer = true,
  bool readOdometer = true,
  MeterRates? rates,
  bool active = true,
  double extraLuggageCharge = 0,
  int freeLuggage = 0,
  double extraPassengerCharge = 0,
  int freePassengers = 1,
}) =>
    defaultMeterProfile.copyWith(
      id: id,
      level: level,
      country: () => country,
      state: () => state,
      city: () => city,
      suburb: () => suburb,
      sourceMode: sourceMode,
      allowStartWithoutOdometer: allowStartWithoutOdometer,
      readOdometer: readOdometer,
      rates: rates,
      active: active,
      panels: allPanelsOn(),
      extraLuggageCharge: extraLuggageCharge,
      freeLuggage: freeLuggage,
      extraPassengerCharge: extraPassengerCharge,
      freePassengers: freePassengers,
    );

const leaveDefault = defaultMeterLeave;

void main() {
  group('normalizeMeterProfile', () {
    test('reads a full row, coercing the numeric strings postgres returns', () {
      final p = normalizeMeterProfile(row())!;
      expect(p.rates.flagFare, 4);
      expect(p.rates.distanceBlockCharge, 0.35);
      expect(p.rates.timeBlockS, 36);
      expect(p.nightMultiplier, 1.5);
      expect(p.currency, 'MYR');
      expect(p.panels['printer'], const MeterPanelAccess());
    });

    test('rejects anything without an id', () {
      expect(normalizeMeterProfile(null), isNull);
      expect(normalizeMeterProfile(<String, dynamic>{}), isNull);
      expect(normalizeMeterProfile(row({'id': '  '})), isNull);
    });

    test('falls back to the built-in default for an unusable value', () {
      final p = normalizeMeterProfile(row({
        'flag_fare': 'not a number',
        'distance_block_m': 0,
        'time_mode': 'per_fortnight',
        'source_mode': 'satellite',
        'night_multiplier': '0.2',
      }))!;
      expect(p.rates.flagFare, defaultMeterProfile.rates.flagFare);
      expect(p.rates.distanceBlockM, defaultMeterProfile.rates.distanceBlockM);
      expect(p.rates.timeMode, defaultMeterProfile.rates.timeMode);
      expect(p.sourceMode, 'gps+obd');
      expect(p.nightMultiplier, defaultMeterProfile.nightMultiplier);
    });

    test('clears place names the level does not own', () {
      final p = normalizeMeterProfile(row({'level': 'master', 'country': 'Malaysia', 'city': 'Ipoh'}))!;
      expect(p.country, isNull);
      expect(p.city, isNull);
      final city = normalizeMeterProfile(
          row({'level': 'city', 'country': 'Malaysia', 'state': 'Selangor', 'city': 'Klang', 'suburb': 'X'}))!;
      expect(city.city, 'Klang');
      expect(city.suburb, isNull);
    });

    test('round-trips through the row shape', () {
      final p = normalizeMeterProfile(row())!;
      final back = normalizeMeterProfile({...meterProfileToRow(p), 'id': p.id, 'updated_at': null})!;
      expect(back.rates, p.rates);
      expect(back.panels, p.panels);
      expect(back.sourceMode, p.sourceMode);
      expect(back.autoLaunch, p.autoLaunch);
      expect(back.leave, p.leave);
    });

    test('reads the leave-the-meter keys, defaulting them to the in-app pair', () {
      final configured = normalizeMeterProfile(row({
        'leave_passenger_action': 'exit',
        'leave_ehailing_action': 'link',
        'leave_ehailing_url': 'driverapp://jobs',
        'leave_ehailing_label': 'Fleet app',
        'leave_ehailing_app_id': 'grab-driver',
        'leave_ehailing_store_ios': 'https://apps.apple.com/app/id123',
      }))!;
      expect(
        configured.leave,
        const MeterLeaveConfig(
          passenger: 'exit',
          ehailing: 'link',
          ehailingUrl: 'driverapp://jobs',
          ehailingLabel: 'Fleet app',
          ehailingAppId: 'grab-driver',
          ehailingStores: MeterLeaveStores(ios: 'https://apps.apple.com/app/id123'),
        ),
      );
      final legacy = row()
        ..remove('leave_passenger_action')
        ..remove('leave_ehailing_action')
        ..remove('leave_ehailing_url');
      expect(normalizeMeterProfile(legacy)!.leave, defaultMeterLeave);
    });

    test('never writes down a link the console could not open', () {
      final p = normalizeMeterProfile(row())!;
      final written = meterProfileToRow(
          p.copyWith(leave: p.leave.copyWith(ehailing: 'link', ehailingUrl: () => 'not a link')));
      expect(written['leave_ehailing_url'], isNull);
    });

    test('reads auto-launch, and defaults it off where the column is missing', () {
      expect(normalizeMeterProfile(row({'auto_launch': true}))!.autoLaunch, isTrue);
      expect(normalizeMeterProfile(row()..remove('auto_launch'))!.autoLaunch, isFalse);
    });
  });

  group('optional column groups', () {
    test('says nothing about a fully migrated database', () {
      expect(describeMissingMeterColumns([]), isNull);
    });

    test('names the setting and its migration', () {
      final n = describeMissingMeterColumns(['leave'])!;
      expect(n, contains('Leave the meter'));
      expect(n, contains('0085'));
      expect(n, contains('cannot be saved'));
      expect(n, contains('Every other setting'));
    });

    test('names both when behind by two migrations, ignores unknown ids', () {
      final n = describeMissingMeterColumns(['auto_launch', 'leave'])!;
      expect(n, contains('0084'));
      expect(n, contains('0085'));
      expect(describeMissingMeterColumns(['something_else']), isNull);
    });

    test('drops a refused group from reads and writes', () {
      expect(meterSettingsColumns(), contains('auto_launch'));
      expect(meterSettingsColumns(['auto_launch']), isNot(contains('auto_launch')));
      final w = meterRowWithoutGroups(meterProfileToRow(defaultMeterProfile), ['leave_app']);
      expect(w.containsKey('leave_ehailing_app_id'), isFalse);
      expect(w.containsKey('leave_ehailing_url'), isTrue);
      expect(meterOptionalGroupNamed('column meter_digital_settings.leave_ehailing_url does not exist')?.id, 'leave');
      expect(meterOptionalGroupNamed('column foo does not exist'), isNull);
    });
  });

  group('resolveMeterProfile', () {
    final master = profile(id: 'm');
    final country = profile(id: 'c', level: 'country', country: 'Malaysia');
    final state = profile(id: 's', level: 'state', country: 'Malaysia', state: 'Selangor');
    final city = profile(id: 'ci', level: 'city', country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya');
    final suburb = profile(
        id: 'su', level: 'suburb', country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya', suburb: 'Bangsar');
    final all = [master, country, state, city, suburb];

    test('takes the narrowest matching scope', () {
      expect(
          resolveMeterProfile(all, country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya', suburb: 'Bangsar')
              .profile
              .id,
          'su');
      expect(resolveMeterProfile(all, country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya').profile.id, 'ci');
      expect(resolveMeterProfile(all, country: 'Malaysia', state: 'Selangor').profile.id, 's');
      expect(resolveMeterProfile(all, country: 'Malaysia').profile.id, 'c');
      expect(resolveMeterProfile(all).profile.id, 'm');
    });

    test('matches place names case- and space-insensitively', () {
      final hit = resolveMeterProfile(all, country: ' malaysia ', state: 'SELANGOR');
      expect(hit.profile.id, 's');
      expect(hit.level, 'state');
    });

    test('skips an inactive card and falls through', () {
      final off = [suburb.copyWith(active: false), city, master];
      expect(
          resolveMeterProfile(off, country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya', suburb: 'Bangsar')
              .profile
              .id,
          'ci');
    });

    test('does not match a card whose parent scope contradicts the hire', () {
      final elsewhere =
          profile(id: 'other', level: 'city', country: 'Singapore', state: 'Central', city: 'Petaling Jaya');
      expect(
          resolveMeterProfile([elsewhere, master], country: 'Malaysia', state: 'Selangor', city: 'Petaling Jaya')
              .profile
              .id,
          'm');
    });

    test('falls back to the built-in tariff when nothing is configured', () {
      final hit = resolveMeterProfile([]);
      expect(hit.level, 'default');
      expect(identical(hit.profile, defaultMeterProfile), isTrue);
      expect(hit.scope, 'Built-in tariff');
    });
  });

  group('the card drives the fare', () {
    final rates = defaultMeterProfile.rates;
    test('prices the default card exactly like the built-in old tariff', () {
      expect(computeMeterFareTotal(rates, distanceM: 1200), 4.35);
      expect(computeMeterFareTotal(rates, distanceM: 2000), 5.75);
      expect(computeMeterFareTotal(rates, distanceM: 1200, chargeableMs: 300000), closeTo(4 + 9 * 0.35, 1e-9));
    });

    test('bills a per-km + per-minute card from the start of the hire', () {
      final r = rates.copyWith(
          flagFare: 3, distanceMode: 'per_km', perKmCharge: 2, timeMode: 'per_minute', perMinuteCharge: 0.5,
          chargeMode: 'sum', chargeFrom: 'start');
      expect(computeMeterFareTotal(r, distanceM: 4000, elapsedMs: 600000), 16);
    });

    test('bills a per-second card and an unusual time block', () {
      final r = rates.copyWith(
          distanceMode: 'off', timeMode: 'per_second', perSecondCharge: 0.01, chargeFrom: 'start', chargeMode: 'sum');
      expect(computeMeterFareTotal(r, distanceM: 0, elapsedMs: 120000), 5.2);
      final b = rates.copyWith(timeBlockS: 45, timeBlockCharge: 1, distanceMode: 'off');
      expect(computeMeterFareTotal(b, distanceM: 1500, chargeableMs: 100000), 7);
    });

    test('lifts a cheap hire to the configured minimum fare', () {
      final r = rates.copyWith(flagFare: 2, minimumFare: 8);
      expect(computeMeterFareTotal(r, distanceM: 1200), 8);
      expect(computeMeterFareTotal(r, distanceM: 6000), closeTo(2 + 25 * 0.35, 1e-9));
    });
  });

  group('sensors and odometer', () {
    test('allowedMeterSources takes the other sensor away in a single-source mode', () {
      expect(allowedMeterSources('gps+obd'), (obd: true, gps: true));
      expect(allowedMeterSources('gps'), (obd: false, gps: true));
      expect(allowedMeterSources('obd'), (obd: true, gps: false));
    });

    test('meterOdometerGate: lenient without a reader, compulsory with one', () {
      expect(meterOdometerGate(profile(), null).canStart, isTrue);
      final gate = meterOdometerGate(profile(), null, true);
      expect(gate.canStart, isFalse);
      expect(gate.reason, contains('odometer'));
      expect(meterOdometerGate(profile(), double.nan, true).canStart, isFalse);
      expect(meterOdometerGate(profile(), -1, true).canStart, isFalse);
      expect(meterOdometerGate(profile(), 128450.6, true).canStart, isTrue);
      expect(meterOdometerGate(profile(), 0, true).canStart, isTrue);
    });

    test('meterOdometerGate never holds for a reading the card cannot produce', () {
      expect(meterOdometerGate(profile(readOdometer: false), null, true).canStart, isTrue);
      expect(meterOdometerGate(profile(sourceMode: 'gps'), null, true).canStart, isTrue);
      final strict = profile(allowStartWithoutOdometer: false);
      expect(meterOdometerGate(strict, null).canStart, isFalse);
      expect(meterOdometerGate(strict, 0).canStart, isTrue);
      final gpsOnly = profile(allowStartWithoutOdometer: false, sourceMode: 'gps');
      expect(meterOdometerGate(gpsOnly, null).canStart, isTrue);
      expect(meterOdometerGate(gpsOnly, null).reason, isNull);
    });

    test('meterReadsOdometerBeforeStart / meterReadsOdometer', () {
      expect(meterReadsOdometerBeforeStart(profile(), true), isTrue);
      expect(meterReadsOdometerBeforeStart(profile(), false), isFalse);
      expect(meterReadsOdometerBeforeStart(profile(allowStartWithoutOdometer: false), false), isTrue);
      expect(meterReadsOdometerBeforeStart(profile(readOdometer: false), true), isFalse);
      expect(meterReadsOdometerBeforeStart(profile(sourceMode: 'gps', allowStartWithoutOdometer: false), false), isFalse);
      expect(meterReadsOdometer(profile()), isTrue);
      expect(meterReadsOdometer(profile(readOdometer: false)), isFalse);
      expect(meterReadsOdometer(profile(sourceMode: 'obd')), isTrue);
      expect(meterReadsOdometer(profile(sourceMode: 'gps')), isFalse);
    });
  });

  group('meterExtraSurcharge', () {
    final p = profile(extraLuggageCharge: 1.5, freeLuggage: 2, extraPassengerCharge: 2, freePassengers: 1);
    test('charges only past the free allowance', () {
      expect(meterExtraSurcharge(p, luggage: 2, passengers: 1), 0);
      expect(meterExtraSurcharge(p, luggage: 4, passengers: 1), 3);
      expect(meterExtraSurcharge(p, luggage: 0, passengers: 3), 4);
      expect(meterExtraSurcharge(p, luggage: 3, passengers: 2), 3.5);
    });
    test('never goes negative and ignores nonsense counts', () {
      expect(meterExtraSurcharge(p, luggage: -5, passengers: -5), 0);
      expect(meterExtraSurcharge(p, luggage: double.nan, passengers: 2.7), 2);
      expect(hasMeterSurcharges(profile()), isFalse);
      expect(hasMeterSurcharges(p), isTrue);
    });
  });

  group('describeMeterRates', () {
    test('names only the charges the card actually bills', () {
      final lines = describeMeterRates(profile());
      expect(lines.first, 'MYR 4.00 flag fare, first 1 km');
      expect(lines, contains('MYR 0.35 per started 200 m'));
      expect(lines, contains('MYR 0.35 per started 36 s'));
      expect(lines, contains('Distance or time — whichever is greater'));
      expect(lines, contains('Night ×1.5 (00:00–06:00)'));
      expect(lines.any((l) => l.contains('per bag')), isFalse);
    });
    test('says nothing about time on a distance-only card', () {
      final lines = describeMeterRates(profile(rates: defaultMeterProfile.rates.copyWith(timeMode: 'off')));
      expect(lines.any((l) => l.contains('per started 36 s')), isFalse);
      expect(lines.any((l) => l.contains('whichever is greater')), isFalse);
    });
    test('spells out the extras when the card charges them', () {
      final lines =
          describeMeterRates(profile(extraLuggageCharge: 2, freeLuggage: 1, extraPassengerCharge: 3, freePassengers: 2));
      expect(lines, contains('MYR 2.00 per bag after 1 free'));
      expect(lines, contains('MYR 3.00 per passenger after 2'));
    });
  });

  group('validateMeterProfile', () {
    test('accepts the default card', () => expect(validateMeterProfile(profile()), isNull));

    test('requires the place names its level needs', () {
      expect(validateMeterProfile(createMeterProfileDraft('country')), 'Select a country.');
      expect(validateMeterProfile(createMeterProfileDraft('state').copyWith(country: () => 'Malaysia')),
          'Select a state.');
      expect(
        validateMeterProfile(createMeterProfileDraft('suburb')
            .copyWith(country: () => 'Malaysia', state: () => 'Selangor', city: () => 'Petaling Jaya')),
        'Enter a suburb.',
      );
    });

    test('refuses a card that would meter every hire at zero', () {
      final free = profile(
          rates: defaultMeterProfile.rates
              .copyWith(flagFare: 0, minimumFare: 0, distanceBlockCharge: 0, timeBlockCharge: 0));
      expect(validateMeterProfile(free), contains('charges nothing'));
    });

    test('refuses an e-hailing key pointed at an app it cannot name', () {
      final p = profile();
      expect(validateMeterProfile(p.copyWith(leave: p.leave.copyWith(ehailing: 'link'))), contains('app link'));
      expect(
          validateMeterProfile(
              p.copyWith(leave: p.leave.copyWith(ehailing: 'link', ehailingUrl: () => 'driverapp://jobs'))),
          isNull);
    });

    test('refuses to hide or lock the meter itself', () {
      final hidden = profile().copyWith(panels: {...allPanelsOn(), 'meter': const MeterPanelAccess(show: false)});
      expect(validateMeterProfile(hidden), contains('cannot be hidden'));
      final locked = profile().copyWith(panels: {...allPanelsOn(), 'meter': const MeterPanelAccess(tap: false)});
      expect(validateMeterProfile(locked), contains('cannot be locked'));
    });

    test('meterProfileScopeLabel prints the scope the way the admin list reads it', () {
      expect(meterProfileScopeLabel(profile()), 'Global (all regions)');
      expect(meterProfileScopeLabel(profile(level: 'country', country: 'Malaysia')), 'Malaysia');
      expect(meterProfileScopeLabel(profile(level: 'suburb', suburb: 'Bangsar', city: 'Kuala Lumpur')),
          'Bangsar, Kuala Lumpur');
    });
  });

  group('setMeterPanelAccess / canApplyMeterPanelLive', () {
    test('hides a panel and takes its tap with it', () {
      expect(setMeterPanelAccess(allPanelsOn(), 'printer', show: false)['printer'],
          const MeterPanelAccess(show: false, tap: false));
    });
    test('shows a panel again without assuming it may be tapped', () {
      final hidden = setMeterPanelAccess(allPanelsOn(), 'obd', show: false);
      expect(setMeterPanelAccess(hidden, 'obd', show: true)['obd'], const MeterPanelAccess(show: true, tap: false));
    });
    test('locks a shown panel, and tap implies show', () {
      expect(setMeterPanelAccess(allPanelsOn(), 'settings', tap: false)['settings'],
          const MeterPanelAccess(show: true, tap: false));
      final hidden = setMeterPanelAccess(allPanelsOn(), 'trips', show: false);
      expect(setMeterPanelAccess(hidden, 'trips', tap: true)['trips'], const MeterPanelAccess());
    });
    test('pins the meter panel on', () {
      expect(setMeterPanelAccess(allPanelsOn(), 'meter', show: false)['meter'], const MeterPanelAccess());
      expect(setMeterPanelAccess(allPanelsOn(), 'meter', tap: false)['meter'], const MeterPanelAccess());
    });
    test("leaves the caller's record untouched and round-trips through the narrow write", () {
      final before = allPanelsOn();
      final next = setMeterPanelAccess(before, 'obd', show: false);
      expect(before['obd'], const MeterPanelAccess());
      final r = meterPanelsToRow(next);
      expect(r.length, 10);
      expect(r['show_obd'], isFalse);
      expect(r['tap_obd'], isFalse);
      expect(r['show_meter'], isTrue);
      expect(normalizeMeterProfile(row(r))!.panels['obd'], const MeterPanelAccess(show: false, tap: false));
    });
    test('applies live to stored and global cards only', () {
      expect(canApplyMeterPanelLive(profile(id: 'row-1', level: 'city')), isTrue);
      expect(canApplyMeterPanelLive(profile(id: '')), isTrue);
      expect(canApplyMeterPanelLive(createMeterProfileDraft('country')), isFalse);
      expect(canApplyMeterPanelLive(createMeterProfileDraft('master')), isTrue);
    });
  });

  group('editor fields', () {
    test('folds typed numbers back, defaulting blanks and clamping hours', () {
      final f = meterFieldsOf(defaultMeterProfile);
      expect(f['flagFare'], '4');
      expect(f['distanceBlockCharge'], '0.35');
      final merged = mergeMeterFields(defaultMeterProfile, {
        ...f,
        'flagFare': '5,5',
        'perKmCharge': '',
        'nightStartHour': '30',
        'nightMultiplier': '0.5',
        'extraStep': '0',
      });
      expect(merged.rates.flagFare, 5.5);
      expect(merged.rates.perKmCharge, defaultMeterProfile.rates.perKmCharge);
      expect(merged.nightStartHour, 23);
      expect(merged.nightMultiplier, 1);
      expect(merged.extraStep, 0.01);
    });

    test('picking a catalogue app fills only the store pages it knows', () {
      final picked = pickMeterLeaveApp(
          const MeterLeaveConfig(ehailingStores: MeterLeaveStores(android: 'https://my.store/x')), 'gvride');
      expect(picked.ehailingAppId, 'gvride');
      expect(picked.ehailingStores.android, 'https://my.store/x');
      expect(picked.ehailingStores.ios, 'https://apps.apple.com/my/app/gvride/id6651835302');
      expect(picked.ehailingStores.huawei, isNull);
      expect(pickMeterLeaveApp(picked, null).ehailingAppId, isNull);
    });
  });

  group('meterLeave', () {
    test('normalizeMeterLeaveUrl takes schemes and refuses everything else', () {
      expect(normalizeMeterLeaveUrl('driverapp://jobs'), 'driverapp://jobs');
      expect(normalizeMeterLeaveUrl('  myfleet://  '), 'myfleet://');
      expect(normalizeMeterLeaveUrl('https://dispatch.example.com/driver'), 'https://dispatch.example.com/driver');
      for (final bad in ['driverapp', 'open the driver app', '', null, 42, 'driverapp:// jobs', 'javascript:alert(1)',
        'JavaScript:alert(1)', 'data:text/html,<b>x</b>', 'file:///etc/passwd', 'app://${'x' * 600}']) {
        expect(normalizeMeterLeaveUrl(bad), isNull, reason: '$bad');
      }
    });

    test('normalizeMeterLeaveLabel collapses whitespace and caps the length', () {
      expect(normalizeMeterLeaveLabel('  Fleet   dispatch  '), 'Fleet dispatch');
      expect(normalizeMeterLeaveLabel('x' * 50), hasLength(22));
      expect(normalizeMeterLeaveLabel('   '), isNull);
      expect(normalizeMeterLeaveLabel(null), isNull);
    });

    test('resolveMeterLeave defaults to the original two keys', () {
      final r = resolveMeterLeave(leaveDefault);
      expect((r.passenger.action, r.passenger.route, r.passenger.label), ('route', '/', 'PASSENGER MODE'));
      expect((r.ehailing.action, r.ehailing.route, r.ehailing.label), ('route', '/partner-ehailing', 'E-HAILING'));
      expect(resolveMeterLeave(null).ehailing.action, 'route');
    });

    test('exit key, link key, captions and fallbacks', () {
      final exit = resolveMeterLeave(const MeterLeaveConfig(passenger: 'exit')).passenger;
      expect((exit.action, exit.route, exit.label), ('exit', null, 'EXIT'));
      expect(exit.hint, contains('stay signed in'));

      final link = resolveMeterLeave(const MeterLeaveConfig(
              ehailing: 'link', ehailingUrl: 'driverapp://jobs', ehailingLabel: 'Fleet app'))
          .ehailing;
      expect((link.action, link.url, link.label, link.route), ('link', 'driverapp://jobs', 'FLEET APP', null));
      expect(resolveMeterLeave(const MeterLeaveConfig(ehailing: 'link', ehailingUrl: 'driverapp://')).ehailing.label,
          'E-HAILING APP');
      final dead = resolveMeterLeave(const MeterLeaveConfig(ehailing: 'link', ehailingUrl: '  ')).ehailing;
      expect((dead.action, dead.route, dead.url), ('route', '/partner-ehailing', null));
      expect(resolveMeterLeave(const MeterLeaveConfig(ehailing: 'link', ehailingUrl: 'javascript:alert(1)')).ehailing.action,
          'route');
      final cap = resolveMeterLeave(const MeterLeaveConfig(ehailingLabel: 'jobs')).ehailing;
      expect((cap.action, cap.label), ('route', 'JOBS'));
    });

    test('with a catalogue app: per-platform links and stores', () {
      const picked = MeterLeaveConfig(ehailing: 'link', ehailingAppId: 'grab-driver');
      final android = resolveMeterLeave(picked, 'android').ehailing;
      expect(android.url, 'intent://#Intent;package=com.grabtaxi.driver2;end');
      expect(android.label, 'GRAB DRIVER');
      expect(android.store, 'https://play.google.com/store/apps/details?id=com.grabtaxi.driver2');

      final withStore = picked.copyWith(ehailingStores: const MeterLeaveStores(ios: 'https://apps.apple.com/app/id123'));
      final ios = resolveMeterLeave(withStore, 'ios').ehailing;
      expect((ios.action, ios.url, ios.store), ('link', null, 'https://apps.apple.com/app/id123'));
      expect(ios.hint, contains('Install Grab Driver'));
      expect(resolveMeterLeave(picked, 'ios').ehailing.route, '/partner-ehailing');

      final own = picked.copyWith(
          ehailingStores: const MeterLeaveStores(android: 'https://play.google.com/store/apps/details?id=x'));
      expect(resolveMeterLeave(own, 'android').ehailing.store, 'https://play.google.com/store/apps/details?id=x');

      final both = picked.copyWith(ehailingUrl: () => 'grabdriver://');
      expect(resolveMeterLeave(both, 'ios').ehailing.url, 'grabdriver://');
      expect(resolveMeterLeave(both, 'android').ehailing.url, contains('intent://'));

      const stale = MeterLeaveConfig(ehailing: 'link', ehailingAppId: 'app-that-was-removed');
      expect(normalizeMeterLeave(stale).ehailingAppId, isNull);
      expect(resolveMeterLeave(stale, 'android').ehailing.action, 'route');
      expect(resolveMeterLeave(picked.copyWith(ehailingLabel: () => 'Jobs'), 'android').ehailing.label, 'JOBS');
      expect(validateMeterLeave(picked), isNull);
    });

    test('describeMeterExit tells the truth per platform', () {
      expect(describeMeterExit('android').supported, isTrue);
      expect(describeMeterExit('android').note, contains('home screen'));
      final ios = describeMeterExit('ios');
      expect(ios.supported, isFalse);
      expect(ios.note, contains('Swipe up'));
      expect(ios.note, isNot(contains('build')));
      final web = describeMeterExit('web', true);
      expect(web.supported, isFalse);
      expect(web.note, contains('tab'));
      for (final os in ['android', 'ios', 'web']) {
        expect(describeMeterExit(os).note, contains('stay signed in'));
      }
    });

    test('validateMeterLeave and describeMeterLeave', () {
      expect(validateMeterLeave(leaveDefault), isNull);
      expect(validateMeterLeave(const MeterLeaveConfig(passenger: 'exit')), isNull);
      expect(validateMeterLeave(const MeterLeaveConfig(ehailing: 'link')), contains('app link'));
      expect(validateMeterLeave(const MeterLeaveConfig(ehailing: 'link', ehailingUrl: 'driverapp')), contains('app link'));
      expect(validateMeterLeave(const MeterLeaveConfig(ehailing: 'link', ehailingUrl: 'driverapp://jobs')), isNull);
      expect(describeMeterLeave(leaveDefault), isEmpty);
      expect(describeMeterLeave(const MeterLeaveConfig(passenger: 'exit', ehailing: 'link', ehailingUrl: 'driverapp://')),
          ['Leave key closes the app', 'E-hailing opens driverapp://']);
      expect(describeMeterLeave(const MeterLeaveConfig(ehailing: 'link', ehailingUrl: 'nonsense')), isEmpty);
    });
  });

  group('meterLeaveApps catalogue', () {
    final grab = meterLeaveAppById('grab-driver')!;
    final gv = meterLeaveAppById('gvride')!;

    test('entries carry a package, never a guessed or App Store iOS route, and unique ids', () {
      for (final a in meterLeaveApps) {
        expect(a.androidPackage, isNotEmpty);
        expect(a.name.trim(), isNotEmpty);
        if (a.iosScheme != null) expect(a.iosScheme, contains(':'));
        if (a.iosLink != null) expect(a.iosLink!.startsWith('https://'), isTrue);
        expect(a.iosLink ?? '', isNot(contains('apps.apple.com')));
      }
      expect(meterLeaveApps.map((a) => a.id).toSet().length, meterLeaveApps.length);
    });

    test('GVRIDE opens by universal link on iOS and package elsewhere', () {
      expect(meterLeaveAppLink(gv, 'ios'), 'https://ride.gvmalaysia.com/app/');
      expect(meterLeaveAppLink(gv, 'android'), 'intent://#Intent;package=com.jobtepi.app;end');
      expect(meterLeaveAppLink(gv, 'huawei'), meterLeaveAppLink(gv, 'android'));
      expect(meterLeaveAppStore(gv, 'ios'), 'https://apps.apple.com/my/app/gvride/id6651835302');
      expect(meterLeaveAppProbe(gv, 'ios'), isNull);
      expect(meterLeaveAppProbe(gv, 'android'), contains('com.jobtepi.app'));
      expect(describeAppIosRoute(gv), contains('opens the app'));
      expect(describeAppIosRoute(grab), contains('needs a link'));
    });

    test('lookups, links and stores', () {
      expect(meterLeaveAppById('  grab-driver  ')?.id, 'grab-driver');
      expect(meterLeaveAppById('not-an-app'), isNull);
      expect(meterLeaveAppById(null), isNull);
      expect(meterLeaveAppLink(grab, 'ios'), isNull);
      expect(meterLeaveAppLink(grab.copyWith(iosScheme: 'grabdriver://'), 'ios'), 'grabdriver://');
      expect(meterLeaveAppLink(null, 'android'), isNull);
      expect(meterLeaveAppStore(grab, 'android'), 'https://play.google.com/store/apps/details?id=com.grabtaxi.driver2');
      expect(meterLeaveAppStore(grab, 'ios'), isNull);
      expect(meterLeaveAppStore(grab, 'huawei'), isNull);
      expect(meterLeaveAppNeedsLink(grab, 'ios'), isTrue);
      expect(meterLeaveAppNeedsLink(grab, 'android'), isFalse);
      expect(meterLeaveAppNeedsLink(null, 'ios'), isFalse);
    });

    test('store platform and presence wording', () {
      expect(storePlatformFor('android', 'Huawei'), 'huawei');
      expect(storePlatformFor('android', 'HONOR'), 'huawei');
      expect(storePlatformFor('android', 'samsung'), 'android');
      expect(storePlatformFor('android'), 'android');
      expect(storePlatformFor('ios', 'Apple'), 'ios');
      expect(describeAppPresence('present'), 'On this device');
      expect(describeAppPresence('not-detected'), isNot(matches(RegExp('not installed', caseSensitive: false))));
      expect(describeAppPresence('unknown'), contains("Can't check"));
    });
  });

  group('always-on pages', () {
    test('normalizeAlwaysOnRoute', () {
      expect(normalizeAlwaysOnRoute('/meter-digital'), 'meter-digital');
      expect(normalizeAlwaysOnRoute('/meter-digital?tab=1'), 'meter-digital');
      expect(normalizeAlwaysOnRoute('meter-digital#x'), 'meter-digital');
      expect(normalizeAlwaysOnRoute('/admin-settings/always-on'), 'admin-settings');
      expect(normalizeAlwaysOnRoute('/'), 'index');
      expect(normalizeAlwaysOnRoute(''), '');
      expect(normalizeAlwaysOnRoute(null), '');
      expect(normalizeAlwaysOnRoute('  navigation  '), 'navigation');
    });

    test('sanitize, match and parse the stored value', () {
      expect(sanitizeAlwaysOnRoutes(['/meter-digital', 'meter-digital', '', '  ', 'navigation']),
          ['meter-digital', 'navigation']);
      expect(sanitizeAlwaysOnRoutes([123, null, 'ride-running']), ['ride-running']);
      expect(sanitizeAlwaysOnRoutes('not-an-array'), isEmpty);
      const routes = ['partner-teksi', 'meter-digital'];
      expect(isRouteAlwaysOn('/meter-digital', routes), isTrue);
      expect(isRouteAlwaysOn('/partner-teksi?x=1', routes), isTrue);
      expect(isRouteAlwaysOn('/wallet', routes), isFalse);
      expect(isRouteAlwaysOn(null, routes), isFalse);
      expect(isRouteAlwaysOn('/meter-digital', ['/meter-digital']), isTrue);
      expect(parseStoredAlwaysOnRoutes('["meter-digital","/navigation"]'), ['meter-digital', 'navigation']);
      expect(parseStoredAlwaysOnRoutes('[]'), isEmpty);
      expect(parseStoredAlwaysOnRoutes('a, b'), ['a', 'b']);
    });

    test('defaults are the driver console pages, all in the catalogue, under a UUID row id', () {
      expect(defaultAlwaysOnRoutes, ['partner-teksi', 'partner-ehailing', 'meter-digital']);
      final catalog = alwaysOnCatalog.map((c) => c.$1).toSet();
      for (final r in defaultAlwaysOnRoutes) {
        expect(catalog, contains(r));
      }
      expect(alwaysOnRowId, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));
    });
  });

  group('display settings', () {
    test('merges stored values over the defaults and keeps unknown keys', () {
      final s = mergeDisplaySettings({
        'searchBar': false,
        'futureKey': 1,
        'serviceBoxes': [
          {'route': 'https://evil', 'comingSoon': 'yes'},
          {'route': ' /wallet '},
        ],
        'userMenu': {'renames': {'wallet': 'Money', 'x': ''}, 'customItems': [{'id': 'c1', 'label': 'L'}, {'id': 2}]},
      });
      expect(s['searchBar'], isFalse);
      expect(s['rideTypes'], isTrue);
      expect(s['futureKey'], 1);
      final boxes = s['serviceBoxes'] as List;
      expect(boxes, hasLength(5));
      expect((boxes[0] as Map).containsKey('route'), isFalse);
      expect(boxes[0]['comingSoon'], isFalse);
      expect(boxes[0]['iconName'], 'ShoppingBag');
      expect(boxes[1]['route'], '/wallet');
      final menu = s['userMenu'] as Map;
      expect(menu['renames'], {'wallet': 'Money'});
      expect(menu['customItems'], [
        {'id': 'c1', 'label': 'L', 'iconName': 'Star'},
      ]);
    });

    test('steppers clamp and round', () {
      final s = defaultDisplaySettings();
      expect(setDisplayNumber(s, 'recentLocationsCount', 12, 0, 8)['recentLocationsCount'], 8);
      expect(setDisplayNumber(s, 'dropPinTopOffset', -250, -200, 200)['dropPinTopOffset'], -200);
      expect(setDisplayNumber(s, 'mapHeightOffset', 12.6, 0, 800)['mapHeightOffset'], 13);
    });

    test('side menu order, rename, routes, visibility and removal', () {
      var s = defaultDisplaySettings();
      s = addCustomMenuItem(s, 'user', '  Refer  ', 'Gift', '/referral', id: 'custom-1');
      final ids = menuItemOrder('user', menuOf(s, 'user')).map((o) => o.id).toList();
      expect(ids.first, 'teksi-ev');
      expect(ids.last, 'custom-1');
      s = moveMenuItem(s, 'user', 'custom-1', -1);
      expect(menuItemOrder('user', menuOf(s, 'user')).map((o) => o.id).toList().reversed.take(2), ['logout', 'custom-1']);
      expect(moveMenuItem(s, 'user', 'teksi-ev', -1), same(s));

      s = renameMenuItem(s, 'user', 'wallet', 'Money');
      expect(menuOf(s, 'user')['renames'], {'wallet': 'Money'});
      s = renameMenuItem(s, 'user', 'wallet', 'Wallet');
      expect(menuOf(s, 'user')['renames'], isEmpty);
      s = renameMenuItem(s, 'user', 'custom-1', 'Invite');
      expect(((menuOf(s, 'user')['customItems'] as List).first as Map)['label'], 'Invite');

      s = setMenuItemRoute(s, 'user', 'custom-1', null);
      expect(((menuOf(s, 'user')['customItems'] as List).first as Map).containsKey('route'), isFalse);
      s = setMenuItemRoute(s, 'user', 'wallet', '/wallet-trade');
      expect(menuOf(s, 'user')['routes'], {'wallet': '/wallet-trade'});

      s = setMenuItemVisibility(s, 'user', 'custom-1', false);
      s = setMenuItemComingSoon(s, 'user', 'custom-1', true);
      expect(menuOf(s, 'user')['hidden'], ['custom-1']);
      s = removeCustomMenuItem(s, 'user', 'custom-1');
      final m = menuOf(s, 'user');
      expect(m['customItems'], isEmpty);
      expect(m['hidden'], isEmpty);
      expect(m['comingSoon'], isEmpty);
      expect(m['order'], isNot(contains('custom-1')));
      expect(menuOf(s, 'partner')['customItems'], isEmpty);
    });

    test('service boxes and the vehicle bar', () {
      var s = updateServiceBox(defaultDisplaySettings(), 2, {'route': '/wallet', 'comingSoon': false});
      expect((s['serviceBoxes'] as List)[2]['route'], '/wallet');
      s = updateServiceBox(s, 2, {'route': null});
      expect(((s['serviceBoxes'] as List)[2] as Map).containsKey('route'), isFalse);

      s = setVehicleServiceVisibility(s, 'v2', false);
      expect(s['hiddenVehicleServiceIds'], ['v2']);
      final vehicles = [
        {'id': 'v1', 'values': {'displayPriority': 2}},
        {'id': 'v2', 'values': {}},
        {'id': 'v3', 'values': {'displayPriority': 1}},
        {'id': 'v4', 'values': {'status': false}},
      ];
      List<String> arranged(Map<String, dynamic> st) => arrangeVehicles<Map<String, Object>>(vehicles, st,
          id: (e) => e['id'] as String, values: (e) => Map<String, dynamic>.from(e['values'] as Map)).map((e) => e['id'] as String).toList();
      expect(arranged(s), ['v3', 'v1']);
      s = moveVehicleInBar(s, 'v1', -1, arranged(s));
      expect(arranged(s), ['v1', 'v3']);
    });

    test('mock master switch and route labels', () {
      final off = setAllMocks(defaultDisplaySettings(), false);
      expect(anyMockEnabled(off), isFalse);
      expect(anyMockEnabled(setDisplayValue(off, 'riderTripSimEnabled', true)), isTrue);
      expect(routeLabel('/teksi-ev'), 'Book TEKSI EV');
      expect(routeLabel('/admin-settings-api-keys'), 'Admin Settings API Keys');
      expect(routeLabelFor(null), 'Not linked');
      expect(normalizeServiceBoxRoute('//evil.com'), isNull);
      expect(allAppRoutes, contains('/admin-settings-display'));
    });
  });

  group('site & branding', () {
    test('hex and lat/lng validation', () {
      expect(isValidHex('#fff'), isTrue);
      expect(isValidHex(' #2dabe2 '), isTrue);
      expect(isValidHex('2dabe2'), isFalse);
      expect(isValidHex('#12345'), isFalse);
      expect(hexToColor('#fff'), const Color(0xFFFFFFFF));
      expect(hexToColor('#2dabe2'), const Color(0xFF2DABE2));
      expect(hexToColor('nope'), isNull);
      expect(isValidLatLng('3.139003', '101.686855'), isTrue);
      expect(isValidLatLng('91', '0'), isFalse);
      expect(isValidLatLng('x', '0'), isFalse);
    });

    test('site settings merge and validate like the Expo screen', () {
      final s = mergeSiteSettings({'light': {'accent': '#000'}, 'startLat': '1'});
      expect((s['light'] as Map)['accent'], '#000');
      expect((s['light'] as Map)['text'], '#111827');
      expect(s['startLng'], '101.686855');
      expect(validateSiteSettings(s), isNull);
      final bad = {...s, 'dark': {...(s['dark'] as Map), 'border': 'grey'}};
      expect(validateSiteSettings(bad), 'Invalid Dark Border color');
      expect(validateSiteSettings({...s, 'startLat': '200'}), 'Invalid start latitude/longitude');
      expect(brandingPath('icon', 'png', DateTime.fromMillisecondsSinceEpoch(42)), 'icon-42.png');
    });

    test('owned categories', () {
      expect(meterappOwnedCategories, {'always-on-pages', 'site-settings'});
    });
  });
}
