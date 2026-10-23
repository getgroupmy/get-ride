/// Admin > Reports: the Excel download. A .xlsx is a zip of a few XML
/// files; this writes the two sheets the page offers (the table with its
/// total row, then "What the AI understood") with numbers as numbers and
/// bold headings, as the scheduled emails' copy does
/// (supabase/functions/_shared/report_files.ts).
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'ai_report.dart';

final _badXml = RegExp('[\u0000-\u0008\u000b\u000c\u000e-\u001f]');

String _xml(String s) => s
    .replaceAll(_badXml, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _col(int i) {
  var s = '';
  for (var n = i + 1; n > 0; n = (n - 1) ~/ 26) {
    s = String.fromCharCode(65 + (n - 1) % 26) + s;
  }
  return s;
}

String _sheet(List<List<Object?>> rows, Set<int> bold, List<int> widths) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
    ..write('<sheetViews><sheetView workbookViewId="0">')
    ..write(bold.contains(0) ? '<pane ySplit="1" topLeftCell="A2" state="frozen"/>' : '')
    ..write('</sheetView></sheetViews>');
  if (widths.isNotEmpty) {
    b.write('<cols>');
    for (final (i, w) in widths.indexed) {
      b.write('<col min="${i + 1}" max="${i + 1}" width="$w" customWidth="1"/>');
    }
    b.write('</cols>');
  }
  b.write('<sheetData>');
  for (final (r, row) in rows.indexed) {
    b.write('<row r="${r + 1}">');
    for (final (c, v) in row.indexed) {
      final ref = '${_col(c)}${r + 1}';
      final s = bold.contains(r) ? ' s="1"' : '';
      if (v == null || v == '') {
        b.write('<c r="$ref"$s/>');
      } else if (v is num && v.isFinite) {
        b.write('<c r="$ref"$s><v>$v</v></c>');
      } else if (v is bool) {
        b.write('<c r="$ref"$s t="b"><v>${v ? 1 : 0}</v></c>');
      } else {
        b.write('<c r="$ref"$s t="inlineStr"><is><t xml:space="preserve">${_xml('$v')}</t></is></c>');
      }
    }
    b.write('</row>');
  }
  b.write('</sheetData></worksheet>');
  return b.toString();
}

Object? _cell(Object? v, String type) => type == 'number' && v is String ? num.tryParse(v) ?? v : v;

const _contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    '</Types>';

const _rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    '</Relationships>';

const _workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    '<sheets><sheet name="Report" sheetId="1" r:id="rId1"/><sheet name="What the AI understood" sheetId="2" r:id="rId2"/></sheets>'
    '</workbook>';

const _workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>'
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '</Relationships>';

const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
    '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>';

/// The workbook: sheet 1 the table, sheet 2 what the AI understood.
Uint8List reportXlsx(ReportResult r, List<(String, String)> understood) {
  final table = <List<Object?>>[
    [for (final c in r.columns) c.label],
    for (final row in r.rows) [for (final (i, v) in row.indexed) _cell(v, i < r.columns.length ? r.columns[i].type : 'text')],
  ];
  final bold = {0};
  final total = r.totalRow;
  if (total != null) {
    bold.add(table.length);
    table.add(total);
  }
  if (r.truncated) table.add(['Showing first ${reportCellText(r.maxRows, 'number')} rows']);
  final widths = [for (final c in r.columns) (c.label.length + 2).clamp(10, 40)];
  final sheet2 = <List<Object?>>[
    ['What the AI understood', ''],
    for (final (k, v) in understood) [k, v],
  ];
  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml', _contentTypes))
    ..addFile(ArchiveFile.string('_rels/.rels', _rels))
    ..addFile(ArchiveFile.string('xl/workbook.xml', _workbook))
    ..addFile(ArchiveFile.string('xl/_rels/workbook.xml.rels', _workbookRels))
    ..addFile(ArchiveFile.string('xl/styles.xml', _styles))
    ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', _sheet(table, bold, widths)))
    ..addFile(ArchiveFile.string('xl/worksheets/sheet2.xml', _sheet(sheet2, {0}, const [24, 80])));
  return ZipEncoder().encodeBytes(archive);
}
