import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart';
import '../../widgets/admin_widgets.dart';
import 'fraud_detection.dart';
import 'security_data.dart';
import 'session_logic.dart' show rowsToCsv;

const _page = 'admin-trace-fraud';

class _Scan {
  const _Scan(this.findings, this.directory, this.at);
  final List<FraudFinding> findings;
  final Map<String, SuspectInfo> directory;
  final DateTime at;
}

final _scanProvider = FutureProvider.autoDispose((ref) async {
  final repo = ref.watch(securityRepositoryProvider);
  final findings = await repo.fraudScan();
  return _Scan(findings, await repo.suspectDirectory(findings), DateTime.now());
});

IconData _iconFor(FraudCategory c) => switch (c) {
      FraudCategory.multiDeviceAccount => Icons.smartphone,
      FraudCategory.sharedDevice => Icons.group,
      FraudCategory.ipCluster => Icons.public,
      FraudCategory.locationMismatch => Icons.wrong_location,
      FraudCategory.implausibleTrip => Icons.speed,
      FraudCategory.collusionPair => Icons.repeat,
      FraudCategory.excessiveCancellations => Icons.cancel_outlined,
      FraudCategory.promotionAbuse => Icons.card_giftcard,
    };

Color _colorFor(FraudSeverity s) => switch (s) {
      FraudSeverity.high => Colors.red,
      FraudSeverity.medium => Colors.orange,
      FraudSeverity.low => Colors.blueGrey,
    };

class AdminTraceFraudScreen extends ConsumerStatefulWidget {
  const AdminTraceFraudScreen({super.key});

  @override
  ConsumerState<AdminTraceFraudScreen> createState() => _TraceFraudState();
}

class _TraceFraudState extends ConsumerState<AdminTraceFraudScreen> {
  String _query = '';
  FraudSeverity? _severity;
  FraudCategory? _category;

  List<FraudFinding> _filter(_Scan scan) => scan.findings.where((f) {
        if (_severity != null && f.severity != _severity) return false;
        if (_category != null && f.category != _category) return false;
        return matchesFindingQuery(f, _query, suspectsFor(f, scan.directory));
      }).toList();

  Future<void> _export(_Scan scan) async {
    final rows = _filter(scan);
    if (rows.isEmpty) {
      showInfo(context, 'No findings match the current filters.');
      return;
    }
    final csv = rowsToCsv([
      for (final f in rows)
        () {
          final suspects = suspectsFor(f, scan.directory);
          return <String, dynamic>{
            'category': f.category.label,
            'severity': f.severity.name,
            'title': f.title,
            'description': f.description,
            'suspectNames': suspects.map((s) => s.name ?? 'Unknown').join(' | '),
            'suspectPhones': suspects.map((s) => s.phone ?? '').join(' | '),
            'subjects': f.subjects.join(' | '),
            'evidence': evidenceText(f.evidence),
          };
        }(),
    ], ['category', 'severity', 'title', 'description', 'suspectNames', 'suspectPhones', 'subjects', 'evidence']);
    await exportCsv(context, 'fraud-findings-${DateTime.now().millisecondsSinceEpoch}.csv', csv);
  }

  void _showEvidence(FraudFinding f, List<SuspectInfo> suspects) => showAdminSheet(
        context,
        title: f.title,
        builder: (_) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(f.description),
          const SizedBox(height: 12),
          DetailTable({
            'Category': f.category.label,
            'Severity': f.severity.name,
            if (suspects.isNotEmpty)
              'Suspects': suspects.map((s) => [s.name ?? 'Unknown', ?s.phone].join(' · ')).join('\n'),
            'Subjects': f.subjects.join('\n'),
            for (final e in f.evidence.entries) e.key: e.value is List ? (e.value as List).join(', ') : e.value,
          }),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(_scanProvider);
    return AdminPage(
      title: 'Trace fraud',
      page: _page,
      actions: [
        IconButton(
          tooltip: 'Export findings (CSV)',
          icon: const Icon(Icons.download),
          onPressed: scan.value == null ? null : () => _export(scan.value!),
        ),
        IconButton(tooltip: 'Re-scan', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(_scanProvider)),
      ],
      body: AsyncView(
        value: scan,
        onRetry: () => ref.invalidate(_scanProvider),
        data: (s) {
          final counts = {for (final v in FraudSeverity.values) v: s.findings.where((f) => f.severity == v).length};
          final categories = {for (final f in s.findings) f.category}.toList();
          final visible = _filter(s);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(_scanProvider),
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
              Text('${s.findings.length} findings · scanned ${dateText(s.at.toIso8601String())}',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in FraudSeverity.values.reversed)
                  Chip(
                    avatar: CircleAvatar(backgroundColor: _colorFor(v), radius: 6),
                    label: Text('${counts[v]} ${v.name}'),
                  ),
              ]),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: 'Search findings, names, phones…', isDense: true),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final v in <FraudSeverity?>[null, FraudSeverity.high, FraudSeverity.medium, FraudSeverity.low])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(v?.name ?? 'all'),
                        selected: _severity == v,
                        onSelected: (_) => setState(() => _severity = v),
                      ),
                    ),
                ]),
              ),
              if (categories.length > 1)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    for (final c in <FraudCategory?>[null, ...categories])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(c?.label ?? 'All categories'),
                          selected: _category == c,
                          onSelected: (_) => setState(() => _category = c),
                        ),
                      ),
                  ]),
                ),
              const SizedBox(height: 8),
              if (visible.isEmpty)
                EmptyState(
                  icon: Icons.verified_user_outlined,
                  title: s.findings.isEmpty ? 'No suspicious activity found' : 'No findings match the filters',
                  message: s.findings.isEmpty ? 'The latest sessions, rides and wallet activity look clean.' : null,
                ),
              for (final f in visible) _findingCard(f, suspectsFor(f, s.directory)),
            ]),
          );
        },
      ),
    );
  }

  Widget _findingCard(FraudFinding f, List<SuspectInfo> suspects) {
    final color = _colorFor(f.severity);
    return Card(
      child: InkWell(
        onTap: () => _showEvidence(f, suspects),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(_iconFor(f.category), color: color, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(f.title, style: Theme.of(context).textTheme.titleSmall),
                  Text(f.category.label, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
                child: Text(f.severity.name, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(f.description),
            if (suspects.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final s in suspects)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.person_outline, size: 16),
                    label: Text([s.name ?? 'Unknown', ?s.phone].join(' · ')),
                  ),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}
