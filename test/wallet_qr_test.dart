import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/wallet_qr.dart';
import 'package:get_ride/src/data/wallet_pay_repository.dart';

const id = '3f2b8c1e-1234-4abc-9def-0123456789ab';

void main() {
  group('walletQrPayload', () {
    test('plain and fixed-amount codes', () {
      expect(walletQrPayload(id), 'getpay://u/$id');
      expect(walletQrPayload(id, amount: 12.5), 'getpay://u/$id?amt=12.50');
      expect(walletQrPayload(id, amount: 0), 'getpay://u/$id');
    });
  });

  group('parseWalletQr', () {
    test('a GET account code, with and without an amount', () {
      final plain = parseWalletQr('getpay://u/$id') as GetAccountQr;
      expect(plain.userId, id);
      expect(plain.amount, isNull);
      final fixed = parseWalletQr(' getpay://u/${id.toUpperCase()}?amt=12.345 ') as GetAccountQr;
      expect(fixed.userId, id);
      expect(fixed.amount, 12.35);
    });

    test('a bad amount is dropped, not the account', () {
      for (final amt in ['abc', '-5', '0']) {
        final q = parseWalletQr('getpay://u/$id?amt=$amt') as GetAccountQr;
        expect(q.amount, isNull, reason: amt);
      }
    });

    test('anything else is a merchant code, a broken GET code included', () {
      expect(parseWalletQr('getpay://u/guest'), isA<MerchantQr>());
      final m = parseWalletQr('00020101021126580014A000000615000101068900360216${'9' * 20}') as MerchantQr;
      expect(m.label.length, 43);
      expect(m.label.endsWith('…'), isTrue);
      expect(parseWalletQr('   '), isNull);
    });
  });

  test('account digits match the Expo derivation', () {
    // Values from Expo's deriveDigits (Math.imul) for the same inputs.
    expect(deriveWalletDigits(id, 16), '6365054943672741');
    expect(deriveWalletDigits('guest', 18), '836907654507836565');
    expect(walletAccountNumber(id), '26006365054943672741');
  });

  group('computeCoinSplit', () {
    test('coins cover part of the amount', () {
      final s = computeCoinSplit(10, 250, 100);
      expect(s.coinValue, 2.5);
      expect(s.coinsUsed, 250);
      expect(s.walletShare, 7.5);
    });

    test('coins cover all of it', () {
      final s = computeCoinSplit(3.3, 1000, 100);
      expect(s.coinValue, 3.3);
      expect(s.coinsUsed, 330);
      expect(s.walletShare, 0);
    });

    test('a coin value is rounded down to the sen', () {
      final s = computeCoinSplit(10, 1.99, 100);
      expect(s.coinValue, 0.01);
      expect(s.coinsUsed, 1);
      expect(s.walletShare, 9.99);
    });

    test('no coins or no rate leaves it all to GET.wallet', () {
      expect(computeCoinSplit(5, 0, 100).walletShare, 5);
      expect(computeCoinSplit(5, 100, 0).coinsUsed, 0);
    });
  });

  group('walletPayProblem', () {
    test('blocks empty, oversized and unaffordable payments', () {
      expect(walletPayProblem(amount: 0, walletBalance: 10), isNotNull);
      expect(walletPayProblem(amount: 100000.01, walletBalance: 1e6), contains('100,000'));
      expect(walletPayProblem(amount: 12, walletBalance: 10), 'Not enough balance in GET.wallet.');
      expect(walletPayProblem(amount: 10, walletBalance: 10), isNull);
    });

    test('only the GET.wallet share needs covering', () {
      final split = computeCoinSplit(12, 500, 100);
      expect(walletPayProblem(amount: 12, walletBalance: 7, split: split), isNull);
    });
  });

  test('walletPayErrorMessage', () {
    expect(walletPayErrorMessage(Exception('insufficient_balance')), 'Not enough balance in GET.wallet.');
    expect(walletPayErrorMessage(Exception('code 42501 not_authorized')), contains('sign in'));
    expect(walletPayErrorMessage(Exception('invalid_amount')), contains('RM100,000'));
    expect(walletPayErrorMessage(Exception('boom')), 'Payment failed. Please try again.');
  });

  test('WalletPayResult.fromRpc', () {
    final r = WalletPayResult.fromRpc({'coins_used': 250, 'coin_value': '2.5', 'wallet_paid': 7.5}, amount: 10);
    expect([r.coinsUsed, r.coinValue, r.walletPaid], [250, 2.5, 7.5]);
    expect(WalletPayResult.fromRpc(null, amount: 4).walletPaid, 4);
  });
}
