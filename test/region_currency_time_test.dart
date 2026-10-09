// A region's currency symbol and time zone, as the rider screens print them.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/format.dart';
import 'package:get_ride/src/core/region_time.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/core/trip_receipt.dart';
import 'package:get_ride/src/data/models.dart';

RideRequest ride(Map<String, dynamic> extra) => RideRequest({
  'id': 'a1b2c3d4-e5f6-7890-abcd-ef0123456789',
  'status': 'completed',
  'fare': 20,
  'ride_fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'created_at': '2026-10-09T15:00:00Z',
  'started_at': '2026-10-09T15:10:00Z',
  'completed_at': '2026-10-09T15:34:00Z',
  ...extra,
});

void main() {
  group('currency symbols from the regions', () {
    tearDown(() => setRegionCurrencySymbols(const {}));

    test("a region's symbol wins, keeping the currency's side and decimals", () {
      final regions = [
        BiddingRegion.fromValues({'country': 'Malaysia', 'currencyName': 'myr', 'currencySymbol': 'RM '})!,
        BiddingRegion.fromValues({'country': 'Vietnam', 'currencyName': 'VND', 'currencySymbol': ' đ'})!,
        BiddingRegion.fromValues({'country': 'Switzerland', 'currencyName': 'CHF', 'currencySymbol': 'Fr.'})!,
        BiddingRegion.fromValues({'country': 'Nowhere', 'currencyName': 'not a code', 'currencySymbol': 'X'})!,
      ];
      expect(regions[0].currency, 'MYR');
      expect(regions[3].currency, isNull);
      setRegionCurrencySymbols(regionCurrencySymbols(regions));
      expect(formatMoney(20, 'MYR'), 'RM20.00', reason: 'trimmed');
      expect(formatMoney(25000, 'VND'), '25,000đ', reason: 'after the amount, no decimals, as VND is written');
      expect(formatMoney(5, 'CHF'), 'Fr.5.00', reason: 'a currency the app had no symbol for');
      expect(formatMoney(5, 'SGD'), r'S$5.00', reason: 'untouched where no region sets one');
    });

    test('without regions the built-in symbols stand', () {
      expect(formatMoney(5, 'CHF'), 'CHF 5.00');
      expect(formatMoney(20, 'MYR'), 'RM20.00');
    });
  });

  group('times in the region\'s zone', () {
    final at = DateTime.utc(2026, 10, 9, 15); // 23:00 in Kuala Lumpur

    test('labelled with the offset when the phone is elsewhere', () {
      expect(formatInZone(at, 'Asia/Kuala_Lumpur', deviceOffset: Duration.zero), '9 Oct 2026, 11:00 PM GMT+8');
      expect(formatInZone(at, 'Asia/Kolkata', pattern: 'h:mm a', deviceOffset: Duration.zero), '8:30 PM GMT+5:30');
      expect(formatInZone(at, 'America/Sao_Paulo', pattern: 'h:mm a', deviceOffset: Duration.zero), '12:00 PM GMT-3');
    });

    test('unlabelled when the phone is in the same zone', () {
      expect(formatInZone(at, 'Asia/Kuala_Lumpur', deviceOffset: const Duration(hours: 8)), '9 Oct 2026, 11:00 PM');
    });

    test("no zone or an unknown one: the phone's own time, as before", () {
      final local = formatInZone(at, null);
      expect(local, isNot(contains('GMT')));
      expect(formatInZone(at, 'Mars/Olympus'), local);
      expect(formatInZone(null, 'Asia/Kuala_Lumpur'), '—');
    });

    test('offset labels', () {
      expect(gmtLabel(Duration.zero), 'GMT');
      expect(gmtLabel(const Duration(hours: 8)), 'GMT+8');
      expect(gmtLabel(const Duration(hours: -9, minutes: -30)), 'GMT-9:30');
      expect(zoneOffset('Europe/London', DateTime.utc(2026, 7, 1)), const Duration(hours: 1), reason: 'summer time');
      expect(zoneOffset('', at), isNull);
    });
  });

  group('the receipt', () {
    test("prints the ride's times in its zone", () {
      final rc = TripReceipt.fromRide(ride({'timezone': 'Asia/Kuala_Lumpur'}));
      expect(rc.timezone, 'Asia/Kuala_Lumpur');
      final details = Map.fromEntries(rc.details.map((d) => MapEntry(d.$1, d.$2)));
      expect(details['Picked up'], startsWith('11:10 PM'));
      expect(details['Dropped off'], startsWith('11:34 PM'));
      expect(details['Date'], startsWith('9 Oct 2026, 11:34 PM'));
      expect(TripReceipt.fromRide(ride({})).timezone, isNull);
    });

    test('bills the region surcharges and taxes stamped on the ride', () {
      final rc = TripReceipt.fromRide(
        ride({
          'charges': [
            {'kind': 'surcharge', 'name': 'Night', 'charge': 'fixed', 'value': 2},
            {'kind': 'tax', 'name': 'SST', 'charge': 'percent', 'value': 6},
          ],
          'toll_charges': 3,
        }),
      );
      expect(rc.lines.map((l) => (l.label, l.amount)), [
        ('Trip fare', 20.0),
        ('Night', 2.0),
        ('SST 6%', 1.32),
        ('Tolls', 3.0),
      ]);
      expect(rc.total, closeTo(26.32, 1e-9));
      expect(
        rc.total,
        closeTo(
          ride({
            'charges': [
              {'kind': 'surcharge', 'name': 'Night', 'charge': 'fixed', 'value': 2},
              {'kind': 'tax', 'name': 'SST', 'charge': 'percent', 'value': 6},
            ],
            'toll_charges': 3,
          }).totalDue!,
          1e-9,
        ),
        reason: 'the receipt and the trip card agree',
      );
    });
  });
}
