// A stand admin's own staff (migration 0251): staff IDs made by phone, each
// with their access chips and on/off. The server lets a stand admin touch
// only their stands' staff rows, and only their access and on/off.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dispatch.dart';
import '../../data/dispatch_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/search_select.dart';
import 'dispatch_console.dart' show dispatchErrorText;

final standStaffProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
  (ref, standId) => ref.watch(dispatchRepositoryProvider).staff(standId),
);

class StandStaffView extends ConsumerStatefulWidget {
  const StandStaffView({super.key, required this.stands});

  /// The stands the caller is the stand admin of.
  final List<DispatchStand> stands;

  @override
  ConsumerState<StandStaffView> createState() => _StandStaffViewState();
}

class _StandStaffViewState extends ConsumerState<StandStaffView> {
  late String _standId = widget.stands.first.id;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  StandPerms _perms = const StandPerms(broadcast: true);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  DispatchStand get _stand => widget.stands.firstWhere((s) => s.id == _standId, orElse: () => widget.stands.first);

  Future<void> _create() async {
    final name = _name.text.trim();
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (name.isEmpty) return setState(() => _error = 'Give their name.');
    if (digits.length < 8 || digits.length > 15) return setState(() => _error = "The phone number doesn't look right.");
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final made = await ref
          .read(dispatchRepositoryProvider)
          .grant(kind: 'staff', name: name, phone: _phone.text, standIds: [_standId], perms: _perms);
      if (!mounted) return;
      _name.clear();
      _phone.clear();
      ref.invalidate(standStaffProvider(_standId));
      showInfo(context, made ? 'Staff ID made. They get an SMS to set their PIN.' : 'Staff added.');
    } catch (e) {
      if (mounted) setState(() => _error = e is DispatchAccountError ? '$e' : dispatchErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update(String userId, {StandPerms? perms, bool? active}) async {
    try {
      await ref.read(dispatchRepositoryProvider).setStaff(_standId, userId, perms: perms, active: active);
      ref.invalidate(standStaffProvider(_standId));
    } catch (e) {
      if (mounted) showError(context, dispatchErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final async = ref.watch(standStaffProvider(_standId));
    final staff = async.value ?? const <Map<String, dynamic>>[];

    final form = Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Add staff', style: t.textTheme.titleMedium),
            if (widget.stands.length > 1) ...[
              const SizedBox(height: 8),
              SearchableDropdownFormField<String>(
                key: const ValueKey('staff-stand'),
                initialValue: _standId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Stand', border: OutlineInputBorder(), isDense: true),
                items: [for (final s in widget.stands) DropdownMenuItem(value: s.id, child: Text(s.name))],
                onChanged: (v) => setState(() => _standId = v ?? _standId),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('staff-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('staff-phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone (their sign-in ID)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Text('Access', style: muted),
            const SizedBox(height: 4),
            AccessChips(perms: _perms, onToggle: (a) => setState(() => _perms = _perms.toggled(a)), keyPrefix: 'new'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: t.colorScheme.error)),
              ),
            const SizedBox(height: 10),
            FilledButton(
              key: const ValueKey('staff-create'),
              onPressed: _busy ? null : _create,
              child: const Text('Create staff ID'),
            ),
            const SizedBox(height: 6),
            Text(
              'Staff sign in with their phone and a PIN they set from the SMS. They only see the console for '
              '${_stand.shortName}, with the access you give.',
              style: muted,
            ),
          ],
        ),
      ),
    );

    final list = Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Staff at ${_stand.shortName}', style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (async.isLoading && async.value == null) const LinearProgressIndicator(),
            if (async.hasValue && staff.isEmpty) Text('No staff yet.', style: muted),
            ListSearchFilter(
              count: staff.length,
              hint: 'Search staff',
              fieldKey: const ValueKey('staff-search'),
              builder: (_, q) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in staff)
                    if (q.isEmpty || '${s['name']} ${s['phone']}'.toLowerCase().contains(q.toLowerCase()))
                      _StaffRow(
                        row: s,
                        onPerms: (p) => _update('${s['user_id']}', perms: p),
                        onActive: (v) => _update('${s['user_id']}', active: v),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (_, c) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (c.maxWidth >= 860)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: form),
                const SizedBox(width: 16),
                Expanded(child: list),
              ],
            )
          else ...[
            form,
            const SizedBox(height: 16),
            list,
          ],
        ],
      ),
    );
  }
}

class _StaffRow extends StatelessWidget {
  const _StaffRow({required this.row, required this.onPerms, required this.onActive});
  final Map<String, dynamic> row;
  final ValueChanged<StandPerms> onPerms;
  final ValueChanged<bool> onActive;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final perms = StandPerms.fromStaffRow(row);
    final id = '${row['user_id']}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: t.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${row['name'] ?? 'Staff'}', style: t.textTheme.bodyLarge),
                    if (row['phone'] != null)
                      Text(
                        '${row['phone']}',
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    const SizedBox(height: 6),
                    AccessChips(perms: perms, onToggle: (a) => onPerms(perms.toggled(a)), keyPrefix: id),
                  ],
                ),
              ),
              Switch(key: ValueKey('staff-active-$id'), value: row['active'] != false, onChanged: onActive),
            ],
          ),
        ),
      ),
    );
  }
}

/// The access chips: Assign, Broadcast, Fixed fare, Cancel, Reassign, See reports.
class AccessChips extends StatelessWidget {
  const AccessChips({super.key, required this.perms, required this.onToggle, this.keyPrefix = '', this.enabled = true});

  final StandPerms perms;
  final ValueChanged<StaffAccess> onToggle;
  final String keyPrefix;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final a in StaffAccess.values)
        FilterChip(
          key: ValueKey('access-$keyPrefix-${a.name}'),
          label: Text(a.label),
          selected: perms.has(a),
          onSelected: enabled ? (_) => onToggle(a) : null,
        ),
    ],
  );
}
