/// The full message an admin push opens in the app (Admin -> Push
/// Notification, `push_messages.blocks`, migration 0279): a short list of
/// blocks, never HTML.
///
///     [{"type": "heading",   "spans": [{"text": "Weekend bonus"}]},
///      {"type": "paragraph", "spans": [{"text": "Earn "}, {"text": "RM 30", "bold": true, "color": "green"}]},
///      {"type": "bullets",   "items": [[{"text": "Any service counts"}]]},
///      {"type": "button",    "label": "Go online", "link": "/drive"},
///      {"type": "image",     "url": "https://…/bonus.jpg"}]
///
/// Whatever is read is cleaned first ([decodePushBlocks]): an unknown block
/// type is dropped, a colour is one of [PushColor] or none, and a link is an
/// http(s) address or an in-app route ("/wallet"), or none.
///
/// The admin writes it as light markup ([parsePushMarkup] / [pushMarkup]),
/// which the composer's toolbar types for them:
///
///     # Heading
///     A paragraph with **bold**, _italic_, {green:colour} and [a link](/wallet).
///     - a bullet
///     [[Button label]](https://example.com)
///     ![](https://…/picture.jpg)
///
/// Pure.
library;

/// The colours a message may use. Stored by name, drawn per theme.
enum PushColor { red, orange, green, blue, purple, grey }

PushColor? pushColorFrom(Object? raw) {
  final v = '${raw ?? ''}'.trim().toLowerCase();
  for (final c in PushColor.values) {
    if (c.name == v) return c;
  }
  return null;
}

/// The colour as ARGB: deep on a light page, light on a dark one, so the
/// text keeps its contrast in both.
int pushColorValue(PushColor c, {required bool dark}) => switch (c) {
  PushColor.red => dark ? 0xFFF2B8B5 : 0xFFB3261E,
  PushColor.orange => dark ? 0xFFFFB870 : 0xFFA35200,
  PushColor.green => dark ? 0xFF7DD6A0 : 0xFF1F7A45,
  PushColor.blue => dark ? 0xFF8CCBF2 : 0xFF0C6BA8,
  PushColor.purple => dark ? 0xFFCDB6F5 : 0xFF6A3FB5,
  PushColor.grey => dark ? 0xFFB4C0CC : 0xFF5D6B7B,
};

String pushColorLabel(PushColor c) => switch (c) {
  PushColor.red => 'Red',
  PushColor.orange => 'Orange',
  PushColor.green => 'Green',
  PushColor.blue => 'Blue',
  PushColor.purple => 'Purple',
  PushColor.grey => 'Grey',
};

/// An in-app route: one path from the app's root ("/wallet",
/// "/drive/scheduled?tab=mine"), never another site ("//x").
bool isInAppPushRoute(String link) => RegExp(r'^/(?!/)[A-Za-z0-9\-._~/?=&%#+:]*$').hasMatch(link);

/// Whether a message may link to [link]: an http(s) address or an in-app route.
bool isSafePushLink(String? link) {
  final l = (link ?? '').trim();
  if (l.isEmpty || l.length > 1000 || RegExp(r'\s').hasMatch(l)) return false;
  if (isInAppPushRoute(l)) return true;
  final u = Uri.tryParse(l);
  return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;
}

/// A picture's address as a message keeps it: https only, else null.
String? safePushImageUrl(Object? raw) {
  final v = '${raw ?? ''}'.trim();
  if (v.isEmpty || v.length > 1000 || RegExp(r'\s').hasMatch(v)) return null;
  final u = Uri.tryParse(v);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty ? v : null;
}

const _maxSpanText = 2000;
const _maxSpans = 100;
const _maxItems = 30;
const _maxBlocks = 60;
const _maxLabel = 60;

/// A run of text in one style.
class PushSpan {
  const PushSpan(this.text, {this.bold = false, this.italic = false, this.color, this.link});

  final String text;
  final bool bold;
  final bool italic;
  final PushColor? color;

  /// An http(s) address or an in-app route ([isSafePushLink]).
  final String? link;

  bool sameStyle(PushSpan o) => o.bold == bold && o.italic == italic && o.color == color && o.link == link;

  Map<String, dynamic> toJson() => {
    'text': text,
    if (bold) 'bold': true,
    if (italic) 'italic': true,
    if (color != null) 'color': color!.name,
    if (link != null) 'link': link,
  };

  /// Null for anything that is not a span with text.
  static PushSpan? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.isEmpty) return null;
    final link = raw['link'] is String ? (raw['link'] as String).trim() : null;
    return PushSpan(
      text.length > _maxSpanText ? text.substring(0, _maxSpanText) : text,
      bold: raw['bold'] == true,
      italic: raw['italic'] == true,
      color: pushColorFrom(raw['color']),
      link: isSafePushLink(link) ? link : null,
    );
  }

  @override
  bool operator ==(Object other) => other is PushSpan && other.text == text && sameStyle(other);

  @override
  int get hashCode => Object.hash(text, bold, italic, color, link);

  @override
  String toString() => 'PushSpan(${toJson()})';
}

enum PushBlockType { heading, paragraph, bullets, button, image }

/// One block of a message.
class PushBlock {
  const PushBlock._(this.type, {this.spans = const [], this.items = const [], this.label = '', this.link, this.url});

  const PushBlock.heading(List<PushSpan> spans) : this._(PushBlockType.heading, spans: spans);
  const PushBlock.paragraph(List<PushSpan> spans) : this._(PushBlockType.paragraph, spans: spans);
  const PushBlock.bullets(List<List<PushSpan>> items) : this._(PushBlockType.bullets, items: items);
  const PushBlock.button(String label, String link) : this._(PushBlockType.button, label: label, link: link);
  const PushBlock.image(String url) : this._(PushBlockType.image, url: url);

  final PushBlockType type;

  /// A heading's or a paragraph's text.
  final List<PushSpan> spans;

  /// A bullet list's items.
  final List<List<PushSpan>> items;

  /// A button's label and where it goes.
  final String label;
  final String? link;

  /// A picture's address.
  final String? url;

  Map<String, dynamic> toJson() => switch (type) {
    PushBlockType.heading || PushBlockType.paragraph => {
      'type': type.name,
      'spans': [for (final s in spans) s.toJson()],
    },
    PushBlockType.bullets => {
      'type': 'bullets',
      'items': [
        for (final i in items) [for (final s in i) s.toJson()],
      ],
    },
    PushBlockType.button => {'type': 'button', 'label': label, 'link': link},
    PushBlockType.image => {'type': 'image', 'url': url},
  };

  @override
  bool operator ==(Object other) =>
      other is PushBlock &&
      other.type == type &&
      _sameSpans(other.spans, spans) &&
      other.items.length == items.length &&
      [for (var i = 0; i < items.length; i++) _sameSpans(other.items[i], items[i])].every((b) => b) &&
      other.label == label &&
      other.link == link &&
      other.url == url;

  @override
  int get hashCode => Object.hash(type, Object.hashAll(spans), items.length, label, link, url);

  @override
  String toString() => 'PushBlock(${toJson()})';
}

bool _sameSpans(List<PushSpan> a, List<PushSpan> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [spans] cleaned: neighbours in the same style joined, at most [_maxSpans].
List<PushSpan> _tidy(Iterable<PushSpan> spans) {
  final out = <PushSpan>[];
  for (final s in spans) {
    if (s.text.isEmpty) continue;
    if (out.isNotEmpty && out.last.sameStyle(s)) {
      final last = out.removeLast();
      out.add(PushSpan(last.text + s.text, bold: s.bold, italic: s.italic, color: s.color, link: s.link));
    } else {
      out.add(s);
    }
  }
  return out.length > _maxSpans ? out.sublist(0, _maxSpans) : out;
}

bool _hasText(List<PushSpan> spans) => spans.any((s) => s.text.trim().isNotEmpty);

List<PushSpan> _spansFrom(Object? raw) => raw is List ? _tidy(raw.map(PushSpan.fromJson).whereType<PushSpan>()) : const [];

/// The blocks in [raw] (the stored list, or its JSON text's decoded form),
/// cleaned: what is not a known block, or has nothing to show, is dropped.
List<PushBlock> decodePushBlocks(Object? raw) {
  if (raw is! List) return const [];
  final out = <PushBlock>[];
  for (final b in raw) {
    if (out.length >= _maxBlocks) break;
    if (b is! Map) continue;
    switch (b['type']) {
      case 'heading':
      case 'paragraph':
        final spans = _spansFrom(b['spans']);
        if (!_hasText(spans)) continue;
        out.add(b['type'] == 'heading' ? PushBlock.heading(spans) : PushBlock.paragraph(spans));
      case 'bullets':
        final items = b['items'] is List
            ? [
                for (final i in (b['items'] as List).take(_maxItems))
                  if (_hasText(_spansFrom(i))) _spansFrom(i),
              ]
            : const <List<PushSpan>>[];
        if (items.isEmpty) continue;
        out.add(PushBlock.bullets(items));
      case 'button':
        final label = '${b['label'] ?? ''}'.trim();
        final link = '${b['link'] ?? ''}'.trim();
        if (label.isEmpty || !isSafePushLink(link)) continue;
        out.add(PushBlock.button(label.length > _maxLabel ? label.substring(0, _maxLabel) : label, link));
      case 'image':
        final url = safePushImageUrl(b['url']);
        if (url == null) continue;
        out.add(PushBlock.image(url));
      default:
        continue;
    }
  }
  return out;
}

/// The list to store.
List<Map<String, dynamic>> encodePushBlocks(List<PushBlock> blocks) => [for (final b in blocks) b.toJson()];

/// The words of a message, for a search or a summary.
String pushBlocksText(List<PushBlock> blocks) => [
  for (final b in blocks)
    switch (b.type) {
      PushBlockType.heading || PushBlockType.paragraph => b.spans.map((s) => s.text).join(),
      PushBlockType.bullets => b.items.map((i) => i.map((s) => s.text).join()).join('\n'),
      PushBlockType.button => b.label,
      PushBlockType.image => '',
    },
].where((t) => t.isNotEmpty).join('\n');

// ---- The admin's markup -------------------------------------------------------------------------

const _escapable = r'\*_[]{}';

String _escape(String t) {
  final b = StringBuffer();
  for (final ch in t.split('')) {
    if (_escapable.contains(ch)) b.write(r'\');
    b.write(ch);
  }
  return b.toString();
}

/// One span as markup: colour outside, then the link, bold, italic.
String _spanMarkup(PushSpan s) {
  var t = _escape(s.text);
  if (s.italic) t = '_${t}_';
  if (s.bold) t = '**$t**';
  if (s.link != null) t = '[$t](${s.link})';
  if (s.color != null) t = '{${s.color!.name}:$t}';
  return t;
}

String _spansMarkup(List<PushSpan> spans) => spans.map(_spanMarkup).join();

/// [blocks] as the admin edits them ([parsePushMarkup] reads it back).
String pushMarkup(List<PushBlock> blocks) => [
  for (final b in blocks)
    switch (b.type) {
      PushBlockType.heading => '# ${_spansMarkup(b.spans).replaceAll('\n', ' ')}',
      PushBlockType.paragraph => _spansMarkup(b.spans),
      PushBlockType.bullets => b.items.map((i) => '- ${_spansMarkup(i).replaceAll('\n', ' ')}').join('\n'),
      PushBlockType.button => '[[${b.label.replaceAll(']]', '] ]')}]](${b.link})',
      PushBlockType.image => '![](${b.url})',
    },
].join('\n\n');

/// The style the inline parser is in.
class _Style {
  const _Style({this.bold = false, this.italic = false, this.color, this.link});
  final bool bold;
  final bool italic;
  final PushColor? color;
  final String? link;

  _Style copy({bool? bold, bool? italic, PushColor? color, String? link}) => _Style(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    color: color ?? this.color,
    link: link ?? this.link,
  );

  PushSpan span(String text) => PushSpan(text, bold: bold, italic: italic, color: color, link: link);
}

/// Where [token] next starts in [s] from [from], past escaped characters;
/// -1 when it does not.
int _find(String s, String token, int from) {
  var i = from;
  while (i < s.length) {
    if (s[i] == r'\' && i + 1 < s.length) {
      i += 2;
      continue;
    }
    if (s.startsWith(token, i)) return i;
    i++;
  }
  return -1;
}

final _colorOpen = RegExp(r'\{([a-z]+):');

List<PushSpan> _inline(String s, _Style st) {
  final out = <PushSpan>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      out.add(st.span(buf.toString()));
      buf.clear();
    }
  }

  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length && _escapable.contains(s[i + 1])) {
      buf.write(s[i + 1]);
      i += 2;
      continue;
    }
    if (s.startsWith('**', i)) {
      final end = _find(s, '**', i + 2);
      if (end > i + 2) {
        flush();
        out.addAll(_inline(s.substring(i + 2, end), st.copy(bold: true)));
        i = end + 2;
        continue;
      }
    } else if (c == '_') {
      final end = _find(s, '_', i + 1);
      if (end > i + 1) {
        flush();
        out.addAll(_inline(s.substring(i + 1, end), st.copy(italic: true)));
        i = end + 1;
        continue;
      }
    } else if (c == '[') {
      final close = _find(s, '](', i + 1);
      if (close > i + 1) {
        final end = s.indexOf(')', close + 2);
        if (end > close + 2) {
          final link = s.substring(close + 2, end).trim();
          flush();
          out.addAll(_inline(s.substring(i + 1, close), isSafePushLink(link) ? st.copy(link: link) : st));
          i = end + 1;
          continue;
        }
      }
    } else if (c == '{') {
      final m = _colorOpen.matchAsPrefix(s, i);
      final color = m == null ? null : pushColorFrom(m[1]);
      if (m != null && color != null) {
        final end = _find(s, '}', m.end);
        if (end > m.end) {
          flush();
          out.addAll(_inline(s.substring(m.end, end), st.copy(color: color)));
          i = end + 1;
          continue;
        }
      }
    }
    buf.write(c);
    i++;
  }
  flush();
  return out;
}

/// The text of one line or paragraph as spans.
List<PushSpan> parsePushInline(String s) => _tidy(_inline(s, const _Style()));

final _headingLine = RegExp(r'^#{1,3}\s+(.*)$');
final _bulletLine = RegExp(r'^\s*[-•]\s+(.*)$');
final _buttonLine = RegExp(r'^\[\[(.+?)\]\]\((\S+)\)$');
final _imageLine = RegExp(r'^!\[[^\]]*\]\((\S+)\)$');

/// The admin's markup as blocks, cleaned as [decodePushBlocks] cleans them.
List<PushBlock> parsePushMarkup(String markup) {
  final blocks = <PushBlock>[];
  final para = <String>[];
  final bullets = <List<PushSpan>>[];

  void endParagraph() {
    if (para.isNotEmpty) {
      blocks.add(PushBlock.paragraph(parsePushInline(para.join('\n'))));
      para.clear();
    }
  }

  void endBullets() {
    if (bullets.isNotEmpty) {
      blocks.add(PushBlock.bullets(List.of(bullets)));
      bullets.clear();
    }
  }

  for (final raw in markup.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trimRight();
    final bullet = _bulletLine.firstMatch(line);
    if (bullet != null) {
      endParagraph();
      bullets.add(parsePushInline(bullet[1]!));
      continue;
    }
    endBullets();
    if (line.trim().isEmpty) {
      endParagraph();
      continue;
    }
    final heading = _headingLine.firstMatch(line.trim());
    final button = _buttonLine.firstMatch(line.trim());
    final image = _imageLine.firstMatch(line.trim());
    if (heading != null || button != null || image != null) {
      endParagraph();
      if (heading != null) blocks.add(PushBlock.heading(parsePushInline(heading[1]!)));
      if (button != null) blocks.add(PushBlock.button(button[1]!.trim(), button[2]!));
      if (image != null) blocks.add(PushBlock.image(image[1]!));
      continue;
    }
    para.add(line);
  }
  endBullets();
  endParagraph();
  return decodePushBlocks(encodePushBlocks(blocks));
}
