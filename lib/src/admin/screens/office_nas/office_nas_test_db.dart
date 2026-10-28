// Admin › Settings › Office NAS › Test database (migration 0321,
// deploy/nas-testdb): a copy of the live database on the NAS, refreshed
// nightly at a time set here, personal data scrambled; "Try migration from
// PR #" asks the NAS to apply that PR's migration files to a throw-away copy
// and report pass or fail, the error and how long it took. Connecting the
// runner on the NAS (a one-time code) is for full admins.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/office_nas_testdb.dart';
import '../../../data/office_nas_testdb_repository.dart';
import '../../../widgets/common.dart';
import '../../../widgets/page_style_host.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../catalogue/catalogue_widgets.dart' show canEditPage;
import '../../../core/office_nas.dart' show officeNasPage;

final officeNasTestDbProvider = FutureProvider.autoDispose<TestDbState>(
  (ref) => ref.watch(officeNasTestDbRepositoryProvider).state(),
);

class OfficeNasTestDbTab extends ConsumerStatefulWidget {
  const OfficeNasTestDbTab({super.key});

  @override
  ConsumerState<OfficeNasTestDbTab> createState() => _OfficeNasTestDbTabState();
}

class _OfficeNasTestDbTabState extends ConsumerState<OfficeNasTestDbTab> {
  final _target = TextEditingController();
  String? _targetError;
  TestDbSettings? _settings;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The runner checks in every minute and runs take minutes: keep it fresh.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) ref.invalidate(officeNasTestDbProvider);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _target.dispose();
    super.dispose();
  }

  OfficeNasTestDbRepository get _repo => ref.read(officeNasTestDbRepositoryProvider);

  Future<void> _save(TestDbSettings next) async {
    final before = _settings;
    setState(() => _settings = next);
    late TestDbSettings stored;
    final ok = await runAdminAction(context, () async => stored = await _repo.save(next));
    if (!mounted) return;
    setState(() => _settings = ok ? stored : before);
  }

  Future<void> _pickTime(TestDbSettings s) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: s.hour, minute: s.minute),
      helpText: 'Refresh the copy every night at (office time)',
    );
    if (t == null || !mounted) return;
    await _save(s.copyWith(refreshAt: TestDbSettings.timeText(t.hour, t.minute)));
  }

  Future<void> _scramble(TestDbSettings s, bool on) async {
    if (!on &&
        !await confirm(
          context,
          'Keep personal data in the copy?',
          "Tonight's copy will keep real names, phone numbers, ID numbers, emails and addresses. Turn this off only "
              'for a short check, and back on after.',
          ok: 'Turn off',
        )) {
      return;
    }
    await _save(s.copyWith(scramble: on));
  }

  Future<void> _try() async {
    final t = parseTryTarget(_target.text);
    if (t == null) {
      setState(() => _targetError = 'A PR number (e.g. 554) or a branch name');
      return;
    }
    setState(() => _targetError = null);
    final ok = await runAdminAction(context, () => _repo.tryMigration(pr: t.pr, branch: t.branch));
    if (!ok || !mounted) return;
    _target.clear();
    ref.invalidate(officeNasTestDbProvider);
  }

  Future<void> _refreshNow() async {
    await runAdminAction(context, _repo.refreshNow);
    if (mounted) ref.invalidate(officeNasTestDbProvider);
  }

  Future<void> _cancel(TestDbRun r) async {
    await runAdminAction(context, () => _repo.cancel(r.id));
    if (mounted) ref.invalidate(officeNasTestDbProvider);
  }

  Future<void> _connect() async {
    final label = await showAppDialog<String>(
      id: 'admin-office-nas.testdb-connect',
      context: context,
      builder: (_) => const _ConnectDialog(),
    );
    if (label == null || !mounted) return;
    ({String code, DateTime? expiresAt})? answer;
    final ok = await runAdminAction(context, () async => answer = await _repo.pairingCode(label));
    if (!ok || answer == null || !mounted) return;
    final until = answer!.expiresAt == null ? null : DateFormat('HH:mm').format(answer!.expiresAt!);
    await showAppDialog<void>(
      id: 'admin-office-nas.testdb-code',
      context: context,
      builder: (c) {
        final t = Theme.of(c);
        return AlertDialog(
          title: const Text('Connection code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                answer!.code,
                key: const ValueKey('testdb-code'),
                style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 4),
              ),
              const SizedBox(height: 12),
              Text(
                'Put this code in the test database runner\'s .env on the NAS (PAIR_CODE) and start it. It works once, '
                '${until == null ? 'for 10 minutes' : 'until $until'}. The runner only calls out to get.ride, so no '
                'ports are opened on your network.',
                style: t.textTheme.bodySmall,
              ),
            ],
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))],
        );
      },
    );
    ref.invalidate(officeNasTestDbProvider);
  }

  Future<void> _disconnect(TestDbRunner r) async {
    if (!await confirm(
      context,
      'Disconnect ${r.label}?',
      'Its key stops working at once. A run it was doing goes back to waiting.',
      ok: 'Disconnect',
    )) {
      return;
    }
    if (!mounted) return;
    await runAdminAction(context, () => _repo.removeRunner(r.id));
    ref.invalidate(officeNasTestDbProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canEditPage(ref, officeNasPage);
    final fullAdmin = ref.watch(adminAccessProvider).value?.isFullAdmin ?? false;
    return AsyncView(
      value: ref.watch(officeNasTestDbProvider),
      onRetry: () => ref.invalidate(officeNasTestDbProvider),
      data: (state) {
        final s = _settings ?? state.settings;
        final now = DateTime.now();
        final t = Theme.of(context);
        return ResponsiveCenter(
          maxWidth: 900,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _RunnerCard(
                runner: state.runner,
                onConnect: fullAdmin ? _connect : null,
                onDisconnect: fullAdmin ? _disconnect : null,
              ),
              const SizedBox(height: 16),
              Card(
                key: const ValueKey('testdb-copy'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('The copy', style: t.textTheme.titleMedium),
                      _Row(
                        'Copy refreshed nightly at',
                        TextButton.icon(
                          key: const ValueKey('testdb-refresh-at'),
                          icon: const Icon(Icons.schedule, size: 18),
                          label: Text(s.refreshAt),
                          onPressed: canEdit ? () => _pickTime(s) : null,
                        ),
                      ),
                      _Row(
                        'Personal data scrambled',
                        Switch(
                          key: const ValueKey('testdb-scramble'),
                          value: s.scramble,
                          // Off is for full admins only (the server says so too).
                          onChanged: canEdit && (fullAdmin || !s.scramble) ? (v) => _scramble(s, v) : null,
                        ),
                      ),
                      _Row(
                        'Last refresh',
                        _Value(_refreshText(state, now), key: const ValueKey('testdb-last-refresh')),
                      ),
                      _Row(
                        'Last migration tried',
                        _Value(
                          state.lastMigration == null ? 'None yet' : runSummary(state.lastMigration!),
                          key: const ValueKey('testdb-last-migration'),
                          bad: state.lastMigration?.status == TestDbRunStatus.failed,
                        ),
                      ),
                      if (state.lastMigration case final m?) _RunDetail(run: m, now: now),
                      _Row(
                        'Next in line',
                        _Value(
                          state.waiting.isEmpty ? 'Nothing waiting' : runSummary(state.waiting.first),
                          key: const ValueKey('testdb-next'),
                        ),
                      ),
                      for (final w in state.waiting)
                        ListTile(
                          key: ValueKey('testdb-waiting-${w.id}'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            w.status == TestDbRunStatus.running ? Icons.play_circle_outline : Icons.hourglass_empty,
                          ),
                          title: Text(w.target),
                          subtitle: Text('${w.status.label} · asked ${whenText(w.createdAt, now)}'),
                          trailing: canEdit && w.status == TestDbRunStatus.queued
                              ? TextButton(onPressed: () => _cancel(w), child: const Text('Cancel'))
                              : null,
                        ),
                      if (canEdit)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('testdb-refresh-now'),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Refresh the copy now'),
                            onPressed: _refreshNow,
                          ),
                        ),
                      if (!s.scramble)
                        Text(
                          'Scrambling is off: the next copy keeps real personal data.',
                          key: const ValueKey('testdb-scramble-off'),
                          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                key: const ValueKey('testdb-try'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Try migration from PR #', style: t.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        "The NAS takes the PR's new or changed files in supabase/migrations, applies them in order to a "
                        "throw-away copy of last night's copy, runs them a second time (they must be re-runnable) and "
                        'reports here.',
                        style: t.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const ValueKey('testdb-target'),
                              controller: _target,
                              enabled: canEdit,
                              decoration: InputDecoration(
                                labelText: 'PR number or branch',
                                hintText: 'e.g. 554',
                                errorText: _targetError,
                              ),
                              onSubmitted: (_) => _try(),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            // The app's buttons are full width; this one sits by the box.
                            child: SizedBox(
                              width: 104,
                              child: FilledButton(
                                key: const ValueKey('testdb-try-button'),
                                onPressed: canEdit ? _try : null,
                                child: const Text('Try'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (state.recent.isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  key: const ValueKey('testdb-recent'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Latest runs', style: t.textTheme.titleMedium),
                        for (final r in state.recent)
                          ListTile(
                            key: ValueKey('testdb-run-${r.id}'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: _StatusIcon(r.status),
                            title: Text(r.isMigration ? '${r.target} · ${runSummary(r)}' : runSummary(r)),
                            subtitle: Text(
                              [
                                whenText(r.finishedAt ?? r.createdAt, now),
                                if (r.error != null) r.error!.split('\n').first,
                              ].join(' · '),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                "Each new migration in a PR is tried on last night's copy first; the result shows here before you run "
                'it live. Personal data in the copy is scrambled (names, phones, IDs, emails, addresses, photo links). '
                'Setup: deploy/nas-testdb/README.md.',
                style: t.textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }

  String _refreshText(TestDbState state, DateTime now) {
    final r = state.lastRefresh;
    final runner = state.runner;
    if (r == null) return runner?.refreshedAt == null ? 'Not yet' : whenText(runner!.refreshedAt, now);
    final parts = [
      whenText(r.finishedAt, now),
      if (r.status == TestDbRunStatus.failed)
        'failed'
      else if (formatBytes(runner?.sizeBytes).isNotEmpty)
        formatBytes(runner?.sizeBytes),
      if (r.ms != null) formatRunTime(r.ms),
    ];
    return parts.where((p) => p.isNotEmpty).join(' · ');
  }
}

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog();

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final _label = TextEditingController(text: 'Office NAS');

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect the test database'),
    content: TextField(
      key: const ValueKey('testdb-label'),
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

class _RunnerCard extends StatelessWidget {
  const _RunnerCard({required this.runner, this.onConnect, this.onDisconnect});
  final TestDbRunner? runner;
  final VoidCallback? onConnect;
  final ValueChanged<TestDbRunner>? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = runner;
    final now = DateTime.now();
    return Card(
      key: const ValueKey('testdb-runner'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 12, color: r?.online == true ? t.colorScheme.primary : t.colorScheme.outline),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r == null
                        ? 'Not connected'
                        : [r.label, r.online ? (r.busy == null ? 'Online' : 'Busy: ${r.busy}') : 'Offline'].join(' · '),
                    key: const ValueKey('testdb-runner-status'),
                    style: t.textTheme.titleMedium,
                  ),
                ),
                if (r == null && onConnect != null)
                  TextButton(key: const ValueKey('testdb-connect'), onPressed: onConnect, child: const Text('Connect')),
                if (r != null && onDisconnect != null)
                  TextButton(
                    key: const ValueKey('testdb-disconnect'),
                    onPressed: () => onDisconnect!(r),
                    child: const Text('Disconnect'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              r == null
                  ? 'Run the test database in Docker on the NAS (deploy/nas-testdb) and connect it with a code.'
                  : [
                      if (!r.online && r.lastSeenAt != null) 'Last seen ${whenText(r.lastSeenAt, now)}',
                      ?r.model,
                      if (r.appVersion != null) 'Version ${r.appVersion}',
                    ].join(' · '),
              style: t.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// A label and its value, as the mockup's rows.
class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: t.textTheme.bodyMedium)),
          const SizedBox(width: 8),
          Flexible(
            child: Align(alignment: Alignment.centerRight, child: value),
          ),
        ],
      ),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.text, {super.key, this.bad = false});
  final String text;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Text(
      text,
      textAlign: TextAlign.right,
      style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: bad ? t.colorScheme.error : null),
    );
  }
}

/// A failed migration's error, the files tried and the commit; a passed one's
/// re-run problem, if any.
class _RunDetail extends StatelessWidget {
  const _RunDetail({required this.run, required this.now});
  final TestDbRun run;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final small = t.textTheme.bodySmall;
    final lines = [
      run.target,
      whenText(run.finishedAt, now),
      if (run.headSha != null) 'commit ${run.headSha!.substring(0, run.headSha!.length < 7 ? run.headSha!.length : 7)}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(lines.join(' · '), style: small),
          if (run.files.isNotEmpty) Text(run.files.map((f) => f.split('/').last).join(', '), style: small),
          if (run.error != null) ...[
            const SizedBox(height: 6),
            Container(
              key: const ValueKey('testdb-error'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(
                run.error!,
                style: small?.copyWith(fontFamily: 'monospace', color: t.colorScheme.onErrorContainer),
              ),
            ),
          ],
          if (run.rerunProblem case final p?)
            Text(
              'Second run: $p',
              key: const ValueKey('testdb-rerun'),
              style: small?.copyWith(color: t.colorScheme.error),
            ),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.status);
  final TestDbRunStatus status;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (icon, color) = switch (status) {
      TestDbRunStatus.passed => (Icons.check_circle_outline, c.primary),
      TestDbRunStatus.failed => (Icons.error_outline, c.error),
      TestDbRunStatus.running => (Icons.play_circle_outline, c.tertiary),
      TestDbRunStatus.queued => (Icons.hourglass_empty, c.outline),
      TestDbRunStatus.cancelled => (Icons.block, c.outline),
    };
    return Icon(icon, color: color, semanticLabel: status.label);
  }
}
