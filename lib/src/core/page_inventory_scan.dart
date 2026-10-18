// Finds every page, sheet and modal in the app's code, for App Page Settings
// (see page_styles.dart). Run by `dart run scripts/page_inventory.dart`, which
// writes page_inventory.g.dart, and by a test that fails when that file is
// out of date -- so a new page, sheet or modal is always listed.
//
// - Router pages: every `GoRoute` with a builder, at its full address.
// - Pushed pages: `AppPageRoute(id: '...')`.
// - Sheets: `showAppSheet(id: '...')`; modals: `showAppDialog(id: '...')` and
//   `showAppGeneralDialog(id: '...')`.
import 'page_surfaces.dart';

/// Every surface in [files] (path → Dart source), sorted by id. Pure.
List<SurfaceEntry> scanSurfaces(Map<String, String> files) {
  final out = <String, SurfaceEntry>{};
  final paths = files.keys.toList()..sort();
  for (final path in paths) {
    // Comments mention the helpers too; only code counts.
    final src = files[path]!.split('\n').map((l) => l.trimLeft().startsWith('//') ? '' : l).join('\n');
    for (final r in _routes(src)) {
      final id = 'route:${r.$1}';
      out.putIfAbsent(id, () => SurfaceEntry(id, SurfaceKind.page, r.$2, path, path: r.$1));
    }
    for (final m in _calls.allMatches(src)) {
      final kind = switch (m.group(1)) {
        'AppPageRoute' => SurfaceKind.page,
        'showAppSheet' => SurfaceKind.sheet,
        _ => SurfaceKind.modal,
      };
      final prefix = switch (kind) {
        SurfaceKind.page => 'page',
        SurfaceKind.sheet => 'sheet',
        SurfaceKind.modal => 'modal',
      };
      final id = '$prefix:${m.group(2)}';
      out.putIfAbsent(id, () => SurfaceEntry(id, kind, surfaceTitle(m.group(2)!), path));
    }
  }
  return out.values.toList()..sort((a, b) => a.id.compareTo(b.id));
}

final _calls = RegExp(
  r"\b(AppPageRoute|showAppSheet|showAppDialog|showAppGeneralDialog)\s*(?:<[^(]*>)?\(\s*id:\s*'([^']+)'",
);

/// "confirm.show-payment-sheet" → "Confirm · Payment sheet"; "fare-info" →
/// "Fare info".
String surfaceTitle(String id) {
  String words(String part) {
    final w = part
        .replaceAll('_', '-')
        .replaceFirst(RegExp(r'^(show|open|ask|pick|prompt)-(?=.)'), '')
        .split('-')
        .where((w) => w.isNotEmpty && int.tryParse(w) == null)
        .join(' ');
    return w.isEmpty ? part : w[0].toUpperCase() + w.substring(1);
  }

  final parts = id.split('.');
  return parts.length == 1 ? words(parts.single) : '${words(parts.first)} · ${words(parts.last)}';
}

/// "WalletHistoryScreen" → "Wallet history".
String _classTitle(String c) {
  final base = c.replaceFirst(RegExp(r'(Screen|Page|View)$'), '').replaceFirst(RegExp(r'^_'), '');
  final words = RegExp(r'[A-Z]+(?![a-z])|[A-Z]?[a-z0-9]+').allMatches(base).map((m) => m.group(0)!).toList();
  if (words.isEmpty) return c;
  final s = words.map((w) => w.length > 1 && w == w.toUpperCase() ? w : w.toLowerCase()).join(' ');
  return s[0].toUpperCase() + s.substring(1);
}

/// "/admin/m/fare-tariffs" → "Fare tariffs".
String _pathTitle(String p) {
  final segs = p.split('/').where((s) => s.isNotEmpty && !s.startsWith(':')).toList();
  return segs.isEmpty ? 'Home' : surfaceTitle(segs.last);
}

/// The `GoRoute`s in [src] that build a page: (full address, title).
List<(String, String)> _routes(String src) {
  final spans = <(int, int)>[];
  for (final m in RegExp(r'\bGoRoute\(').allMatches(src)) {
    final open = m.end - 1;
    final close = _matching(src, open);
    if (close > open) spans.add((open, close));
  }
  final out = <(String, String)>[];
  final full = <int, String?>{};
  for (var i = 0; i < spans.length; i++) {
    final (s, e) = spans[i];
    // Its own arguments: nested routes blanked out.
    final own = StringBuffer();
    var at = s + 1;
    for (final (cs, ce) in spans.skip(i + 1)) {
      if (cs < at || cs > e) continue;
      own.write(src.substring(at, cs));
      at = ce + 1;
    }
    if (at < e) own.write(src.substring(at, e));
    final text = own.toString();
    final path = RegExp(r"path:\s*'([^']*)'").firstMatch(text)?.group(1);
    // The nearest route around it.
    String? parent;
    for (var j = i - 1; j >= 0; j--) {
      final (ps, pe) = spans[j];
      if (ps < s && pe > e) {
        parent = full[j];
        break;
      }
    }
    final address = path == null
        ? null
        : path.startsWith('/') || parent == null
        ? path
        : '${parent == '/' ? '' : parent}/$path';
    full[i] = address;
    if (address == null || address.contains(r'$')) continue;
    final builder = RegExp(r'\b(?:builder|pageBuilder):').firstMatch(text);
    if (builder == null) continue;
    final widget = RegExp(r'\b([A-Z]\w*)\(').firstMatch(text.substring(builder.end))?.group(1);
    final useful = widget != null && !const {'MaterialPage', 'NoTransitionPage', 'CustomTransitionPage'}.contains(widget);
    out.add((address, useful ? _classTitle(widget) : _pathTitle(address)));
  }
  return out;
}

/// The index of the bracket closing the one at [open], skipping strings and
/// comments; -1 when unbalanced.
int _matching(String s, int open) {
  var depth = 0;
  var i = open;
  while (i < s.length) {
    final c = s[i];
    if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      final nl = s.indexOf('\n', i);
      i = nl < 0 ? s.length : nl + 1;
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      final end = s.indexOf('*/', i + 2);
      i = end < 0 ? s.length : end + 2;
      continue;
    }
    if (c == "'" || c == '"') {
      final triple = s.startsWith(c * 3, i);
      final q = triple ? c * 3 : c;
      final raw = i > 0 && s[i - 1] == 'r';
      i += q.length;
      while (i < s.length && !s.startsWith(q, i)) {
        if (!raw && s[i] == r'\') i++;
        i++;
      }
      i += q.length;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

/// page_inventory.g.dart for [surfaces].
String inventorySource(List<SurfaceEntry> surfaces) {
  final b = StringBuffer()
    ..writeln('// GENERATED by `dart run scripts/page_inventory.dart` -- do not edit.')
    ..writeln('// Every page, sheet and modal App Page Settings lists (page_inventory_scan.dart).')
    ..writeln("import 'page_surfaces.dart';")
    ..writeln()
    ..writeln('const pageInventory = <SurfaceEntry>[');
  String q(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";
  for (final s in surfaces) {
    final path = s.path == null ? '' : ', path: ${q(s.path!)}';
    b.writeln('  SurfaceEntry(${q(s.id)}, SurfaceKind.${s.kind.name}, ${q(s.title)}, ${q(s.file)}$path),');
  }
  b.writeln('];');
  return b.toString();
}
