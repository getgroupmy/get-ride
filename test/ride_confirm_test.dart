import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_bidding.dart';
import 'package:get_ride/src/core/ride_confirm.dart';

void main() {
  test('the trip time reads as Expo writes it', () {
    expect(confirmDuration(null), '');
    expect(confirmDuration(0), '');
    expect(confirmDuration(24.6), '~25 min');
    expect(confirmDuration(60), '~1 hr');
    expect(confirmDuration(65), '~1 hr, 5 min');
    expect(confirmDuration(130), '~2 hrs, 10 min');
  });

  test('an offer at or under the auto-accept amount is taken; a higher one asks', () {
    const at = RideOffer(partnerId: 'p', amount: 25);
    const over = RideOffer(partnerId: 'p', amount: 30);
    expect(shouldAutoAccept(limit: 25, offer: at), isTrue);
    expect(shouldAutoAccept(limit: 25, offer: over), isFalse);
    expect(shouldAutoAccept(limit: null, offer: at), isFalse, reason: 'switched off');
    expect(shouldAutoAccept(limit: 25, offer: null), isFalse);
  });

  test("the entrance goes ahead of the rider's note", () {
    expect(driverNote(), isNull);
    expect(driverNote(entrance: ' 3 '), 'Entrance 3');
    expect(driverNote(note: 'Blue gate'), 'Blue gate');
    expect(driverNote(entrance: '12', note: 'Blue gate'), 'Entrance 12 · Blue gate');
  });

  test('the admin offsets and the promo bar switch are read from Display Settings', () {
    final l = ConfirmLayout.fromSettings({
      'rcBackHorizontal': 10,
      'rcBackVertical': '-20',
      'rcAddressVertical': 15,
      'discountBar': false,
      'discountBarHeightOffset': 5,
    });
    expect(l.back, (10.0, -20.0));
    expect(l.address, (0.0, 15.0));
    expect(l.promoBar, isFalse);
    expect(l.promoBarOffset, 5);
    expect(ConfirmLayout.fromSettings(const {}).promoBar, isTrue, reason: 'on by default, as Expo');
  });
}
