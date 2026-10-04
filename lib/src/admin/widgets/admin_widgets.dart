import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../admin_shell.dart';

/// Standard admin page: title bar, optional actions, read-only banner.
class AdminPage extends ConsumerWidget {
  const AdminPage({
    super.key,
    required this.title,
    this.module,
    this.page,
    required this.body,
    this.actions = const [],
    this.floatingActionButton,
  });

  final String title;
  /// Admin module id (core screens) or Expo page key (ported screens);
  /// exactly one should be set.
  final String? module;
  final String? page;
  final Widget body;
  final List<Widget> actions;
  final Widget? floatingActionButton;

  Widget? _leading(BuildContext context) {
    if (Navigator.of(context).canPop()) return const BackButton();
    final scope = AdminDrawerScope.maybeOf(context);
    return scope == null ? null : IconButton(icon: const Icon(Icons.menu), onPressed: scope.openDrawer);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = page != null
        ? ref.watch(pageAccessProvider(page!))
        : ref.watch(moduleAccessProvider(module ?? ''));
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: actions,
        leading: _leading(context),
      ),
      floatingActionButton: level == AccessLevel.edit ? floatingActionButton : null,
      body: Column(children: [
        if (level == AccessLevel.read)
          MaterialBanner(
            content: const Text('Read-only: your admin access lets you view this page but not change it.'),
            leading: const Icon(Icons.visibility_outlined),
            actions: const [SizedBox.shrink()],
          ),
        Expanded(child: body),
      ]),
    );
  }
}

/// Coloured pill for a status value.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String? status;

  static Color colorFor(String s) {
    final v = s.toLowerCase();
    if (v.contains('approved') && !v.contains('un')) return Colors.green;
    if (v == 'verified' || v == 'permit-verified' || v == 'completed' || v == 'closed') return Colors.green;
    if (v.contains('block') || v.contains('reject') || v.contains('deleted') || v.contains('cancel') || v == 'expired') {
      return Colors.red;
    }
    if (v.contains('pending') || v.contains('review') || v == 'open' || v.contains('un')) return Colors.orange;
    return Colors.blueGrey;
  }

  @override
  Widget build(BuildContext context) {
    final s = (status == null || status!.isEmpty) ? '—' : status!;
    final c = colorFor(s);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(s, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// Search box + filter chips above a list.
class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.filters,
    required this.selected,
    required this.onSelected,
    required this.onSearch,
    this.hint = 'Search',
  });

  final Map<String, String> filters;
  final String selected;
  final ValueChanged<String> onSelected;
  final ValueChanged<String> onSearch;
  final String hint;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: hint, isDense: true),
            onChanged: onSearch,
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final e in filters.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(e.value),
                    selected: selected == e.key,
                    onSelected: (_) => onSelected(e.key),
                  ),
                ),
            ]),
          ),
        ]),
      );
}

/// Runs an admin write, reporting errors (RLS refusals included).
Future<bool> runAdminAction(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null && context.mounted) showInfo(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

Future<bool> confirm(BuildContext context, String title, String message, {String ok = 'Confirm'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    ) ==
    true;

/// Two-column key/value table for record details.
class DetailTable extends StatelessWidget {
  const DetailTable(this.rows, {super.key});
  final Map<String, Object?> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(children: [
      for (final e in rows.entries)
        if (e.value != null && '${e.value}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 140, child: Text(e.key, style: t.textTheme.bodySmall)),
              Expanded(child: SelectableText('${e.value}')),
            ]),
          ),
    ]);
  }
}

/// Shows record details in a side sheet on wide screens, a bottom sheet on
/// phones.
Future<T?> showAdminSheet<T>(BuildContext context, {required String title, required Widget Function(BuildContext) builder}) {
  Widget content(BuildContext ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
          child: Row(children: [
            Expanded(child: Text(title, style: Theme.of(ctx).textTheme.titleLarge)),
            IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: builder(ctx))),
      ]);

  if (MediaQuery.sizeOf(context).width >= 900) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      pageBuilder: (ctx, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          elevation: 8,
          child: SizedBox(width: 480, height: double.infinity, child: SafeArea(child: content(ctx))),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => FractionallySizedBox(heightFactor: 0.9, child: content(ctx)),
  );
}

String dateText(Object? iso) {
  if (iso == null) return '';
  final d = DateTime.tryParse('$iso');
  if (d == null) return '$iso';
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}
