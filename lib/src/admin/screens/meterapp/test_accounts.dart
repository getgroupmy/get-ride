// Admin → Display Settings → Demo / Mockup Data → Tester accounts
// (migration 0241): the accounts the Claude test sessions sign in with. Their
// calls are labelled test traffic, so the speed and usage figures (Fare AI
// response log, Maps usage) show real users unless the admin asks for test
// traffic too. Being listed changes nothing else for the account.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart';
import '../../../widgets/search_select.dart';
import '../../profile_search.dart';
import '../../test_traffic.dart';
import '../../widgets/admin_widgets.dart';

class TestAccountsCard extends ConsumerWidget {
  const TestAccountsCard({super.key, required this.canEdit});

  final bool canEdit;

  Future<void> _remove(BuildContext context, WidgetRef ref, TestAccount a) async {
    final ok = await runAdminAction(context, () => ref.read(testAccountsRepositoryProvider).remove(a.id),
        success: '${a.label} is no longer a tester');
    if (ok) ref.invalidate(testAccountsProvider);
  }

  Widget _list(BuildContext context, WidgetRef ref, List<TestAccount> list) {
    final t = Theme.of(context);
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No tester accounts: every call counts as a real user.',
          key: const ValueKey('test-accounts-empty'),
          style: t.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
        ),
      );
    }
    return ListSearchFilter(
      count: list.length,
      fieldKey: const ValueKey('test-accounts-filter'),
      hint: 'Search tester accounts',
      builder: (_, q) => Column(children: [
        for (final a in list)
          if (q.isEmpty || searchSelectMatches('${a.label} ${a.details} ${a.id}', q))
            ListTile(
              key: ValueKey('test-account-${a.id}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: Text(a.label),
              subtitle: Text(a.details),
              trailing: canEdit
                  ? IconButton(
                      key: ValueKey('test-account-remove-${a.id}'),
                      tooltip: 'Remove',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _remove(context, ref, a),
                    )
                  : null,
            ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final accounts = ref.watch(testAccountsProvider);
    return Card(
      key: const ValueKey('test-accounts-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.science_outlined, color: t.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  accounts.hasValue ? 'Tester accounts (${accounts.requireValue.length})' : 'Tester accounts',
                  style: t.textTheme.titleSmall,
                ),
              ),
              if (canEdit)
                TextButton.icon(
                  key: const ValueKey('test-accounts-add'),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Add account'),
                  onPressed: () => showAdminSheet<void>(
                    context,
                    title: 'Add tester account',
                    builder: (_) => const _TestAccountSearch(),
                  ),
                ),
            ]),
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 4),
              child: Text(
                'The accounts the Claude test sessions use. Their calls are marked as test traffic, so the '
                'speed and usage figures (Fare AI response log, Maps usage) show real users only. Nothing '
                'else changes for them: limits, payments and checks apply as usual.',
                style: muted,
              ),
            ),
            if (accounts.hasValue)
              _list(context, ref, accounts.requireValue)
            else if (accounts.hasError)
              Row(children: [
                Expanded(
                  child: Text(
                    "Couldn't load the tester accounts: ${errorText(accounts.error!)}",
                    key: const ValueKey('test-accounts-error'),
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error),
                  ),
                ),
                TextButton(onPressed: () => ref.invalidate(testAccountsProvider), child: const Text('Retry')),
              ])
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
              ),
          ],
        ),
      ),
    );
  }
}

/// Finds an account by name, phone, email or account id (the admin's usual
/// people search) and lists it as a tester.
class _TestAccountSearch extends ConsumerStatefulWidget {
  const _TestAccountSearch();

  @override
  ConsumerState<_TestAccountSearch> createState() => _TestAccountSearchState();
}

class _TestAccountSearchState extends ConsumerState<_TestAccountSearch> {
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
      final rows = await ref.read(testAccountsRepositoryProvider).searchPeople(q);
      if (mounted) setState(() => _results = rows);
    } catch (e) {
      if (mounted) setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _add(Map<String, dynamic> r) async {
    final ok = await runAdminAction(context, () => ref.read(testAccountsRepositoryProvider).add('${r['id']}'),
        success: '${personLabel(r)} is now a tester');
    if (ok) ref.invalidate(testAccountsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final listed = {for (final a in ref.watch(testAccountsProvider).value ?? const <TestAccount>[]) a.id};
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('test-account-search'),
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
                    key: const ValueKey('test-account-find'),
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
            key: ValueKey('test-account-pick-${r['id']}'),
            leading: const Icon(Icons.person_outline),
            title: Text(personLabel(r)),
            subtitle: Text(personDetails(r)),
            trailing: listed.contains('${r['id']}')
                ? Icon(Icons.check_circle, color: t.colorScheme.primary, semanticLabel: 'Listed')
                : const Icon(Icons.add_circle_outline, semanticLabel: 'Add'),
            onTap: listed.contains('${r['id']}') ? null : () => _add(r),
          ),
      ],
    );
  }
}
