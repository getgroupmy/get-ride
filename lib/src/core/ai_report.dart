/// Admin > Reports (migration 0280): the pure half of the page. The
/// catalogue of approved datasets (`ai_report_catalogue()`), a report plan
/// and its words ("What the AI understood"), a run's result, the periods
/// (Malaysia's days), the CSV file and the email schedules' next run.
///
/// The server is the authority on all of it: it checks every plan again
/// (`ai_report_run`) and works the schedules' next run out itself
/// (`ai_report_next_run`); what is here shows the same before it asks.
library;

/// Malaysia is UTC+8 all year.
const _myt = Duration(hours: 8);

/// The calendar day it is in Malaysia at [now].
DateTime malaysiaDay(DateTime now) {
  final m = now.toUtc().add(_myt);
  return DateTime(m.year, m.month, m.day);
}

String isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? parseIsoDay(Object? v) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch('${v ?? ''}');
  if (m == null) return null;
  final d = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  return isoDay(d) == m[0] ? d : null;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "5 Oct 2026".
String shortDay(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

List<String> _strings(Object? v) => [for (final x in v is List ? v : const []) '$x'];
Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

// ---- The catalogue -----------------------------------------------------------------------------

class ReportField {
  const ReportField({required this.id, required this.label, required this.type, this.values = const [], this.personal});

  factory ReportField.fromJson(Object? json) {
    final m = _map(json);
    return ReportField(
      id: '${m['id'] ?? ''}',
      label: '${m['label'] ?? m['id'] ?? ''}',
      type: '${m['type'] ?? 'text'}',
      values: _strings(m['values']),
      personal: m['personal'] as String?,
    );
  }

  final String id;
  final String label;

  /// text, number, time or bool.
  final String type;
  final List<String> values;

  /// The People pages it needs (users / partners); null when it isn't personal.
  final String? personal;

  bool get isTime => type == 'time';
  bool get isNumber => type == 'number';
}

class ReportDataset {
  const ReportDataset({
    required this.id,
    required this.label,
    required this.time,
    required this.fields,
    this.about = '',
    this.list = const [],
    this.hidden = const [],
    this.limited = false,
  });

  factory ReportDataset.fromJson(Object? json) {
    final m = _map(json);
    return ReportDataset(
      id: '${m['id'] ?? ''}',
      label: '${m['label'] ?? m['id'] ?? ''}',
      about: '${m['about'] ?? ''}',
      time: '${m['time'] ?? 'created_at'}',
      list: _strings(m['list']),
      fields: [for (final f in (m['fields'] as List?) ?? const []) ReportField.fromJson(f)],
      hidden: _strings(m['hidden']),
      limited: m['limited'] == true,
    );
  }

  final String id;
  final String label;
  final String about;

  /// The date a period goes by unless the plan names another.
  final String time;
  final List<String> list;
  final List<ReportField> fields;

  /// Personal fields left out for this admin (their labels).
  final List<String> hidden;

  /// Limited to this admin's region.
  final bool limited;

  ReportField? field(String id) {
    for (final f in fields) {
      if (f.id == id) return f;
    }
    return null;
  }
}

class ReportCatalogue {
  const ReportCatalogue({
    required this.datasets,
    this.aggs = const ['count', 'count_distinct', 'sum', 'avg', 'min', 'max'],
    this.buckets = const ['day', 'week', 'month', 'year'],
    this.maxRows = 50000,
    this.maxGroupBy = 3,
    this.maxMeasures = 8,
    this.scoped = false,
    this.canEdit = false,
    this.region,
  });

  factory ReportCatalogue.fromJson(Object? json) {
    final m = _map(json);
    final limits = _map(m['limits']);
    final scope = _map(m['scope']);
    int n(String k, int d) => (limits[k] as num?)?.toInt() ?? d;
    return ReportCatalogue(
      datasets: [for (final d in (m['datasets'] as List?) ?? const []) ReportDataset.fromJson(d)],
      aggs: m['aggs'] is List ? _strings(m['aggs']) : const ['count', 'count_distinct', 'sum', 'avg', 'min', 'max'],
      buckets: m['buckets'] is List ? _strings(m['buckets']) : const ['day', 'week', 'month', 'year'],
      maxRows: n('max_rows', 50000),
      maxGroupBy: n('max_group_by', 3),
      maxMeasures: n('max_measures', 8),
      scoped: scope['scoped'] == true,
      canEdit: scope['edit'] == true,
      region: scope['region'] is Map ? Map<String, dynamic>.from(scope['region'] as Map) : null,
    );
  }

  final List<ReportDataset> datasets;
  final List<String> aggs;
  final List<String> buckets;
  final int maxRows;
  final int maxGroupBy;
  final int maxMeasures;

  /// A sub-admin limited to [region] (none set: no rows where a place applies).
  final bool scoped;
  final bool canEdit;
  final Map<String, dynamic>? region;

  ReportDataset? dataset(String id) {
    for (final d in datasets) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// "Selangor, Malaysia" for a sub-admin's region; null when not limited.
  String? get regionLabel {
    if (!scoped) return null;
    final r = region ?? const {};
    final parts = [for (final k in ['suburb', 'city', 'state', 'country']) '${r[k] ?? ''}'.trim()]
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? '' : parts.join(', ');
  }
}

// ---- A plan ------------------------------------------------------------------------------------

class ReportFilter {
  const ReportFilter(this.field, this.op, [this.value]);

  factory ReportFilter.fromJson(Object? json) {
    final m = _map(json);
    return ReportFilter('${m['field'] ?? ''}', '${m['op'] ?? 'eq'}', m['value']);
  }

  final String field;
  final String op;
  final Object? value;

  Map<String, dynamic> toJson() => {'field': field, 'op': op, if (value != null) 'value': value};
}

class ReportMeasure {
  const ReportMeasure(this.field, this.agg);

  factory ReportMeasure.fromJson(Object? json) {
    final m = _map(json);
    return ReportMeasure('${m['field'] ?? '*'}', '${m['agg'] ?? 'count'}');
  }

  static const count = ReportMeasure('*', 'count');

  final String field;
  final String agg;

  /// The column the database names it.
  String get column => field == '*' ? 'count' : '${agg}_$field';

  Map<String, dynamic> toJson() => {'field': field, 'agg': agg};

  @override
  bool operator ==(Object other) => other is ReportMeasure && other.field == field && other.agg == agg;

  @override
  int get hashCode => Object.hash(field, agg);
}

class ReportSort {
  const ReportSort(this.field, {this.descending = false});

  factory ReportSort.fromJson(Object? json) {
    final m = _map(json);
    return ReportSort('${m['field'] ?? ''}', descending: '${m['dir']}'.toLowerCase() == 'desc');
  }

  final String field;
  final bool descending;

  Map<String, dynamic> toJson() => {'field': field, 'dir': descending ? 'desc' : 'asc'};
}

/// A period: a preset ("last_week", "last_n_days" with [days]) or the dates
/// [from] to [to], both included, Malaysia's.
class ReportPeriod {
  const ReportPeriod.preset(this.preset, {this.days, this.field}) : from = null, to = null;
  const ReportPeriod.dates(DateTime this.from, DateTime this.to, {this.field}) : preset = null, days = null;

  static ReportPeriod? fromJson(Object? json) {
    final m = _map(json);
    final field = m['field'] as String?;
    final preset = '${m['preset'] ?? ''}';
    if (preset.isNotEmpty) return ReportPeriod.preset(preset, days: (m['days'] as num?)?.toInt(), field: field);
    final from = parseIsoDay(m['from']), to = parseIsoDay(m['to']);
    if (from != null && to != null) return ReportPeriod.dates(from, to, field: field);
    return null;
  }

  final String? preset;
  final int? days;
  final DateTime? from;
  final DateTime? to;

  /// The date it goes by; the dataset's own when null.
  final String? field;

  Map<String, dynamic> toJson() => {
    if (preset != null) 'preset': preset,
    if (days != null) 'days': days,
    if (from != null) 'from': isoDay(from!),
    if (to != null) 'to': isoDay(to!),
    if (field != null) 'field': field,
  };

  ReportPeriod withField(String? f) =>
      preset != null ? ReportPeriod.preset(preset!, days: days, field: f) : ReportPeriod.dates(from!, to!, field: f);
}

/// The days a period covers at [now] (Malaysia's), as `ai_report_period_dates`
/// works them out; null for an unknown preset.
({DateTime from, DateTime to})? periodDays(ReportPeriod p, DateTime now) {
  if (p.preset == null) return (from: p.from!, to: p.to!);
  final t = malaysiaDay(now);
  DateTime day(int y, int m, int d) => DateTime(y, m, d);
  final monday = t.subtract(Duration(days: t.weekday - 1));
  final first = day(t.year, t.month, 1);
  final lastMonthEnd = first.subtract(const Duration(days: 1));
  return switch (p.preset) {
    'today' => (from: t, to: t),
    'yesterday' || 'previous_day' => (from: t.subtract(const Duration(days: 1)), to: t.subtract(const Duration(days: 1))),
    'last_7_days' => (from: t.subtract(const Duration(days: 6)), to: t),
    'last_30_days' => (from: t.subtract(const Duration(days: 29)), to: t),
    'this_week' => (from: monday, to: t),
    'last_week' || 'previous_week' => (
      from: monday.subtract(const Duration(days: 7)),
      to: monday.subtract(const Duration(days: 1)),
    ),
    'this_month' || 'month_to_date' => (from: first, to: t),
    'last_month' || 'previous_month' => (from: day(lastMonthEnd.year, lastMonthEnd.month, 1), to: lastMonthEnd),
    'this_year' => (from: day(t.year, 1, 1), to: t),
    'last_year' => (from: day(t.year - 1, 1, 1), to: day(t.year - 1, 12, 31)),
    'last_n_days' when (p.days ?? 0) >= 1 => (
      from: t.subtract(Duration(days: p.days!)),
      to: t.subtract(const Duration(days: 1)),
    ),
    _ => null,
  };
}

const _presetWords = {
  'today': 'Today',
  'yesterday': 'Yesterday',
  'last_7_days': 'The last 7 days',
  'last_30_days': 'The last 30 days',
  'this_week': 'This week',
  'last_week': 'Last week',
  'this_month': 'This month',
  'last_month': 'Last month',
  'month_to_date': 'This month so far',
  'this_year': 'This year',
  'last_year': 'Last year',
  'previous_day': 'The day before',
  'previous_week': 'The week before',
  'previous_month': 'The month before',
};

/// "Last week", "The last 14 whole days", "1 Oct 2026 to 31 Oct 2026".
String periodWords(ReportPeriod? p) {
  if (p == null) return 'All time';
  if (p.preset == 'last_n_days') return 'The last ${p.days} whole days';
  if (p.preset != null) return _presetWords[p.preset] ?? p.preset!;
  return p.from == p.to ? shortDay(p.from!) : '${shortDay(p.from!)} to ${shortDay(p.to!)}';
}

class ReportPlan {
  const ReportPlan({
    required this.dataset,
    this.columns = const [],
    this.filters = const [],
    this.period,
    this.groupBy = const [],
    this.measures = const [],
    this.sort = const [],
    this.limit,
    this.title = '',
  });

  factory ReportPlan.fromJson(Object? json) {
    final m = _map(json);
    return ReportPlan(
      dataset: '${m['dataset'] ?? ''}',
      columns: _strings(m['columns']),
      filters: [for (final f in (m['filters'] as List?) ?? const []) ReportFilter.fromJson(f)],
      period: ReportPeriod.fromJson(m['period']),
      groupBy: _strings(m['group_by']),
      measures: [for (final x in (m['measures'] as List?) ?? const []) ReportMeasure.fromJson(x)],
      sort: [for (final x in (m['sort'] as List?) ?? const []) ReportSort.fromJson(x)],
      limit: (m['limit'] as num?)?.toInt(),
      title: '${m['title'] ?? ''}',
    );
  }

  final String dataset;
  final List<String> columns;
  final List<ReportFilter> filters;
  final ReportPeriod? period;

  /// Field ids; a date's as "field:day|week|month|year".
  final List<String> groupBy;
  final List<ReportMeasure> measures;
  final List<ReportSort> sort;
  final int? limit;
  final String title;

  bool get isList => groupBy.isEmpty && measures.isEmpty;

  Map<String, dynamic> toJson() => {
    'dataset': dataset,
    'columns': columns,
    'filters': [for (final f in filters) f.toJson()],
    'period': period?.toJson(),
    'group_by': groupBy,
    'measures': [for (final x in measures) x.toJson()],
    'sort': [for (final x in sort) x.toJson()],
    if (limit != null) 'limit': limit,
    if (title.isNotEmpty) 'title': title,
  };

  ReportPlan copyWith({
    List<String>? columns,
    List<ReportFilter>? filters,
    ReportPeriod? period,
    bool clearPeriod = false,
    List<String>? groupBy,
    List<ReportMeasure>? measures,
    List<ReportSort>? sort,
    String? title,
  }) =>
      ReportPlan(
        dataset: dataset,
        columns: columns ?? this.columns,
        filters: filters ?? this.filters,
        period: clearPeriod ? null : period ?? this.period,
        groupBy: groupBy ?? this.groupBy,
        measures: measures ?? this.measures,
        sort: sort ?? this.sort,
        limit: limit,
        title: title ?? this.title,
      );

  /// The output column a group or measure makes.
  static String groupColumn(String g) {
    final i = g.indexOf(':');
    return i < 0 ? g : '${g.substring(0, i)}_${g.substring(i + 1)}';
  }

  /// With the group [g] in or out; sorts on a column that went are dropped.
  ReportPlan toggleGroup(String g) {
    final next = groupBy.contains(g) ? [...groupBy.where((x) => x != g)] : [...groupBy, g];
    return _keepSorts(copyWith(groupBy: next));
  }

  /// With the figure [m] in or out.
  ReportPlan toggleMeasure(ReportMeasure m) {
    final next = measures.contains(m) ? [...measures.where((x) => x != m)] : [...measures, m];
    return _keepSorts(copyWith(measures: next));
  }

  static ReportPlan _keepSorts(ReportPlan p) {
    final cols = {...p.groupBy.map(groupColumn), ...p.measures.map((m) => m.column), ...p.columns};
    return p.copyWith(sort: [for (final s in p.sort) if (cols.contains(s.field)) s]);
  }
}

const _opWords = {
  'eq': 'is',
  'neq': 'is not',
  'in': 'is one of',
  'not_in': 'is none of',
  'contains': 'contains',
  'gt': 'is more than',
  'gte': 'is at least',
  'lt': 'is less than',
  'lte': 'is at most',
  'between': 'is between',
  'is_null': 'is empty',
  'not_null': 'is filled in',
};

const _aggWords = {
  'count': 'Count of',
  'count_distinct': 'Different',
  'sum': 'Total',
  'avg': 'Average',
  'min': 'Lowest',
  'max': 'Highest',
};

const _bucketWords = {'day': 'by day', 'week': 'by week', 'month': 'by month', 'year': 'by year'};

String _lowerFirst(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

/// The label of a field, a date group or a figure in [ds].
String fieldWords(ReportDataset? ds, String id) {
  if (id == '*') return 'Rows';
  final i = id.indexOf(':');
  final f = i < 0 ? id : id.substring(0, i);
  final label = ds?.field(f)?.label ?? f;
  return i < 0 ? label : '$label, ${_bucketWords[id.substring(i + 1)] ?? id.substring(i + 1)}';
}

String measureWords(ReportDataset? ds, ReportMeasure m) =>
    m.field == '*' ? 'Count' : '${_aggWords[m.agg] ?? m.agg} ${_lowerFirst(fieldWords(ds, m.field))}';

String _valueWords(Object? v) {
  if (v is List) return v.map((x) => '$x').join(', ');
  final d = parseIsoDay(v);
  return d != null ? shortDay(d) : '$v';
}

/// "What the AI understood": the plan line by line.
List<(String, String)> describeReportPlan(
  ReportPlan plan,
  ReportCatalogue catalogue, {
  ({DateTime from, DateTime to})? resolved,
  List<ReportColumn> columns = const [],
}) {
  final ds = catalogue.dataset(plan.dataset);
  final period = plan.period;
  final lines = <(String, String)>[('Data', ds?.label ?? plan.dataset)];
  final days = resolved == null || period?.preset == null
      ? ''
      : ' (${resolved.from == resolved.to ? shortDay(resolved.from) : '${shortDay(resolved.from)} to ${shortDay(resolved.to)}'})';
  final by = period == null ? '' : ', by ${_lowerFirst(fieldWords(ds, period.field ?? ds?.time ?? ''))}';
  lines.add(('Period', '${periodWords(period)}$days$by (Malaysia time)'));
  if (plan.filters.isNotEmpty) {
    lines.add((
      'Only',
      plan.filters
          .map((f) => '${fieldWords(ds, f.field)} ${_opWords[f.op] ?? f.op}${f.value == null ? '' : ' ${_valueWords(f.value)}'}')
          .join('; '),
    ));
  }
  if (plan.groupBy.isNotEmpty) lines.add(('Group by', plan.groupBy.map((g) => fieldWords(ds, g)).join(', ')));
  if (plan.measures.isNotEmpty) {
    lines.add(('Columns', plan.measures.map((m) => measureWords(ds, m)).join(', ')));
  } else if (plan.columns.isNotEmpty) {
    lines.add(('Columns', plan.columns.map((c) => fieldWords(ds, c)).join(', ')));
  }
  if (plan.sort.isNotEmpty) {
    String label(String id) {
      for (final c in columns) {
        if (c.id == id) return c.label;
      }
      for (final m in plan.measures) {
        if (m.column == id) return measureWords(ds, m);
      }
      for (final g in plan.groupBy) {
        if (ReportPlan.groupColumn(g) == id) return fieldWords(ds, g);
      }
      return fieldWords(ds, id);
    }

    lines.add((
      'Sort',
      plan.sort.map((s) => '${label(s.field)}, ${s.descending ? 'highest first' : 'lowest first'}').join('; '),
    ));
  }
  if (plan.limit != null) lines.add(('Rows', 'The first ${plan.limit}'));
  if (ds != null && ds.hidden.isNotEmpty) lines.add(('Hidden', 'Not in this report: ${ds.hidden.join(', ')}'));
  return lines;
}

// ---- A result ----------------------------------------------------------------------------------

class ReportColumn {
  const ReportColumn({required this.id, required this.label, required this.type, required this.role, this.field, this.agg, this.bucket});

  factory ReportColumn.fromJson(Object? json) {
    final m = _map(json);
    return ReportColumn(
      id: '${m['id'] ?? ''}',
      label: '${m['label'] ?? m['id'] ?? ''}',
      type: '${m['type'] ?? 'text'}',
      role: '${m['role'] ?? 'column'}',
      field: m['field'] as String?,
      agg: m['agg'] as String?,
      bucket: m['bucket'] as String?,
    );
  }

  final String id;
  final String label;
  final String type;

  /// group, measure or column.
  final String role;
  final String? field;
  final String? agg;
  final String? bucket;

  bool get isNumber => type == 'number';
  bool get isMeasure => role == 'measure';
}

class ReportResult {
  const ReportResult({
    required this.datasetLabel,
    required this.columns,
    required this.rows,
    required this.plan,
    this.totals,
    this.rowCount = 0,
    this.truncated = false,
    this.maxRows = 50000,
    this.period,
    this.hidden = const [],
    this.limited = false,
  });

  factory ReportResult.fromJson(Object? json) {
    final m = _map(json);
    final p = _map(m['period']);
    final from = parseIsoDay(p['from']), to = parseIsoDay(p['to']);
    return ReportResult(
      datasetLabel: '${m['dataset_label'] ?? m['dataset'] ?? ''}',
      columns: [for (final c in (m['columns'] as List?) ?? const []) ReportColumn.fromJson(c)],
      rows: [
        for (final r in (m['rows'] as List?) ?? const [])
          if (r is List) List<Object?>.from(r),
      ],
      totals: m['totals'] is List ? List<Object?>.from(m['totals'] as List) : null,
      rowCount: (m['row_count'] as num?)?.toInt() ?? 0,
      truncated: m['truncated'] == true,
      maxRows: (m['max_rows'] as num?)?.toInt() ?? 50000,
      period: from != null && to != null ? (from: from, to: to) : null,
      hidden: _strings(m['hidden']),
      limited: m['limited'] == true,
      plan: ReportPlan.fromJson(m['plan']),
    );
  }

  final String datasetLabel;
  final List<ReportColumn> columns;
  final List<List<Object?>> rows;

  /// The figures over everything the report covers, one per measure.
  final List<Object?>? totals;
  final int rowCount;
  final bool truncated;
  final int maxRows;
  final ({DateTime from, DateTime to})? period;
  final List<String> hidden;
  final bool limited;

  /// The plan as the server checked it.
  final ReportPlan plan;

  /// "Total", blanks under the groups, then the figures; null with no figures.
  List<Object?>? get totalRow {
    final t = totals;
    if (t == null) return null;
    final measures = columns.where((c) => c.isMeasure).length;
    final groups = columns.length - measures;
    return [for (var i = 0; i < groups; i++) i == 0 ? 'Total' : '', ...t.take(measures)];
  }

  /// One figure by the groups, as drawn: null when there is nothing to draw.
  List<({String label, double value})>? chartBars({int max = 12}) {
    final groups = [for (final (i, c) in columns.indexed) if (c.role == 'group') i];
    final mi = columns.indexWhere((c) => c.isMeasure && c.isNumber);
    if (groups.isEmpty || mi < 0 || rows.isEmpty) return null;
    final bars = [
      for (final r in rows.take(max))
        (label: groups.map((i) => '${r[i] ?? '—'}').join(' · '), value: (r[mi] is num ? (r[mi] as num).toDouble() : double.tryParse('${r[mi]}') ?? 0)),
    ];
    return bars.every((b) => b.value <= 0) ? null : bars;
  }
}

/// A cell as shown: "1,234.50", "Yes", the text.
String reportCellText(Object? v, String type) {
  if (v == null) return '';
  if (v is bool) return v ? 'Yes' : 'No';
  if (type == 'number') {
    final n = v is num ? v : num.tryParse('$v');
    if (n != null) return _grouped(n);
  }
  return '$v';
}

String _grouped(num n) {
  final whole = n == n.roundToDouble();
  final s = whole ? n.round().abs().toString() : n.abs().toStringAsFixed(2);
  final dot = s.indexOf('.');
  final intPart = dot < 0 ? s : s.substring(0, dot);
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  return '${n < 0 ? '-' : ''}$buf${dot < 0 ? '' : s.substring(dot)}';
}

// ---- CSV ---------------------------------------------------------------------------------------

/// One CSV cell: quotes doubled, quoted when it holds a comma, a quote, a
/// new line or edge spaces; text a spreadsheet would run as a formula gets a
/// leading '.
String csvCell(Object? v) {
  if (v == null) return '';
  if (v is num || v is bool) return '$v';
  var s = '$v';
  if (RegExp(r'^[=+\-@\t\r]').hasMatch(s)) s = "'$s";
  return RegExp(r'[",\r\n]|^\s|\s$').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// The report as CSV: UTF-8 with a BOM (so Excel reads accents), the labels,
/// the rows and the total row.
String reportCsv(ReportResult r) {
  final lines = [r.columns.map((c) => csvCell(c.label)).join(',')];
  for (final row in r.rows) {
    lines.add(row.map(csvCell).join(','));
  }
  final total = r.totalRow;
  if (total != null) lines.add(total.map(csvCell).join(','));
  return '\u{FEFF}${lines.join('\r\n')}\r\n';
}

/// "weekly-commission-2026-10-12-to-2026-10-18".
String reportFileBase(String name, ({DateTime from, DateTime to})? period) {
  var slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 60) slug = slug.substring(0, 60);
  if (slug.isEmpty) slug = 'report';
  return period == null ? '$slug-all-time' : '$slug-${isoDay(period.from)}-to-${isoDay(period.to)}';
}

// ---- Email schedules ---------------------------------------------------------------------------

enum ScheduleFrequency { daily, weekly, monthly }

/// When a schedule sends, Malaysia time.
class ScheduleTiming {
  const ScheduleTiming({
    required this.frequency,
    required this.hour,
    required this.minute,
    this.weekdays = const {1},
    this.monthDay = 1,
  });

  final ScheduleFrequency frequency;
  final int hour;
  final int minute;

  /// ISO weekdays, Monday 1 to Sunday 7.
  final Set<int> weekdays;

  /// 1 to 28, or -1 for the last day of the month.
  final int monthDay;

  static const lastDay = -1;

  /// "08:00:00", as the database keeps it.
  String get atTime => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00';
}

/// The next send strictly after [after] (as `ai_report_next_run`), in UTC.
DateTime? nextScheduleRun(ScheduleTiming t, DateTime after) {
  final a = after.toUtc();
  final start = malaysiaDay(a);
  for (var i = 0; i <= 62; i++) {
    final d = DateTime(start.year, start.month, start.day + i);
    final at = DateTime.utc(d.year, d.month, d.day, t.hour, t.minute).subtract(_myt);
    if (!at.isAfter(a)) continue;
    final ok = switch (t.frequency) {
      ScheduleFrequency.daily => true,
      ScheduleFrequency.weekly => t.weekdays.contains(d.weekday),
      ScheduleFrequency.monthly =>
        t.monthDay == ScheduleTiming.lastDay ? DateTime(d.year, d.month, d.day + 1).day == 1 : d.day == t.monthDay,
    };
    if (ok) return at;
  }
  return null;
}

const weekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// "Every Monday and Wednesday at 08:00", "Every month on the last day at 07:30".
String scheduleWords(ScheduleTiming t) {
  final at = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  switch (t.frequency) {
    case ScheduleFrequency.daily:
      return 'Every day at $at';
    case ScheduleFrequency.weekly:
      final days = [for (var d = 1; d <= 7; d++) if (t.weekdays.contains(d)) weekdayNames[d - 1]];
      final list = days.length <= 1 ? days.join() : '${days.sublist(0, days.length - 1).join(', ')} and ${days.last}';
      return 'Every $list at $at';
    case ScheduleFrequency.monthly:
      return t.monthDay == ScheduleTiming.lastDay
          ? 'Every month on the last day at $at'
          : 'Every month on day ${t.monthDay} at $at';
  }
}

/// What each run covers.
const schedulePeriods = <String, String>{
  'previous_day': 'The day before',
  'previous_week': 'The week before (Monday to Sunday)',
  'previous_month': 'The month before',
  'month_to_date': 'This month so far',
  'last_n_days': 'The last N whole days',
};

/// The schedule's emails can carry these files.
const scheduleFormats = <String, String>{'csv': 'CSV', 'xlsx': 'Excel (.xlsx)', 'pdf': 'PDF'};

final _email = RegExp(r'^[^@\s<>(),;:"]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$');

/// The addresses typed (comma, space or new line between), and the ones
/// that aren't email addresses.
({List<String> ok, List<String> bad}) parseEmails(String text) {
  final ok = <String>[], bad = <String>[];
  for (final raw in text.split(RegExp(r'[\s,;]+'))) {
    final e = raw.trim();
    if (e.isEmpty) continue;
    if (_email.hasMatch(e) && e.length <= 254) {
      if (!ok.contains(e.toLowerCase())) ok.add(e.toLowerCase());
    } else {
      bad.add(e);
    }
  }
  return (ok: ok, bad: bad);
}

/// {report}, {period} and {rows} filled in, as the email does.
String fillReportPlaceholders(String template, {required String report, required String period, required int rows}) =>
    template.replaceAll('{report}', report).replaceAll('{period}', period).replaceAll('{rows}', _grouped(rows));

/// A saved report.
class SavedReport {
  const SavedReport({required this.id, required this.name, required this.plan, this.request, this.lastRunAt, this.lastRows});

  factory SavedReport.fromJson(Object? json) {
    final m = _map(json);
    return SavedReport(
      id: '${m['id']}',
      name: '${m['name'] ?? ''}',
      plan: ReportPlan.fromJson(m['plan']),
      request: m['request'] as String?,
      lastRunAt: DateTime.tryParse('${m['last_run_at'] ?? ''}'),
      lastRows: (m['last_rows'] as num?)?.toInt(),
    );
  }

  final String id;
  final String name;
  final ReportPlan plan;
  final String? request;
  final DateTime? lastRunAt;
  final int? lastRows;
}

/// An email schedule, as kept in `ai_report_schedules`.
class ReportSchedule {
  const ReportSchedule({
    required this.id,
    required this.savedId,
    required this.timing,
    required this.period,
    this.emails = const [],
    this.adminIds = const [],
    this.formats = const ['csv'],
    this.linkOnly = false,
    this.subject = '{report} for {period}',
    this.message = '',
    this.skipEmpty = false,
    this.paused = false,
    this.nextRunAt,
    this.lastRunAt,
    this.lastStatus,
    this.lastError,
  });

  factory ReportSchedule.fromJson(Object? json) {
    final m = _map(json);
    final at = '${m['at_time'] ?? '08:00'}'.split(':');
    return ReportSchedule(
      id: '${m['id']}',
      savedId: '${m['saved_id']}',
      timing: ScheduleTiming(
        frequency: ScheduleFrequency.values.firstWhere((f) => f.name == m['frequency'], orElse: () => ScheduleFrequency.daily),
        hour: int.tryParse(at.first) ?? 8,
        minute: at.length > 1 ? int.tryParse(at[1]) ?? 0 : 0,
        weekdays: {for (final d in (m['weekdays'] as List?) ?? const [1]) (d as num).toInt()},
        monthDay: (m['month_day'] as num?)?.toInt() ?? 1,
      ),
      period: ReportPeriod.fromJson(m['period']) ?? const ReportPeriod.preset('previous_day'),
      emails: _strings(m['emails']),
      adminIds: _strings(m['admin_ids']),
      formats: _strings(m['formats']),
      linkOnly: m['link_only'] == true,
      subject: '${m['subject'] ?? '{report} for {period}'}',
      message: '${m['message'] ?? ''}',
      skipEmpty: m['skip_empty'] == true,
      paused: m['paused'] == true,
      nextRunAt: DateTime.tryParse('${m['next_run_at'] ?? ''}'),
      lastRunAt: DateTime.tryParse('${m['last_run_at'] ?? ''}'),
      lastStatus: m['last_status'] as String?,
      lastError: m['last_error'] as String?,
    );
  }

  final String id;
  final String savedId;
  final ScheduleTiming timing;
  final ReportPeriod period;
  final List<String> emails;
  final List<String> adminIds;
  final List<String> formats;
  final bool linkOnly;
  final String subject;
  final String message;
  final bool skipEmpty;
  final bool paused;
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;
  final String? lastStatus;
  final String? lastError;

  /// The row to write (the server keeps who made it, the next run and the rest).
  Map<String, dynamic> toRow() => {
    'saved_id': savedId,
    'frequency': timing.frequency.name,
    'at_time': timing.atTime,
    'weekdays': (timing.weekdays.toList()..sort()),
    'month_day': timing.monthDay,
    'period': period.toJson(),
    'emails': emails,
    'admin_ids': adminIds,
    'formats': formats,
    'link_only': linkOnly,
    'subject': subject,
    'message': message,
    'skip_empty': skipEmpty,
    'paused': paused,
  };
}
