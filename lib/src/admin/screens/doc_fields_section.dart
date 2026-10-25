// Admin > Documents > a document (document reading, part 2): every field
// printed on it, as the AI check read it, beside what GET.ride has on file,
// with a match, something to check, or a mismatch. Which fields depends on
// what the Required Document is read as (Admin > Required Documents).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/doc_kinds.dart';
import 'catalogue/catalogue_data.dart' show catalogueEntriesProvider, requiredDocumentsCategory;

/// What each Required Document (by id) is read as.
final requiredDocKindsProvider = FutureProvider.autoDispose<Map<String, DocKind?>>((ref) async {
  try {
    final entries = await ref.watch(catalogueEntriesProvider(requiredDocumentsCategory).future);
    return {for (final e in entries) e.id: docKindFor(e.values)};
  } catch (_) {
    return const {};
  }
});

/// The kind [doc] is read as: its Required Document's, else a guess from its name.
DocKind? docKindOfUpload(Map<String, dynamic> doc, Map<String, DocKind?> kinds) {
  final id = '${doc['doc_id'] ?? ''}';
  if (kinds.containsKey(id)) return kinds[id];
  return guessDocKind('${doc['doc_name'] ?? ''}');
}

/// The fields the AI read off [doc] (`ai_verification.extracted.permitFields`).
Map<String, dynamic> docFieldsByAi(Map<String, dynamic> doc) {
  final ai = doc['ai_verification'];
  final ex = ai is Map ? ai['extracted'] : null;
  final f = ex is Map ? ex['permitFields'] : null;
  return f is Map ? Map<String, dynamic>.from(f) : const {};
}

/// The fields as the partner confirmed them at upload (`read_fields`, 0294),
/// else as the AI read them.
Map<String, dynamic> docFieldsRead(Map<String, dynamic> doc) {
  final rf = doc['read_fields'];
  final f = rf is Map ? rf['fields'] : null;
  return f is Map && f.isNotEmpty ? Map<String, dynamic>.from(f) : docFieldsByAi(doc);
}

/// The fields the partner changed from what was read.
Set<String> docFieldsChanged(Map<String, dynamic> doc) {
  final rf = doc['read_fields'];
  final c = rf is Map ? rf['changed'] : null;
  return c is List ? {for (final k in c) '$k'} : const {};
}

/// The photo check at upload, in words; null when there was none.
String? docPhotoCheckText(Map<String, dynamic> doc) {
  final rf = doc['read_fields'];
  final p = rf is Map ? rf['photo'] : null;
  if (p is! Map) return null;
  final bad = [
    if (p['sharp'] == false) 'blurred',
    if (p['glare'] == true) 'glare',
    if (p['corners'] == false) 'an edge cut off',
  ];
  return bad.isEmpty ? 'Photo check: sharp, no glare, all four corners.' : 'Photo check: ${bad.join(', ')}.';
}

class DocFieldsSection extends ConsumerWidget {
  const DocFieldsSection({super.key, required this.doc, this.today});
  final Map<String, dynamic> doc;

  /// For tests; else now.
  final DateTime? today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kinds = ref.watch(requiredDocKindsProvider).value ?? const <String, DocKind?>{};
    final kind = docKindOfUpload(doc, kinds);
    if (kind == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final read = docFieldsRead(doc);
    final byAi = docFieldsByAi(doc);
    final changed = docFieldsChanged(doc);
    final photo = docPhotoCheckText(doc);
    final onFile = doc['_onFile'] is DocOnFile ? doc['_onFile'] as DocOnFile : const DocOnFile();
    final rows = checkDocFields(kind, read, onFile, today: today ?? DateTime.now());
    return Padding(
      key: const ValueKey('doc-fields'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Read as ${kind.name}', style: t.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          read.isEmpty
              ? 'No fields read yet. They are read when a photo is uploaded.'
              : docFieldsSummary(rows),
          key: const ValueKey('doc-fields-summary'),
          style: t.textTheme.bodySmall,
        ),
        if (photo != null) Text(photo, key: const ValueKey('doc-photo-check'), style: t.textTheme.bodySmall),
        if (read.isNotEmpty) ...[
          const SizedBox(height: 6),
          Table(
            columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(3), 2: FlexColumnWidth(3), 3: FixedColumnWidth(28)},
            defaultVerticalAlignment: TableCellVerticalAlignment.top,
            children: [
              TableRow(children: [
                for (final h in ['Field', 'Read', 'On file', ''])
                  Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(h, style: t.textTheme.labelSmall)),
              ]),
              for (final r in rows)
                TableRow(
                  key: ValueKey('doc-field-${r.field.key}'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(r.field.label, style: t.textTheme.bodySmall),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SelectableText(r.read ?? '–', style: t.textTheme.bodySmall),
                        if (changed.contains(r.field.key))
                          Text(
                            'Changed by the partner (read as ${'${byAi[r.field.key] ?? ''}'.trim().isEmpty ? 'nothing' : byAi[r.field.key]})',
                            key: ValueKey('doc-field-changed-${r.field.key}'),
                            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.tertiary),
                          ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(r.onFile ?? '', style: t.textTheme.bodySmall),
                        if (r.note != null && r.verdict != FieldVerdict.match && r.verdict != FieldVerdict.none)
                          Text(r.note!, style: t.textTheme.bodySmall?.copyWith(color: _color(t, r.verdict))),
                      ]),
                    ),
                    Padding(padding: const EdgeInsets.only(top: 2), child: _mark(t, r.verdict)),
                  ],
                ),
            ],
          ),
        ],
        if (kind.notKept.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Never read or kept: ${kind.notKept.join(', ')}.', style: t.textTheme.bodySmall),
          ),
      ]),
    );
  }

  static Color? _color(ThemeData t, FieldVerdict v) => switch (v) {
        FieldVerdict.match => t.colorScheme.primary,
        FieldVerdict.check => t.colorScheme.tertiary,
        FieldVerdict.mismatch => t.colorScheme.error,
        FieldVerdict.none => null,
      };

  static Widget _mark(ThemeData t, FieldVerdict v) => switch (v) {
        FieldVerdict.match => Icon(Icons.check_circle, size: 18, color: _color(t, v), semanticLabel: 'Matches'),
        FieldVerdict.check => Icon(Icons.error_outline, size: 18, color: _color(t, v), semanticLabel: 'Check this'),
        FieldVerdict.mismatch => Icon(Icons.cancel, size: 18, color: _color(t, v), semanticLabel: "Doesn't match"),
        FieldVerdict.none => const SizedBox.shrink(),
      };
}

/// What the office NAS read off a document (0295), side by side: plates and
/// numbers, each marked when it matches what is on file, and how sure it was.
class NasReadingSection extends StatelessWidget {
  const NasReadingSection({super.key, required this.doc});
  final Map<String, dynamic> doc;

  @override
  Widget build(BuildContext context) {
    final rows = doc['_nas'] is List ? (doc['_nas'] as List).whereType<Map>().toList() : const <Map>[];
    if (rows.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final onFile = doc['_onFile'] is DocOnFile ? doc['_onFile'] as DocOnFile : const DocOnFile();
    final known = {
      for (final v in [onFile.plate, onFile.chassis, onFile.engine, onFile.ic]) ?nasKey(v),
    };
    return Padding(
      key: const ValueKey('doc-nas'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Read by ${rows.first['reader_label'] ?? 'the office NAS'}', style: t.textTheme.titleSmall),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${'${r['side']}' == 'back' ? 'Back' : 'Front'}: ${nasReadingStatus(r)}', style: t.textTheme.bodySmall),
              for (final v in nasValues(r))
                Chip(
                  key: ValueKey('doc-nas-${nasKey(v)}'),
                  visualDensity: VisualDensity.compact,
                  avatar: known.contains(nasKey(v))
                      ? Icon(Icons.check_circle, size: 16, color: t.colorScheme.primary, semanticLabel: 'Matches the record')
                      : null,
                  label: Text(v),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// Plates, then numbers, then QR codes, as the NAS read them.
List<String> nasValues(Map r) {
  final res = r['result'] is Map ? r['result'] as Map : const {};
  return [
    for (final k in ['plates', 'numbers', 'qr'])
      if (res[k] is List)
        for (final v in res[k] as List)
          if ('$v'.trim().isNotEmpty) '$v'.trim(),
  ];
}

/// How a reading compares: letters and digits only, upper case.
String? nasKey(String? s) {
  final k = (s ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return k.isEmpty ? null : k;
}

/// "97% sure, 1.2 s" / "passed on (40% sure)" / "couldn't read it".
String nasReadingStatus(Map r) {
  final c = r['confidence'] is num ? (r['confidence'] as num).round() : null;
  final ms = r['ms'] is num ? (r['ms'] as num).toInt() : null;
  return switch ('${r['status']}') {
    'passed_on' => 'passed on to the next reader${c == null ? '' : ' ($c% sure)'}',
    'failed' => "couldn't read it",
    _ => [if (c != null) '$c% sure', if (ms != null) '${(ms / 1000).toStringAsFixed(1)} s'].join(', '),
  };
}
