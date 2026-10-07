import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../../widgets/in_app_page.dart';

final adminDocsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, table) => ref.watch(adminRepositoryProvider).documents(table),
);

/// Expiry wins over a non-rejected status (Expo `computeDisplayStatus`).
String documentDisplayStatus(Map<String, dynamic> d, {DateTime? now}) {
  final status = (d['status'] as String?) ?? 'Pending Review';
  final exp = DateTime.tryParse('${d['expiry_date'] ?? ''}');
  if (exp != null && exp.isBefore(now ?? DateTime.now()) && status != 'Rejected') return 'Expired';
  return status;
}

const _docFilters = {
  'Pending Review': 'To review',
  'Approved': 'Approved',
  'Rejected': 'Rejected',
  'Expired': 'Expired',
  'all': 'All',
};

class AdminDocumentsScreen extends ConsumerStatefulWidget {
  const AdminDocumentsScreen({super.key, this.vehicle = false});
  final bool vehicle;

  @override
  ConsumerState<AdminDocumentsScreen> createState() => _AdminDocumentsScreenState();
}

class _AdminDocumentsScreenState extends ConsumerState<AdminDocumentsScreen> {
  late bool _vehicle = widget.vehicle;
  String _filter = 'Pending Review';
  String _query = '';

  String get _table => _vehicle ? 'vehicle_documents' : 'provider_documents';

  void _open(Map<String, dynamic> d) {
    final canEdit = ref.read(moduleAccessProvider('documents')) == AccessLevel.edit;
    final notes = TextEditingController(text: d['reviewer_notes'] as String?);
    final ai = d['ai_verification'];
    showAdminSheet<void>(
      context,
      title: (d['doc_name'] as String?) ?? 'Document',
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [StatusChip(documentDisplayStatus(d))]),
        const SizedBox(height: 12),
        DetailTable({
          'Document number': d['document_number'],
          'Detected as': d['detected_document_name'],
          'Issuing country': d['issuance_country'],
          'Insurance provider': d['insurance_provider_name'],
          'Start': d['start_date'],
          'Expiry': d['expiry_date'],
          'PWD': d['is_pwd'] == true ? 'Yes' : null,
          'Partner ID': d['partner_id'],
          if (_vehicle) 'Vehicle ID': d['vehicle_id'],
          'AI verified': d['ai_verified'] == null ? null : (d['ai_verified'] == true ? 'Yes' : 'No'),
          'Uploaded': dateText(d['uploaded_at']),
          'Reviewed': dateText(d['reviewed_at']),
        }),
        Wrap(spacing: 8, children: [
          for (final (label, key) in [('View front', 'file_url'), ('View back', 'file_url_back')])
            if ((d[key] as String?)?.startsWith('http') == true)
              OutlinedButton.icon(
                icon: const Icon(Icons.visibility_outlined),
                label: Text(label),
                onPressed: () => openInApp(context, d[key] as String),
              ),
        ]),
        if (ai != null) ...[
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('AI verification details'),
            children: [SelectableText(const JsonEncoder.withIndent('  ').convert(ai))],
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: notes,
          enabled: canEdit,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Reviewer notes (shown to the partner)'),
        ),
        const SizedBox(height: 12),
        if (canEdit)
          Row(children: [
            Expanded(
              child: BusyButton.outlined(
                icon: const Icon(Icons.close),
                child: const Text('Reject'),
                onPressed: () => _review(ctx, d, 'Rejected', notes.text),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: BusyButton.filled(
                icon: const Icon(Icons.check),
                child: const Text('Approve'),

                onPressed: () => _review(ctx, d, 'Approved', notes.text),
              ),
            ),
          ]),
      ]),
    );
  }

  Future<void> _review(BuildContext ctx, Map<String, dynamic> d, String status, String notes) async {
    if (status == 'Rejected' && notes.trim().isEmpty) {
      showInfo(ctx, 'Add a note telling the partner why the document was rejected.');
      return;
    }
    final ok = await runAdminAction(
      ctx,
      () => ref.read(adminRepositoryProvider).reviewDocument(
            _table,
            d['id'] as String,
            status,
            notes.trim().isEmpty ? null : notes.trim(),
          ),
      success: 'Document ${status.toLowerCase()}',
    );
    if (ok) {
      ref.invalidate(adminDocsProvider(_table));
      if (ctx.mounted) Navigator.pop(ctx);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      title: 'Documents',
      module: 'documents',
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Partner documents'), icon: Icon(Icons.badge_outlined)),
              ButtonSegment(value: true, label: Text('Vehicle documents'), icon: Icon(Icons.directions_car_outlined)),
            ],
            selected: {_vehicle},
            onSelectionChanged: (v) => setState(() => _vehicle = v.first),
          ),
        ),
        FilterBar(
          filters: _docFilters,
          selected: _filter,
          onSelected: (f) => setState(() => _filter = f),
          onSearch: (q) => setState(() => _query = q),
          hint: 'Search document name or number…',
        ),
        Expanded(
          child: AsyncView(
            value: ref.watch(adminDocsProvider(_table)),
            onRetry: () => ref.invalidate(adminDocsProvider(_table)),
            data: (docs) {
              final q = _query.trim().toLowerCase();
              final list = docs.where((d) {
                if (_filter != 'all' && documentDisplayStatus(d) != _filter) return false;
                if (q.isEmpty) return true;
                return '${d['doc_name']} ${d['document_number']}'.toLowerCase().contains(q);
              }).toList();
              if (list.isEmpty) return const EmptyState(icon: Icons.task_alt, title: 'Nothing to show');
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final d = list[i];
                  return ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text((d['doc_name'] as String?) ?? 'Document'),
                    subtitle: Text([
                      d['document_number'],
                      if (d['expiry_date'] != null) 'expires ${d['expiry_date']}',
                      dateText(d['uploaded_at']),
                    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ')),
                    trailing: StatusChip(documentDisplayStatus(d)),
                    onTap: () => _open(d),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
