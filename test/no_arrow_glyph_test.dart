// "→" (U+2192) is an empty box on some phones' fonts: no string the app
// shows may carry it (code comments may). Routes read "KLCC to KL Sentral",
// menu paths "Settings > Bluetooth".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The single-line string literals on [line], up to a `//` comment.
List<String> _literals(String line) {
  final out = <String>[];
  var i = 0;
  while (i < line.length) {
    if (line.startsWith('//', i)) break;
    final c = line[i];
    if (c == "'" || c == '"') {
      var j = i + 1;
      while (j < line.length && line[j] != c) {
        j += line[j] == r'\' ? 2 : 1;
      }
      out.add(line.substring(i + 1, j.clamp(i + 1, line.length)));
      i = j + 1;
      continue;
    }
    i++;
  }
  return out;
}

void main() {
  test('no "→" in a string under lib/', () {
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var n = 0; n < lines.length; n++) {
        final l = lines[n];
        if (!l.contains('→') || l.trimLeft().startsWith('//')) continue;
        if (_literals(l).any((s) => s.contains('→'))) found.add('${f.path}:${n + 1}');
      }
    }
    expect(found, isEmpty);
  });
}
