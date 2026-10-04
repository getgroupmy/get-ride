import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/escpos.dart';
import 'package:get_ride/src/core/meter_trip.dart';
import 'package:get_ride/src/core/printers.dart';
import 'package:get_ride/src/core/taxi_meter.dart';
import 'package:get_ride/src/data/printer/printer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_printer.dart';

MeterTrip _trip() => buildMeterTrip(
      const MeterState(startedAt: 1000, distanceM: 3420, elapsedMs: 600000, waitingMs: 60000, gpsSamples: 600),
      id: 't1',
      endedAt: 601000,
      fare: 12.4,
      details: resolveTripDetails(const MeterTripDetailsDraft(pax: 2, luggage: 1, charges: 3, airport: MeterAirport.pickup))!,
      rateLabel: 'Global rate card',
      period: MeterPeriod.day,
      flagFare: 4,
      nightMultiplier: 1.5,
      currency: 'RM',
      cardSurcharge: 1,
      plate: 'WXY 1',
      driver: 'Aina',
      pickup: const MeterWaypoint(at: 1000, latitude: 3.1, longitude: 101.6, place: 'Jalan Tun Razak, Kuala Lumpur'),
      dropoff: const MeterWaypoint(at: 601000, latitude: 3.2, longitude: 101.7, odometerKm: 128450.6),
    );

/// The printed text with the control codes taken out.
String _text(String doc) => doc.replaceAll(RegExp(r'\x1B[@]|\x1B[aEd].|\x1D[!V].'), '');

void main() {
  group('ESC/POS text', () {
    test('accents fold to ASCII and the unprintable becomes ?', () {
      expect(asciiFold('Café – Jalan Ampang · 5'), 'Cafe - Jalan Ampang - 5');
      expect(asciiFold('東京 🚕'), '?? ?');
    });

    test('rows spread label and value across the roll', () {
      expect(padRow('Total', 'RM 19.40', 20), 'Total       RM 19.40\n');
      expect(padRow('Total', 'RM 19.40', 20).length, 21);
    });

    test('a value too long to sit beside its label drops below it, right-aligned', () {
      expect(padRow('Pickup', 'Jalan Tun Razak, Kuala Lumpur', 20), 'Pickup\n    Jalan Tun Razak,\n        Kuala Lumpur\n');
    });

    test('wrapping splits a word wider than the roll', () {
      expect(wrapText('a bcdefghij k', 4), ['a', 'bcde', 'fghi', 'j', 'k']);
      expect(wrapText('   ', 4), ['']);
    });
  });

  group('ESC/POS documents', () {
    test('a receipt is plain ASCII that fits the roll', () {
      for (final paper in PaperWidth.values) {
        final doc = buildMeterReceiptEscpos(_trip(), paper: paper);
        expect(doc.codeUnits.every((c) => c <= 0x7F), isTrue);
        expect(doc, startsWith(escposInit));
        for (final line in _text(doc).split('\n')) {
          expect(line.length, lessThanOrEqualTo(paper.columns), reason: '"$line" on ${paper.label}');
        }
      }
    });

    test('a receipt prints the same lines as the screen', () {
      final text = _text(buildMeterReceiptEscpos(_trip()));
      expect(text, contains('GET TAXI METER'));
      expect(text, contains('Vehicle WXY 1'));
      expect(text, contains('Driver Aina'));
      expect(text, contains('Drop-off odometer'));
      expect(text, contains('128 450.6 km'));
      expect(text, contains(padRow('Total', 'RM 19.40', 32)));
      expect(text, contains('Pickup\n   Jalan Tun Razak, Kuala Lumpur\n'));
      expect(text, contains('Thank you for riding.'));
      // The total is the one bold line.
      expect(RegExp('\x1BE\x01').allMatches(buildMeterReceiptEscpos(_trip())), hasLength(2),
          reason: 'the title and the total');
    });

    test('80 mm paper uses 48 columns, and the cut is only sent when asked', () {
      final test = _text(buildTestPrintEscpos(paper: PaperWidth.mm80));
      expect(test, contains('Paper${' ' * 29}80mm (48 cols)\n'));
      expect(buildMeterReceiptEscpos(_trip()), isNot(contains('\x1DV\x00')));
      expect(buildMeterReceiptEscpos(_trip(), cut: true), contains('\x1DV\x00'));
    });
  });

  group('saved printers', () {
    test('a Wi-Fi printer needs an address and defaults to port 9100', () {
      expect(normalizeWifiPrinter(id: 'a', createdAt: 't').error, "Enter the printer's IP address.");
      final p = normalizeWifiPrinter(id: 'a', createdAt: 't', host: '192.168.0.50', paper: PaperWidth.mm80).value!;
      expect(p.port, 9100);
      expect(p.name, 'Wi-Fi printer');
      expect(describePrinter(p), 'Wi-Fi · 192.168.0.50:9100 · 80mm');
      expect(normalizeWifiPrinter(id: 'a', createdAt: 't', host: 'http://x').error, isNotNull);
      expect(normalizeWifiPrinter(id: 'a', createdAt: 't', host: '10.0.0.2', port: '0').error, isNotNull);
    });

    test('the same address replaces the entry; the default is selected, then last used', () {
      final a = normalizeWifiPrinter(id: 'a', createdAt: 't1', host: '10.0.0.2', name: 'Old').value!;
      final again = normalizeWifiPrinter(id: 'b', createdAt: 't2', host: '10.0.0.2', name: 'New').value!;
      final list = upsertPrinter([a], again);
      expect(list.single.id, 'a');
      expect(list.single.name, 'New');
      final c = normalizeWifiPrinter(id: 'c', createdAt: 't', host: '10.0.0.3').value!.copyWith(lastPrintedAt: 9);
      expect(pickDefaultPrinter([...list, c], null)!.id, 'c');
      expect(pickDefaultPrinter([...list, c], 'a')!.id, 'a');
      expect(removePrinter([...list, c], 'a').single.id, 'c');
    });

    test('a saved printer survives storage, and an unknown paper is 58 mm', () {
      final p = normalizeWifiPrinter(id: 'a', createdAt: 't', host: '10.0.0.2', paper: PaperWidth.mm80).value!;
      expect(SavedPrinter.fromJson(p.toJson())!.toJson(), p.toJson());
      expect(SavedPrinter.fromJson({'id': 'x', 'transport': 'wifi', 'paperWidth': 'A4'})!.paper, PaperWidth.mm58);
    });
  });

  group('printing', () {
    late FakePrinter printer;
    late ProviderContainer container;
    final saved = normalizeWifiPrinter(id: 'p1', createdAt: 't', host: '10.0.0.2').value!;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      printer = FakePrinter();
      container = ProviderContainer(overrides: [
        printerSinkFactoryProvider.overrideWithValue((_) => printer),
        printerSettleProvider.overrideWithValue(Duration.zero),
      ]);
      await container.read(printerStoreProvider).save([saved]);
    });

    tearDown(() => container.dispose());

    test('a job connects, writes, closes and marks the printer used', () async {
      final error = await container.read(printerServiceProvider).send(saved, 'X');
      expect(error, isNull);
      expect(printer.jobs, ['X']);
      expect(printer.open, isFalse);
      await pumpEventQueue();
      expect((await container.read(printerStoreProvider).load()).single.lastPrintedAt, isNotNull);
    });

    test('an unreachable printer is an answer, not a crash', () async {
      printer.refuse = true;
      final error = await container.read(printerServiceProvider).send(saved, 'X');
      expect(error, contains('Connection refused'));
      expect(printer.jobs, isEmpty);
    });
  });
}
