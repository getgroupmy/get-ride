import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_filters.dart';
import '../admin_providers.dart';
import '../widgets/admin_widgets.dart';
import '../../widgets/in_app_page.dart';

final adminUsersProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepositoryProvider).users());
final adminPartnersProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepositoryProvider).partners());
final adminVehiclesProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepositoryProvider).vehicles());

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
  return CircleAvatar(
    backgroundImage: u != null ? NetworkImage(u) : null,
    child: u == null ? const Icon(Icons.person_outline) : null,
  );
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
          'Joined': dateText(u['joined_at']),
        }),
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
            if (s == 'deleted' &&
                !await confirm(ctx, 'Mark as deleted?', 'The account is hidden from the app but its data is kept.')) {
              return;
            }
            if (!ctx.mounted) return;
            final ok = await runAdminAction(
              ctx,
              () => ref.read(adminRepositoryProvider).setUserStatus(u['id'] as String, s),
              success: 'Status updated',
            );
            if (ok) {
              ref.invalidate(adminUsersProvider);
              if (ctx.mounted) Navigator.pop(ctx);
            }
          },
        ),
        _editButton(ctx, ref, 'admin-user-edit', '/admin/m/user-edit', u['id'] as String, () => ref.invalidate(adminUsersProvider)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _RecordList(
        title: 'Users',
        module: 'users',
        watch: (r) => r.watch(adminUsersProvider),
        filters: userFilters,
        initialFilter: initialFilter,
        matches: userMatches,
        searchColumns: const ['name', 'phone', 'email', 'display_id', 'ic'],
        onOpen: (u) => _open(context, ref, u),
        tile: (u) => ListTile(
          leading: _avatar(u['avatar_url'] ?? u['profile_image']),
          title: Text((u['name'] as String?)?.isNotEmpty == true ? u['name'] as String : '(no name)'),
          subtitle: Text([u['phone'], u['display_id']].whereType<String>().join(' · ')),
          trailing: StatusChip(userStatus(u)),
        ),
      );
}

// ---- Partners & vehicles ---------------------------------------------------

class AdminPartnersScreen extends ConsumerWidget {
  const AdminPartnersScreen({super.key, this.initialFilter, this.vehicles = false});
  final String? initialFilter;
  final bool vehicles;

  String get _module => vehicles ? 'vehicles' : 'partners';

  void _open(BuildContext context, WidgetRef ref, Map<String, dynamic> p) {
    final canEdit = ref.read(moduleAccessProvider(_module)) == AccessLevel.edit;
    final repo = ref.read(adminRepositoryProvider);
    final id = p['id'] as String;
    Future<void> patch(BuildContext ctx, Map<String, dynamic> change) async {
      final ok = await runAdminAction(
        ctx,
        () => vehicles ? repo.updateVehicle(id, change) : repo.updatePartner(id, change),
        success: 'Saved',
      );
      if (ok) {
        ref.invalidate(vehicles ? adminVehiclesProvider : adminPartnersProvider);
        if (ctx.mounted) Navigator.pop(ctx);
      }
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
              }),
        _statusPicker(
          context: ctx,
          label: 'Status',
          current: '${p['status'] ?? ''}',
          choices: partnerStatusChoices,
          enabled: canEdit,
          onPick: (s) => patch(ctx, {'status': s}),
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
  Widget build(BuildContext context, WidgetRef ref) => _RecordList(
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
        tile: (p) => ListTile(
          leading: _avatar(p['avatar_url'] ?? p['image_front']),
          title: Text(vehicles
              ? [p['plate'], p['make'], p['model']].whereType<String>().join(' ')
              : ((p['name'] as String?) ?? '(no name)')),
          subtitle: Text(vehicles
              ? [p['owner_name'], p['display_id']].whereType<String>().join(' · ')
              : [p['phone'], p['plate'], p['display_id']].whereType<String>().join(' · ')),
          trailing: StatusChip(p['status'] as String?),
        ),
      );
}
