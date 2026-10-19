import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/fare_info.dart';
import 'package:get_ride/src/core/fare_tariff.dart';
import 'package:get_ride/src/core/route_estimate.dart' show FareTrendDirection;

void main() {
  test('a taxi is metered by name or service type', () {
    expect(isMeteredService(const RideService('Teksi', '', 1, 4)), isTrue);
    expect(isMeteredService(const RideService('City Taxi', '', 1, 4)), isTrue);
    expect(isMeteredService(const RideService('Blue', '', 1, 4, serviceTypes: ['Taxi'])), isTrue);
    expect(isMeteredService(const RideService('GET Car', '', 1.1, 4, serviceTypes: ['Car'])), isFalse);
  });

  test("a card's rates, with the vehicle's multiplier where the fare applies it", () {
    const card = FareTariff(level: 'country', currency: 'PHP', baseFare: 50, perKm: 13.5, perMinute: 2);
    const xl = RideService('XL', '', 1.5, 6);
    final lines = fareRateLines(card, xl);
    expect(lines, hasLength(3));
    expect(lines[0], startsWith('Base fare: '));
    expect(lines[0], contains('75'));
    expect(lines[1], contains('20.25'));
    expect(lines[2], contains('3'));
    expect(lines[2], isNot(contains('3.00')), reason: 'whole rates print without decimals');
  });

  test("a vehicle's own card is not multiplied again; minimum and booking fee when set", () {
    const card = FareTariff(
      level: 'country',
      baseFare: 4,
      perKm: 1,
      perMinute: 0.3,
      minimumFare: 6,
      bookingFee: 1,
      vehicleService: 'v1',
    );
    final lines = fareRateLines(card, const RideService('XL', '', 2, 6));
    expect(lines[0], contains('4'));
    expect(lines[2], contains('0.30'));
    expect(lines.where((l) => l.startsWith('Minimum fare: ')), hasLength(1));
    expect(lines.where((l) => l.startsWith('Booking fee: ')), hasLength(1));
  });

  test('without a card, the built-in TEKSI tariff', () {
    final lines = fareRateLines(null, const RideService('Teksi', '', 1, 4));
    expect(lines.first, contains('Flag fall'));
    expect(lines.last, contains('per 200 m or 36 s'));
  });

  test('the demand copy follows the trend both ways', () {
    expect(demandHeadline(FareTrendDirection.up), 'High demand — fare is higher');
    expect(demandHeadline(FareTrendDirection.down), 'Low demand — fare is lower');
    expect(demandDetail(FareTrendDirection.up), contains('temporarily higher'));
    expect(demandDetail(FareTrendDirection.down), contains('temporarily lower'));
  });

  test('high demand: the uplift and how much higher come from the fare with and without the trend', () {
    expect(demandUplift(7, 7), isNull);
    expect(demandUplift(6, 7), isNull, reason: 'lower is no uplift');
    expect(demandUplift(8, 0), isNull);
    final u = demandUplift(12, 10)!;
    expect(u.amount, 2);
    expect(u.factor, 1.2);
    expect(demandUpliftLabel('RM2'), '+RM2');
    expect(demandIncludesNote('RM2'), 'Includes high demand +RM2');
    expect(demandHigherLine(1.2), startsWith('Fares are 20% higher right now because of demand'));
    expect(demandHigherLine(null), startsWith('Fares are higher right now'), reason: 'no number without a multiplier');
    expect(demandHigherLine(1.001), startsWith('Fares are higher right now'));
  });
}
