import 'package:intl/intl.dart';

String formatMoney(num? amount, [String currency = 'MYR']) {
  if (amount == null) return '—';
  final symbol = switch (currency) {
    'MYR' => 'RM',
    'USD' => r'$',
    'SGD' => r'S$',
    'IDR' => 'Rp',
    _ => '$currency ',
  };
  return NumberFormat.currency(symbol: symbol, decimalDigits: 2).format(amount);
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
