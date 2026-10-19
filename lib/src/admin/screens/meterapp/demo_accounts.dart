// Admin → Display Settings → Demo / Mockup Data: the accounts the demo is
// for ("Demo riders", "Demo drivers"). The switches say the demo is on; these
// lists say for whom. Kept in the display settings blob as bare profile ids.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/demo_mode.dart' show demoDriverIdsKey, demoRiderIdsKey;
import '../../../widgets/search_select.dart';
import '../../admin_providers.dart';
import '../../profile_search.dart';
import '../../widgets/admin_widgets.dart';
import 'display_logic.dart';
import 'display_screen.dart' show applyDisplay;
import 'display_store.dart' show displaySettingsProvider;

/// The people on a demo list, by id (ids joined with commas, so equal
/// lists share one read).
final demoPeopleProvider = FutureProvider.autoDispose.family<Map<String, Map<String, dynamic>>, String>((ref, ids) {
  final list = ids.split(',').where((s) => s.isNotEmpty).toList();
  return ref.watch(adminRepositoryProvider).peopleByIds(list);
});

/// One demo list in the Demo / Mockup Data card: who is on it, Remove on
/// each, and Add account (a search of every account).
class DemoAccountsSection extends ConsumerWidget {
  const DemoAccountsSection({
    super.key,
    required this.settings,
    required this.listKey,
    required this.title,
    required this.help,
    required this.canEdit,
  });

  final Map<String, dynamic> settings;

  /// [demoRiderIdsKey] or [demoDriverIdsKey].
  final String listKey;
  final String title;
  final String help;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final ids = demoAccounts(settings, listKey);
    final people = ids.isEmpty ? const <String, Map<String, dynamic>>{} : ref.watch(demoPeopleProvider(ids.join(','))).value ?? const {};
    return Padding(
      key: ValueKey('demo-accounts-$listKey'),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: Text('$title (${ids.length})', style: t.textTheme.titleSmall)),
            if (canEdit)
              TextButton.icon(
                key: ValueKey('demo-add-$listKey'),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('Add account'),
                onPressed: () => showAdminSheet<void>(
                  context,
                  title: 'Add to $title',
                  builder: (_) => _DemoAccountSearch(listKey: listKey),
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 4),
            child: Text(help, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          if (ids.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Nobody is listed, so nobody gets this demo.',
                key: ValueKey('demo-empty-$listKey'),
                style: t.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
              ),
            )
          else
            ListSearchFilter(
              count: ids.length,
              fieldKey: ValueKey('demo-filter-$listKey'),
              hint: 'Search $title',
              builder: (_, q) => Column(children: [
                for (final id in ids)
                  if (q.isEmpty || searchSelectMatches('${personLabel(people[id] ?? {'id': id})} ${personDetails(people[id] ?? const {})} $id', q))
                    ListTile(
                      key: ValueKey('demo-account-$listKey-$id'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline),
                      title: Text(personLabel(people[id] ?? {'id': id})),
                      subtitle: Text(people[id] == null ? id : personDetails(people[id]!)),
                      trailing: canEdit
                          ? IconButton(
                              key: ValueKey('demo-remove-$listKey-$id'),
                              tooltip: 'Remove',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () => applyDisplay(context, ref, (x) => removeDemoAccount(x, listKey, id)),
                            )
                          : null,
                    ),
              ]),
            ),
        ],
      ),
    );
  }
}

/// Finds an account by name, phone, email or account id (the admin's usual
/// people search) and adds it to the list.
class _DemoAccountSearch extends ConsumerStatefulWidget {
  const _DemoAccountSearch({required this.listKey});
  final String listKey;

  @override
  ConsumerState<_DemoAccountSearch> createState() => _DemoAccountSearchState();
}

class _DemoAccountSearchState extends ConsumerState<_DemoAccountSearch> {
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _results;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final q = _search.text.trim();
    if (!isProfileUuid(q) && peopleSearchTerm(q) == null) {
      setState(() => _error = 'Type at least two characters.');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final rows = await ref.read(adminRepositoryProvider).searchPeople(q);
      if (mounted) setState(() => _results = rows);
    } catch (e) {
      if (mounted) setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listed = demoAccounts(ref.watch(displaySettingsProvider).value ?? const {}, widget.listKey).toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('demo-account-search'),
          controller: _search,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _find(),
          decoration: InputDecoration(
            labelText: 'Name, phone, email or account id',
            errorText: _error,
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    key: const ValueKey('demo-account-find'),
                    tooltip: 'Search',
                    icon: const Icon(Icons.search),
                    onPressed: _find,
                  ),
          ),
        ),
        if (_results != null && _results!.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('No account matches. They need to sign up first.'),
          ),
        for (final r in _results ?? const <Map<String, dynamic>>[])
          ListTile(
            key: ValueKey('demo-pick-${r['id']}'),
            leading: const Icon(Icons.person_outline),
            title: Text(personLabel(r)),
            subtitle: Text(personDetails(r)),
            trailing: listed.contains('${r['id']}')
                ? const Icon(Icons.check_circle, semanticLabel: 'Listed')
                : const Icon(Icons.add_circle_outline, semanticLabel: 'Add'),
            onTap: listed.contains('${r['id']}')
                ? null
                : () => applyDisplay(context, ref, (x) => addDemoAccount(x, widget.listKey, '${r['id']}')),
          ),
      ],
    );
  }
}
