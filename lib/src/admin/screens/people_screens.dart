import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:url_launcher/url_launcher.dart';

import '../../core/account_deletion.dart';
import '../../core/partner_status.dart';
import '../../data/account_deletion_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../account_app_version.dart';
import '../admin_access.dart';
import '../admin_filters.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../../widgets/in_app_page.dart';
import '../../widgets/net_image.dart';
import 'people/account_deletion_section.dart';
import 'people/people_data.dart';
import 'people/vehicle_screens.dart' show confirmVehicleApprovable;
import 'security/sign_in_security_card.dart';
import '../../data/live_tables.dart';

final adminUsersProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('profiles');
  return ref.watch(adminRepositoryProvider).users();
});
final adminPartnersProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('partners');
  return ref.watch(adminRepositoryProvider).partners();
});
final adminVehiclesProvider = FutureProvider.autoDispose((ref) {
  ref.watchAdminLive('vehicle');
  return ref.watch(adminRepositoryProvider).vehicles();
});

/// Opens the phone's dialer for a list card's call button (overridden in tests).
final adminDialerProvider = Provider<Future<bool> Function(Uri)>((ref) => launchUrl);

/// A list card: the record's tile, with a call button when a phone is known
/// and, for an admin who can edit, the one-tap status actions under it
/// (Expo `AdminUserList` / `AdminPartnerList` / `AdminVehicleList`).
class _RecordCard extends ConsumerWidget {
  const _RecordCard({
    required this.id,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.phone,
    required this.canEdit,
    required this.onAction,
  });

  final String id;
  final Widget leading;
  final String title;
  final String subtitle;
  final String status;
  final Object? phone;
  final bool canEdit;
  final Future<void> Function(QuickStatusAction) onAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = phoneCallUri(phone);
    final actions = canEdit ? quickStatusActions(status) : const <QuickStatusAction>[];
    final c = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        leading: leading,
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (call != null)
            IconButton(
              key: ValueKey('call-$id'),
              tooltip: 'Call $phone',
              icon: const Icon(Icons.call_outlined),
              onPressed: () async {
                final ok = await ref.read(adminDialerProvider)(call);
                if (!ok && context.mounted) showInfo(context, 'Call $phone');
              },
            ),
          StatusChip(status),
        ]),
      ),
      if (actions.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
          child: Wrap(spacing: 8, runSpacing: 4, alignment: WrapAlignment.end, children: [
            for (final a in actions)
              a.destructive
                  ? OutlinedButton(
                      key: ValueKey('quick-${a.next}-$id'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: c.error,
                        side: BorderSide(color: c.error.withValues(alpha: 0.6)),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => onAction(a),
                      child: Text(a.label),
                    )
                  : FilledButton.tonal(
                      key: ValueKey('quick-${a.next}-$id'),
                      // Not the theme's full-width filled button.
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(64, 36),
                      ),
                      onPressed: () => onAction(a),
                      child: Text(a.label),
                    ),
          ]),
        ),
    ]);
  }
}

/// Shared searchable, filterable record list.
class _RecordList extends ConsumerStatefulWidget {
  const _RecordList({
    required this.title,
    required this.module,
    required this.watch,
    required this.filters,
    required this.matches,
    required this.searchColumns,
    required this.tile,
    required this.onOpen,
    this.initialFilter,
    this.floatingActionButton,
  });

  final String title;
  final String module;
  final AsyncValue<List<Map<String, dynamic>>> Function(WidgetRef ref) watch;
  final Map<String, String> filters;
  final bool Function(Map<String, dynamic>, String) matches;
  final List<String> searchColumns;
  final Widget Function(Map<String, dynamic>) tile;
  final void Function(Map<String, dynamic>) onOpen;
  final String? initialFilter;
  final Widget? floatingActionButton;

  @override
  ConsumerState<_RecordList> createState() => _RecordListState();
}

class _RecordListState extends ConsumerState<_RecordList> {
  late String _filter = widget.filters.containsKey(widget.initialFilter) ? widget.initialFilter! : 'all';
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final value = widget.watch(ref);
    return AdminPage(
      title: widget.title,
      module: widget.module,
      floatingActionButton: widget.floatingActionButton,
      body: Column(children: [
        FilterBar(
          filters: widget.filters,
          selected: _filter,
          onSelected: (f) => setState(() => _filter = f),
          onSearch: (q) => setState(() => _query = q),
          hint: 'Search name, phone, ID…',
        ),
        Expanded(
          child: AsyncView(
            value: value,
            data: (rows) {
              final list = rows
                  .where((r) => widget.matches(r, _filter) && rowSearch(r, _query, widget.searchColumns))
                  .toList();
              if (list.isEmpty) return const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing here');
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: list.length + 1,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => i == 0
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('${list.length} of ${rows.length}', style: Theme.of(context).textTheme.bodySmall),
                      )
                    : InkWell(onTap: () => widget.onOpen(list[i - 1]), child: widget.tile(list[i - 1])),
              );
            },
          ),
        ),
      ]),
    );
  }
}

Widget _avatar(Object? url) {
  final u = url is String && url.startsWith('http') ? url : null;
  return NetAvatar(url: u, fallback: const Icon(Icons.person_outline));
}

Widget _statusPicker({
  required BuildContext context,
  required String label,
  required String current,
  required List<String> choices,
  required bool enabled,
  required Future<void> Function(String) onPick,
}) =>
    Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in choices)
            ChoiceChip(
              label: Text(c),
              selected: c == current,
              onSelected: !enabled || c == current ? null : (_) => onPick(c),
            ),
        ]),
      ]),
    );

/// Why a partner is being rejected or blocked, shown to them on the Drive
/// tab. Optional; null when the admin cancels the change.
Future<String?> _askStatusReason(BuildContext context, String status, String? current) =>
    showDialog<String>(context: context, builder: (_) => _StatusReasonDialog(status: status, current: current));

/// The reason dialog. It owns its text controller, so the controller lives
/// until the dialog has finished closing (disposing it as soon as the dialog
/// returned broke the closing animation).
class _StatusReasonDialog extends StatefulWidget {
  const _StatusReasonDialog({required this.status, this.current});
  final String status;
  final String? current;

  @override
  State<_StatusReasonDialog> createState() => _StatusReasonDialogState();
}

class _StatusReasonDialogState extends State<_StatusReasonDialog> {
  late final _c = TextEditingController(text: widget.current ?? '');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blocked = widget.status == 'blocked';
    return AlertDialog(
      title: Text(blocked ? 'Block this partner?' : 'Reject this application?'),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const ValueKey('status-reason'),
          controller: _c,
          maxLines: 3,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Reason (shown to the partner)',
            hintText: 'e.g. The permit photo is unreadable. Please upload a clear one.',
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('status-reason-save'),
          onPressed: () => Navigator.pop(context, _c.text),
          child: Text(blocked ? 'Block' : 'Reject'),
        ),
      ],
    );
  }
}

/// "Edit" in a detail sheet: opens the ported edit form, then refreshes.
Widget _editButton(BuildContext ctx, WidgetRef ref, String page, String path, String id, VoidCallback onDone) =>
    ref.read(pageAccessProvider(page)) != AccessLevel.edit
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit'),
              onPressed: () async {
                final router = GoRouter.of(ctx);
                Navigator.pop(ctx);
                await router.push('$path?id=${Uri.encodeQueryComponent(id)}');
                onDone();
              },
            ),
          );

// ---- Users -----------------------------------------------------------------

class AdminUsersScreen extends ConsumerWidget {
  const AdminUsersScreen({super.key, this.initialFilter});
  final String? initialFilter;

  /// Changes a user's status: the one path for the detail sheet's picker and
  /// the list card's quick actions. True when it saved.
  static Future<bool> _setStatus(BuildContext ctx, WidgetRef ref, Map<String, dynamic> u, String s) async {
    if (s == 'deleted' &&
        !await confirm(ctx, 'Mark as deleted?', 'The account is hidden from the app but its data is kept.')) {
      return false;
    }
    if (!ctx.mounted) return false;
    final ok = await runAdminAction(
      ctx,
      () => ref.read(adminRepositoryProvider).setUserStatus(u['id'] as String, s),
      success: 'Status updated',
    );
    if (ok) ref.invalidate(adminUsersProvider);
    return ok;
  }

  /// A list card's quick action; Reject / Block are confirmed first.
  static Future<void> _quick(BuildContext context, WidgetRef ref, Map<String, dynamic> u, QuickStatusAction a) async {
    if (a.destructive && !await confirm(context, '${a.label} this user?', _userName(u), ok: a.label)) return;
    if (context.mounted) await _setStatus(context, ref, u, a.next);
  }

  static String _userName(Map<String, dynamic> u) => [
        (u['name'] as String?)?.isNotEmpty == true ? u['name'] : '(no name)',
        u['display_id'] ?? u['id'],
      ].whereType<String>().join(' · ');

  void _open(BuildContext context, WidgetRef ref, Map<String, dynamic> u) {
    final canEdit = ref.read(moduleAccessProvider('users')) == AccessLevel.edit;
    showAdminSheet<void>(
      context,
      title: (u['name'] as String?)?.isNotEmpty == true ? u['name'] as String : 'User',
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [_avatar(u['avatar_url'] ?? u['profile_image']), const SizedBox(width: 12), StatusChip(userStatus(u))]),
        const SizedBox(height: 12),
        DetailTable({
          'ID': u['display_id'] ?? u['id'],
          'Phone': u['phone'],
          'Email': u['email'],
          'ID type': u['id_type'],
          'IC / ID': u['ic'],
          'ID verified': u['id_verified'],
          'Nationality': u['nationality'],
          'Gender': u['gender'],
          'Birth date': u['birth_date'],
          'Address': u['address'],
          'Referral code': u['referral_code'],
          'Total rides': u['total_rides'],
          'Devices': u['device_count'],
          'App': accountAppVersion(u),
          'Joined': dateText(u['joined_at']),
        }),
        ActiveDeviceSection(userId: '${u['id']}', canEdit: canEdit),
        AccountDeletionSection(user: u, canEdit: canEdit),
        if ((u['id_image'] as String?)?.startsWith('http') == true)
          TextButton.icon(
            icon: const Icon(Icons.badge_outlined),
            label: const Text('Open ID image'),
            onPressed: () => openInApp(context, u['id_image'] as String),
          ),
        _statusPicker(
          context: ctx,
          label: 'Account status',
          current: userStatus(u),
          choices: userStatusChoices,
          enabled: canEdit,
          onPick: (s) async {
            if (await _setStatus(ctx, ref, u, s) && ctx.mounted) Navigator.pop(ctx);
          },
        ),
        _editButton(ctx, ref, 'admin-user-edit', '/admin/m/user-edit', u['id'] as String, () => ref.invalidate(adminUsersProvider)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(moduleAccessProvider('users')) == AccessLevel.edit;
    final keepDays = ref.watch(accountRetentionDaysProvider).value ?? 365;
    return _RecordList(
        title: 'Users',
        module: 'users',
        watch: (r) => r.watch(adminUsersProvider),
        filters: userFilters,
        initialFilter: initialFilter,
        matches: (u, f) => f == 'final-delete' ? dueForFinalDeletion(u, keepDays, DateTime.now()) : userMatches(u, f),
        searchColumns: const ['name', 'phone', 'deleted_phone', 'email', 'display_id', 'ic', 'app_version'],
        onOpen: (u) => _open(context, ref, u),
        tile: (u) => _RecordCard(
          id: '${u['id']}',
          leading: _avatar(u['avatar_url'] ?? u['profile_image']),
          title: (u['name'] as String?)?.isNotEmpty == true ? u['name'] as String : '(no name)',
          subtitle: [
            u['phone'] ?? u['deleted_phone'],
            u['display_id'],
            if (accountAppVersionShort(u) case final v?) 'app $v',
          ].whereType<String>().join(' · '),
          status: userStatus(u),
          phone: u['phone'],
          canEdit: canEdit,
          onAction: (a) => _quick(context, ref, u, a),
        ),
      );
  }
}

// ---- Partners & vehicles ---------------------------------------------------

class AdminPartnersScreen extends ConsumerWidget {
  const AdminPartnersScreen({super.key, this.initialFilter, this.vehicles = false});
  final String? initialFilter;
  final bool vehicles;

  String get _module => vehicles ? 'vehicles' : 'partners';

  /// Saves a change to a partner or vehicle. True when it saved.
  Future<bool> _patch(BuildContext ctx, WidgetRef ref, String id, Map<String, dynamic> change) async {
    final repo = ref.read(adminRepositoryProvider);
    final ok = await runAdminAction(
      ctx,
      () async {
        if (vehicles) return repo.updateVehicle(id, change);
        try {
          await repo.updatePartner(id, change);
        } on PostgrestException catch (e) {
          // A database without migration 0118 has no reason column: the
          // status still changes.
          if (!change.containsKey('status_note') || !e.message.contains('status_note')) rethrow;
          await repo.updatePartner(id, {...change}..remove('status_note'));
        }
      },
      success: 'Saved',
    );
    if (ok) ref.invalidate(vehicles ? adminVehiclesProvider : adminPartnersProvider);
    return ok;
  }

  /// Changes a partner's or vehicle's status: the one path for the detail
  /// sheet's picker and the list card's quick actions, with the same checks
  /// (a vehicle's documents before approving it, a partner's reason for a
  /// rejection or block). True when it saved.
  Future<bool> _setStatus(BuildContext ctx, WidgetRef ref, Map<String, dynamic> p, String s) async {
    final id = p['id'] as String;
    if (vehicles) {
      // Approving needs every vehicle document approved, as in the form.
      if (s == 'approved' &&
          p['status'] != 'approved' &&
          !await confirmVehicleApprovable(
            ctx,
            documents: () => ref.read(peopleRepositoryProvider).vehicleDocuments(id),
            plate: '${p['plate'] ?? ''}',
            documentsOk: p['documents_ok'] == true,
          )) {
        return false;
      }
      if (!ctx.mounted) return false;
      return _patch(ctx, ref, id, {'status': s});
    }
    String? reason;
    if (statusTakesReason(s)) {
      reason = await _askStatusReason(ctx, s, p['status_note'] as String?);
      if (reason == null || !ctx.mounted) return false;
    }
    return _patch(ctx, ref, id, partnerStatusPatch(s, reason: reason));
  }

  /// A list card's quick action. A vehicle's Reject / Block is confirmed
  /// first; a partner's is confirmed by the reason dialog it already asks.
  Future<void> _quick(BuildContext context, WidgetRef ref, Map<String, dynamic> p, QuickStatusAction a) async {
    if (a.destructive &&
        vehicles &&
        !await confirm(context, '${a.label} this vehicle?', _vehicleTitle(p), ok: a.label)) {
      return;
    }
    if (context.mounted) await _setStatus(context, ref, p, a.next);
  }

  static String _vehicleTitle(Map<String, dynamic> p) =>
      [p['plate'], p['make'], p['model']].whereType<String>().join(' ');

  void _open(BuildContext context, WidgetRef ref, Map<String, dynamic> p) {
    final canEdit = ref.read(moduleAccessProvider(_module)) == AccessLevel.edit;
    final id = p['id'] as String;
    Future<void> patch(BuildContext ctx, Map<String, dynamic> change) async {
      if (await _patch(ctx, ref, id, change) && ctx.mounted) Navigator.pop(ctx);
    }

    final title = vehicles
        ? [p['plate'], p['make'], p['model']].whereType<String>().join(' ')
        : ((p['name'] as String?) ?? 'Partner');

    showAdminSheet<void>(
      context,
      title: title.isEmpty ? 'Vehicle' : title,
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _avatar(p['avatar_url'] ?? p['image_front']),
          const SizedBox(width: 12),
          StatusChip(p['status'] as String?),
          const SizedBox(width: 8),
          StatusChip('permit: ${p['permit'] ?? 'none'}'),
        ]),
        const SizedBox(height: 12),
        DetailTable(vehicles
            ? {
                'ID': p['display_id'] ?? p['id'],
                'Plate': p['plate'],
                'Make / model': [p['make'], p['model'], p['year']].whereType<String>().join(' '),
                'Colour': p['color'],
                'Type': p['vehicle_type'],
                'VIN': p['vin'],
                'Engine no.': p['engine_number'],
                'Owner': p['owner_name'],
                'Owner phone': p['owner_phone'],
                'Owner partner': p['owner_partner_display_id'],
                'Partner types': (p['partner_types'] as List?)?.join(', '),
                'Service area': (p['service_cities'] as List?)?.join(', '),
                'Onboarding step': p['onboarding_step'],
                'Documents OK': p['documents_ok'] == true ? 'Yes' : 'No',
                'Joined': dateText(p['joined_at']),
              }
            : {
                'ID': p['display_id'] ?? p['id'],
                'Phone': p['phone'],
                'Email': p['email'],
                'IC': p['ic'],
                'Vehicle': [p['vehicle'], p['plate']].whereType<String>().join(' · '),
                'Partner types': (p['partner_types'] as List?)?.join(', ') ?? p['partner_type'],
                'Permit no.': p['permit_number'],
                'Rating': p['rating'],
                'Total rides': p['total_rides'],
                'Service area': (p['service_cities'] as List?)?.join(', '),
                'Onboarding step': p['onboarding_step'],
                'Documents OK': p['documents_ok'] == true ? 'Yes' : 'No',
                'Joined': dateText(p['joined_at']),
                'Reason shown to partner': p['status_note'],
                'Sent back for review': dateText(p['resubmitted_at']),
              }),
        _statusPicker(
          context: ctx,
          label: 'Status',
          current: '${p['status'] ?? ''}',
          choices: partnerStatusChoices,
          enabled: canEdit,
          onPick: (s) async {
            if (await _setStatus(ctx, ref, p, s) && ctx.mounted) Navigator.pop(ctx);
          },
        ),
        _statusPicker(
          context: ctx,
          label: 'Permit',
          current: '${p['permit'] ?? 'none'}',
          choices: permitChoices,
          enabled: canEdit,
          onPick: (s) => patch(ctx, {'permit': s}),
        ),
        const SizedBox(height: 12),
        BusySwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Documents complete'),

          value: p['documents_ok'] == true,
          onChanged: canEdit ? (v) => patch(ctx, {'documents_ok': v}) : null,
        ),
        vehicles
            ? _editButton(ctx, ref, 'admin-vehicle-edit', '/admin/m/vehicle-edit', id, () => ref.invalidate(adminVehiclesProvider))
            : _editButton(ctx, ref, 'admin-partner-edit', '/admin/m/partner-edit', id, () => ref.invalidate(adminPartnersProvider)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(moduleAccessProvider(_module)) == AccessLevel.edit;
    return _RecordList(
        title: vehicles ? 'Vehicles' : 'Partners',
        module: _module,
        watch: (r) => r.watch(vehicles ? adminVehiclesProvider : adminPartnersProvider),
        filters: partnerFilters,
        initialFilter: initialFilter,
        matches: partnerMatches,
        searchColumns: vehicles
            ? const ['plate', 'make', 'model', 'owner_name', 'owner_phone', 'display_id', 'vin']
            : const ['name', 'phone', 'plate', 'email', 'display_id'],
        onOpen: (p) => _open(context, ref, p),
        floatingActionButton: ref.watch(pageAccessProvider(vehicles ? 'admin-vehicle-add' : 'admin-partner-add')) ==
                AccessLevel.edit
            ? FloatingActionButton.extended(
                icon: const Icon(Icons.add),
                label: Text(vehicles ? 'Add vehicle' : 'Add partner'),
                onPressed: () async {
                  await context.push(vehicles ? '/admin/m/vehicle-add' : '/admin/m/partner-add');
                  ref.invalidate(vehicles ? adminVehiclesProvider : adminPartnersProvider);
                },
              )
            : null,
        tile: (p) => _RecordCard(
          id: '${p['id']}',
          leading: _avatar(p['avatar_url'] ?? p['image_front']),
          title: vehicles ? _vehicleTitle(p) : ((p['name'] as String?) ?? '(no name)'),
          subtitle: vehicles
              ? [p['owner_name'], p['display_id']].whereType<String>().join(' · ')
              : [p['phone'], p['plate'], p['display_id']].whereType<String>().join(' · '),
          status: '${p['status'] ?? ''}',
          phone: vehicles ? p['owner_phone'] : p['phone'],
          canEdit: canEdit,
          onAction: (a) => _quick(context, ref, p, a),
        ),
      );
  }
}
