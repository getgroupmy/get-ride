import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';

void main() {
  RideRequest ride(Map<String, dynamic> extra) =>
      RideRequest({'id': 'r1', 'status': 'pending', 'currency': 'MYR', ...extra});

  test('a ride with a fare shows it on Accept', () {
    expect(acceptLabel(ride({'ride_fare': 25})), contains('25'));
  });

  test('a metered order with no fare says so instead of a dash', () {
    final label = acceptLabel(ride({'fare_mode': 'meter'}));
    expect(label, 'Accept · by meter');
    expect(label, isNot(contains('—')));
  });

  test('no fare and no meter: just Accept', () {
    expect(acceptLabel(ride({})), 'Accept');
  });
}
