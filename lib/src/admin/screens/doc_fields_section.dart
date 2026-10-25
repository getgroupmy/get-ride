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
Map<String, dynamic> docFieldsRead(Map<String, dynamic> doc) {
  final ai = doc['ai_verification'];
  final ex = ai is Map ? ai['extracted'] : null;
  final f = ex is Map ? ex['permitFields'] : null;
  return f is Map ? Map<String, dynamic>.from(f) : const {};
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
                      child: SelectableText(r.read ?? '–', style: t.textTheme.bodySmall),
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
