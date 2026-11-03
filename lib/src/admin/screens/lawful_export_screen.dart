// Admin -> Security & integrations -> Lawful-request export (migration 0338).
//
// Answers a valid authority request (police / MCMC / court order) by EXPORTING
// the data get.ride ALREADY lawfully holds about one user. It is read-only: it
// adds no tracking and changes nothing in the subject's data. Full admins only
// (the server enforces it); every export is logged in the register below and
// in the admin audit log.
//
// On screen any ID number is masked to its last 4 — the full number is in the
// downloaded / copied document only, which is the lawful disclosure.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/lawful_export_repository.dart';
import '../../platform/web_download.dart';
import '../../widgets/common.dart';
import '../../widgets/search_select.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';

const _page = 'admin-lawful-export';

/// Shows the last 4 of an ID / phone-like value, the rest masked. Empty when
/// there is nothing to show.
String maskTail(Object? value) {
  final s = '${value ?? ''}'.trim();
  if (s.isEmpty) return '';
  if (s.length <= 4) return '••$s';
  return '${'•' * (s.length - 4)}${s.substring(s.length - 4)}';
}

class LawfulExportScreen extends ConsumerStatefulWidget {
  const LawfulExportScreen({super.key});

  @override
  ConsumerState<LawfulExportScreen> createState() => _LawfulExportState();
}

class _LawfulExportState extends ConsumerState<LawfulExportScreen> {
  final _form = GlobalKey<FormState>();
  final _agency = TextEditingController();
  final _officer = TextEditingController();
  final _reference = TextEditingController();
  final _legalBasis = TextEditingController();
  final _notes = TextEditingController();

  String? _subjectId;
  bool _busy = false;
  Map<String, dynamic>? _doc;

  @override
  void dispose() {
    _agency.dispose();
    _officer.dispose();
    _reference.dispose();
    _legalBasis.dispose();
    _notes.dispose();
    super.dispose();
  }

  String get _prettyJson => const JsonEncoder.withIndent('  ').convert(_doc ?? const {});

  String get _fileName {
    final ref = _reference.text.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    final raw = (_subjectId ?? 'subject').replaceAll('-', '');
    final subj = raw.length >= 8 ? raw.substring(0, 8) : raw;
    return 'lawful-export-${ref.isEmpty ? 'request' : ref}-$subj.json';
  }

  Future<void> _generate() async {
    if (!(_form.currentState?.validate() ?? false) || _subjectId == null) return;
    setState(() => _busy = true);
    try {
      final doc = await ref.read(lawfulExportRepositoryProvider).export(
        subjectId: _subjectId!,
        agency: _agency.text.trim(),
        officer: _officer.text.trim().isEmpty ? null : _officer.text.trim(),
        reference: _reference.text.trim(),
        legalBasis: _legalBasis.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );
      if (!mounted) return;
      setState(() => _doc = doc);
      ref.invalidate(lawfulRequestsProvider);
      showInfo(context, 'Export generated and logged. Use Copy or Download to hand it over.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _prettyJson));
    if (mounted) showInfo(context, 'The full export document was copied to the clipboard.');
  }

  Future<void> _download() async {
    final bytes = Uint8List.fromList(utf8.encode(_prettyJson));
    try {
      if (kIsWeb) {
        final ok = webDownload(bytes, fileName: _fileName, mimeType: 'application/json');
        if (mounted) {
          ok ? showInfo(context, 'Downloaded $_fileName.') : showError(context, 'The download could not start.');
        }
        return;
      }
      await SharePlus.instance.share(
        ShareParams(files: [XFile.fromData(bytes, mimeType: 'application/json', name: _fileName)],
          fileNameOverrides: [_fileName]),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFullAdmin = ref.watch(adminAccessProvider).value?.isFullAdmin ?? false;
    return AdminPage(
      title: 'Lawful-request export',
      page: _page,
      body: isFullAdmin ? _body(context) : _fullAdminsOnly(context),
    );
  }

  Widget _fullAdminsOnly(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        'Only a full admin can make a lawful-request export. It discloses a whole '
        'account, so it is not a sub-admin action.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    final candidates = ref.watch(lawfulExportCandidatesProvider).value ?? const <LawfulSubject>[];
    final subjectItems = [
      for (final c in candidates) DropdownMenuItem(value: c.id, child: Text(c.label, overflow: TextOverflow.ellipsis)),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('New export', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Discloses only the data already held about the chosen account, on a valid request. '
                    'Read-only; every export is logged.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  SearchableDropdownFormField<String>(
                    items: subjectItems,
                    initialValue: _subjectId,
                    isExpanded: true,
                    hint: const Text('Pick the account (search by name, phone or code)'),
                    decoration: const InputDecoration(labelText: 'Subject account', border: OutlineInputBorder()),
                    validator: (v) => v == null ? 'Pick the account the request is about.' : null,
                    onChanged: (v) => setState(() => _subjectId = v),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _agency,
                    decoration: const InputDecoration(
                      labelText: 'Agency', hintText: 'e.g. PDRM, MCMC', border: OutlineInputBorder()),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'The agency is required.' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _officer,
                    decoration: const InputDecoration(
                      labelText: 'Officer (optional)', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _reference,
                    decoration: const InputDecoration(
                      labelText: 'Reference', hintText: 'Case / warrant / report number', border: OutlineInputBorder()),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'A reference is required.' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _legalBasis,
                    decoration: const InputDecoration(
                      labelText: 'Legal basis', hintText: 'e.g. Court order, CPC s.116', border: OutlineInputBorder()),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'The legal basis is required.' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _notes,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Notes (optional)', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _generate,
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.description_outlined),
                    label: const Text('Generate export'),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_doc != null) ...[const SizedBox(height: 16), _result(context)],
        const SizedBox(height: 16),
        _register(context),
      ],
    );
  }

  Widget _result(BuildContext context) {
    final doc = _doc!;
    final account = (doc['account'] as Map?)?.cast<String, dynamic>() ?? const {};
    final trips = (doc['trips'] as Map?)?['total'];
    final payments = (doc['payments'] as Map?)?['total'];
    final locations = (doc['location_history'] as Map?)?['total'];
    final sessions = (doc['sessions'] as Map?)?['total'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Export document', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DetailTable({
              'Name': '${account['name'] ?? '-'}',
              'Account code': '${account['display_id'] ?? '-'}',
              // Masked on screen; the full number is in the downloaded document.
              'ID number': maskTail(account['id_number']).isEmpty ? '-' : maskTail(account['id_number']),
              'Phone': '${account['phone'] ?? '-'}',
              'Trips': '${trips ?? 0}',
              'Payments': '${payments ?? 0}',
              'Location fixes': '${locations ?? 0}',
              'Sessions': '${sessions ?? 0}',
            }),
            const SizedBox(height: 8),
            Text(
              'The ID number is masked here. The downloaded document carries the full number — '
              'that is the lawful disclosure.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _copy, icon: const Icon(Icons.copy_all_outlined), label: const Text('Copy JSON')),
                FilledButton.icon(
                  onPressed: _download, icon: const Icon(Icons.download_outlined), label: const Text('Download JSON')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _register(BuildContext context) {
    final requests = ref.watch(lawfulRequestsProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Past requests', style: Theme.of(context).textTheme.titleMedium)),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () => ref.invalidate(lawfulRequestsProvider),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 4),
            requests.when(
              loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
              error: (_, _) => const Text('The register could not be read.'),
              data: (rows) => rows.isEmpty
                  ? Text('No lawful requests recorded yet.',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
                  : Column(
                      children: [
                        for (final r in rows)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${r.agency} · ${r.reference}'),
                            subtitle: Text([
                              r.legalBasis,
                              if ((r.subjectName ?? '').isNotEmpty) 'Subject: ${r.subjectName}'
                              else if ((r.subjectDisplayId ?? '').isNotEmpty) 'Subject: ${r.subjectDisplayId}',
                              if (r.officer != null) 'Officer: ${r.officer}',
                              if (r.exportedAt != null) 'Exported ${r.exportedAt}',
                            ].where((e) => e.trim().isNotEmpty).join('  ·  ')),
                            isThreeLine: true,
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
