import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/loading_skeleton.dart';
import '../../../widgets/map_tiles.dart';
import '../../../widgets/ride_map.dart';
import '../../admin_access.dart';
import '../../widgets/admin_widgets.dart';
import 'security_data.dart';
import 'session_logic.dart';

const _page = 'admin-session-history';

/// Session cards rendered in the detail sheet; the CSV export has them all.
const _sessionRenderCap = 40;
const _locationRenderCap = 200;

final _overviewProvider = FutureProvider.autoDispose((ref) => ref.watch(securityRepositoryProvider).sessionsOverview());
final _ipHealthProvider = FutureProvider.autoDispose((ref) => ref.watch(securityRepositoryProvider).ipLookupHealthy());

String _fmt(Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (d == null) return '${iso ?? ''}';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String? _s(Object? v) => v == null || '$v'.isEmpty ? null : '$v';

class AdminSessionHistoryScreen extends ConsumerStatefulWidget {
  const AdminSessionHistoryScreen({super.key});

  @override
  ConsumerState<AdminSessionHistoryScreen> createState() => _SessionHistoryState();
}

class _SessionHistoryState extends ConsumerState<AdminSessionHistoryScreen> {
  String _query = '';
  bool _flaggedOnly = false;
  bool _showGuard = false;
  bool _showDates = false;
  String _from = '';
  String _to = '';
  DeviceGuardConfig? _guard;
  bool _savingGuard = false;

  @override
  void initState() {
    super.initState();
    ref.read(securityRepositoryProvider).deviceGuardConfig().then((c) {
      if (mounted) setState(() => _guard = c);
    });
  }

  void _refresh() {
    ref.invalidate(_overviewProvider);
    ref.invalidate(_ipHealthProvider);
  }

  Future<void> _saveGuard(DeviceGuardConfig next) async {
    final prev = _guard;
    setState(() {
      _guard = next; // optimistic, reverted on failure
      _savingGuard = true;
    });
    final ok = await runAdminAction(context, () => ref.read(securityRepositoryProvider).setDeviceGuardConfig(next));
    if (!mounted) return;
    setState(() {
      _savingGuard = false;
      if (!ok) _guard = prev;
    });
  }

  Future<void> _pickDate(bool from) async {
    final current = DateTime.tryParse(from ? _from : _to) ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null) return;
    setState(() => from ? _from = ymd(d) : _to = ymd(d));
  }

  Future<void> _exportAll(List<Map<String, dynamic>> sessions) async {
    final range = dayRange(_from, _to);
    final rows = sessions.where((s) => inDayRange(s['captured_at'], range)).toList();
    if (rows.isEmpty) {
      showInfo(context, 'No sessions in the selected range.');
      return;
    }
    await exportCsv(context, 'sessions-${DateTime.now().millisecondsSinceEpoch}.csv', rowsToCsv(rows, allSessionCsvColumns));
  }

  @override
  Widget build(BuildContext context) {
    final level = ref.watch(securityLevelProvider(_page));
    final overview = ref.watch(_overviewProvider);
    final data = overview.value;
    final sessions = data?.sessions ?? const <Map<String, dynamic>>[];
    final users = data == null ? <UserSummary>[] : summarizeUsers(data.sessions, data.pings);
    final links = computeDeviceLinks(identitiesOf(sessions));
    final emulators = emulatorAccounts(sessions);
    final datesActive = _from.isNotEmpty || _to.isNotEmpty;

    return AdminPage(
      title: 'Session & location history',
      page: _page,
      actions: [
        if (links.isNotEmpty)
          IconButton(
            tooltip: 'Show flagged accounts only',
            isSelected: _flaggedOnly,
            icon: const Icon(Icons.group_outlined),
            selectedIcon: const Icon(Icons.group),
            onPressed: () => setState(() => _flaggedOnly = !_flaggedOnly),
          ),
        IconButton(
          tooltip: 'Duplicate-account guard',
          isSelected: _showGuard,
          icon: const Icon(Icons.shield_outlined),
          selectedIcon: const Icon(Icons.shield),
          onPressed: () => setState(() => _showGuard = !_showGuard),
        ),
        IconButton(
          tooltip: 'Filter by date',
          isSelected: _showDates || datesActive,
          icon: const Icon(Icons.calendar_today_outlined),
          selectedIcon: const Icon(Icons.calendar_today),
          onPressed: () => setState(() => _showDates = !_showDates),
        ),
        BusyIconButton(
          tooltip: 'Export sessions (CSV)',
          icon: const Icon(Icons.download),
          onPressed: data == null ? null : () => _exportAll(sessions),
        ),
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh),
      ],
      body: AsyncView(
        value: overview,
        onRetry: _refresh,
        data: (_) {
          final visible = users
              .where((u) => (!_flaggedOnly || links.containsKey(u.key)) && matchesUserQuery(u, _query))
              .toList();
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
              Text('${users.length} user${users.length == 1 ? '' : 's'}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              if (_showDates) _dateRow(),
              TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: 'Search phone, user id, device…', isDense: true),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 8),
              if (_showGuard) _guardCard(level == AccessLevel.edit),
              if (ref.watch(_ipHealthProvider).value == false)
                const _Banner(
                  icon: Icons.warning_amber,
                  color: Colors.orange,
                  text: "IP geolocation is unavailable — the ip-lookup edge function is not reachable, so Public IP, "
                      "ISP Org and IP Location won't be recorded on new sessions. Deploy it with "
                      "`supabase functions deploy ip-lookup --no-verify-jwt`.",
                ),
              if (links.isNotEmpty)
                _Banner(
                  icon: Icons.group,
                  color: Colors.orange,
                  text: '${links.length} account${links.length == 1 ? '' : 's'} sign in from a device also used by '
                      'another account — possible duplicate / multi-account activity. '
                      '${_flaggedOnly ? 'Showing flagged only — tap to show all.' : 'Tap to show only these.'}',
                  onTap: () => setState(() => _flaggedOnly = !_flaggedOnly),
                ),
              if (visible.isEmpty)
                EmptyState(
                  icon: Icons.person_search,
                  title: _flaggedOnly
                      ? 'No flagged accounts match.'
                      : _query.trim().isNotEmpty
                          ? 'No users match your search.'
                          : 'No session data yet.',
                  message: _flaggedOnly || _query.trim().isNotEmpty
                      ? null
                      : 'Sign in on a device to populate the tables.',
                ),
              for (final u in visible)
                _UserTile(
                  user: u,
                  link: links[u.key],
                  emulator: emulators.contains(u.key),
                  onTap: () => showAdminSheet(
                    context,
                    title: u.phone ?? '(no phone)',
                    builder: (_) => _AccountDetail(user: u, users: users, link: links[u.key], from: _from, to: _to),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }

  Widget _dateRow() => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.event),
            label: Text(_from.isEmpty ? 'From' : 'From $_from'),
            onPressed: () => _pickDate(true),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.event),
            label: Text(_to.isEmpty ? 'To' : 'To $_to'),
            onPressed: () => _pickDate(false),
          ),
          if (_from.isNotEmpty || _to.isNotEmpty)
            IconButton(
              tooltip: 'Clear dates',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _from = '';
                _to = '';
              }),
            ),
        ]),
      );

  Widget _guardCard(bool canEdit) {
    final g = _guard;
    final busy = g == null || _savingGuard || !canEdit;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.verified_user_outlined, size: 18),
            const SizedBox(width: 6),
            Text('Duplicate-account guard', style: Theme.of(context).textTheme.titleSmall),
          ]),
          const SizedBox(height: 4),
          const Text('Blocks a new sign-up when its device already backs this many other accounts. '
              'Enforced at registration.'),
          BusySwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            value: g?.enabled ?? true,
            onChanged: busy ? null : (v) => _saveGuard(g.copyWith(enabled: v)),
          ),
          Row(children: [
            const Expanded(child: Text('Max accounts / device')),
            BusyIconButton(
              tooltip: 'Lower the guard threshold',
              icon: const Icon(Icons.remove),
              onPressed: busy || g.maxAccountsPerDevice <= 1
                  ? null
                  : () => _saveGuard(g.copyWith(maxAccountsPerDevice: g.maxAccountsPerDevice - 1)),
            ),
            Text('${g?.maxAccountsPerDevice ?? '—'}', style: Theme.of(context).textTheme.titleMedium),
            BusyIconButton(
              tooltip: 'Raise the guard threshold',
              icon: const Icon(Icons.add),
              onPressed: busy || g.maxAccountsPerDevice >= 50
                  ? null
                  : () => _saveGuard(g.copyWith(maxAccountsPerDevice: g.maxAccountsPerDevice + 1)),
            ),
          ]),
          BusySwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Block emulators'),
            subtitle: const Text('Refuse sign-ups from simulators/emulators. Best-effort — a modified client can '
                'spoof this.'),
            value: g?.blockEmulators ?? false,
            onChanged: busy ? null : (v) => _saveGuard(g.copyWith(blockEmulators: v)),
          ),
          if (_savingGuard) const Text('Saving…'),
        ]),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text, this.onTap});
  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
        color: color.withValues(alpha: 0.12),
        child: ListTile(leading: Icon(icon, color: color), title: Text(text), onTap: onTap),
      );
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user, required this.link, required this.emulator, required this.onTap});
  final UserSummary user;
  final AccountLink? link;
  final bool emulator;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final u = user;
    final initials = (u.phone ?? u.userId ?? '?').replaceAll(RegExp('[^A-Za-z0-9]'), '');
    final n = link?.linkedAccounts.length ?? 0;
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          child: Text(initials.isEmpty ? '?' : initials.substring(initials.length < 2 ? 0 : initials.length - 2).toUpperCase()),
        ),
        title: Text(u.phone ?? '(no phone)'),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${u.lastOs ?? 'Unknown OS'}${u.lastDevice != null ? ' · ${u.lastDevice}' : ''}'),
          Text('${u.sessionCount} session${u.sessionCount == 1 ? '' : 's'} · last ${_fmt(u.lastSeen)}'),
          if (u.lastIsp != null) Text('ISP: ${u.lastIsp}'),
          if (u.lastLat != null && u.lastLng != null)
            Text('Last ping ${u.lastLat!.toStringAsFixed(3)}, ${u.lastLng!.toStringAsFixed(3)}'),
          if (link != null || emulator)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                if (link != null) _Pill('Shares device with $n other account${n == 1 ? '' : 's'}', Colors.orange),
                if (emulator) const _Pill('Emulator / simulator', Colors.red),
              ]),
            ),
        ]),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

class _AccountDetail extends ConsumerStatefulWidget {
  const _AccountDetail({required this.user, required this.users, required this.link, required this.from, required this.to});
  final UserSummary user;
  final List<UserSummary> users;
  final AccountLink? link;
  final String from;
  final String to;

  @override
  ConsumerState<_AccountDetail> createState() => _AccountDetailState();
}

class _AccountDetailState extends ConsumerState<_AccountDetail> {
  late final _future = ref.read(securityRepositoryProvider).accountDetail(widget.user);

  String get _phoneTag {
    final t = (widget.user.phone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    return t.isEmpty ? 'user' : t;
  }

  Future<void> _openTrail() async {
    final rows = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) => _TrailOptionsDialog(user: widget.user),
    );
    if (rows == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _TrailPage(title: widget.user.phone ?? '(no phone)', pings: rows),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    final t = Theme.of(context);
    final range = dayRange(widget.from, widget.to);
    return FutureBuilder(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) return Text(errorText(snap.error!));
        if (!snap.hasData) return const LoadingSkeletonPage();
        final all = snap.data!;
        final sessions = all.sessions.where((s) => inDayRange(s['captured_at'], range)).toList();
        final locations = all.locations.where((l) => inDayRange(l['captured_at'], range)).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (u.lastLat != null && u.lastLng != null) ...[
            SizedBox(
              height: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RideMap(pickup: LatLng(u.lastLat!, u.lastLng!)),
              ),
            ),
            const SizedBox(height: 4),
            Text('Last known location · ${_fmt(u.lastPingAt)}', style: t.textTheme.bodySmall),
            const SizedBox(height: 12),
          ],
          if (widget.link != null)
            Card(
              color: Colors.orange.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Possible duplicate account', style: t.textTheme.titleSmall),
                  Text('Shares ${widget.link!.sharedDevices.length} device'
                      '${widget.link!.sharedDevices.length == 1 ? '' : 's'} with:'),
                  for (final k in widget.link!.linkedAccounts) Text('• ${accountLabel(k, widget.users)}'),
                ]),
              ),
            ),
          if (widget.from.isNotEmpty || widget.to.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Chip(
                avatar: const Icon(Icons.calendar_today, size: 14),
                label: Text('${widget.from.isEmpty ? '…' : widget.from} → ${widget.to.isEmpty ? '…' : widget.to}'),
              ),
            ),
          if (all.locations.isNotEmpty)
            FilledButton.icon(onPressed: _openTrail, icon: const Icon(Icons.map), label: const Text('View full trail')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Text(
                'Sessions (${sessions.length}${sessions.length != all.sessions.length ? ' of ${all.sessions.length}' : ''})',
                style: t.textTheme.titleMedium,
              ),
            ),
            BusyButton.text(
              icon: const Icon(Icons.download, size: 16),
              onPressed: sessions.isEmpty
                  ? null
                  : () => exportCsv(context, 'sessions-$_phoneTag-${DateTime.now().millisecondsSinceEpoch}.csv',
                      rowsToCsv(sessions, userSessionCsvColumns)),
              child: const Text('CSV'),
            ),
          ]),
          if (sessions.isEmpty) const Text('No sessions in range.'),
          for (final s in sessions.take(_sessionRenderCap)) _SessionCard(s),
          if (sessions.length > _sessionRenderCap)
            Text('Showing the $_sessionRenderCap most recent of ${sessions.length} sessions — export CSV for the full list.',
                style: t.textTheme.bodySmall),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: Text(
                'Location pings (${locations.length}'
                '${locations.length != all.locations.length ? ' of ${all.locations.length}' : ''})',
                style: t.textTheme.titleMedium,
              ),
            ),
            BusyButton.text(
              icon: const Icon(Icons.download, size: 16),
              onPressed: locations.isEmpty
                  ? null
                  : () => exportCsv(context, 'locations-$_phoneTag-${DateTime.now().millisecondsSinceEpoch}.csv',
                      rowsToCsv(locations, locationCsvColumns)),
              child: const Text('CSV'),
            ),
          ]),
          if (locations.isEmpty) const Text('No location pings in range.'),
          for (final l in locations.take(_locationRenderCap))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_outlined),
              title: Text('${(l['latitude'] as num?)?.toStringAsFixed(6)}, ${(l['longitude'] as num?)?.toStringAsFixed(6)}'),
              subtitle: Text([
                _fmt(l['captured_at']),
                if (l['accuracy'] is num) '±${(l['accuracy'] as num).round()}m',
                if (l['speed'] is num && (l['speed'] as num) >= 0) '${(l['speed'] as num).toStringAsFixed(1)} m/s',
                if (_s(l['device_id']) != null) 'Device: ${l['device_id']}',
              ].join(' · ')),
            ),
          if (locations.length > _locationRenderCap)
            Text('Showing the $_locationRenderCap most recent pings — export CSV for the full list.',
                style: t.textTheme.bodySmall),
        ]);
      },
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard(this.s);
  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    String or(Object? v) => _s(v) ?? '—';
    final ipLoc = [s['ip_city'], s['ip_region'], s['ip_country']].map(_s).whereType<String>().join(', ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            StatusChip(_s(s['event_type'])),
            const Spacer(),
            Text(_fmt(s['captured_at']), style: Theme.of(context).textTheme.bodySmall),
          ]),
          const SizedBox(height: 8),
          DetailTable({
            'Device': '${_s(s['device_brand']) ?? _s(s['device_manufacturer']) ?? '?'} ${_s(s['device_model_name']) ?? ''}'.trim(),
            'Model ID': or(s['device_model_id']),
            'OS': '${_s(s['os_name']) ?? '?'}${_s(s['os_version']) != null ? ' ${s['os_version']}' : ''}',
            'Network': '${_s(s['network_type']) ?? '?'}${_s(s['network_operator']) != null ? ' · ${s['network_operator']}' : ''}',
            'Connection': or(s['connection_type']),
            'ISP / Provider': or(s['isp_provider']),
            'ISP Org': or(s['isp_org']),
            'IP Location': ipLoc.isEmpty ? '—' : ipLoc,
            'Mobile Operator': or(s['mobile_operator_name']),
            'MCC / MNC': formatPlmn(_s(s['mobile_country_code']), _s(s['mobile_network_code'])) ?? '—',
            'SIM Type': or(s['cellular_generation']),
            'SIM Serial (ICCID)': or(s['iccid']),
            'Local IP': or(s['ip_address']),
            'Public IP': or(s['public_ip']),
            'App': '${_s(s['app_version']) ?? '?'}${_s(s['app_build_version']) != null ? ' (${s['app_build_version']})' : ''}',
            'Device ID': or(s['device_id']),
          }),
        ]),
      ),
    );
  }
}

class _TrailOptionsDialog extends ConsumerStatefulWidget {
  const _TrailOptionsDialog({required this.user});
  final UserSummary user;

  @override
  ConsumerState<_TrailOptionsDialog> createState() => _TrailOptionsDialogState();
}

class _TrailOptionsDialogState extends ConsumerState<_TrailOptionsDialog> {
  TrailScope _scope = TrailScope.today;
  bool _timeFilter = false;
  TimeOfDay _timeFrom = const TimeOfDay(hour: 0, minute: 0);
  TimeOfDay _timeTo = const TimeOfDay(hour: 23, minute: 59);
  String _rangeFrom = '';
  String _rangeTo = '';
  bool _loading = false;
  String? _error;

  String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _apply() async {
    String? err;
    final window = trailWindow(_scope, DateTime.now(),
        rangeFrom: _rangeFrom, rangeTo: _rangeTo, onError: (e) => err = e);
    if (window == null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var rows = await ref.read(securityRepositoryProvider).trail(widget.user, window.start, window.end);
      if (_timeFilter) rows = filterByTimeOfDay(rows, _hhmm(_timeFrom), _hhmm(_timeTo));
      if (mounted) Navigator.pop(context, rows);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _date(bool from) async {
    final d = await showDatePicker(
        context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now());
    if (d != null) setState(() => from ? _rangeFrom = ymd(d) : _rangeTo = ymd(d));
  }

  Future<void> _time(bool from) async {
    final t = await showTimePicker(context: context, initialTime: from ? _timeFrom : _timeTo);
    if (t != null) setState(() => from ? _timeFrom = t : _timeTo = t);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Location trail'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<TrailScope>(
              segments: const [
                ButtonSegment(value: TrailScope.today, label: Text('Today')),
                ButtonSegment(value: TrailScope.yesterday, label: Text('Yesterday')),
                ButtonSegment(value: TrailScope.range, label: Text('Range')),
              ],
              selected: {_scope},
              onSelectionChanged: (s) => setState(() => _scope = s.first),
            ),
            if (_scope == TrailScope.range)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, children: [
                  OutlinedButton(onPressed: () => _date(true), child: Text(_rangeFrom.isEmpty ? 'From' : _rangeFrom)),
                  OutlinedButton(onPressed: () => _date(false), child: Text(_rangeTo.isEmpty ? 'To' : _rangeTo)),
                ]),
              ),
            const SizedBox(height: 16),
            const Text('Time of day'),
            const SizedBox(height: 6),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('All')),
                ButtonSegment(value: true, label: Text('Time filter')),
              ],
              selected: {_timeFilter},
              onSelectionChanged: (s) => setState(() => _timeFilter = s.first),
            ),
            if (_timeFilter)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, children: [
                  OutlinedButton(onPressed: () => _time(true), child: Text('From ${_hhmm(_timeFrom)}')),
                  OutlinedButton(onPressed: () => _time(false), child: Text('To ${_hhmm(_timeTo)}')),
                ]),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          BusyButton.filled(
            onPressed: _loading ? null : _apply,
            child: const Text('Show trail'),
          ),
        ],
      );
}

class _TrailPage extends StatefulWidget {
  const _TrailPage({required this.title, required this.pings});
  final String title;
  final List<Map<String, dynamic>> pings;

  @override
  State<_TrailPage> createState() => _TrailPageState();
}

class _TrailPageState extends State<_TrailPage> {
  bool _heatmap = false;

  @override
  Widget build(BuildContext context) {
    final coords = [for (final c in trailCoordinates(widget.pings)) LatLng(c.lat, c.lng)];
    final points = [
      for (final p in sampleEvenly(widget.pings, 80))
        if (p['latitude'] is num && p['longitude'] is num)
          LatLng((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble()),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('Location trail · ${widget.title} · ${widget.pings.length} pings'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.route), label: Text('Path')),
                ButtonSegment(value: true, icon: Icon(Icons.local_fire_department), label: Text('Heat')),
              ],
              selected: {_heatmap},
              onSelectionChanged: (s) => setState(() => _heatmap = s.first),
            ),
          ),
        ],
      ),
      body: widget.pings.isEmpty
          ? const EmptyState(icon: Icons.location_off, title: 'No location pings in this window.')
          : _heatmap
              ? _HeatMap(points: points)
              : coords.length < 2
                  ? RideMap(pickup: points.isEmpty ? null : points.first)
                  : RideMap(pickup: coords.first, drop: coords.last, route: coords),
    );
  }
}

class _HeatMap extends StatelessWidget {
  const _HeatMap({required this.points});
  final List<LatLng> points;

  @override
  Widget build(BuildContext context) => FlutterMap(
        options: MapOptions(
          initialCameraFit: points.length > 1
              ? CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(48), maxZoom: 16)
              : null,
          initialCenter: points.isEmpty ? const LatLng(3.139, 101.6869) : points.first,
          initialZoom: 14,
        ),
        children: [
          baseTileLayer(context),
          CircleLayer(circles: [
            for (final p in points)
              CircleMarker(
                point: p,
                radius: 80,
                useRadiusInMeter: true,
                color: const Color(0x2EEF4444),
                borderColor: const Color(0x00000000),
              ),
          ]),
          const RichAttributionWidget(
            alignment: AttributionAlignment.bottomLeft,
            attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
          ),
        ],
      );
}
