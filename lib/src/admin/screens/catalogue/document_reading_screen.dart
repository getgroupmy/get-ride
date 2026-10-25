// Admin > Services & catalogue > Document reading (migration 0293): who reads
// a document's photo, in what order, each with an on/off switch; the office
// NAS with its status, today's work and what it reads; connecting a NAS or a
// GPU reading PC with a one-time code (full admins only). A GPU PC is listed
// in the order only once one is connected. Every change saves at once.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/document_reading.dart';
import '../../../data/document_reading_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'catalogue_widgets.dart' show canEditPage;

const documentReadingPath = '/admin/m/document-reading';

/// The page key that grants this page.
const documentReadingPage = 'admin-settings-document-reading';

final docReadersProvider = FutureProvider.autoDispose<ReadersState>(
  (ref) => ref.watch(documentReadingRepositoryProvider).readers(),
);

IconData _icon(DocReaderId id) => switch (id) {
      DocReaderId.phone => Icons.smartphone,
      DocReaderId.nas => Icons.storage,
      DocReaderId.gpu => Icons.dns,
      DocReaderId.cloud => Icons.cloud_outlined,
    };

class DocumentReadingScreen extends ConsumerStatefulWidget {
  const DocumentReadingScreen({super.key});

  @override
  ConsumerState<DocumentReadingScreen> createState() => _DocumentReadingScreenState();
}

class _DocumentReadingScreenState extends ConsumerState<DocumentReadingScreen> {
  DocumentReadingConfig? _cfg;
  bool _saved = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Readers check in every minute: keep their status and today's work fresh.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) ref.invalidate(docReadersProvider);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _save(DocumentReadingConfig next) async {
    final before = _cfg;
    setState(() {
      _cfg = next;
      _saved = false;
    });
    late DocumentReadingConfig stored;
    final ok = await runAdminAction(context, () async {
      stored = await ref.read(documentReadingRepositoryProvider).save(next);
    });
    if (!mounted) return;
    setState(() {
      _cfg = ok ? stored : before;
      _saved = ok;
    });
    if (ok) ref.invalidate(documentReadingConfigProvider);
  }

  Future<void> _connect(DocReaderId kind) async {
    final name = await showAppDialog<String>(
      id: 'admin-doc-reading.connect',
      context: context,
      builder: (_) => _ConnectDialog(kind: kind),
    );
    if (name == null || !mounted) return;
    ({String code, DateTime? expiresAt})? answer;
    final ok = await runAdminAction(context, () async {
      answer = await ref.read(documentReadingRepositoryProvider).pairingCode(kind, name);
    });
    if (!ok || answer == null || !mounted) return;
    final until = answer!.expiresAt == null ? null : DateFormat('HH:mm').format(answer!.expiresAt!);
    await showAppDialog<void>(
      id: 'admin-doc-reading.code',
      context: context,
      builder: (c) {
        final t = Theme.of(c);
        return AlertDialog(
          title: const Text('Connection code'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SelectableText(
              answer!.code,
              key: const ValueKey('doc-reader-code'),
              style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 4),
            ),
            const SizedBox(height: 12),
            Text(
              'Start the GET.ride reader on the ${kind == DocReaderId.nas ? 'NAS' : 'PC'} and enter this code. '
              'It works once, ${until == null ? 'for 10 minutes' : 'until $until'}. The reader only calls out to '
              'GET.ride, so no ports are opened on your network.',
              style: t.textTheme.bodySmall,
            ),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))],
        );
      },
    );
    ref.invalidate(docReadersProvider);
  }

  Future<void> _disconnect(ConnectedReader r) async {
    if (!await confirm(context, 'Disconnect ${r.label}?',
        'It stops reading at once and its key stops working. Photos it was reading go back to the queue.',
        ok: 'Disconnect')) {
      return;
    }
    if (!mounted) return;
    await runAdminAction(context, () => ref.read(documentReadingRepositoryProvider).remove(r.id));
    ref.invalidate(docReadersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, documentReadingPage);
    final fullAdmin = ref.watch(adminAccessProvider).value?.isFullAdmin ?? false;
    final config = ref.watch(documentReadingConfigProvider);
    final readers = ref.watch(docReadersProvider).value ?? const ReadersState();
    return AdminPage(
      title: 'Document reading',
      page: documentReadingPage,
      body: AsyncView(
        value: config,
        onRetry: () => ref.invalidate(documentReadingConfigProvider),
        data: (loaded) {
          final cfg = _cfg ?? loaded;
          return ResponsiveCenter(
            maxWidth: 900,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              _OrderCard(
                cfg: cfg,
                gpuConnected: readers.of(DocReaderId.gpu).isNotEmpty,
                canEdit: canEdit,
                saved: _saved,
                onChange: _save,
                onConnectGpu: fullAdmin ? () => _connect(DocReaderId.gpu) : null,
              ),
              const SizedBox(height: 16),
              _NasCard(
                cfg: cfg,
                readers: readers,
                canEdit: canEdit,
                onChange: _save,
                onConnect: fullAdmin ? () => _connect(DocReaderId.nas) : null,
                onDisconnect: fullAdmin ? _disconnect : null,
              ),
              for (final gpu in readers.of(DocReaderId.gpu)) ...[
                const SizedBox(height: 16),
                _ReaderStatus(reader: gpu, onDisconnect: fullAdmin ? _disconnect : null),
              ],
            ]),
          );
        },
      ),
    );
  }
}

/// Names the reader before its code is made. Owns its text box, which lives
/// as long as the dialog (closing animation included).
class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({required this.kind});
  final DocReaderId kind;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  late final _label = TextEditingController(text: widget.kind.label);

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.kind == DocReaderId.nas ? 'Connect a NAS' : 'Connect a GPU reading PC'),
        content: TextField(
          key: const ValueKey('doc-reader-label'),
          controller: _label,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. DS224+ at the office'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _label.text.trim()), child: const Text('Get code')),
        ],
      );
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({
    required this.cfg,
    required this.gpuConnected,
    required this.canEdit,
    required this.saved,
    required this.onChange,
    this.onConnectGpu,
  });

  final DocumentReadingConfig cfg;
  final bool gpuConnected;
  final bool canEdit;
  final bool saved;
  final ValueChanged<DocumentReadingConfig> onChange;
  final VoidCallback? onConnectGpu;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final shown = shownReaders(cfg, gpuConnected: gpuConnected);
    final ids = {for (final r in shown) r.id};
    var n = 0;
    return Card(
      key: const ValueKey('doc-reading-order'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Who reads, in order', style: t.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Use the arrows to change the order and the switch to turn a reader on or off. Each reader does what it '
            'can and passes the rest on.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final (i, r) in shown.indexed)
            ListTile(
              key: ValueKey('doc-reader-${r.id.name}'),
              contentPadding: EdgeInsets.zero,
              enabled: r.on,
              leading: SizedBox(
                width: 56,
                child: Row(children: [
                  SizedBox(
                    width: 20,
                    child: Text(r.on ? '${++n}' : '–',
                        textAlign: TextAlign.center,
                        style: t.textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                  const SizedBox(width: 8),
                  Icon(_icon(r.id)),
                ]),
              ),
              title: Text(r.id.label),
              subtitle: Text(r.id.help),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  key: ValueKey('doc-reader-up-${r.id.name}'),
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: canEdit && i > 0 ? () => onChange(cfg.move(r.id, -1, shown: ids)) : null,
                ),
                IconButton(
                  key: ValueKey('doc-reader-down-${r.id.name}'),
                  tooltip: 'Move down',
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: canEdit && i < shown.length - 1 ? () => onChange(cfg.move(r.id, 1, shown: ids)) : null,
                ),
                Switch(
                  key: ValueKey('doc-reader-switch-${r.id.name}'),
                  value: r.on,
                  onChanged: canEdit ? (v) => onChange(cfg.toggled(r.id, v)) : null,
                ),
              ]),
            ),
          const SizedBox(height: 4),
          Text(
            '${readingSummary(shown)}${saved ? ' Saved.' : ''}',
            key: const ValueKey('doc-reading-summary'),
            style: t.textTheme.bodySmall,
          ),
          if (!gpuConnected) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('A GPU reading PC appears here once one is connected.', style: t.textTheme.bodySmall),
              if (onConnectGpu != null)
                TextButton(
                  key: const ValueKey('doc-reader-connect-gpu'),
                  onPressed: onConnectGpu,
                  child: const Text('Connect a GPU PC'),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _NasCard extends StatelessWidget {
  const _NasCard({
    required this.cfg,
    required this.readers,
    required this.canEdit,
    required this.onChange,
    this.onConnect,
    this.onDisconnect,
  });

  final DocumentReadingConfig cfg;
  final ReadersState readers;
  final bool canEdit;
  final ValueChanged<DocumentReadingConfig> onChange;
  final VoidCallback? onConnect;
  final ValueChanged<ConnectedReader>? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final nas = readers.of(DocReaderId.nas);
    return Card(
      key: const ValueKey('doc-reading-nas'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.storage),
            const SizedBox(width: 8),
            Expanded(child: Text('Office NAS', style: t.textTheme.titleMedium)),
            if (onConnect != null)
              TextButton(
                key: const ValueKey('doc-reader-connect-nas'),
                onPressed: onConnect,
                child: Text(nas.isEmpty ? 'Connect a NAS' : 'Connect another'),
              ),
          ]),
          const SizedBox(height: 4),
          if (nas.isEmpty)
            Text(
              'No NAS connected yet. Run the GET.ride reader in Docker on the NAS and enter a connection code. '
              'It reads plates and document numbers in the background.',
              style: t.textTheme.bodySmall,
            )
          else ...[
            for (final r in nas) _ReaderStatus(reader: r, onDisconnect: onDisconnect, flat: true),
            Text('Waiting: ${readers.waiting} ${readers.waiting == 1 ? 'photo' : 'photos'}',
                key: const ValueKey('doc-reading-waiting'), style: t.textTheme.bodySmall),
          ],
          const Divider(height: 24),
          Text('What the NAS reads', style: t.textTheme.titleSmall),
          for (final job in NasJob.values)
            SwitchListTile(
              key: ValueKey('doc-reader-job-${job.name}'),
              contentPadding: EdgeInsets.zero,
              title: Text(job.label),
              subtitle: Text(job.help),
              value: cfg.nasJobs[job] ?? true,
              onChanged: canEdit ? (v) => onChange(cfg.withJob(job, v)) : null,
            ),
          const SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Whole documents'),
            subtitle: Text('Too heavy for a NAS: done by a GPU reading PC or the cloud reader.'),
            value: false,
            onChanged: null,
          ),
          const SizedBox(height: 8),
          Text('Pass on when the NAS is less than ${cfg.passOnBelow}% sure', style: t.textTheme.titleSmall),
          Slider(
            key: const ValueKey('doc-reader-pass-on'),
            min: 50,
            max: 100,
            divisions: 10,
            label: '${cfg.passOnBelow}%',
            value: cfg.passOnBelow.toDouble(),
            onChanged: canEdit ? (v) => onChange(cfg.copyWith(passOnBelow: v.round())) : null,
          ),
          Text('Readings it is less sure of go to the next reader in the order.', style: t.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

/// One connected reader: status, model, version, today's work, disconnect.
class _ReaderStatus extends StatelessWidget {
  const _ReaderStatus({required this.reader, this.onDisconnect, this.flat = false});
  final ConnectedReader reader;
  final ValueChanged<ConnectedReader>? onDisconnect;

  /// Inside the NAS card rather than a card of its own.
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final rows = [
      ('plates', 'Plates'),
      ('numbers', 'Document numbers'),
      ('qr', 'QR codes'),
    ];
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(Icons.circle, size: 12, color: reader.online ? scheme.primary : scheme.outline),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            [reader.label, readerSeen(reader, DateTime.now())].join(' · '),
            key: ValueKey('doc-reader-status-${reader.id}'),
            style: t.textTheme.titleSmall,
          ),
        ),
        if (onDisconnect != null)
          TextButton(
            key: ValueKey('doc-reader-disconnect-${reader.id}'),
            onPressed: () => onDisconnect!(reader),
            child: const Text('Disconnect'),
          ),
      ]),
      if (reader.model != null || reader.appVersion != null)
        Text([?reader.model, if (reader.appVersion != null) 'Version ${reader.appVersion}'].join(' · '),
            style: t.textTheme.bodySmall),
      const SizedBox(height: 8),
      Text('Today', style: t.textTheme.labelLarge),
      Table(
        columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1)},
        children: [
          TableRow(children: [
            for (final h in ['Job', 'Done', 'Average', 'Passed on'])
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(h, style: t.textTheme.labelSmall)),
          ]),
          for (final (key, label) in rows)
            TableRow(children: [
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(label)),
              Text('${reader.today[key]?.done ?? 0}'),
              Text(readerSeconds(reader.today[key]?.avgMs)),
              Text('${reader.today[key]?.passedOn ?? 0}'),
            ]),
        ],
      ),
      const SizedBox(height: 8),
    ]);
    if (flat) return body;
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: body));
  }
}
