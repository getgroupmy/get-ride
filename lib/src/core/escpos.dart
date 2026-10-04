// ESC/POS receipt rendering for mini thermal printers, ported from the Expo
// app's `utils/printer/escpos.ts`.
//
// A mini Bluetooth / Wi-Fi receipt printer has no driver: the app builds the
// byte stream itself. The document is a String on purpose — every character
// is ≤ 0x7F (the control codes used all live in 0x00–0x1F and the text is
// folded to ASCII, a mini printer's default code page), so it travels down
// any transport unchanged and is directly assertable in a test.
//
// The content comes from `meterReceiptLines` / `meterReceiptFooterNote`, the
// same lines the on-screen receipt shows, so paper and phone can never print
// different totals.

import 'meter_trip.dart';

const _esc = '\x1B';
const _gs = '\x1D';

/// Resets the printer, clearing any leftover styling.
const escposInit = '$_esc@';
const _alignLeft = '${_esc}a\x00';
const _alignCenter = '${_esc}a\x01';
const _boldOn = '${_esc}E\x01';
const _boldOff = '${_esc}E\x00';

/// `GS ! n`: low nibble height, high nibble width.
const _sizeNormal = '$_gs!\x00';
const _sizeDouble = '$_gs!\x11';

/// `GS V 0`, a full cut. Harmless on the many printers with no cutter.
const _cut = '${_gs}V\x00';

String _feed(int n) => '${_esc}d${String.fromCharCode(n.clamp(0, 255))}';

/// The two roll widths a mini printer takes, and the characters a line holds
/// at Font A.
enum PaperWidth {
  mm58('58mm', 32),
  mm80('80mm', 48);

  const PaperWidth(this.label, this.columns);
  final String label;
  final int columns;

  static PaperWidth parse(Object? raw) => values.firstWhere((w) => w.label == raw, orElse: () => mm58);
}

const _fold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', //
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', //
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', //
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', //
  'ñ': 'n', 'ç': 'c', //
  'À': 'A', 'Á': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A', //
  'È': 'E', 'É': 'E', 'Ê': 'E', 'Ë': 'E', //
  'Ì': 'I', 'Í': 'I', 'Î': 'I', 'Ï': 'I', //
  'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O', //
  'Ù': 'U', 'Ú': 'U', 'Û': 'U', 'Ü': 'U', //
  'Ñ': 'N', 'Ç': 'C', //
  '’': "'", '‘': "'", '“': '"', '”': '"', '–': '-', '—': '-', '·': '-', //
};

/// Folds text to printable ASCII. Common accents lose their mark; anything
/// else the printer cannot draw (an emoji, CJK) becomes '?', which is clearer
/// than a box of mojibake.
String asciiFold(String input) {
  final out = StringBuffer();
  for (final ch in input.runes.map(String.fromCharCode)) {
    final code = ch.codeUnitAt(0);
    if (ch == '\n') {
      out.write(ch);
    } else if (_fold[ch] case final mapped?) {
      out.write(mapped);
    } else {
      out.write(ch.length == 1 && code >= 0x20 && code <= 0x7E ? ch : '?');
    }
  }
  return out.toString();
}

/// Breaks [text] into lines of at most [cols], on whitespace; a single word
/// wider than the roll is split rather than run off the edge.
List<String> wrapText(String text, int cols) {
  final words = asciiFold(text).split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final lines = <String>[];
  var line = '';
  for (final word in words) {
    if (word.length > cols) {
      if (line.isNotEmpty) lines.add(line);
      line = '';
      for (var i = 0; i < word.length; i += cols) {
        lines.add(word.substring(i, (i + cols).clamp(0, word.length)));
      }
      continue;
    }
    final next = line.isEmpty ? word : '$line $word';
    if (next.length > cols) {
      lines.add(line);
      line = word;
    } else {
      line = next;
    }
  }
  if (line.isNotEmpty) lines.add(line);
  return lines.isEmpty ? [''] : lines;
}

/// Label left, value right. A value that will not fit beside its label drops
/// onto its own right-aligned line(s) beneath it.
String padRow(String label, String value, int cols) {
  final l = asciiFold(label), v = asciiFold(value);
  final gap = cols - l.length - v.length;
  if (gap >= 1) return '$l${' ' * gap}$v\n';
  final wrapped = wrapText(v, cols).map((line) => line.padLeft(cols));
  return '$l\n${wrapped.join('\n')}\n';
}

String _center(String text, int cols) {
  var t = asciiFold(text);
  if (t.length > cols) t = t.substring(0, cols);
  return '${' ' * ((cols - t.length) ~/ 2)}$t\n';
}

String _rule(int cols) => '${'-' * cols}\n';

/// The header of every slip: the title in double size, then optional lines.
void _header(StringBuffer b, int cols, String title, Iterable<String> lines) {
  b
    ..write(escposInit)
    ..write(_alignCenter)
    ..write(_boldOn)
    ..write(_sizeDouble)
    // Double width halves the columns.
    ..write(_center(title, cols ~/ 2))
    ..write(_sizeNormal)
    ..write(_boldOff);
  for (final l in lines) {
    b.write(_center(l, cols));
  }
  b
    ..write(_alignLeft)
    ..write(_rule(cols));
}

void _footer(StringBuffer b, {required int feedLines, required bool cut}) {
  b.write(_feed(feedLines));
  if (cut) b.write(_cut);
  b.write(_alignLeft);
}

/// A completed hire as an ESC/POS document.
String buildMeterReceiptEscpos(
  MeterTrip trip, {
  PaperWidth paper = PaperWidth.mm58,
  String title = 'GET TAXI METER',
  String? subtitle,
  int feedLines = 3,
  bool cut = false,
}) {
  final cols = paper.columns;
  final b = StringBuffer();
  _header(b, cols, title, [
    ?subtitle,
    if (trip.plate != null) 'Vehicle ${trip.plate}',
    if (trip.driver != null) 'Driver ${trip.driver}',
  ]);
  for (final line in meterReceiptLines(trip)) {
    // The total is emphasised so it reads at a glance off the roll.
    b.write(line.strong ? '$_boldOn${padRow(line.label, line.value, cols)}$_boldOff' : padRow(line.label, line.value, cols));
  }
  b
    ..write(_rule(cols))
    ..write(_alignCenter);
  for (final line in wrapText(meterReceiptFooterNote(trip), cols)) {
    b.write('$line\n');
  }
  b.write(_center('Thank you for riding.', cols));
  _footer(b, feedLines: feedLines, cut: cut);
  return b.toString();
}

/// The "Test print" slip, so a printer is known to work before a fare
/// depends on it.
String buildTestPrintEscpos({PaperWidth paper = PaperWidth.mm58, String title = 'GET TAXI METER', int feedLines = 3}) {
  final cols = paper.columns;
  final b = StringBuffer();
  _header(b, cols, title, const ['Printer test']);
  b
    ..write(padRow('Paper', '${paper.label} ($cols cols)', cols))
    ..write(padRow('Status', 'OK', cols))
    ..write(_rule(cols))
    ..write(_alignCenter)
    ..write(_center('If you can read this,', cols))
    ..write(_center('the printer is ready.', cols));
  _footer(b, feedLines: feedLines, cut: false);
  return b.toString();
}
