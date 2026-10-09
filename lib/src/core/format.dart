import 'package:intl/intl.dart';

/// How an ISO 4217 currency is written: its symbol, which side of the
/// amount it goes, and how many minor digits it shows. The symbols are
/// Expo's (`constants/currency.ts`), so both apps print the same amount the
/// same way.
typedef CurrencyStyle = ({String symbol, bool after, int decimals});

const currencyStyles = <String, CurrencyStyle>{
  'MYR': (symbol: 'RM', after: false, decimals: 2),
  'SGD': (symbol: r'S$', after: false, decimals: 2),
  'IDR': (symbol: 'Rp', after: false, decimals: 2),
  'THB': (symbol: '฿', after: false, decimals: 2),
  'PHP': (symbol: '₱', after: false, decimals: 2),
  'VND': (symbol: '₫', after: true, decimals: 0),
  'INR': (symbol: '₹', after: false, decimals: 2),
  'USD': (symbol: r'$', after: false, decimals: 2),
  'GBP': (symbol: '£', after: false, decimals: 2),
  'EUR': (symbol: '€', after: false, decimals: 2),
  'JPY': (symbol: '¥', after: false, decimals: 0),
  'KRW': (symbol: '₩', after: false, decimals: 0),
  'AUD': (symbol: r'A$', after: false, decimals: 2),
  'AED': (symbol: 'AED ', after: false, decimals: 2),
  'SAR': (symbol: 'SAR ', after: false, decimals: 2),
  'PKR': (symbol: 'Rs', after: false, decimals: 2),
  'BDT': (symbol: '৳', after: false, decimals: 2),
  'LKR': (symbol: 'Rs', after: false, decimals: 2),
  'MMK': (symbol: 'K', after: true, decimals: 2),
  'KHR': (symbol: '៛', after: true, decimals: 2),
  'LAK': (symbol: '₭', after: false, decimals: 2),
  'BND': (symbol: r'B$', after: false, decimals: 2),
  'CNY': (symbol: '¥', after: false, decimals: 2),
  'TWD': (symbol: r'NT$', after: false, decimals: 2),
  'HKD': (symbol: r'HK$', after: false, decimals: 2),
};

/// The symbols the admin gives currencies (Admin → Country / States /
/// Cities → Country information), by code. They win over [currencyStyles]'
/// own, and give a currency missing from it its symbol.
final Map<String, String> _regionSymbols = {};

/// Replaces the admin-set currency symbols (code → symbol).
void setRegionCurrencySymbols(Map<String, String> symbols) {
  _regionSymbols
    ..clear()
    ..addAll({
      for (final e in symbols.entries)
        if (e.key.trim().isNotEmpty && e.value.trim().isNotEmpty) e.key.trim().toUpperCase(): e.value.trim(),
    });
}

/// [amount] in [currency] (an ISO 4217 code, as stored on a ride). An
/// unknown code is printed as itself rather than passed off as ringgit.
String formatMoney(num? amount, [String currency = 'MYR', int? decimals]) {
  if (amount == null) return '—';
  final code = currency.trim().toUpperCase();
  final known = currencyStyles[code];
  final admin = _regionSymbols[code];
  final style = admin == null
      ? known
      : (symbol: admin, after: known?.after ?? false, decimals: known?.decimals ?? 2);
  // [decimals] narrows a currency's own (a region with whole fares).
  int places(int own) => decimals == null ? own : (decimals < own ? decimals : own);
  if (style == null) return NumberFormat.currency(symbol: '$code ', decimalDigits: places(2)).format(amount);
  if (!style.after) {
    return NumberFormat.currency(symbol: style.symbol, decimalDigits: places(style.decimals)).format(amount);
  }
  return '${NumberFormat.currency(symbol: '', decimalDigits: places(style.decimals)).format(amount)}${style.symbol}';
}

String formatDateTime(DateTime? dt) =>
    dt == null ? '—' : DateFormat('d MMM yyyy, h:mm a').format(dt.toLocal());

String formatTime(DateTime? dt) =>
    dt == null ? '' : DateFormat('h:mm a').format(dt.toLocal());

String formatDistance(num? km) =>
    km == null ? '—' : (km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(1)} km');

String formatDuration(num? min) {
  if (min == null) return '—';
  final m = min.round();
  return m < 60 ? '$m min' : '${m ~/ 60} h ${m % 60} min';
}
