// Checks that every piece of text under a finder reads (WCAG 4.5:1) on what
// is actually painted behind it: the nearest opaque Material, ColoredBox or
// box decoration above it, else the page. Disabled (translucent) text and
// text over an image are left out.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/common.dart' show contrastRatio;

Color? _groundOf(Element e) {
  Color? found;
  e.visitAncestorElements((a) {
    final w = a.widget;
    Color? c;
    if (w is Material && w.type != MaterialType.transparency) c = w.color;
    if (w is ColoredBox) c = w.color;
    if (w is DecoratedBox && w.decoration is BoxDecoration) {
      final d = w.decoration as BoxDecoration;
      if (d.image != null) {
        found = Colors.transparent; // over an image: not judged here
        return false;
      }
      c = d.color;
    }
    if (w is Scaffold) c = w.backgroundColor ?? Theme.of(a).scaffoldBackgroundColor;
    if (c != null && c.a == 1) {
      found = c;
      return false;
    }
    return true;
  });
  return found;
}

/// The texts under [scope] that fail, as "text: ratio on colour".
List<String> unreadableTexts(WidgetTester tester, Finder scope, {double min = 4.5}) {
  final out = <String>[];
  final texts = find.descendant(of: scope, matching: find.byType(RichText));
  for (final e in texts.evaluate()) {
    final p = e.renderObject as RenderParagraph;
    if (!p.attached || p.size.isEmpty) continue;
    final color = p.text.style?.color;
    final words = p.text.toPlainText().trim();
    if (color == null || color.a < 1 || words.isEmpty) continue;
    // Icon fonts draw glyphs, not words.
    if (p.text.style?.fontFamily == 'MaterialIcons') continue;
    final ground = _groundOf(e);
    if (ground == null || ground.a < 1) continue;
    final r = contrastRatio(color, ground);
    if (r < min) out.add('"$words": ${r.toStringAsFixed(2)} on $ground');
  }
  return out;
}
