import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/format.dart';

void main() {
  test('each currency is written with its own symbol, on its own side', () {
    expect(formatMoney(20), 'RM20.00');
    expect(formatMoney(1234.5, 'MYR'), 'RM1,234.50');
    expect(formatMoney(12, 'SGD'), r'S$12.00');
    expect(formatMoney(150, 'THB'), '฿150.00');
    expect(formatMoney(25000, 'VND'), '25,000₫');
    expect(formatMoney(800, 'JPY'), '¥800');
    expect(formatMoney(30, 'AED'), 'AED 30.00');
    expect(formatMoney(-12.5, 'MYR'), '-RM12.50');
  });

  test('a lower-case code still reads; an unknown one prints as itself', () {
    expect(formatMoney(5, 'myr'), 'RM5.00');
    expect(formatMoney(5, 'CHF'), 'CHF 5.00');
    expect(formatMoney(null, 'MYR'), '—');
  });
}
