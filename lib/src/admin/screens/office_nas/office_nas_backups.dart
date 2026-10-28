// Admin > Settings > Office NAS > Backups (migration 0318): when the NAS
// backs up, how many copies it keeps, which buckets, the monthly restore
// test, the off-site copy, "Back up now" and "Run a restore test", and the
// recent runs. Every change saves at once (EDIT on Office NAS).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/office_nas.dart';
import '../../../data/office_nas_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/date_boxes.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';
import '../../widgets/admin_widgets.dart';
import '../catalogue/catalogue_widgets.dart' show canEditPage;
import 'office_nas_overview.dart';

String _ordinal(int n) => switch (n % 100) {
      11 || 12 || 13 => '${n}th',
      _ => switch (n % 10) { 1 => '${n}st', 2 => '${n}nd', 3 => '${n}rd', _ => '${n}th' },
    };

/// The Backups tab.
class OfficeNasBackups extends ConsumerStatefulWidget {
  const OfficeNasBackups({super.key});

  @override
  ConsumerState<OfficeNasBackups> createState() => _OfficeNasBackupsState();
}

class _OfficeNasBackupsState extends ConsumerState<OfficeNasBackups> {
  NasBackupSettings? _cfg;

  Future<void> _save(NasBackupSettings next) async {
    final before = _cfg;
    setState(() => _cfg = next);
    late NasBackupSettings stored;
    final ok = await runAdminAction(context, () async {
      stored = await ref.read(officeNasRepositoryProvider).saveBackup(next);
    });
    if (!mounted) return;
    setState(() => _cfg = ok ? stored : before);
    if (ok) ref.invalidate(officeNasProvider);
  }

  Future<void> _pickTime(NasBackupSettings cfg) async {
    final parts = cfg.at.split(':');
    final picked = await showAppDialog<TimeOfDay>(
      id: 'admin-office-nas.backup-time',
      context: context,
      builder: (_) => TimePickerDialog(
        initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
        helpText: 'Back up every night at',
      ),
    );
    if (picked == null || !mounted) return;
    String two(int n) => n.toString().padLeft(2, '0');
    await _save(cfg.copyWith(at: '${two(picked.hour)}:${two(picked.minute)}'));
  }

  Future<void> _request(RunKind kind) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(officeNasRepositoryProvider).request(kind),
      success: kind == RunKind.backup
          ? 'The NAS starts the backup within a minute. It shows below when it is done.'
          : 'The NAS starts the restore test within a minute. It restores into the test copy on the NAS, never the '
              'live database.',
    );
    if (ok) ref.invalidate(officeNasProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, officeNasPage);
    return AsyncView(
      value: ref.watch(officeNasProvider),
      onRetry: () => ref.invalidate(officeNasProvider),
      errorTitle: "Couldn't load the backups",
      data: (nas) {
        final cfg = _cfg ?? nas.backup;
        final t = Theme.of(context);
        return ResponsiveCenter(
          maxWidth: 900,
          child: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            _StatusCard(nas: nas, cfg: cfg, canEdit: canEdit, onRequest: _request),
            const SizedBox(height: 12),
            _ScheduleCard(cfg: cfg, canEdit: canEdit, onChange: _save, onPickTime: () => _pickTime(cfg)),
            const SizedBox(height: 12),
            _BucketsCard(nas: nas, cfg: cfg, canEdit: canEdit, onChange: _save),
            const SizedBox(height: 12),
            _RestoreCard(cfg: cfg, canEdit: canEdit, onChange: _save),
            const SizedBox(height: 12),
            _OffsiteCard(nas: nas, cfg: cfg, canEdit: canEdit, onChange: _save),
            const SizedBox(height: 12),
            _RunsCard(nas: nas),
            const SizedBox(height: 12),
            Text(
              'Backups are encrypted on the NAS with a key only you hold (printed once at setup). A restore never '
              'touches the live database: it goes into the test copy.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ]),
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.nas, required this.cfg, required this.canEdit, required this.onRequest});
  final OfficeNasState nas;
  final NasBackupSettings cfg;
  final bool canEdit;
  final ValueChanged<RunKind> onRequest;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final last = nas.lastBackup;
    final rt = nas.lastRestoreTest;
    final running = nas.service('backup')?.detail['running'];
    final waitingBackup = nas.waiting(RunKind.backup) || running == 'backup';
    final waitingRestore = nas.waiting(RunKind.restoreTest) || running == 'restore_test';
    final card = backupCard(nas);
    return Card(
      key: const ValueKey('office-nas-backup-status'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NasCardTitle(Icons.backup_outlined, 'Backups'),
          NasRow(
            'Last backup',
            last == null
                ? 'None yet'
                : '${whenText(last.finishedAt ?? last.startedAt, nas.now)} · ${runSummary(last)}',
            tone: last == null ? Tone.idle : (last.ok ? card.tone : Tone.bad),
            valueKey: const ValueKey('office-nas-last-backup'),
          ),
          NasRow('Off-site copy (Hyper Backup)',
              '${cfg.offsite == OffsiteTarget.none ? '' : '${cfg.offsite.label} · '}${offsiteText(nas)}'),
          NasRow(
            'Restore test',
            '${cfg.restoreTestOn ? 'Monthly, ${_ordinal(cfg.restoreTestDay)}' : 'Off'} · '
                '${rt == null ? 'not run yet' : 'last ${rt.ok ? 'passed' : 'failed'} ${dayText(rt.startedAt)}'}',
            tone: rt == null ? null : (rt.ok ? Tone.ok : Tone.bad),
            valueKey: const ValueKey('office-nas-last-restore'),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton(
              key: const ValueKey('office-nas-backup-now'),
              onPressed: canEdit && nas.connected && !waitingBackup ? () => onRequest(RunKind.backup) : null,
              child: Text(waitingBackup ? 'Backing up…' : 'Back up now'),
            ),
            OutlinedButton(
              key: const ValueKey('office-nas-restore-now'),
              onPressed: canEdit && nas.connected && !waitingRestore ? () => onRequest(RunKind.restoreTest) : null,
              child: Text(waitingRestore ? 'Restore test running…' : 'Run a restore test'),
            ),
            if (!nas.connected)
              Text('Connect the NAS on Overview first.', style: t.textTheme.bodySmall),
          ]),
        ]),
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.cfg, required this.canEdit, required this.onChange, required this.onPickTime});
  final NasBackupSettings cfg;
  final bool canEdit;
  final ValueChanged<NasBackupSettings> onChange;
  final VoidCallback onPickTime;

  @override
  Widget build(BuildContext context) {
    // One night at a time up to a month, then five.
    int nightlyStep(int v, int dir) => (dir > 0 ? v >= 30 : v > 30) ? 5 : 1;
    return Card(
      key: const ValueKey('office-nas-schedule'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NasCardTitle(Icons.schedule, 'Every night'),
          SwitchListTile(
            key: const ValueKey('office-nas-backup-on'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Back up the database and storage every night'),
            subtitle: const Text('The database with pg_dump; new and changed storage files.'),
            value: cfg.on,
            onChanged: canEdit ? (v) => onChange(cfg.copyWith(on: v)) : null,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Database, every night at'),
            trailing: TextButton(
              key: const ValueKey('office-nas-backup-at'),
              onPressed: canEdit ? onPickTime : null,
              child: Text(cfg.at, style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          SearchableDropdownFormField<String>(
            key: ValueKey('office-nas-timezone-${cfg.timezone}'),
            initialValue: cfg.timezone,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Time zone'),
            items: [
              for (final z in {...backupTimeZones, cfg.timezone}) DropdownMenuItem(value: z, child: Text(z)),
            ],
            onChanged: canEdit ? (v) => v == null ? null : onChange(cfg.copyWith(timezone: v)) : null,
          ),
          const SizedBox(height: 8),
          NasStepper(
            label: 'Nightly copies kept',
            hint: 'The newest nights of the database',
            value: '${cfg.keepNightly}',
            valueKey: const ValueKey('office-nas-keep-nightly'),
            onDown: canEdit && cfg.keepNightly > 1
                ? () => onChange(cfg.copyWith(keepNightly: cfg.keepNightly - nightlyStep(cfg.keepNightly, -1)))
                : null,
            onUp: canEdit && cfg.keepNightly < 365
                ? () => onChange(cfg.copyWith(keepNightly: cfg.keepNightly + nightlyStep(cfg.keepNightly, 1)))
                : null,
          ),
          NasStepper(
            label: 'Monthly copies kept',
            hint: 'The first backup of each month, after the nightly ones',
            value: '${cfg.keepMonthly}',
            valueKey: const ValueKey('office-nas-keep-monthly'),
            onDown: canEdit && cfg.keepMonthly > 0 ? () => onChange(cfg.copyWith(keepMonthly: cfg.keepMonthly - 1)) : null,
            onUp: canEdit && cfg.keepMonthly < 120 ? () => onChange(cfg.copyWith(keepMonthly: cfg.keepMonthly + 1)) : null,
          ),
        ]),
      ),
    );
  }
}

class _BucketsCard extends StatelessWidget {
  const _BucketsCard({required this.nas, required this.cfg, required this.canEdit, required this.onChange});
  final OfficeNasState nas;
  final NasBackupSettings cfg;
  final bool canEdit;
  final ValueChanged<NasBackupSettings> onChange;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final buckets = {...nas.bucketsSeen, ...cfg.skipBuckets}.toList()..sort();
    final copied = buckets.where((b) => !cfg.skipBuckets.contains(b)).length;
    return Card(
      key: const ValueKey('office-nas-buckets'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NasCardTitle(Icons.folder_copy_outlined, 'Storage buckets'),
          Text(
            buckets.isEmpty
                ? 'Every bucket is copied: new and changed files each night. The NAS lists them here after its first '
                    'check-in, to leave some out.'
                : '$copied of ${buckets.length} copied: new and changed files each night. Tap one to leave it out.',
            style: t.textTheme.bodySmall,
          ),
          if (buckets.isNotEmpty)
            ListSearchFilter(
              count: buckets.length,
              hint: 'Search buckets',
              fieldKey: const ValueKey('office-nas-bucket-search'),
              builder: (context, q) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final b in buckets)
                    if (q.isEmpty || b.toLowerCase().contains(q.toLowerCase()))
                      FilterChip(
                        key: ValueKey('office-nas-bucket-$b'),
                        label: Text(b),
                        selected: !cfg.skipBuckets.contains(b),
                        onSelected: canEdit ? (v) => onChange(cfg.withBucket(b, v)) : null,
                      ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

class _RestoreCard extends StatelessWidget {
  const _RestoreCard({required this.cfg, required this.canEdit, required this.onChange});
  final NasBackupSettings cfg;
  final bool canEdit;
  final ValueChanged<NasBackupSettings> onChange;

  @override
  Widget build(BuildContext context) => Card(
        key: const ValueKey('office-nas-restore'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const NasCardTitle(Icons.restore, 'Restore test'),
            SwitchListTile(
              key: const ValueKey('office-nas-restore-on'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Test a restore every month'),
              subtitle: const Text("That night's dump is restored into the test database on the NAS and checked."),
              value: cfg.restoreTestOn,
              onChanged: canEdit ? (v) => onChange(cfg.copyWith(restoreTestOn: v)) : null,
            ),
            NasStepper(
              label: 'Day of the month',
              value: _ordinal(cfg.restoreTestDay),
              valueKey: const ValueKey('office-nas-restore-day'),
              onDown: canEdit && cfg.restoreTestDay > 1
                  ? () => onChange(cfg.copyWith(restoreTestDay: cfg.restoreTestDay - 1))
                  : null,
              onUp: canEdit && cfg.restoreTestDay < 28
                  ? () => onChange(cfg.copyWith(restoreTestDay: cfg.restoreTestDay + 1))
                  : null,
            ),
          ]),
        ),
      );
}

class _OffsiteCard extends StatelessWidget {
  const _OffsiteCard({required this.nas, required this.cfg, required this.canEdit, required this.onChange});
  final OfficeNasState nas;
  final NasBackupSettings cfg;
  final bool canEdit;
  final ValueChanged<NasBackupSettings> onChange;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final detected = nas.service('backup')?.detail['offsite'] is Map;
    final today = DateTime(nas.now.year, nas.now.month, nas.now.day);
    return Card(
      key: const ValueKey('office-nas-offsite'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NasCardTitle(Icons.cloud_upload_outlined, 'Off-site copy'),
          Text(
            'Synology Hyper Backup copies the backup folder to Backblaze B2 or Synology C2 every night '
            '(deploy/nas-backup/README.md, step 5).',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SearchableDropdownFormField<OffsiteTarget>(
            key: ValueKey('office-nas-offsite-${cfg.offsite.name}'),
            initialValue: cfg.offsite,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Copied to'),
            items: [for (final o in OffsiteTarget.values) DropdownMenuItem(value: o, child: Text(o.label))],
            onChanged: canEdit ? (v) => v == null ? null : onChange(cfg.copyWith(offsite: v)) : null,
          ),
          const SizedBox(height: 8),
          Text(offsiteText(nas), key: const ValueKey('office-nas-offsite-status'), style: t.textTheme.bodyMedium),
          if (!detected && cfg.offsite != OffsiteTarget.none) ...[
            const SizedBox(height: 8),
            DateBoxesField(
              key: ValueKey('office-nas-offsite-date-${cfg.lastCopyOn}'),
              label: 'Last off-site copy',
              initialValue: cfg.lastCopyOn == null ? null : DateTime.tryParse(cfg.lastCopyOn!),
              lastDate: today,
              enabled: canEdit,
              helperText: 'The NAS can\'t see Hyper Backup: set the date of its last good run by hand.',
              onChanged: (d) {
                if (d == null) return;
                final s = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
                    '${d.day.toString().padLeft(2, '0')}';
                if (s != cfg.lastCopyOn && !d.isAfter(today)) onChange(cfg.copyWith(lastCopyOn: () => s));
              },
            ),
          ],
        ]),
      ),
    );
  }
}

class _RunsCard extends StatelessWidget {
  const _RunsCard({required this.nas});
  final OfficeNasState nas;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('office-nas-runs'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NasCardTitle(Icons.history, 'Recent runs'),
          if (nas.runs.isEmpty) Text('None yet.', style: t.textTheme.bodySmall),
          for (final r in nas.runs.take(15))
            ListTile(
              key: ValueKey('office-nas-run-${r.id}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                r.running ? Icons.sync : (r.ok ? Icons.check_circle_outline : Icons.error_outline),
                color: toneColor(r.running ? Tone.idle : (r.ok ? Tone.ok : Tone.bad), t),
              ),
              title: Text(
                '${r.kind == RunKind.backup ? 'Backup' : 'Restore test'}${r.manual ? ' (asked for)' : ''} · '
                '${whenText(r.startedAt, nas.now)}',
              ),
              subtitle: Text(runSummary(r)),
            ),
        ]),
      ),
    );
  }
}
