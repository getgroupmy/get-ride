import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/get_coin.dart' show formatCoins, rideRewardCoins;
import 'package:get_ride/src/core/referral.dart';

void main() {
  test('the invite card names the real bonuses, or promises nothing', () {
    String? line({bool on = true, double me = 0, double friend = 0}) =>
        referralBonusLine(enabled: on, referrer: me, referred: friend, coins: formatCoins);
    expect(
      line(me: 100, friend: 50),
      'Invite a friend: they get 50 GC and you get 100 GC when they sign up with your code.',
    );
    expect(line(friend: 50), 'Invite a friend: they get 50 GC when they sign up with your code.');
    expect(line(me: 20), 'Invite a friend: you get 20 GC when they sign up with your code.');
    expect(line(), isNull);
    expect(line(on: false, me: 100, friend: 50), isNull);
  });

  test('the sign-up hint', () {
    expect(
      referralSignupHint(enabled: true, referred: 25.5, coins: formatCoins),
      'Invited by a friend? You get 25.50 GC.',
    );
    expect(referralSignupHint(enabled: true, referred: 0, coins: formatCoins), isNull);
    expect(referralSignupHint(enabled: false, referred: 10, coins: formatCoins), isNull);
  });

  test('the booking reward is the fare at the earn rate', () {
    expect(rideRewardCoins(25, 2), 50);
    expect(rideRewardCoins(25, 0), 0);
  });
}
