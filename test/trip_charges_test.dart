import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_charges.dart';
import 'package:get_ride/src/core/trip_receipt.dart';
import 'package:get_ride/src/data/models.dart';

void main() {
  test('amounts are read the way drivers type them', () {
    expect(parseChargeAmount(''), 0);
    expect(parseChargeAmount('5'), 5);
    expect(parseChargeAmount('5,50'), 5.5);
    expect(parseChargeAmount('RM 12.345'), 12.35);
    expect(parseChargeAmount('1.2.3'), isNull);
    expect(parseChargeAmount('abc'), isNull);
  });

  test('resolveTripCharges checks amounts and the note', () {
    final none = resolveTripCharges(tolls: '', other: '', note: '');
    expect(none.charges?.isEmpty, isTrue);
    expect(none.charges?.toPatch(), {'toll_charges': 0.0, 'other_charges': 0.0, 'other_charges_note': null});

    final ok = resolveTripCharges(tolls: '5.5', other: '3', note: ' Parking ');
    expect(ok.charges?.total, 8.5);
    expect(ok.charges?.toPatch(), {'toll_charges': 5.5, 'other_charges': 3.0, 'other_charges_note': 'Parking'});

    expect(resolveTripCharges(tolls: 'x', other: '', note: '').problem, contains('tolls'));
    expect(resolveTripCharges(tolls: '', other: '3', note: '').problem, 'Say what the other charges are for.');
    expect(resolveTripCharges(tolls: '10001', other: '', note: '').problem, contains('at most'));
    expect(resolveTripCharges(tolls: '', other: '1', note: 'x' * 201).problem, contains('200'));

    // A note with nothing to explain isn't stored.
    expect(
      resolveTripCharges(tolls: '2', other: '', note: 'Toll at Sg Besi').charges?.toPatch()['other_charges_note'],
      isNull,
    );
  });

  test('the rider is shown the fare plus what the driver declared', () {
    final r = RideRequest({
      'id': 'abcdef12-0000',
      'status': 'completed',
      'fare': 20,
      'ride_fare': 20,
      'toll_charges': 5.5,
      'other_charges': 3,
      'other_charges_note': 'Parking',
      'currency': 'MYR',
    });
    expect(r.totalDue, 28.5);
    final receipt = TripReceipt.fromRide(r);
    expect(receipt.lines.map((l) => l.label), ['Trip fare', 'Tolls', 'Other charges (Parking)']);
    expect(receipt.total, 28.5);
    expect(RideRequest({'id': 'x', 'fare': 20}).totalDue, 20);
  });

  test('GET.coin paid towards the ride is taken off what the driver collects', () {
    final r = RideRequest({
      'id': 'abcdef12-0000',
      'status': 'completed',
      'ride_fare': 20,
      'toll_charges': 5,
      'fare_coins_value': 7.5,
      'currency': 'MYR',
    });
    expect(r.totalDue, 25);
    expect(r.fareCoinsValue, 7.5);
    expect(r.cashDue, 17.5);
    final receipt = TripReceipt.fromRide(r);
    expect(receipt.lines.last, (label: 'Paid with GET.coin', amount: -7.5));
    expect(receipt.total, 17.5);
    expect(receipt.totalLabel, 'Balance paid');
    expect(TripReceipt.fromRide(RideRequest({'id': 'x', 'status': 'completed', 'fare': 10})).totalLabel, 'Total');
    expect(RideRequest({'id': 'x', 'fare': 5, 'fare_coins_value': 9}).cashDue, 0);
  });
}
