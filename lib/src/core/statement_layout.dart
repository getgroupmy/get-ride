// The partner statement's look (migration 0217), edited in Admin → Partner
// statements → Layout and drawn by the `partner-statement` function: which
// fields show and their names in English and Malay, the order of the partner
// lines and of the blocks, the font and sizes, the colours, and the logo.
// The catalog mirrors supabase/functions/_shared/statement_layout.ts
// (test/statement_layout_test.dart keeps them in step).
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

enum StatementFieldGroup {
  header('Header'),
  partner('Partner'),
  earnings('Earnings'),
  deductions('Deductions'),
  net('Net'),
  passThrough('Collected for others'),
  howPaid('How riders paid'),
  activity('Activity'),
  lists('Incentive and adjustment lists'),
  breakdown('Breakdown and trips'),
  footer('Footer');

  const StatementFieldGroup(this.label);
  final String label;
}

/// One field an admin may hide or rename, with its built-in names.
class StatementField {
  const StatementField(this.id, this.group, this.en, this.ms, {this.renamable = true});
  final String id;
  final StatementFieldGroup group;
  final String en;
  final String ms;

  /// False for a value with no label of its own (the company name, the period).
  final bool renamable;

  String builtIn(String lang) => lang == 'ms' ? ms : en;
}

const statementFields = <StatementField>[
  StatementField('companyName', StatementFieldGroup.header, 'Company name', 'Nama syarikat', renamable: false),
  StatementField('companySsm', StatementFieldGroup.header, 'SSM no.', 'No. SSM'),
  StatementField('supportContact', StatementFieldGroup.header, 'Support', 'Sokongan'),
  StatementField('title', StatementFieldGroup.header, 'Partner Earnings Statement', 'Penyata Pendapatan Rakan Pemandu'),
  StatementField('period', StatementFieldGroup.header, 'Period', 'Tempoh', renamable: false),
  StatementField('statementNo', StatementFieldGroup.header, 'Statement no.', 'No. penyata'),
  StatementField('status', StatementFieldGroup.header, 'Status badge', 'Lencana status', renamable: false),
  StatementField('issued', StatementFieldGroup.header, 'Issued', 'Dikeluarkan'),
  StatementField('partner', StatementFieldGroup.partner, 'Partner', 'Rakan pemandu'),
  StatementField('partnerId', StatementFieldGroup.partner, 'Partner ID', 'ID rakan'),
  StatementField('ic', StatementFieldGroup.partner, 'IC no.', 'No. KP'),
  StatementField('plate', StatementFieldGroup.partner, 'Vehicle plate', 'No. pendaftaran'),
  StatementField('bank', StatementFieldGroup.partner, 'Payout account', 'Akaun pembayaran'),
  StatementField('earnings', StatementFieldGroup.earnings, 'Earnings', 'Pendapatan'),
  StatementField('fares', StatementFieldGroup.earnings, 'Fares', 'Tambang'),
  StatementField('surcharges', StatementFieldGroup.earnings, 'Surcharges', 'Caj tambahan'),
  StatementField('feesCollected', StatementFieldGroup.earnings, 'Fees collected for GET.ride', 'Fi dikutip untuk GET.ride'),
  StatementField('incentives', StatementFieldGroup.earnings, 'Incentives', 'Insentif'),
  StatementField('handoverIn', StatementFieldGroup.earnings, 'Trip handover share received', 'Syer serahan perjalanan diterima'),
  StatementField('totalEarnings', StatementFieldGroup.earnings, 'Total earnings', 'Jumlah pendapatan'),
  StatementField('deductions', StatementFieldGroup.deductions, 'Deductions', 'Potongan'),
  StatementField('commission', StatementFieldGroup.deductions, 'Commission', 'Komisen'),
  StatementField('platformFees', StatementFieldGroup.deductions, 'Platform fees', 'Fi platform'),
  StatementField('handoverOut', StatementFieldGroup.deductions, 'Trip handover share paid', 'Syer serahan perjalanan dibayar'),
  StatementField('totalDeductions', StatementFieldGroup.deductions, 'Total deductions', 'Jumlah potongan'),
  StatementField('adjustments', StatementFieldGroup.net, 'Adjustments', 'Pelarasan'),
  StatementField('net', StatementFieldGroup.net, 'Net earnings', 'Pendapatan bersih'),
  StatementField('passThrough', StatementFieldGroup.passThrough, 'Collected for others (not income)',
      'Dikutip bagi pihak lain (bukan pendapatan)'),
  StatementField('taxes', StatementFieldGroup.passThrough, 'Taxes', 'Cukai'),
  StatementField('tolls', StatementFieldGroup.passThrough, 'Tolls', 'Tol'),
  StatementField('otherCharges', StatementFieldGroup.passThrough, 'Other charges', 'Caj lain'),
  StatementField('otherSurcharges', StatementFieldGroup.passThrough, 'Other surcharges', 'Caj tambahan lain'),
  StatementField('total', StatementFieldGroup.passThrough, 'Total', 'Jumlah'),
  StatementField('howPaid', StatementFieldGroup.howPaid, 'How riders paid', 'Cara penumpang membayar'),
  StatementField('cash', StatementFieldGroup.howPaid, 'Cash', 'Tunai'),
  StatementField('coins', StatementFieldGroup.howPaid, 'GET.coin', 'GET.coin'),
  StatementField('activity', StatementFieldGroup.activity, 'Activity', 'Aktiviti'),
  StatementField('trips', StatementFieldGroup.activity, 'Trips', 'Perjalanan'),
  StatementField('onlineHours', StatementFieldGroup.activity, 'Hours online', 'Jam dalam talian'),
  StatementField('distance', StatementFieldGroup.activity, 'Distance (km)', 'Jarak (km)'),
  StatementField('incentivesList', StatementFieldGroup.lists, 'Incentives', 'Insentif'),
  StatementField('adjustmentsList', StatementFieldGroup.lists, 'Adjustments', 'Pelarasan'),
  StatementField('daily', StatementFieldGroup.breakdown, 'Daily breakdown', 'Pecahan harian'),
  StatementField('weeklyBreakdown', StatementFieldGroup.breakdown, 'Weekly breakdown', 'Pecahan mingguan'),
  StatementField('monthlyBreakdown', StatementFieldGroup.breakdown, 'Monthly breakdown', 'Pecahan bulanan'),
  StatementField('tripList', StatementFieldGroup.breakdown, 'Trips', 'Perjalanan'),
  StatementField('verify', StatementFieldGroup.footer, 'Verify this statement', 'Sahkan penyata ini'),
  StatementField('footer', StatementFieldGroup.footer,
      'Computer-generated statement; no signature is required. Amounts in RM.',
      'Penyata janaan komputer; tandatangan tidak diperlukan. Amaun dalam RM.'),
  StatementField('pageNumbers', StatementFieldGroup.footer, 'Page numbers', 'Nombor halaman', renamable: false),
  StatementField('watermark', StatementFieldGroup.footer, 'PROVISIONAL', 'SEMENTARA'),
];

final _byId = {for (final f in statementFields) f.id: f};
StatementField? statementField(String id) => _byId[id];

/// The blocks under the partner lines, in their built-in order, with what the editor calls them.
const statementSections = <String, String>{
  'earnings': 'Earnings',
  'deductions': 'Deductions',
  'net': 'Adjustments and net',
  'passThrough': 'Collected for others',
  'howPaid': 'How riders paid',
  'activity': 'Activity',
  'incentivesList': 'Incentive list',
  'adjustmentsList': 'Adjustment list',
  'breakdown': 'Breakdown',
  'tripList': 'Trip list (weekly)',
};

const statementPartnerLines = ['partner', 'partnerId', 'ic', 'plate', 'bank'];

const statementFontSizes = <String, ({String label, double size})>{
  'company': (label: 'Company name', size: 12),
  'title': (label: 'Title', size: 12),
  'heading': (label: 'Section headings', size: 10),
  'body': (label: 'Lines', size: 9),
  'total': (label: 'Totals', size: 10),
  'table': (label: 'Tables', size: 8),
  'small': (label: 'Small print', size: 7),
};
const statementFontMin = 6.0;
const statementFontMax = 24.0;

const statementColors = <String, ({String label, int argb})>{
  'brand': (label: 'Company and headings', argb: 0xFF007859),
  'ink': (label: 'Text', argb: 0xFF1A1A1F),
  'muted': (label: 'Labels and small print', argb: 0xFF6B7080),
  'rule': (label: 'Lines', argb: 0xFFD9DBE0),
  'badge': (label: 'Final badge', argb: 0xFF007859),
  'watermark': (label: 'Provisional watermark', argb: 0xFFE6E6EB),
};

const statementFontFamilies = {'helvetica': 'Helvetica', 'times': 'Times', 'courier': 'Courier'};

const logoWidthMin = 20.0;
const logoWidthMax = 220.0;
const logoWidthInitial = 70.0;
const logoShiftMax = 200.0;

/// A field's saved setting: hidden, or renamed in either language.
@immutable
class StatementFieldSetting {
  const StatementFieldSetting({this.show = true, this.en = '', this.ms = ''});
  final bool show;
  final String en;
  final String ms;

  bool get isDefault => show && en.isEmpty && ms.isEmpty;

  StatementFieldSetting copyWith({bool? show, String? en, String? ms}) =>
      StatementFieldSetting(show: show ?? this.show, en: en ?? this.en, ms: ms ?? this.ms);

  Map<String, dynamic> toJson() => {if (!show) 'show': false, if (en.isNotEmpty) 'en': en, if (ms.isNotEmpty) 'ms': ms};

  @override
  bool operator ==(Object other) =>
      other is StatementFieldSetting && other.show == show && other.en == en && other.ms == ms;

  @override
  int get hashCode => Object.hash(show, en, ms);
}

@immutable
class StatementLogo {
  const StatementLogo({this.path = '', this.position = 'left', this.width = logoWidthInitial, this.dx = 0, this.dy = 0});
  final String path;

  /// left | center | right
  final String position;
  final double width;
  final double dx;
  final double dy;

  StatementLogo copyWith({String? path, String? position, double? width, double? dx, double? dy}) => StatementLogo(
    path: path ?? this.path,
    position: position ?? this.position,
    width: width ?? this.width,
    dx: dx ?? this.dx,
    dy: dy ?? this.dy,
  );

  Map<String, dynamic> toJson() =>
      {'path': path, 'position': position, 'width': width.round(), 'dx': dx.round(), 'dy': dy.round()};

  @override
  bool operator ==(Object other) =>
      other is StatementLogo &&
      other.path == path &&
      other.position == position &&
      other.width == width &&
      other.dx == dx &&
      other.dy == dy;

  @override
  int get hashCode => Object.hash(path, position, width, dx, dy);
}

/// "#007859" → its colour; anything else, null.
Color? hexColor(String? s) {
  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch((s ?? '').trim());
  return m == null ? null : Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
}

String colorHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

double _num(Object? v, double lo, double hi, double d) {
  final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
  return (n == null || n.isNaN ? d : n).clamp(lo, hi).toDouble();
}

List<String> _ordered(Object? given, Iterable<String> all) {
  final out = <String>[];
  if (given is List) {
    for (final x in given) {
      if (all.contains(x) && !out.contains(x)) out.add('$x');
    }
  }
  for (final x in all) {
    if (!out.contains(x)) out.add(x);
  }
  return out;
}

@immutable
class StatementLayout {
  const StatementLayout({
    this.fields = const {},
    this.sections = const [],
    this.partnerOrder = const [],
    this.fontFamily = 'helvetica',
    this.fonts = const {},
    this.colors = const {},
    this.logo = const StatementLogo(),
    this.companySide = 'left',
  });

  factory StatementLayout.fromJson(Object? raw) {
    final r = raw is Map ? raw : const {};
    final f = r['fields'] is Map ? r['fields'] as Map : const {};
    final fonts = r['fonts'] is Map ? r['fonts'] as Map : const {};
    final colors = r['colors'] is Map ? r['colors'] as Map : const {};
    final logo = r['logo'] is Map ? r['logo'] as Map : const {};
    String text(Object? v) {
      final s = v is String ? v.trim() : '';
      return s.length > 80 ? s.substring(0, 80) : s;
    }

    return StatementLayout(
      fields: {
        for (final field in statementFields)
          if (f[field.id] is Map)
            field.id: StatementFieldSetting(
              show: (f[field.id] as Map)['show'] != false,
              en: text((f[field.id] as Map)['en']),
              ms: text((f[field.id] as Map)['ms']),
            ),
      }..removeWhere((_, v) => v.isDefault),
      sections: _ordered(r['sections'], statementSections.keys),
      partnerOrder: _ordered(r['partnerOrder'], statementPartnerLines),
      fontFamily: statementFontFamilies.containsKey(r['fontFamily']) ? '${r['fontFamily']}' : 'helvetica',
      fonts: {
        for (final e in statementFontSizes.entries)
          if (fonts[e.key] is num && fonts[e.key] != e.value.size)
            e.key: _num(fonts[e.key], statementFontMin, statementFontMax, e.value.size),
      },
      colors: {
        for (final e in statementColors.entries)
          if (hexColor(colors[e.key] as String?) case final c? when c.toARGB32() != e.value.argb) e.key: c,
      },
      logo: StatementLogo(
        path: logo['path'] is String && RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$').hasMatch(logo['path'] as String)
            ? logo['path'] as String
            : '',
        position: logo['position'] == 'center' || logo['position'] == 'right' ? '${logo['position']}' : 'left',
        width: _num(logo['width'], logoWidthMin, logoWidthMax, logoWidthInitial).roundToDouble(),
        dx: _num(logo['dx'], -logoShiftMax, logoShiftMax, 0).roundToDouble(),
        dy: _num(logo['dy'], -logoShiftMax, logoShiftMax, 0).roundToDouble(),
      ),
      companySide: r['companySide'] == 'right' ? 'right' : 'left',
    );
  }

  /// Only what differs from the built-in look.
  final Map<String, StatementFieldSetting> fields;

  /// Every block, in order (empty: the built-in order).
  final List<String> sections;
  final List<String> partnerOrder;
  final String fontFamily;
  final Map<String, double> fonts;
  final Map<String, Color> colors;
  final StatementLogo logo;

  /// left | right: where the company sits, the title opposite.
  final String companySide;

  List<String> get sectionOrder => _ordered(sections, statementSections.keys);
  List<String> get partnerLineOrder => _ordered(partnerOrder, statementPartnerLines);

  StatementFieldSetting field(String id) => fields[id] ?? const StatementFieldSetting();
  bool shows(String id) => field(id).show;

  /// The name shown in this language: the admin's, or the built-in one.
  String label(String id, String lang) {
    final s = field(id);
    final mine = lang == 'ms' ? s.ms : s.en;
    return mine.isNotEmpty ? mine : statementField(id)?.builtIn(lang) ?? id;
  }

  double fontSize(String key) => fonts[key] ?? statementFontSizes[key]?.size ?? 9;
  Color color(String key) => colors[key] ?? Color(statementColors[key]?.argb ?? 0xFF000000);

  bool get isDefault => this == const StatementLayout();

  StatementLayout withField(String id, StatementFieldSetting s) =>
      copyWith(fields: {...fields, id: s}..removeWhere((_, v) => v.isDefault));

  StatementLayout copyWith({
    Map<String, StatementFieldSetting>? fields,
    List<String>? sections,
    List<String>? partnerOrder,
    String? fontFamily,
    Map<String, double>? fonts,
    Map<String, Color>? colors,
    StatementLogo? logo,
    String? companySide,
  }) => StatementLayout(
    fields: fields ?? this.fields,
    sections: sections ?? this.sections,
    partnerOrder: partnerOrder ?? this.partnerOrder,
    fontFamily: fontFamily ?? this.fontFamily,
    fonts: fonts ?? this.fonts,
    colors: colors ?? this.colors,
    logo: logo ?? this.logo,
    companySide: companySide ?? this.companySide,
  );

  Map<String, dynamic> toJson() => {
    'fields': {for (final e in fields.entries) e.key: e.value.toJson()},
    'sections': sectionOrder,
    'partnerOrder': partnerLineOrder,
    'fontFamily': fontFamily,
    'fonts': {for (final e in fonts.entries) e.key: e.value},
    'colors': {for (final e in colors.entries) e.key: colorHex(e.value)},
    'logo': logo.toJson(),
    'companySide': companySide,
  };

  @override
  bool operator ==(Object other) =>
      other is StatementLayout &&
      mapEquals(other.fields, fields) &&
      listEquals(other.sectionOrder, sectionOrder) &&
      listEquals(other.partnerLineOrder, partnerLineOrder) &&
      other.fontFamily == fontFamily &&
      mapEquals(other.fonts, fonts) &&
      mapEquals(other.colors, colors) &&
      other.logo == logo &&
      other.companySide == companySide;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(fields.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAll(sectionOrder),
    Object.hashAll(partnerLineOrder),
    fontFamily,
    Object.hashAllUnordered(fonts.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAllUnordered(colors.entries.map((e) => Object.hash(e.key, e.value))),
    logo,
    companySide,
  );
}
