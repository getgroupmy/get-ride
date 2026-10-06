import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_request_metadata.dart';
import 'package:get_ride/src/data/geo_service.dart';

void main() {
  test('metadata carries only what is known, trimmed', () {
    final m = rideRequestMetadata(
      area: const AreaInfo(
        country: 'Malaysia',
        state: ' Selangor ',
        city: '',
        suburb: 'Bangsar',
        address: 'Jalan X, KL',
      ),
      ipAddress: '1.2.3.4',
      gender: 'female',
      riderPhoto: 'https://cdn/x.png',
    );
    expect(m, {
      'country': 'Malaysia',
      'state': 'Selangor',
      'suburb': 'Bangsar',
      'full_address': 'Jalan X, KL',
      'ip_address': '1.2.3.4',
      'gender': 'female',
      'rider_photo': 'https://cdn/x.png',
    });
  });

  test('nothing known means nothing written; a non-URL photo is dropped', () {
    expect(rideRequestMetadata(), isEmpty);
    expect(rideRequestMetadata(riderPhoto: 'data:image/png;base64,AAAA'), isEmpty);
  });

  test('the area keeps the full geocoder address', () {
    final a = AreaInfo.fromNominatim({
      'display_name': 'KLCC, Jalan Ampang, Kuala Lumpur, Malaysia',
      'address': {'country': 'Malaysia', 'city': 'Kuala Lumpur', 'suburb': 'KLCC'},
    });
    expect(a.address, 'KLCC, Jalan Ampang, Kuala Lumpur, Malaysia');
    expect(a.label, 'KLCC, Jalan Ampang');
    expect(AreaInfo.fromNominatim({}).address, isNull);
  });

  test('only optional columns still in the row are dropped', () {
    const optional = {'stops', 'gender', 'ip_address'};
    const keys = ['rider_id', 'gender', 'stops'];
    expect(droppableRideColumn("Could not find the 'gender' column of 'ride_requests'", optional, keys), 'gender');
    expect(droppableRideColumn("Could not find the 'ip_address' column", optional, keys), isNull); // already gone
    expect(droppableRideColumn("Could not find the 'rider_id' column", optional, keys), isNull); // required
    expect(droppableRideColumn('column "stops" does not exist', optional, keys), 'stops');
    expect(droppableRideColumn('permission denied', optional, keys), isNull);
  });
}
