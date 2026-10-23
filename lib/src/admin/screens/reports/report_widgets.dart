// Admin > Reports: the pieces of a report on the page. "What the AI
// understood", the preview chart (one figure by the groups, as bars) and
// the table with its total row. Theme colours only, so light and dark both
// read.
import 'package:flutter/material.dart';

import '../../../core/ai_report.dart';
import '../../../widgets/common.dart' show mutedTextColor;

/// A filled button sized to its words (the app's theme makes them full width).
final reportButtonStyle = FilledButton.styleFrom(minimumSize: const Size(0, 40));

/// A card of the Reports page.
class ReportCard extends StatelessWidget {
  const ReportCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: t.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: t.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }
}

/// A small coloured label ("Checked by the server", "Privacy").
class ReportTag extends StatelessWidget {
  const ReportTag(this.text, {super.key, this.warn = false});
  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final bg = warn ? s.tertiaryContainer : s.secondaryContainer;
    final fg = warn ? s.onTertiaryContainer : s.onSecondaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
      ),
    );
  }
}

/// "What the AI understood": label / words, line by line.
class ReportPlanLines extends StatelessWidget {
  const ReportPlanLines({super.key, required this.lines});
  final List<(String, String)> lines;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    return Column(
      key: const ValueKey('reports-plan-lines'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, words) in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 96, child: Text(label, style: t.textTheme.bodySmall?.copyWith(color: muted))),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(words, style: t.textTheme.bodyMedium),
                      if (label == 'Hidden') const ReportTag('Privacy', warn: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One figure by the groups, as bars, biggest as the table has them.
class ReportBars extends StatelessWidget {
  const ReportBars({super.key, required this.bars, required this.measureLabel});
  final List<({String label, double value})> bars;
  final String measureLabel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final top = bars.fold<double>(0, (m, b) => b.value > m ? b.value : m);
    return Semantics(
      label: 'Chart of $measureLabel',
      child: Column(
        key: const ValueKey('reports-chart'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(measureLabel, style: t.textTheme.labelMedium?.copyWith(color: mutedTextColor(t))),
          const SizedBox(height: 6),
          for (final (i, b) in bars.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.5),
              child: Row(
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(b.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (_, box) => Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          key: ValueKey('reports-bar-$i'),
                          height: 12,
                          width: top <= 0 ? 1 : (box.maxWidth * (b.value < 0 ? 0 : b.value) / top).clamp(1, box.maxWidth),
                          decoration: BoxDecoration(
                            color: t.colorScheme.primary,
                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 76,
                    child: Text(
                      reportCellText(b.value, 'number'),
                      textAlign: TextAlign.right,
                      style: t.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The table, with the total row in bold. Long reports show their first
/// [maxRows] here; the downloads have them all.
class ReportTable extends StatelessWidget {
  const ReportTable({super.key, required this.result, this.maxRows = 200});
  final ReportResult result;
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cols = result.columns;
    final total = result.totalRow;
    final numStyle = t.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final bold = numStyle?.copyWith(fontWeight: FontWeight.w700);
    DataRow row(List<Object?> r, {bool strong = false, LocalKey? key}) => DataRow(
      key: key,
      cells: [
        for (final (i, c) in cols.indexed)
          DataCell(Text(reportCellText(i < r.length ? r[i] : null, c.type), style: strong ? bold : numStyle)),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          key: const ValueKey('reports-table'),
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 36,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 40,
            columnSpacing: 20,
            horizontalMargin: 8,
            headingTextStyle: t.textTheme.labelMedium?.copyWith(color: mutedTextColor(t), fontWeight: FontWeight.w600),
            columns: [for (final c in cols) DataColumn(label: Text(c.label), numeric: c.isNumber)],
            rows: [
              for (final r in result.rows.take(maxRows)) row(r),
              if (total != null) row(total, strong: true, key: const ValueKey('reports-total-row')),
            ],
          ),
        ),
        if (result.rows.length > maxRows)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'The table shows the first $maxRows rows; the downloads have all ${reportCellText(result.rowCount, 'number')}.',
              style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
            ),
          ),
        if (result.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Showing first ${reportCellText(result.maxRows, 'number')} rows.',
              key: const ValueKey('reports-truncated'),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
