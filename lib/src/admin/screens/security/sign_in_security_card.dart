// Admin → App Settings → Sign-in security (migrations 0179 and 0180), and
// Admin → Users → an account's current device with "Sign out all devices".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/sign_in_security.dart';
import '../../../data/session_guard.dart';
import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../../widgets/page_style_host.dart';

class SignInSecurityCard extends ConsumerStatefulWidget {
  const SignInSecurityCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<SignInSecurityCard> createState() => _SignInSecurityCardState();
}

class _SignInSecurityCardState extends ConsumerState<SignInSecurityCard> {
  SignInConfig? _edited;

  Future<void> _save(SignInConfig stored, SignInConfig next) async {
    if (next.oneDevice && !stored.oneDevice) {
      final ok = await showAppDialog<bool>(id: 'sign-in-security.save',
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('One device per account?'),
          content: const Text(
            'Accounts that are not admins or sub-admins will be signed in on one device at a time: signing in '
            'on a new phone signs the old one out.\n\n'
            'Turn this on only once App updates\' minimum is 1.4.8 or later. Older builds are not told why '
            'they stopped working.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Turn on')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final db = ref.read(supabaseProvider);
    final saved = await runAdminAction(
      context,
      () => db.rpc('set_sign_in_config', params: {'p_config': next.toJson()}),
      success: 'Sign-in security saved',
    );
    if (!mounted || !saved) return;
    setState(() => _edited = null);
    ref.invalidate(signInConfigProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return AsyncView(
      value: ref.watch(signInConfigProvider),
      onRetry: () => ref.invalidate(signInConfigProvider),
      data: (stored) {
        final c = _edited ?? stored;
        Widget toggle(String key, String title, String subtitle, bool value, SignInConfig Function(bool) set) =>
            SwitchListTile(
              key: ValueKey('sign-in-$key'),
              contentPadding: EdgeInsets.zero,
              value: value,
              onChanged: widget.canEdit ? (v) => setState(() => _edited = set(v)) : null,
              title: Text(title),
              subtitle: Text(subtitle),
            );
        return Card(
          key: const ValueKey('sign-in-security-card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Sign-in security', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Passkeys let people sign in with their face or fingerprint. Turn each surface on only once it is '
                  'set up: passkeys on in the Supabase dashboard (relying party www.getride.my) for all three, plus the '
                  'app association files for Android and iOS. A button shown before that fails for everyone.',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                const SizedBox(height: 8),
                toggle(
                  'passkey-web',
                  'Passkeys on the website',
                  'Sign in with a passkey on www.getride.my.',
                  c.passkeyWeb,
                  (v) => c.copyWith(passkeyWeb: v),
                ),
                toggle(
                  'passkey-android',
                  'Passkeys in the Android app',
                  'Needs assetlinks.json with both signing keys.',
                  c.passkeyAndroid,
                  (v) => c.copyWith(passkeyAndroid: v),
                ),
                toggle(
                  'passkey-ios',
                  'Passkeys in the iOS app',
                  'Needs the webcredentials association for www.getride.my.',
                  c.passkeyIos,
                  (v) => c.copyWith(passkeyIos: v),
                ),
                const Divider(height: 24),
                toggle(
                  'one-device',
                  'One device per account',
                  c.oneDevice
                      ? 'On: signing in on a new device signs the old one out. Admins and sub-admins are not limited.'
                      : 'Off: an account may be signed in on several devices.',
                  c.oneDevice,
                  (v) => c.copyWith(oneDevice: v),
                ),
                if (widget.canEdit) ...[
                  const SizedBox(height: 8),
                  BusyButton.filled(
                    key: const ValueKey('sign-in-security-save'),
                    onPressed: c == stored ? null : () => _save(stored, c),
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save sign-in security'),
                  ),
                ],
                if (stored.oneDevice) ...[
                  const Divider(height: 24),
                  DeviceAllowancesList(canEdit: widget.canEdit),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The account's recorded device, or null when none (off, an admin, or
/// a database without 0180).
final activeSessionProvider = FutureProvider.autoDispose.family<Map<String, dynamic>?, String>((ref, userId) async {
  try {
    final row = await ref.watch(supabaseProvider).from('active_sessions').select().eq('user_id', userId).maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  } catch (_) {
    return null;
  }
});

/// An account's device allowance (0298): how many devices it may use at
/// once and why; one, the default, when none is set or it can't be read.
final deviceAllowanceProvider = FutureProvider.autoDispose.family<({int devices, String? reason}), String>((ref, userId) async {
  try {
    final row = await ref.watch(supabaseProvider).from('device_allowances').select().eq('user_id', userId).maybeSingle();
    return (devices: (row?['devices'] as num?)?.toInt() ?? 1, reason: row?['reason'] as String?);
  } catch (_) {
    return (devices: 1, reason: null);
  }
});

/// The devices of an account with an allowance, newest first (0298); a
/// placeholder row left by "Sign out" (no device) is not one of them.
final accountDevicesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, userId) async {
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('account_devices')
        .select()
        .eq('user_id', userId)
        .order('claimed_at', ascending: false);
    return [
      for (final r in rows)
        if (r['device_id'] != null || r['device_label'] != null) Map<String, dynamic>.from(r),
    ];
  } catch (_) {
    return const [];
  }
});

/// The accounts allowed more than one device, for Sign-in security.
final deviceAllowancesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  try {
    final rows = await ref.watch(supabaseProvider).rpc('admin_device_allowances');
    return [if (rows is List) for (final r in rows) if (r is Map) Map<String, dynamic>.from(r)];
  } catch (_) {
    return const [];
  }
});

String _when(DateTime d) => DateFormat('d MMM HH:mm').format(d);

/// In the user sheet: how many devices the account may use, where it is
/// signed in, and the buttons that end those sign-ins (a lost or stolen
/// phone, a support case).
class ActiveDeviceSection extends ConsumerStatefulWidget {
  const ActiveDeviceSection({super.key, required this.userId, required this.canEdit});

  final String userId;
  final bool canEdit;

  @override
  ConsumerState<ActiveDeviceSection> createState() => _ActiveDeviceSectionState();
}

class _ActiveDeviceSectionState extends ConsumerState<ActiveDeviceSection> {
  int? _devices;
  final _reason = TextEditingController();
  ({int devices, String? reason})? _loaded;

  String get _userId => widget.userId;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(activeSessionProvider(_userId));
    ref.invalidate(accountDevicesProvider(_userId));
    ref.invalidate(deviceAllowanceProvider(_userId));
    ref.invalidate(deviceAllowancesProvider);
  }

  Future<void> _signOutEverywhere() async {
    final ok = await showAppDialog<bool>(id: 'sign-in-security.sign-out-everywhere',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sign out all devices?'),
        content: const Text(
          'Every device signed in to this account is signed out. They can sign in again with their number.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out all')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await runAdminAction(
      context,
      () => ref.read(supabaseProvider).rpc('admin_sign_out_everywhere', params: {'p_user': _userId}),
      success: 'Signed out of every device',
    );
    _refresh();
  }

  Future<void> _signOutDevice(Map<String, dynamic> d) async {
    await runAdminAction(
      context,
      () => ref
          .read(supabaseProvider)
          .rpc('admin_sign_out_device', params: {'p_user': _userId, 'p_session': d['session_id']}),
      success: 'That device was signed out',
    );
    _refresh();
  }

  Future<void> _saveAllowance(int devices) async {
    final ok = await runAdminAction(
      context,
      () => saveDeviceAllowance(ref, _userId, devices, _reason.text),
      success: devices == 1 ? 'Back to one device' : 'This account may use $devices devices',
    );
    if (ok && mounted) {
      setState(() => _devices = null);
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final allowance = ref.watch(deviceAllowanceProvider(_userId)).value ?? (devices: 1, reason: null);
    if (_loaded != allowance) {
      _loaded = allowance;
      _reason.text = allowance.reason ?? '';
    }
    final devices = _devices ?? allowance.devices;
    final several = allowance.devices > 1;
    final row = ref.watch(activeSessionProvider(_userId)).value;
    final list = several ? (ref.watch(accountDevicesProvider(_userId)).value ?? const []) : const <Map<String, dynamic>>[];
    final changed = devices != allowance.devices || (devices > 1 && _reason.text.trim() != (allowance.reason ?? ''));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              const Text('Allowed devices'),
              DeviceCountStepper(
                value: devices,
                onChanged: widget.canEdit ? (v) => setState(() => _devices = v) : null,
              ),
            ],
          ),
          Text(
            devices == 1
                ? 'App default: one device at a time.'
                : 'This account may stay signed in on up to $devices devices at once. A new sign-in past that '
                    'signs out the device that signed in longest ago.',
            key: const ValueKey('admin-user-devices-line'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          if (devices > 1) ...[
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('admin-user-devices-reason'),
              controller: _reason,
              enabled: widget.canEdit,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Reason (only admins see it)'),
              onChanged: (_) => setState(() {}),
            ),
          ],
          if (widget.canEdit && changed)
            Align(
              alignment: Alignment.centerLeft,
              child: BusyButton.tonal(
                key: const ValueKey('admin-user-devices-save'),
                onPressed: () => _saveAllowance(devices),
                icon: const Icon(Icons.save_outlined),
                child: const Text('Save devices'),
              ),
            ),
          const SizedBox(height: 4),
          if (several) ...[
            Text('Signed in now · ${list.length} of ${allowance.devices}', style: t.textTheme.titleSmall),
            for (final d in list)
              ListTile(
                key: ValueKey('admin-user-device-${d['session_id']}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.smartphone),
                title: Text('${d['device_label'] ?? 'Device'}'),
                subtitle: Text(activeDeviceLine(d, when: _when), style: t.textTheme.bodySmall),
                trailing: widget.canEdit
                    ? BusyButton.outlined(
                        key: ValueKey('admin-user-device-signout-${d['session_id']}'),
                        onPressed: () => _signOutDevice(d),
                        child: const Text('Sign out'),
                      )
                    : null,
              ),
          ] else
            ListTile(
              key: const ValueKey('admin-user-device'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.smartphone),
              title: const Text('Signed in on'),
              subtitle: Text(
                row == null ? 'Not limited to one device' : activeDeviceLine(row, when: _when),
                style: t.textTheme.bodySmall,
              ),
            ),
          if (widget.canEdit)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('admin-user-sign-out-everywhere'),
                icon: const Icon(Icons.logout),
                label: const Text('Sign out all devices'),
                onPressed: _signOutEverywhere,
              ),
            ),
        ],
      ),
    );
  }
}

/// Saves how many devices [userId] may use (1 = the app default).
Future<void> saveDeviceAllowance(WidgetRef ref, String userId, int devices, String reason) => ref
    .read(supabaseProvider)
    .rpc('admin_device_allowance_set', params: {
      'p_user': userId,
      'p_devices': devices,
      'p_reason': reason.trim().isEmpty ? null : reason.trim(),
    });

/// − and + around a device count from 1 to 10.
class DeviceCountStepper extends StatelessWidget {
  const DeviceCountStepper({super.key, required this.value, this.onChanged});

  final int value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final change = onChanged;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton.outlined(
        key: const ValueKey('devices-less'),
        tooltip: 'Fewer devices',
        onPressed: change != null && value > 1 ? () => change(value - 1) : null,
        icon: const Icon(Icons.remove),
      ),
      SizedBox(
        width: 36,
        child: Text(
          '$value',
          key: const ValueKey('devices-count'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      IconButton.outlined(
        key: const ValueKey('devices-more'),
        tooltip: 'More devices',
        onPressed: change != null && value < 10 ? () => change(value + 1) : null,
        icon: const Icon(Icons.add),
      ),
    ]);
  }
}

/// Sign-in security: the accounts allowed more than one device, and a way
/// to allow one more.
class DeviceAllowancesList extends ConsumerWidget {
  const DeviceAllowancesList({super.key, required this.canEdit});

  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, {Map<String, dynamic>? account}) async {
    final saved = await showAppDialog<bool>(id: 'sign-in-security.allow-devices',
      context: context,
      builder: (_) => AllowDevicesDialog(account: account),
    );
    if (saved == true) ref.invalidate(deviceAllowancesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final rows = ref.watch(deviceAllowancesProvider).value ?? const [];
    return Column(
      key: const ValueKey('device-allowances'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Accounts allowed more than one device', style: t.textTheme.titleSmall),
        const SizedBox(height: 4),
        if (rows.isEmpty)
          Text('None. Every account is held to one device.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        for (final r in rows)
          ListTile(
            key: ValueKey('device-allowance-${r['user_id']}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.devices_other),
            title: Text([r['name'], r['display_id']].whereType<String>().where((x) => x.isNotEmpty).join(' · ')),
            subtitle: Text(
              [
                '${r['devices']} devices · ${r['in_use'] ?? 0} in use',
                if ('${r['reason'] ?? ''}'.isNotEmpty) '${r['reason']}',
              ].join(' · '),
              style: t.textTheme.bodySmall,
            ),
            trailing: canEdit
                ? TextButton(
                    key: ValueKey('device-allowance-change-${r['user_id']}'),
                    onPressed: () => _edit(context, ref, account: {
                      'id': r['user_id'],
                      'name': r['name'],
                      'display_id': r['display_id'],
                      'devices': r['devices'],
                      'reason': r['reason'],
                    }),
                    child: const Text('Change'),
                  )
                : null,
          ),
        if (canEdit)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('device-allowance-add'),
              icon: const Icon(Icons.person_search),
              label: const Text('Allow an account more devices'),
              onPressed: () => _edit(context, ref),
            ),
          ),
      ],
    );
  }
}

/// Finds an account (by name, phone or ID) and sets its device allowance;
/// opened on one account, only sets it. Pops true once saved.
class AllowDevicesDialog extends ConsumerStatefulWidget {
  const AllowDevicesDialog({super.key, this.account});

  final Map<String, dynamic>? account;

  @override
  ConsumerState<AllowDevicesDialog> createState() => _AllowDevicesDialogState();
}

class _AllowDevicesDialogState extends ConsumerState<AllowDevicesDialog> {
  final _query = TextEditingController();
  final _reason = TextEditingController();
  List<Map<String, dynamic>> _found = const [];
  bool _searching = false;
  Map<String, dynamic>? _picked;
  int _devices = 2;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    if (a != null) _pick(a);
  }

  @override
  void dispose() {
    _query.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _pick(Map<String, dynamic> a) {
    _picked = a;
    _devices = ((a['devices'] as num?)?.toInt() ?? 2).clamp(1, 10);
    if (_devices < 2 && widget.account == null) _devices = 2;
    _reason.text = '${a['reason'] ?? ''}';
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final page = await ref.read(adminRepositoryProvider).users(limit: 20, query: q);
      if (mounted) setState(() => _found = page.rows);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _save() async {
    final a = _picked;
    if (a == null) return;
    final ok = await runAdminAction(
      context,
      () => saveDeviceAllowance(ref, '${a['id']}', _devices, _reason.text),
    );
    if (ok && mounted) Navigator.pop(context, true);
  }

  String _name(Map<String, dynamic> a) =>
      [a['name'], a['display_id'], a['phone']].whereType<String>().where((x) => x.isNotEmpty).join(' · ');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final a = _picked;
    return AlertDialog(
      title: const Text('Devices for an account'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (a == null) ...[
              TextField(
                key: const ValueKey('allow-devices-search'),
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Name, phone or ID',
                  suffixIcon: IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: _search),
                ),
                onSubmitted: (_) => _search(),
              ),
              if (_searching) const LinearProgressIndicator(),
              for (final r in _found)
                ListTile(
                  key: ValueKey('allow-devices-pick-${r['id']}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(_name(r)),
                  onTap: () => setState(() => _pick(r)),
                ),
              if (!_searching && _found.isEmpty && _query.text.trim().isNotEmpty)
                Text('Search to find the account.', style: t.textTheme.bodySmall),
            ] else ...[
              Text(_name(a), style: t.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                const Text('Allowed devices'),
                DeviceCountStepper(value: _devices, onChanged: (v) => setState(() => _devices = v)),
              ]),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('allow-devices-reason'),
                controller: _reason,
                maxLength: 200,
                decoration: const InputDecoration(labelText: 'Reason (only admins see it)'),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        if (a != null)
          BusyButton.filled(
            key: const ValueKey('allow-devices-save'),
            onPressed: _save,
            child: Text(_devices == 1 ? 'Back to one device' : 'Allow $_devices devices'),
          ),
      ],
    );
  }
}
