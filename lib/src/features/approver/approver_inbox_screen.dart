import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/approver_inbox_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/offline_strip.dart';
import '../../widgets/page_style_host.dart';

/// Side menu → Approvals: the documents waiting for review in this approver's
/// scope (migrations 0349/0350). Read only in this phase — tapping a row opens
/// the uploaded image(s); approve / reject / upload / delete come next.
class ApproverInboxScreen extends ConsumerWidget {
  const ApproverInboxScreen({super.key});

  static IconData iconFor(String source) => switch (source) {
        'partner' => Icons.badge_outlined,
        'vehicle' => Icons.directions_car_outlined,
        'identity' => Icons.credit_card_outlined,
        _ => Icons.description_outlined,
      };

  static String sourceLabel(String source) => switch (source) {
        'partner' => 'Partner registration',
        'vehicle' => 'Vehicle document',
        'identity' => 'User ID',
        _ => 'Document',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(approverPendingProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Approvals')),
      body: OfflineStrip.over(AsyncView<List<ApproverDoc>>(
        value: value,
        onRetry: () => ref.invalidate(approverPendingProvider),
        data: (docs) => docs.isEmpty
            ? const EmptyState(
                icon: Icons.fact_check_outlined,
                title: 'Nothing to review',
                message: 'Documents waiting for your review appear here, within the scope your admin set.',
              )
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(approverPendingProvider),
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: docs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final cs = Theme.of(context).colorScheme;
                    return ResponsiveCenter(
                      maxWidth: 760,
                      child: ListTile(
                        key: ValueKey('approver-doc-${d.id}'),
                        leading: CircleAvatar(
                          backgroundColor: cs.surfaceContainerHighest,
                          foregroundColor: cs.onSurfaceVariant,
                          child: Icon(iconFor(d.source)),
                        ),
                        title: Text(d.docLabel, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${d.ownerName} · ${sourceLabel(d.source)}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openDocument(context, d),
                      ),
                    );
                  },
                ),
              ),
      )),
    );
  }

  Future<void> _openDocument(BuildContext context, ApproverDoc d) => showAppDialog<void>(
        id: 'approver.document',
        context: context,
        builder: (c) => _DocumentViewer(doc: d),
      );
}

/// The uploaded image(s) for one document, read only.
class _DocumentViewer extends StatelessWidget {
  const _DocumentViewer({required this.doc});

  final ApproverDoc doc;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final urls = [
      if ((doc.fileUrl ?? '').isNotEmpty) doc.fileUrl!,
      if ((doc.fileUrlBack ?? '').isNotEmpty) doc.fileUrlBack!,
    ];
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(doc.docLabel, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text('${doc.ownerName} · ${ApproverInboxScreen.sourceLabel(doc.source)}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('approver-document-close'),
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: urls.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('No image was uploaded for this document.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      children: [
                        for (final url in urls)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: InteractiveViewer(
                                child: Image.network(
                                  url,
                                  fit: BoxFit.contain,
                                  loadingBuilder: (c, child, progress) => progress == null
                                      ? child
                                      : const Padding(
                                          padding: EdgeInsets.all(32),
                                          child: Center(child: CircularProgressIndicator()),
                                        ),
                                  errorBuilder: (c, _, _) => Padding(
                                    padding: const EdgeInsets.all(32),
                                    child: Text("Couldn't load this image.",
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: cs.onSurfaceVariant)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text('Review actions are coming soon.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}
