// Permits per country (lib/src/core/permits.dart): plate colours from a
// country's list, a vehicle's permit status, the driver's badges and
// banners, the admin list's notes, field and type checks, reminder days.
// All values are made up.
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/date_order.dart';
import 'package:get_ride/src/core/document_ai.dart';
import 'package:get_ride/src/core/permits.dart';

/// A country list like the seeded default.
final _colours = PlateColourSettings.fromJson({
  'types': [
    {'type': 'TEKSI', 'bg': '#ffffff', 'fg': '#111111'},
  ],
  'energies': [
    {'energy': 'Petrol', 'bg': '#111111', 'fg': '#ffffff'},
    {'energy': 'EV', 'bg': '#1e8e3e', 'fg': '#ffffff'},
    {'energy': 'Diesel', 'bg': '#1a56c4', 'fg': '#ffffff'},
    {'energy': 'Hybrid', 'bg': '#9be3a8', 'fg': '#0b2a14'},
  ],
  'other': {'bg': '#111111', 'fg': '#ffffff'},
});

PermitItem _permit({
  String state = 'with',
  DateTime? until,
  int warn = 45,
  bool required = true,
  bool enforce = true,
  PermitUploader uploader = PermitUploader.admin,
  String name = 'Sample vehicle permit',
}) => PermitItem(
  typeId: 't1',
  name: name,
  shortName: 'Vehicle permit',
  issuer: 'Sample Agency',
  state: state,
  validUntil: until,
  warnDays: warn,
  required: required,
  enforce: enforce,
  uploader: uploader,
  renewalText: 'GET.ride is renewing it with {issuer}.',
);

void main() {
  setUp(() => deviceDateCountry = () => 'MY');

  group('plate colours', () {
    test('a taxi partner type first, whatever the energy', () {
      final c = plateColoursFor(_colours, types: ['eHailing', 'teksi'], energy: 'EV')!;
      expect(c.bg, const Color(0xFFFFFFFF));
      expect(c.fg, const Color(0xFF111111));
    });

    test('then the energy, without case', () {
      expect(plateColoursFor(_colours, energy: 'ev')!.bg, const Color(0xFF1E8E3E));
      expect(plateColoursFor(_colours, energy: 'Diesel')!.bg, const Color(0xFF1A56C4));
      final hybrid = plateColoursFor(_colours, energy: 'Hybrid')!;
      expect(hybrid.bg, const Color(0xFF9BE3A8));
      expect(hybrid.fg, const Color(0xFF0B2A14));
      expect(plateColoursFor(_colours, energy: 'Petrol')!.bg, const Color(0xFF111111));
    });

    test('an unknown or missing energy takes "other"', () {
      expect(plateColoursFor(_colours, energy: 'Steam')!.bg, const Color(0xFF111111));
      expect(plateColoursFor(_colours)!.fg, const Color(0xFFFFFFFF));
    });

    test('a country with no list keeps the plain plate', () {
      expect(plateColoursFor(const PlateColourSettings(), energy: 'EV'), isNull);
    });

    test('another country can differ', () {
      final other = PlateColourSettings.fromJson({
        'energies': [
          {'energy': 'EV', 'bg': '#0000ff', 'fg': '#ffff00'},
        ],
      });
      expect(plateColoursFor(other, energy: 'EV')!.bg, const Color(0xFF0000FF));
      expect(plateColoursFor(other, energy: 'Petrol'), isNull);
    });

    test('the stamped colours and hex round trip', () {
      expect(plateColoursFromJson({'bg': '#1e8e3e', 'fg': '#ffffff'})!.bg, const Color(0xFF1E8E3E));
      expect(plateColoursFromJson({'bg': 'green'}), isNull);
      expect(hexOf(const Color(0xFF1A56C4)), '#1a56c4');
      expect(PlateColourSettings.fromJson(_colours.toJson()).energies.length, 4);
    });

    test("a country's own colours, else the default row", () {
      final rows = [
        PermitCountrySettings.fromRow({'country': '*', 'plate_colours': _colours.toJson()}),
        PermitCountrySettings.fromRow({'country': 'Malaysia', 'enforce': true, 'bypass_days': 5}),
      ];
      expect(settingsFor(rows, 'malaysia').enforce, isTrue);
      expect(settingsFor(rows, 'malaysia').bypassDays, 5);
      expect(settingsFor(rows, 'Elsewhere').country, '*');
      expect(plateSettingsFor(rows, 'Malaysia').energies.length, 4);
    });
  });

  group('status', () {
    final now = DateTime(2026, 10, 20, 9);

    test('with, without, expired', () {
      expect(vehiclePermitStatus([(required: true, state: 'with')], now: now), PermitStatus.withPermit);
      expect(vehiclePermitStatus([(required: true, state: 'without')], now: now), PermitStatus.without);
      expect(vehiclePermitStatus([(required: true, state: 'pending')], now: now), PermitStatus.without);
      expect(vehiclePermitStatus([(required: true, state: 'expired')], now: now), PermitStatus.expired);
      expect(vehiclePermitStatus([(required: false, state: 'without')], now: now), PermitStatus.none);
    });

    test('bypass while it lasts, then back by itself', () {
      final p = [(required: true, state: 'without')];
      expect(vehiclePermitStatus(p, bypassUntil: now.add(const Duration(days: 2)), now: now), PermitStatus.bypass);
      expect(vehiclePermitStatus(p, bypassUntil: now.subtract(const Duration(minutes: 1)), now: now), PermitStatus.without);
      expect(vehiclePermitStatus([(required: true, state: 'with')], bypassUntil: now.add(const Duration(days: 2)), now: now),
          PermitStatus.withPermit);
    });

    test('a document state', () {
      final today = DateTime(2026, 10, 20);
      expect(permitDocState('Approved', DateTime(2027, 7, 4), today), 'with');
      expect(permitDocState('Approved', DateTime(2026, 10, 19), today), 'expired');
      expect(permitDocState('Approved', DateTime(2026, 10, 20), today), 'with');
      expect(permitDocState('Pending Review', null, today), 'pending');
      expect(permitDocState('Rejected', null, today), 'without');
      expect(permitDocState(null, null, today), 'without');
    });
  });

  group("the driver's view", () {
    final today = DateTime(2026, 10, 20);

    test('badges', () {
      expect(permitBadge(_permit(until: DateTime(2027, 7, 4)), today).text, 'Permit valid');
      final soon = permitBadge(_permit(until: DateTime(2026, 11, 9)), today);
      expect(soon.text, 'Expires in 20 days');
      expect(soon.tone, PermitBadgeTone.warn);
      expect(permitBadge(_permit(state: 'expired'), today).tone, PermitBadgeTone.bad);
      expect(permitBadge(_permit(state: 'without'), today, bypassUntil: DateTime(2026, 10, 23)).text, 'Bypass until 23/10/2026');
    });

    test('expiring: the renewal note with the issuer', () {
      final b = driverPermitBanner(_permit(until: DateTime(2026, 11, 9)), today)!;
      expect(b.blocked, isFalse);
      expect(b.title, 'Your Sample vehicle permit expires on 09/11/2026.');
      expect(b.body, 'GET.ride is renewing it with Sample Agency. The new permit will appear here.');
      expect(driverPermitBanner(_permit(until: DateTime(2027, 7, 4)), today), isNull);
    });

    test('expired or missing blocks only where permits are required', () {
      final b = driverPermitBanner(_permit(state: 'expired', until: DateTime(2026, 10, 4)), today, plate: 'TST 1')!;
      expect(b.blocked, isTrue);
      expect(b.title, "Sample vehicle permit expired: you can't go online for rides with TST 1.");
      expect(b.body, "GET.ride is renewing it with Sample Agency. You'll be notified when it's uploaded.");
      expect(driverPermitBanner(_permit(state: 'expired', enforce: false), today), isNull);
      expect(driverPermitBanner(_permit(state: 'without'), today, bypassUntil: DateTime(2026, 10, 22)), isNull);
      final own = driverPermitBanner(_permit(state: 'without', uploader: PermitUploader.driver), today)!;
      expect(own.body, 'Upload it in Documents.');
    });

    test('the button: one permit by its short name, several as Permits, none hidden', () {
      expect(permitButtonLabel(const []), isNull);
      expect(permitButtonLabel([_permit()]), 'Vehicle permit');
      expect(permitButtonLabel([_permit(), _permit(name: 'Driver permit')]), 'Permits');
      expect(permitSheetTitle([_permit()]), 'Sample vehicle permit');
    });
  });

  group("the admin list's notes", () {
    final today = DateTime(2026, 10, 20);

    test('valid until, expiring, expired, pass ends, joined', () {
      expect(
        permitListNote(status: PermitStatus.withPermit, permits: [_permit(until: DateTime(2027, 7, 4))], today: today).text,
        'valid until 04/07/2027',
      );
      final soon = permitListNote(status: PermitStatus.withPermit, permits: [_permit(until: DateTime(2026, 11, 9))], today: today);
      expect(soon.text, 'expires in 20 days');
      expect(soon.highlight, isTrue);
      expect(
        permitListNote(status: PermitStatus.expired, permits: [_permit(state: 'expired', until: DateTime(2026, 10, 4))], today: today).text,
        'expired 04/10/2026 · cannot take rides',
      );
      expect(
        permitListNote(status: PermitStatus.bypass, permits: [_permit(state: 'without')], bypassUntil: DateTime(2026, 10, 22), today: today).text,
        'pass ends 22/10/2026 (2 days left)',
      );
      expect(
        permitListNote(status: PermitStatus.without, permits: [_permit(state: 'without')], joinedAt: DateTime(2026, 10, 17), today: today).text,
        'joined 3 days ago',
      );
      expect(
        permitListNote(status: PermitStatus.without, permits: [_permit(state: 'pending')], today: today).text,
        'waiting for review',
      );
    });

    test('plate on the permit', () {
      expect(platesMatch('TST1234', 'tst 1234'), isTrue);
      expect(platesMatch('TST-1235', 'TST 1234'), isFalse);
      expect(platesMatch(null, 'TST 1234'), isNull);
    });
  });

  group('permit types and fields', () {
    const evp = [
      PermitField(key: 'ref', label: 'Reference', role: PermitFieldRole.number, passenger: true),
      PermitField(key: 'until', label: 'Valid until', isDate: true, role: PermitFieldRole.validUntil, passenger: true),
    ];

    test('field checks', () {
      expect(permitFieldsProblem(evp), isNull);
      expect(permitFieldsProblem([...evp, const PermitField(key: 'ref', label: 'Again')]), contains('Two fields'));
      expect(
        permitFieldsProblem([...evp, const PermitField(key: 'x', label: 'Also until', isDate: true, role: PermitFieldRole.validUntil)]),
        contains('Only one field'),
      );
      expect(permitFieldsProblem([const PermitField(key: 'y', label: 'Until', role: PermitFieldRole.validUntil)]),
          contains('must be a date'));
      expect(permitFieldKey('Permit Reference No. (Sub)'), 'permit_reference_no_sub');
      expect(permitTypeKey('Taxi driver permit'), 'taxi-driver-permit');
    });

    test('a type round trips and is checked', () {
      final t = PermitType(country: 'Testland', key: 'tvp', name: 'Test vehicle permit', fields: evp, required: true);
      final back = PermitType.fromRow({...t.toRow(), 'id': 'x'});
      expect(back.fields.map((f) => f.key), ['ref', 'until']);
      expect(back.fields.last.role, PermitFieldRole.validUntil);
      expect(back.required, isTrue);
      expect(permitTypeProblem(t), isNull);
      expect(permitTypeProblem(PermitType(country: 'Testland', key: 'd', name: 'Driver permit', forDriver: true,
          uploader: PermitUploader.driver)), contains('document drivers upload'));
    });

    test('values from the server', () {
      final p = PermitItem.fromJson({
        'type_id': 't',
        'name': 'Test vehicle permit',
        'fields': [
          {'key': 'until', 'label': 'Valid until', 'label_local': 'Sah sehingga', 'kind': 'date', 'role': 'valid_until', 'value': '2027-07-04'},
        ],
        'bucket': 'vehicle-documents',
        'path': 'v/permits/a.pdf',
      });
      expect(p.fields.single.shown, '04/07/2027');
      expect(p.fields.single.field.labelLocal, 'Sah sehingga');
      expect(p.hasFile, isTrue);
      expect(p.fieldValue(PermitFieldRole.validUntil), '2027-07-04');
    });

    test('the AI is asked for the type fields by their labels', () {
      final body = docAiRequestBody(frontDataUrl: 'data:image/png;base64,AA', docName: 'Test permit', permitFields: [
        (key: 'ref', label: 'Reference', labelLocal: 'Rujukan', isDate: false),
        (key: 'until', label: 'Valid until', labelLocal: '', isDate: true),
      ]);
      final fields = (body['context'] as Map)['permitFields'] as List;
      expect(fields.first, {'key': 'ref', 'label': 'Reference', 'labelLocal': 'Rujukan', 'kind': 'text'});
      expect(fields.last, {'key': 'until', 'label': 'Valid until', 'kind': 'date'});
      expect((docAiRequestBody(frontDataUrl: 'x', docName: 'Licence')['context'] as Map).containsKey('permitFields'), isFalse);
      final r = DocumentAiResult({
        'extracted': {
          'permitFields': {'ref': ' AB-1 ', 'until': null},
        },
      });
      expect(r.permitFields, {'ref': 'AB-1', 'until': null});
    });
  });

  group('reminder days', () {
    test('typed in any way, largest first, each once', () {
      expect(parseReminderDays('45, 30 15;3,1, 30').days, [45, 30, 15, 3, 1]);
      expect(parseReminderDays('').days, isEmpty);
      expect(parseReminderDays('five').error, isNotNull);
      expect(parseReminderDays('401').error, isNotNull);
      expect(reminderDaysText([45, 30]), '45, 30');
    });

    test('a permit type, else the document, else the country, else the default', () {
      final rows = [
        const ReminderDays(scope: ReminderScope.defaultDays, days: [45, 30, 15, 3, 1]),
        const ReminderDays(scope: ReminderScope.country, scopeKey: 'Testland', days: [60]),
        const ReminderDays(scope: ReminderScope.permitType, scopeKey: 'type-1', days: [90, 7]),
        const ReminderDays(scope: ReminderScope.document, scopeKey: 'doc-1', days: [10]),
      ];
      expect(reminderDaysFor(rows, country: 'testland', permitTypeId: 'type-1'), [90, 7]);
      expect(reminderDaysFor(rows, country: 'Testland', documentId: 'doc-1'), [10]);
      expect(reminderDaysFor(rows, country: 'Testland'), [60]);
      expect(reminderDaysFor(rows, country: 'Elsewhere'), [45, 30, 15, 3, 1]);
      expect(reminderDaysFor(const []), isEmpty);
    });
  });
}
