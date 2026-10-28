// Admin → Partner statements → Layout (migration 0217): how the statement
// PDF looks. Turn each field on or off and rename it in English and Malay,
// move the partner lines and the blocks, pick the font, its sizes and the
// colours, and add, move or remove the logo (drag it on the preview). The
// preview redraws as you go; "Sample PDF" asks the server for the real PDF
// in the layout being edited, before it is saved.
import 'package:flutter/gestures.dart' show EagerGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/partner_statement.dart';
import '../../../core/statement_layout.dart';
import '../../../data/partner_statement_repository.dart';
import '../../../features/partner/statements_screen.dart' show statementPdfOpenerProvider;
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../widgets/admin_widgets.dart';
import '../meterapp/page_settings_screen.dart' show pickStyleColor;
import '../meterapp/pick_image.dart';

/// Asks for a logo file. Overridden in tests.
final statementLogoPickerProvider = Provider<Future<PickedImage?> Function(BuildContext context)>(
  (ref) => (context) => pickImage(context),
);

class StatementLayoutTab extends ConsumerStatefulWidget {
  const StatementLayoutTab({super.key, required this.canEdit, this.companyName = ''});
  final bool canEdit;

  /// From the Settings tab, for the preview.
  final String companyName;

  @override
  ConsumerState<StatementLayoutTab> createState() => _StatementLayoutTabState();
}

class _StatementLayoutTabState extends ConsumerState<StatementLayoutTab> {
  StatementLayout? _stored;
  StatementLayout? _draft;
  String _lang = 'en';
  StatementType _type = StatementType.monthly;
  bool _busy = false;

  void _set(StatementLayout l) => setState(() => _draft = l);

  Future<void> _save() async {
    final d = _draft;
    if (d == null) return;
    setState(() => _busy = true);
    await runAdminAction(context, () async {
      final saved = await ref.read(partnerStatementRepositoryProvider).saveLayout(d);
      if (mounted) setState(() => _stored = _draft = saved);
    }, success: 'Statement layout saved');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _sample() async {
    final d = _draft;
    if (d == null) return;
    setState(() => _busy = true);
    try {
      final pdf = await ref
          .read(partnerStatementRepositoryProvider)
          .sample(d, _type, _lang == 'ms' ? StatementLang.ms : StatementLang.en);
      if (!mounted) return;
      await ref.read(statementPdfOpenerProvider)(context, pdf.bytes, pdf.fileName, 'Sample statement');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadLogo() async {
    final img = await ref.read(statementLogoPickerProvider)(context);
    if (img == null || !mounted) return;
    if (img.ext != 'png' && img.ext != 'jpg') {
      showInfo(context, 'Use a PNG or JPEG logo.');
      return;
    }
    if (img.bytes.length > 2000000) {
      showInfo(context, 'Use a logo under 2 MB.');
      return;
    }
    setState(() => _busy = true);
    try {
      final path = await ref.read(partnerStatementRepositoryProvider).uploadLogo(img.bytes, img.ext);
      if (mounted) _set(_draft!.copyWith(logo: _draft!.logo.copyWith(path: path)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(statementLayoutProvider);
    final fresh = loaded.value;
    if (fresh != null && fresh != _stored) {
      // Saved elsewhere meanwhile: take it unless this admin has changes of their own.
      if (_draft == null || _draft == _stored) _draft = fresh;
      _stored = fresh;
    }
    return AsyncView(
      value: loaded,
      onRetry: () => ref.invalidate(statementLayoutProvider),
      data: (_) {
        final d = _draft!;
        final dirty = d != _stored;
        final repo = ref.read(partnerStatementRepositoryProvider);
        final preview = StatementPreview(
          key: const ValueKey('layout-preview'),
          layout: d,
          lang: _lang,
          type: _type,
          companyName: widget.companyName,
          logoUrl: d.logo.path.isEmpty ? null : repo.logoUrl(d.logo.path),
          onLogoMoved: widget.canEdit
              ? (dx, dy) => _set(d.copyWith(
                    logo: d.logo.copyWith(
                      // Kept whole only when saved, so slow drags (fractions of a point) still move it.
                      dx: (d.logo.dx + dx).clamp(-logoShiftMax, logoShiftMax),
                      dy: (d.logo.dy + dy).clamp(-logoShiftMax, logoShiftMax),
                    ),
                  ))
              : null,
        );
        final bar = _Toolbar(
          lang: _lang,
          type: _type,
          dirty: dirty,
          busy: _busy,
          canEdit: widget.canEdit,
          onLang: (l) => setState(() => _lang = l),
          onType: (t) => setState(() => _type = t),
          onSave: _save,
          onDiscard: () => setState(() => _draft = _stored),
          onReset: () => _set(StatementLayout(logo: StatementLogo(path: d.logo.path))),
          onSample: _sample,
        );
        final editor = _Editor(
          layout: d,
          lang: _lang,
          canEdit: widget.canEdit && !_busy,
          onChanged: _set,
          onUploadLogo: _uploadLogo,
          logoUrl: d.logo.path.isEmpty ? null : repo.logoUrl(d.logo.path),
        );
        return LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth >= 1000) {
              return Column(
                children: [
                  bar,
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 8, 8, 96), child: editor),
                        ),
                        Expanded(
                          flex: 4,
                          child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(8, 8, 16, 24), child: preview),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 96),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  bar,
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: preview),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: editor),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.lang,
    required this.type,
    required this.dirty,
    required this.busy,
    required this.canEdit,
    required this.onLang,
    required this.onType,
    required this.onSave,
    required this.onDiscard,
    required this.onReset,
    required this.onSample,
  });
  final String lang;
  final StatementType type;
  final bool dirty;
  final bool busy;
  final bool canEdit;
  final ValueChanged<String> onLang;
  final ValueChanged<StatementType> onType;
  final VoidCallback onSave;
  final VoidCallback onDiscard;
  final VoidCallback onReset;
  final VoidCallback onSample;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<String>(
            key: const ValueKey('layout-lang'),
            segments: const [
              ButtonSegment(value: 'en', label: Text('English')),
              ButtonSegment(value: 'ms', label: Text('Melayu')),
            ],
            selected: {lang},
            showSelectedIcon: false,
            onSelectionChanged: (v) => onLang(v.first),
          ),
          SegmentedButton<StatementType>(
            key: const ValueKey('layout-type'),
            segments: [for (final t in StatementType.values) ButtonSegment(value: t, label: Text(t.label))],
            selected: {type},
            showSelectedIcon: false,
            onSelectionChanged: (v) => onType(v.first),
          ),
          OutlinedButton.icon(
            key: const ValueKey('layout-sample'),
            onPressed: busy ? null : onSample,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Sample PDF'),
          ),
          if (canEdit) ...[
            TextButton(
              key: const ValueKey('layout-reset'),
              onPressed: busy ? null : onReset,
              child: const Text('Built-in look'),
            ),
            if (dirty) ...[
              TextButton(
                key: const ValueKey('layout-discard'),
                onPressed: busy ? null : onDiscard,
                child: const Text('Discard'),
              ),
              FilledButton.icon(
                key: const ValueKey('layout-save'),
                onPressed: busy ? null : onSave,
                icon: const Icon(Icons.save_outlined),
                label: Text(busy ? 'Saving…' : 'Save layout'),
              ),
            ],
          ],
        ],
      ),
    ),
  );
}

// ---- The editor ---------------------------------------------------------------------------------
class _Editor extends StatelessWidget {
  const _Editor({
    required this.layout,
    required this.lang,
    required this.canEdit,
    required this.onChanged,
    required this.onUploadLogo,
    required this.logoUrl,
  });
  final StatementLayout layout;
  final String lang;
  final bool canEdit;
  final ValueChanged<StatementLayout> onChanged;
  final VoidCallback onUploadLogo;
  final String? logoUrl;

  static const _onlyWhenNotZero = {'handoverIn', 'tips', 'handoverOut', 'adjustments', 'otherCharges', 'otherSurcharges'};

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final l = layout;
    final logo = l.logo;
    Widget card(String key, String title, IconData icon, List<Widget> children, {bool open = false}) => Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: ValueKey(key),
        leading: Icon(icon),
        title: Text(title),
        initiallyExpanded: open,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
    Widget slider(String key, String label, double value, double min, double max, ValueChanged<double> set,
            {String unit = 'pt', int? divisions}) =>
        Row(
          children: [
            SizedBox(width: 130, child: Text(label, overflow: TextOverflow.ellipsis)),
            Expanded(
              child: Slider(
                key: ValueKey(key),
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions ?? ((max - min) * 2).round(),
                label: '${value.toStringAsFixed(value % 1 == 0 ? 0 : 1)} $unit',
                onChanged: canEdit ? set : null,
              ),
            ),
            SizedBox(
              width: 52,
              child: Text('${value.toStringAsFixed(value % 1 == 0 ? 0 : 1)} $unit', textAlign: TextAlign.end),
            ),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Changes show in the preview at once and reach drivers\' statements when saved. Kept final '
            'statements are redrawn in the new look the next time they are opened; their numbers do not change. '
            'Company name, SSM and support number are on the Settings tab.',
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
        card('layout-logo', 'Logo', Icons.image_outlined, open: true, [
          Row(
            children: [
              Container(
                width: 96,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.colorScheme.outlineVariant),
                ),
                child: logoUrl == null
                    ? Text('No logo', style: TextStyle(color: Colors.grey.shade600, fontSize: 12))
                    : Image.network(logoUrl!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.broken_image)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('layout-logo-upload'),
                      onPressed: canEdit ? onUploadLogo : null,
                      icon: const Icon(Icons.upload),
                      label: Text(logo.path.isEmpty ? 'Add logo' : 'Replace'),
                    ),
                    if (logo.path.isNotEmpty)
                      TextButton.icon(
                        key: const ValueKey('layout-logo-remove'),
                        onPressed: canEdit ? () => onChanged(l.copyWith(logo: logo.copyWith(path: ''))) : null,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remove'),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('PNG or JPEG, under 2 MB. Drag the logo on the preview to move it.',
              style: t.textTheme.bodySmall?.copyWith(color: muted)),
          if (logo.path.isNotEmpty) ...[
            const SizedBox(height: 12),
            SegmentedButton<String>(
              key: const ValueKey('layout-logo-position'),
              segments: const [
                ButtonSegment(value: 'left', icon: Icon(Icons.align_horizontal_left), label: Text('Left')),
                ButtonSegment(value: 'center', icon: Icon(Icons.align_horizontal_center), label: Text('Centre')),
                ButtonSegment(value: 'right', icon: Icon(Icons.align_horizontal_right), label: Text('Right')),
              ],
              selected: {logo.position},
              showSelectedIcon: false,
              onSelectionChanged: canEdit
                  ? (v) => onChanged(l.copyWith(logo: logo.copyWith(position: v.first, dx: 0, dy: 0)))
                  : null,
            ),
            slider('layout-logo-width', 'Width', logo.width, logoWidthMin, logoWidthMax,
                (v) => onChanged(l.copyWith(logo: logo.copyWith(width: v.roundToDouble()))),
                divisions: (logoWidthMax - logoWidthMin).round()),
            slider('layout-logo-dx', 'Move across', logo.dx, -logoShiftMax, logoShiftMax,
                (v) => onChanged(l.copyWith(logo: logo.copyWith(dx: v.roundToDouble()))),
                divisions: (logoShiftMax * 2).round()),
            slider('layout-logo-dy', 'Move down', logo.dy, -logoShiftMax, logoShiftMax,
                (v) => onChanged(l.copyWith(logo: logo.copyWith(dy: v.roundToDouble()))),
                divisions: (logoShiftMax * 2).round()),
          ],
        ]),
        card('layout-look', 'Font and colours', Icons.text_fields, [
          Row(
            children: [
              const SizedBox(width: 130, child: Text('Font')),
              Expanded(
                child: DropdownButton<String>(
                  key: const ValueKey('layout-font'),
                  isExpanded: true,
                  value: l.fontFamily,
                  items: [
                    for (final e in statementFontFamilies.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: canEdit ? (v) => onChanged(l.copyWith(fontFamily: v)) : null,
                ),
              ),
            ],
          ),
          for (final e in statementFontSizes.entries)
            slider('layout-size-${e.key}', e.value.label, l.fontSize(e.key), statementFontMin, statementFontMax,
                (v) {
                  final fonts = {...l.fonts, e.key: v};
                  if (v == e.value.size) fonts.remove(e.key);
                  onChanged(l.copyWith(fonts: fonts));
                }),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in statementColors.entries)
                InputChip(
                  key: ValueKey('layout-color-${e.key}'),
                  avatar: CircleAvatar(backgroundColor: l.color(e.key)),
                  label: Text(e.value.label),
                  onPressed: !canEdit
                      ? null
                      : () async {
                          final picked = await pickStyleColor(context, l.color(e.key), e.value.label);
                          if (picked == null) return;
                          final colors = {...l.colors};
                          final c = picked.isEmpty ? null : hexColor('#${picked.substring(picked.length - 6)}');
                          if (c == null || c.toARGB32() == e.value.argb) {
                            colors.remove(e.key);
                          } else {
                            colors[e.key] = c;
                          }
                          onChanged(l.copyWith(colors: colors));
                        },
                ),
            ],
          ),
        ]),
        card('layout-order', 'Order', Icons.swap_vert, [
          SegmentedButton<String>(
            key: const ValueKey('layout-company-side'),
            segments: const [
              ButtonSegment(value: 'left', label: Text('Company left, title right')),
              ButtonSegment(value: 'right', label: Text('Title left, company right')),
            ],
            selected: {l.companySide},
            showSelectedIcon: false,
            onSelectionChanged: canEdit ? (v) => onChanged(l.copyWith(companySide: v.first)) : null,
          ),
          const SizedBox(height: 12),
          Text('Partner lines', style: t.textTheme.titleSmall),
          _OrderList(
            keyPrefix: 'layout-partner',
            items: l.partnerLineOrder,
            label: (id) => l.label(id, lang),
            enabled: canEdit,
            onChanged: (order) => onChanged(l.copyWith(partnerOrder: order)),
          ),
          const SizedBox(height: 12),
          Text('Blocks', style: t.textTheme.titleSmall),
          _OrderList(
            keyPrefix: 'layout-section',
            items: l.sectionOrder,
            label: (id) => statementSections[id] ?? id,
            enabled: canEdit,
            onChanged: (order) => onChanged(l.copyWith(sections: order)),
          ),
        ]),
        for (final g in StatementFieldGroup.values)
          card('layout-group-${g.name}', g.label, Icons.list_alt, [
            for (final f in statementFields.where((f) => f.group == g))
              _FieldRow(
                field: f,
                setting: l.field(f.id),
                shown: l.label(f.id, lang),
                note: _onlyWhenNotZero.contains(f.id) ? 'Shown only when not zero' : null,
                enabled: canEdit,
                onChanged: (s) => onChanged(l.withField(f.id, s)),
              ),
          ]),
      ],
    );
  }
}

class _OrderList extends StatelessWidget {
  const _OrderList({
    required this.keyPrefix,
    required this.items,
    required this.label,
    required this.enabled,
    required this.onChanged,
  });
  final String keyPrefix;
  final List<String> items;
  final String Function(String id) label;
  final bool enabled;
  final ValueChanged<List<String>> onChanged;

  void _move(int from, int to) {
    final next = [...items];
    next.insert(to, next.removeAt(from));
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < items.length; i++)
        ListTile(
          key: ValueKey('$keyPrefix-${items[i]}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Text('${i + 1}.'),
          title: Text(label(items[i])),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: ValueKey('$keyPrefix-${items[i]}-up'),
                tooltip: 'Move up',
                icon: const Icon(Icons.arrow_upward),
                onPressed: enabled && i > 0 ? () => _move(i, i - 1) : null,
              ),
              IconButton(
                key: ValueKey('$keyPrefix-${items[i]}-down'),
                tooltip: 'Move down',
                icon: const Icon(Icons.arrow_downward),
                onPressed: enabled && i < items.length - 1 ? () => _move(i, i + 1) : null,
              ),
            ],
          ),
        ),
    ],
  );
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.field,
    required this.setting,
    required this.shown,
    required this.note,
    required this.enabled,
    required this.onChanged,
  });
  final StatementField field;
  final StatementFieldSetting setting;
  final String shown;
  final String? note;
  final bool enabled;
  final ValueChanged<StatementFieldSetting> onChanged;

  Future<void> _rename(BuildContext context) async {
    final names = await showAppDialog<_Names>(
      id: 'partner-statements.rename-field',
      context: context,
      builder: (_) => _RenameDialog(field: field, setting: setting),
    );
    if (names != null) onChanged(setting.copyWith(en: names.$1, ms: names.$2));
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final renamed = setting.en.isNotEmpty || setting.ms.isNotEmpty;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Switch(
        key: ValueKey('layout-show-${field.id}'),
        value: setting.show,
        onChanged: enabled ? (v) => onChanged(setting.copyWith(show: v)) : null,
      ),
      title: Text(shown, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [if (renamed) 'Renamed (built-in: ${field.en})', ?note].join(' · '),
        style: TextStyle(color: muted),
      ),
      trailing: field.renamable
          ? IconButton(
              key: ValueKey('layout-rename-${field.id}'),
              tooltip: 'Rename',
              icon: const Icon(Icons.edit_outlined),
              onPressed: enabled ? () => _rename(context) : null,
            )
          : null,
    );
  }
}

/// A field's names: English, Malay.
typedef _Names = (String, String);

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.field, required this.setting});
  final StatementField field;
  final StatementFieldSetting setting;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _en = TextEditingController(text: widget.setting.en);
  late final _ms = TextEditingController(text: widget.setting.ms);

  @override
  void dispose() {
    _en.dispose();
    _ms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    return AlertDialog(
      title: Text('Rename "${f.en}"'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('layout-rename-en'),
                controller: _en,
                maxLength: 80,
                decoration: InputDecoration(labelText: 'English', hintText: f.en),
              ),
              TextField(
                key: const ValueKey('layout-rename-ms'),
                controller: _ms,
                maxLength: 80,
                decoration: InputDecoration(labelText: 'Bahasa Melayu', hintText: f.ms),
              ),
              Text('Leave blank to keep the built-in name.', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('layout-rename-ok'),
          onPressed: () => Navigator.pop(context, (_en.text.trim(), _ms.text.trim())),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

// ---- The preview --------------------------------------------------------------------------------
/// An A4 page drawn like the PDF, with made-up numbers. The paper stays white in dark mode, as printed.
class StatementPreview extends StatelessWidget {
  const StatementPreview({
    super.key,
    required this.layout,
    required this.lang,
    required this.type,
    this.companyName = '',
    this.logoUrl,
    this.onLogoMoved,
  });
  final StatementLayout layout;
  final String lang;
  final StatementType type;
  final String companyName;
  final String? logoUrl;
  final void Function(double dx, double dy)? onLogoMoved;

  static const _w = 595.0;
  static const _h = 842.0;
  static const _m = 40.0;

  static const _sample = <String, double>{
    'fares': 1848, 'surcharges': 126, 'feesCollected': 0, 'incentives': 50, 'totalEarnings': 2024,
    'commission': -277.2, 'platformFees': -9, 'totalDeductions': -286.2, 'adjustments': -2, 'net': 1735.8,
    'taxes': 0, 'tolls': 67.2, 'total': 67.2, 'cash': 1108.8, 'coins': 92.4,
  };
  static const _activity = {'trips': '84', 'meterTrips': '6', 'onlineHours': '134.4', 'distance': '798.0'};
  static const _heads = {'earnings', 'deductions', 'passThrough', 'howPaid', 'activity'};
  static const _quiet = {'handoverIn', 'tips', 'handoverOut', 'otherCharges', 'otherSurcharges'};

  static String _money(double v) {
    final s = v.abs().toStringAsFixed(2).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    return v < 0 ? '-$s' : s;
  }

  @override
  Widget build(BuildContext context) {
    final l = layout;
    final ink = l.color('ink');
    final muted = l.color('muted');
    final brand = l.color('brand');
    final rule = l.color('rule');
    final family = switch (l.fontFamily) {
      'times' => 'Times New Roman',
      'courier' => 'Courier New',
      _ => null,
    };
    final fallback = switch (l.fontFamily) {
      'times' => const ['serif'],
      'courier' => const ['monospace'],
      _ => null,
    };
    TextStyle st(double size, {bool bold = false, Color? color}) => TextStyle(
      fontSize: size,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      color: color ?? ink,
      fontFamily: family,
      fontFamilyFallback: fallback,
      height: 1.15,
    );
    String w(String id) => l.label(id, lang);
    final fs = l.fontSize;
    final companyRight = l.companySide == 'right';
    Widget line() => Container(height: 0.5, color: rule, margin: const EdgeInsets.symmetric(vertical: 3));

    final company = Column(
      crossAxisAlignment: companyRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (l.shows('companyName'))
          Text(companyName.isEmpty ? 'Company name' : companyName, style: st(fs('company'), bold: true, color: brand)),
        if (l.shows('companySsm')) Text('${w('companySsm')} 202201025129', style: st(fs('small') + 1, color: muted)),
        if (l.shows('supportContact')) Text('${w('supportContact')} +6012-5252255', style: st(fs('small') + 1, color: muted)),
      ],
    );
    final period = switch (type) {
      StatementType.weekly => lang == 'ms' ? 'Mingguan - 7 Sep 2026 - 13 Sep 2026' : 'Weekly - 7 Sep 2026 - 13 Sep 2026',
      StatementType.monthly => lang == 'ms' ? 'Bulanan - Sep 2026' : 'Monthly - Sep 2026',
      StatementType.annual => lang == 'ms' ? 'Tahunan - 2025' : 'Annual - 2025',
    };
    final title = Column(
      crossAxisAlignment: companyRight ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: [
        if (l.shows('title')) Text(w('title'), style: st(fs('title'), bold: true)),
        if (l.shows('period')) Text(period, style: st(fs('body'))),
        if (l.shows('statementNo')) Text('${w('statementNo')} SAMPLE', style: st(fs('small') + 1, color: muted)),
      ],
    );

    final partnerValues = {
      'partner': 'Ahmad Bin Ali',
      'partnerId': 'GR201A',
      'ic': '******-**-5678',
      'plate': 'WXY 201',
      'bank': 'Maybank ****4321 (AHMAD BIN ALI)',
    };
    final body = <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (companyRight) _badge(l, lang, st, fs) else const SizedBox(),
          const Spacer(),
          if (!companyRight) _badge(l, lang, st, fs),
        ],
      ),
      for (final id in l.partnerLineOrder)
        if (l.shows(id))
          Row(
            children: [
              SizedBox(width: 90, child: Text(w(id), style: st(fs('body'), color: muted))),
              Expanded(child: Text(partnerValues[id]!, style: st(fs('body'), bold: id == 'partner'))),
            ],
          ),
      const SizedBox(height: 6),
    ];

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Text(text, style: st(fs('heading'), bold: true, color: brand)), line()],
      ),
    );
    Widget amountRow(String label, String value, {bool bold = false}) => Padding(
      padding: EdgeInsets.only(left: 8, bottom: bold ? 4 : 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: st(bold ? fs('total') : fs('body'), bold: bold))),
          Text(value, style: st(bold ? fs('total') : fs('body'), bold: bold)),
        ],
      ),
    );
    Widget table(String titleText, List<String> heads, List<List<String>> rows) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(titleText, style: st(fs('heading'), bold: true, color: brand)),
          Row(
            children: [
              for (var i = 0; i < heads.length; i++)
                Expanded(
                  flex: i == 0 ? 3 : 1,
                  child: Text(heads[i], textAlign: i == 0 ? TextAlign.start : TextAlign.end,
                      style: st(fs('table'), bold: true, color: muted)),
                ),
            ],
          ),
          line(),
          for (final r in rows)
            Row(
              children: [
                for (var i = 0; i < r.length; i++)
                  Expanded(
                    flex: i == 0 ? 3 : 1,
                    child: Text(r[i], textAlign: i == 0 ? TextAlign.start : TextAlign.end, style: st(fs('table') + 1)),
                  ),
              ],
            ),
        ],
      ),
    );

    final groupOf = {for (final f in statementFields) f.id: f.group.name};
    for (final s in l.sectionOrder) {
      switch (s) {
        case 'incentivesList':
          if (l.shows(s)) {
            body
              ..add(heading(w(s)))
              ..add(amountRow('2026-09-09   Rainy day bonus', '10.00'));
          }
        case 'adjustmentsList':
          if (l.shows(s) && type != StatementType.weekly) {
            body
              ..add(heading(w(s)))
              ..add(amountRow('2026-09-18   Toll refunded twice', '-2.00'));
          }
        case 'breakdown':
          final (id, first, rows) = switch (type) {
            StatementType.weekly => ('daily', lang == 'ms' ? 'Tarikh' : 'Date', [
              for (final d in ['Mon 7 Sep', 'Tue 8 Sep', 'Wed 9 Sep']) [d, '2', '49.00', '41.90'],
            ]),
            StatementType.monthly => ('weeklyBreakdown', lang == 'ms' ? 'Minggu' : 'Week', [
              for (final d in ['1 Sep - 6 Sep', '7 Sep - 13 Sep', '14 Sep - 20 Sep', '21 Sep - 27 Sep'])
                [d, '21', '506.00', '434.00'],
            ]),
            StatementType.annual => ('monthlyBreakdown', lang == 'ms' ? 'Bulan' : 'Month', [
              for (final d in ['Jan 2025', 'Feb 2025', 'Mar 2025']) [d, '76', '1,832.00', '1,571.40'],
            ]),
          };
          if (l.shows(id)) {
            body.add(table(w(id), [first, w('trips'), lang == 'ms' ? 'Pendapatan' : 'Earnings', w('net')], rows));
          }
        case 'tripList':
          if (l.shows(s) && type == StatementType.weekly) {
            body.add(table(w(s), [lang == 'ms' ? 'Masa' : 'Time', w('fares'), w('commission')], [
              for (final t in ['2026-09-07 09:15', '2026-09-08 10:15']) [t, '22.00', '-3.30'],
            ]));
          }
        default:
          final ids = statementFields.where((f) => groupOf[f.id] == s).map((f) => f.id).where(l.shows);
          final lines = ids.where((id) => !_heads.contains(id) && !_quiet.contains(id)).toList();
          if (lines.isEmpty) break;
          for (final id in ids) {
            if (_quiet.contains(id)) continue;
            if (_heads.contains(id)) {
              body.add(heading(w(id)));
            } else {
              final bold = const {'totalEarnings', 'totalDeductions', 'net', 'total'}.contains(id);
              body.add(amountRow(w(id), _activity[id] ?? _money(_sample[id] ?? 0), bold: bold));
            }
          }
      }
    }

    final logo = logoUrl == null
        ? null
        : Align(
            alignment: switch (l.logo.position) {
              'center' => Alignment.topCenter,
              'right' => Alignment.topRight,
              _ => Alignment.topLeft,
            },
            child: Transform.translate(
              offset: Offset(l.logo.dx, l.logo.dy),
              child: MouseRegion(
                cursor: onLogoMoved == null ? MouseCursor.defer : SystemMouseCursors.move,
                // The logo claims a touch that starts on it, so the page does not scroll
                // while it is dragged.
                child: RawGestureDetector(
                  key: const ValueKey('layout-preview-logo'),
                  gestures: {
                    if (onLogoMoved != null)
                      EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                        EagerGestureRecognizer.new,
                        (_) {},
                      ),
                  },
                  child: Listener(
                    onPointerMove: onLogoMoved == null ? null : (e) => onLogoMoved!(e.localDelta.dx, e.localDelta.dy),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 120),
                    child: Image.network(
                      logoUrl!,
                      width: l.logo.width,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => Container(
                        width: l.logo.width,
                        height: l.logo.width / 3,
                        color: const Color(0xFFEEEEEE),
                        alignment: Alignment.center,
                        child: const Text('LOGO', style: TextStyle(color: Color(0xFF888888))),
                      ),
                    ),
                  ),
                  ),
                ),
              ),
            ),
          );

    final footer = Column(
      children: [
        line(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (l.shows('verify')) ...[
              Icon(Icons.qr_code_2, size: 54, color: ink),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (l.shows('verify')) ...[
                    Text(w('verify'), style: st(fs('small') + 1, bold: true)),
                    Text('https://getride.my/verify/SAMPLE', style: st(fs('small'), color: muted)),
                  ],
                  if (l.shows('footer')) Text(w('footer'), style: st(fs('small'), color: muted)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (l.shows('statementNo')) Text('SAMPLE', style: st(fs('small') + 1, bold: true)),
                if (l.shows('pageNumbers'))
                  Text(lang == 'ms' ? 'Halaman 1 daripada 1' : 'Page 1 of 1', style: st(fs('small'), color: muted)),
              ],
            ),
          ],
        ),
      ],
    );

    final page = Container(
      width: _w,
      height: _h,
      color: Colors.white,
      padding: const EdgeInsets.all(_m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?logo,
          if (logo != null) const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: companyRight
                ? [Expanded(child: title), const SizedBox(width: 12), Expanded(child: company)]
                : [Expanded(child: company), const SizedBox(width: 12), Expanded(child: title)],
          ),
          line(),
          const SizedBox(height: 10),
          Expanded(
            child: ClipRect(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
              ),
            ),
          ),
          footer,
        ],
      ),
    );
    return Semantics(
      label: 'Statement preview',
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: AspectRatio(
          aspectRatio: _w / _h,
          child: FittedBox(fit: BoxFit.contain, alignment: Alignment.topCenter, child: page),
        ),
      ),
    );
  }

  static Widget _badge(StatementLayout l, String lang, TextStyle Function(double, {bool bold, Color? color}) st,
      double Function(String) fs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (l.shows('status'))
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            color: l.color('badge'),
            child: Text(lang == 'ms' ? 'MUKTAMAD' : 'FINAL', style: st(fs('body'), bold: true, color: Colors.white)),
          ),
        if (l.shows('issued'))
          Text('${l.label('issued', lang)} 2026-10-01 10:00', style: st(fs('small') + 1, color: l.color('muted'))),
      ],
    );
  }
}
