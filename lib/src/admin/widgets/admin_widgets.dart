import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart' show formatDateTime;
import '../../widgets/back_or_go_button.dart';
import '../../widgets/common.dart';
import '../admin_access.dart';
import '../admin_providers.dart';
import '../admin_shell.dart';
import '../../widgets/page_style_host.dart';

/// Standard admin page: title bar, optional actions, read-only banner.
/// The room under a list for the floating button over its foot: the
/// button (as tall as the text makes it) and its margin above and below,
/// the home bar, and a gap, so the last row scrolls whole above it at any
/// width or text size.
double fabListBottomPadding(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
  return kFloatingActionButtonMargin * 2 + 56 * scale + MediaQuery.viewPaddingOf(context).bottom + 16;
}

class AdminPage extends ConsumerWidget {
  const AdminPage({
    super.key,
    required this.title,
    this.module,
    this.page,
    required this.body,
    this.actions = const [],
    this.floatingActionButton,
    this.bottom,
  });

  final String title;
  /// Admin module id (core screens) or Expo page key (ported screens);
  /// exactly one should be set.
  final String? module;
  final String? page;
  final Widget body;
  final List<Widget> actions;
  final Widget? floatingActionButton;
  /// Under the title, e.g. a [TabBar] (wrap the page in a [DefaultTabController]).
  final PreferredSizeWidget? bottom;

  Widget? _leading(BuildContext context) {
    if (Navigator.of(context).canPop()) return const BackButton();
    // A page reached from Settings (every /admin/m/… page and the
    // settings categories), not a destination of its own: Back to
    // Settings, not the menu.
    final path = GoRouter.maybeOf(context)?.routeInformationProvider.value.uri.path ?? '';
    if (adminPageUnderSettings(path)) return const BackOrGoButton(fallback: '/admin/settings');
    final scope = AdminDrawerScope.maybeOf(context);
    return scope == null ? null : IconButton(tooltip: 'Menu', icon: const Icon(Icons.menu), onPressed: scope.openDrawer);
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
        bottom: bottom,
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
  const StatusChip(this.status, {super.key, this.label});
  final String? status;

  /// The words shown, where the screen has its own for [status] (its list
  /// filters'); else [labelFor] makes them.
  final String? label;

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

  /// A stored status as words: "on_trip" → "On trip".
  static String labelFor(String s) {
    final words = s.replaceAll(RegExp(r'[_-]+'), ' ').trim();
    return words.isEmpty ? s : '${words[0].toUpperCase()}${words.substring(1)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = (status == null || status!.isEmpty) ? '—' : status!;
    final c = colorFor(s);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(label ?? labelFor(s), style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
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
    await showAppDialog<bool>(id: 'admin-widgets.confirm',
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
          // Read out as "Fare, RM12.00": selectable text alone is not in
          // the screen reader's tree.
          Semantics(
            container: true,
            label: e.key,
            value: '${e.value}',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 140, child: Text(e.key, style: t.textTheme.bodySmall)),
                Expanded(child: SelectableText('${e.value}')),
              ]),
            ),
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
            IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: builder(ctx))),
      ]);

  if (MediaQuery.sizeOf(context).width >= 900) {
    return showAppGeneralDialog<T>(id: 'admin.form-panel',
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
  return showAppSheet<T>(id: 'admin.form-sheet',
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => FractionallySizedBox(heightFactor: 0.9, child: content(ctx)),
  );
}

/// A stored timestamp in the app's usual form ("18 Oct 2026, 9:05 AM").
/// A data key as words: `sharedDevices` / `shared_devices` → "Shared
/// devices", `ipAddress` → "IP address", `deviceIds` → "Device IDs".
String humanKey(String key) {
  final spaced = key
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[_\-.]+'), ' ')
      .trim()
      .toLowerCase();
  if (spaced.isEmpty) return key;
  const acronyms = {'id': 'ID', 'ids': 'IDs', 'ip': 'IP', 'ips': 'IPs', 'sim': 'SIM', 'os': 'OS', 'gps': 'GPS', 'url': 'URL'};
  final words = [for (final w in spaced.split(RegExp(r'\s+'))) acronyms[w] ?? w];
  final first = words.first;
  words[0] = acronyms.containsValue(first) ? first : '${first[0].toUpperCase()}${first.substring(1)}';
  return words.join(' ');
}

/// Whether the admin page at [path] is reached from Settings rather than
/// being a menu destination: `/admin/m/…` and `/admin/settings/<category>`.
bool adminPageUnderSettings(String path) =>
    path.startsWith('/admin/m/') || path.startsWith('/admin/settings/');

String dateText(Object? iso) {
  if (iso == null) return '';
  final d = DateTime.tryParse('$iso');
  if (d == null) return '$iso';
  return formatDateTime(d);
}
