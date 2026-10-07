// One ride of the rider's own at a time; any number booked for others.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/book_for.dart';
import 'package:get_ride/src/data/models.dart';

RideRequest _ride(String id, {String? forName, String? forPhone, String status = 'open'}) => RideRequest({
  'id': id,
  'status': status,
  'rider_name': 'Ali',
  'rider_phone': '+60111111111',
  'booked_for_name': forName,
  'booked_for_phone': forPhone,
});

void main() {
  test('the passenger is who it was booked for, else the rider', () {
    final own = _ride('a');
    expect(own.isForOthers, isFalse);
    expect(own.passengerName, 'Ali');
    expect(own.passengerPhone, '+60111111111');
    final forMak = _ride('b', forName: 'Mak', forPhone: '+60123456789');
    expect(forMak.isForOthers, isTrue);
    expect(forMak.passengerName, 'Mak');
    expect(forMak.passengerPhone, '+60123456789');
    expect(
      _ride('c', forName: '  ', forPhone: '  ').isForOthers,
      isFalse,
      reason: 'blank is not a booking for others',
    );
  });

  test("rides for others never stand in for the rider's own", () {
    final rides = [
      _ride('m', forName: 'Mak', forPhone: '+601'),
      _ride('own'),
      _ride('a', forName: 'Adik', forPhone: '+602'),
    ];
    expect(ownRide(rides)?.id, 'own');
    expect(ridesForOthers(rides).map((r) => r.id), ['m', 'a']);
    expect(ownRide([_ride('m', forName: 'Mak', forPhone: '+601')]), isNull);
    expect(ownRide(const []), isNull);
  });

  test("the passenger's details are required, and the number is kept as + and digits", () {
    expect(bookForProblem('', '0123456789'), "Enter the passenger's name.");
    expect(bookForProblem('Mak', '123'), "Enter the passenger's phone number.");
    expect(bookForProblem('Mak', '+60 12-345 6789'), isNull);
    expect(bookedFor('Mak', ''), isNull);
    expect(bookedFor(' Mak ', '+60 12-345 6789'), (name: 'Mak', phone: '+60123456789'));
    expect(cleanBookForPhone('(012) 345-6789'), '0123456789');
    expect(bookForProblem('x' * 81, '0123456789'), 'The name is too long.');
  });

  test('the database refusal reads as a duplicate', () {
    expect(isDuplicateRideError('RIDE_REQUEST_DUPLICATE'), isTrue);
    expect(isDuplicateRideError('duplicate key value'), isFalse);
    expect(isDuplicateRideError(null), isFalse);
    expect(const DuplicateRideRequest(forOthers: false).toString(), contains('Only one can be sent at a time'));
    expect(const DuplicateRideRequest(forOthers: true).toString(), contains('for this passenger'));
  });
}
