// Document reading, part 3: at upload, the fields read off the photo, for
// the partner to check and fix before sending, and the photo check (sharp,
// no glare, all four corners). What they confirm is kept on the document
// (`read_fields`, migration 0294) with the fields they changed, so a
// reviewer sees both.
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/doc_kinds.dart';
import '../../../core/photo_quality.dart';
import '../../../widgets/date_boxes.dart';

/// Checks a photo's bytes; on a background isolate in the app, overridden in tests.
final photoQualityCheckProvider = Provider<Future<PhotoQuality?> Function(Uint8List bytes)>(
  (ref) => (bytes) => compute(checkPhotoBytes, bytes),
);

/// The fields read off one photo, as the partner confirms them.
class DocReadFields {
  DocReadFields(this.kind, Map<String, String?> read)
      : _ai = {
          for (final f in kind.fields)
            if ((read[f.key] ?? '').trim().isNotEmpty) f.key: read[f.key]!.trim(),
        } {
    for (final e in _ai.entries) {
      _controllers[e.key] = TextEditingController(text: _field(e.key)!.date ? _iso(e.value) ?? e.value : e.value);
    }
  }

  final DocKind kind;
  final Map<String, String> _ai;
  final _controllers = <String, TextEditingController>{};

  DocField? _field(String key) => kind.fields.where((f) => f.key == key).firstOrNull;

  /// The read fields, in the kind's order.
  List<DocField> get fields => [for (final f in kind.fields) if (_controllers.containsKey(f.key)) f];

  TextEditingController controller(String key) => _controllers[key]!;

  bool get isEmpty => _controllers.isEmpty;

  Map<String, String> get values => {for (final e in _controllers.entries) e.key: e.value.text.trim()};

  /// The fields the partner changed from what was read.
  List<String> get changed => [
        for (final e in _controllers.entries)
          if (_norm(e.value.text) != _norm(_field(e.key)!.date ? _iso(_ai[e.key]!) ?? _ai[e.key]! : _ai[e.key]!)) e.key,
      ];

  /// The first "valid until" date confirmed (yyyy-mm-dd): the document's
  /// expiry, for reminders, when the form asks for none.
  String? get validUntil {
    for (final f in fields) {
      if (f.check == DocCheck.validUntil) {
        final iso = _iso(_controllers[f.key]!.text);
        if (iso != null) return iso;
      }
    }
    return null;
  }

  /// What a field's value looks like now: expired, ending soon, or not what
  /// that document should say (nothing on file is compared on the phone).
  String? hint(DocField f, DateTime today) {
    final row = checkDocFields(kind, {f.key: _controllers[f.key]?.text}, const DocOnFile(), today: today)
        .firstWhere((r) => r.field.key == f.key);
    return switch (row.verdict) {
      FieldVerdict.mismatch => row.note ?? "This doesn't look right. Check it against the document.",
      FieldVerdict.check => row.note,
      _ => null,
    };
  }

  /// Kept on the document as `read_fields`.
  Map<String, dynamic> toJson({PhotoQuality? photo}) => {
        'kind': kind.id,
        'fields': values,
        'changed': changed,
        'photo': ?photo?.toJson(),
      };

  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
  }

  static String _norm(String s) => s.toUpperCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static String? _iso(String s) {
    final t = s.trim();
    final d = DateTime.tryParse(t);
    if (d != null) return '${d.year.toString().padLeft(4, '0')}-${_pad2(d.month)}-${_pad2(d.day)}';
    final m = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$').firstMatch(t);
    if (m == null) return null;
    return '${m[3]}-${_pad2(int.parse(m[2]!))}-${_pad2(int.parse(m[1]!))}';
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
}

/// The three photo checks as chips, with what to do when one fails.
class PhotoQualityChips extends StatelessWidget {
  const PhotoQualityChips({super.key, required this.quality});
  final PhotoQuality quality;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget chip(String key, String label, bool ok) => Chip(
          key: ValueKey('photo-check-$key'),
          avatar: Icon(ok ? Icons.check_circle : Icons.error_outline,
              size: 18, color: ok ? t.colorScheme.primary : t.colorScheme.tertiary),
          label: Text(label),
          visualDensity: VisualDensity.compact,
        );
    return Padding(
      key: const ValueKey('photo-checks'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 4, children: [
          chip('sharp', quality.sharp ? 'Sharp' : 'Blurred', quality.sharp),
          chip('glare', quality.noGlare ? 'No glare' : 'Glare', quality.noGlare),
          chip('corners', quality.allCorners ? 'All four corners' : 'Edge cut off', quality.allCorners),
        ]),
        if (quality.advice case final a?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(a, key: const ValueKey('photo-advice'), style: t.textTheme.bodySmall),
          ),
      ]),
    );
  }
}

/// "We read these from your photo": each field to check and fix.
class DocReadFieldsForm extends StatefulWidget {
  const DocReadFieldsForm({super.key, required this.fields, this.today});
  final DocReadFields fields;

  /// For tests; else now.
  final DateTime? today;

  @override
  State<DocReadFieldsForm> createState() => _DocReadFieldsFormState();
}

class _DocReadFieldsFormState extends State<DocReadFieldsForm> {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.fields;
    final today = widget.today ?? DateTime.now();
    return Padding(
      key: const ValueKey('doc-read-fields'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('We read these from your photo', style: t.textTheme.titleSmall),
        Text('Check each one and fix anything wrong.', style: t.textTheme.bodySmall),
        for (final f in r.fields) ...[
          const SizedBox(height: 8),
          if (f.date)
            DateBoxesField(
              key: ValueKey('doc-read-${f.key}'),
              label: f.label,
              controller: r.controller(f.key),
              onChanged: (_) => setState(() {}),
            )
          else
            TextField(
              key: ValueKey('doc-read-${f.key}'),
              controller: r.controller(f.key),
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [LengthLimitingTextInputFormatter(200)],
              decoration: InputDecoration(labelText: f.label),
              onChanged: (_) => setState(() {}),
            ),
          if (r.hint(f, today) case final h?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(h, key: ValueKey('doc-read-hint-${f.key}'),
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.tertiary)),
            ),
        ],
      ]),
    );
  }
}
