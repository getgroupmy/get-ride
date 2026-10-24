import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/sms_limits.dart' show maskPhone;
import '../../widgets/busy.dart';
import '../../widgets/common.dart' show errorText;
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../god_view_people.dart';
import '../profile_search.dart' show isProfileUuid, peopleSearchTerm;

/// Finds people to add to a list: name, phone, email, account or profile id.
typedef GodViewPersonSearch = Future<List<GodViewListedPerson>> Function(String query);

/// Admin → Sub-admins → God View: who the sub-admin sees (migration 0285).
/// Region shows [regionChildren] (the region and Everywhere) and the hide
/// list; Only these people the only list; Nobody neither.
class GodViewPeopleSection extends StatelessWidget {
  const GodViewPeopleSection({
    super.key,
    required this.people,
    required this.onChanged,
    required this.search,
    this.regionChildren = const [],
    this.loading = false,
    this.error,
  });

  final GodViewPeople people;
  final ValueChanged<GodViewPeople> onChanged;
  final GodViewPersonSearch search;
  final List<Widget> regionChildren;
  final bool loading;

  /// Why the lists could not be read; nothing here can be changed then.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    // Not read yet, or not readable: the region still edits; the lists wait.
    if (loading || error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...regionChildren,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: error != null
                ? Text(
                    "Couldn't read who they see on God View: $error",
                    key: const ValueKey('grant-god-view-people-error'),
                    style: TextStyle(color: t.colorScheme.error),
                  )
                : const Row(
                    children: [
                      BusySpinner(),
                      SizedBox(width: 12),
                      Expanded(child: Text('Loading who they see on God View')),
                    ],
                  ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('Who they see on God View', style: t.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in GodViewPeopleMode.values)
              ChoiceChip(
                key: ValueKey('grant-god-view-mode-${m.wire}'),
                label: Text(m.label),
                selected: people.mode == m,
                onSelected: (_) => onChanged(people.copyWith(mode: m)),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(people.summary, key: const ValueKey('grant-god-view-people-summary'), style: muted),
        ),
        if (people.mode == GodViewPeopleMode.region) ...[
          ...regionChildren,
          _PeopleList(
            list: 'hide',
            title: 'Hide these people',
            empty: 'No one hidden.',
            people: people.hide,
            search: search,
            onChanged: (l) => onChanged(people.copyWith(hide: l)),
          ),
        ],
        if (people.mode == GodViewPeopleMode.only)
          _PeopleList(
            list: 'only',
            title: 'Only these people',
            empty: 'No one listed: they see no one until you add someone.',
            people: people.only,
            search: search,
            onChanged: (l) => onChanged(people.copyWith(only: l)),
          ),
      ],
    );
  }
}

class _PeopleList extends StatelessWidget {
  const _PeopleList({
    required this.list,
    required this.title,
    required this.empty,
    required this.people,
    required this.search,
    required this.onChanged,
  });

  /// 'only' or 'hide', for the keys.
  final String list;
  final String title;
  final String empty;
  final List<GodViewListedPerson> people;
  final GodViewPersonSearch search;
  final ValueChanged<List<GodViewListedPerson>> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: Text('$title · ${people.length}', style: t.textTheme.titleSmall)),
            TextButton.icon(
              key: ValueKey('grant-god-view-$list-add'),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add'),
              onPressed: () async {
                final picked = await showGodViewPersonSearch(
                  context,
                  title: title,
                  search: search,
                  already: {for (final p in people) p.id},
                );
                if (picked != null) onChanged(addListedPerson(people, picked));
              },
            ),
          ],
        ),
        if (people.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(empty, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          )
        else
          ListSearchFilter(
            count: people.length,
            hint: list == 'only' ? 'Search listed people' : 'Search hidden people',
            fieldKey: ValueKey('grant-god-view-$list-search'),
            builder: (context, q) {
              final shown = [for (final p in people) if (listedPersonMatches(p, q)) p];
              if (shown.isEmpty) {
                return const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Nobody matches'));
              }
              return Column(
                children: [
                  for (final p in shown)
                    ListTile(
                      key: ValueKey('grant-god-view-$list-${p.id}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(p.partner ? Icons.local_taxi_outlined : Icons.person_outline),
                      title: Text(p.label, overflow: TextOverflow.ellipsis),
                      subtitle: _detailsOf(p).isEmpty ? null : Text(_detailsOf(p), overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _KindChip(partner: p.partner),
                          IconButton(
                            key: ValueKey('grant-god-view-$list-remove-${p.id}'),
                            tooltip: 'Remove ${p.label}',
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => onChanged(removeListedPerson(people, p.id)),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

/// The second line of a person: masked phone and display id.
String _detailsOf(GodViewListedPerson p) =>
    [if (p.phone != null) maskPhone(p.phone!), if (p.displayId != null && p.displayId != p.label) p.displayId!].join(' · ');

class _KindChip extends StatelessWidget {
  const _KindChip({required this.partner});

  final bool partner;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: partner ? s.tertiaryContainer : s.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        partner ? 'Partner' : 'User',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: partner ? s.onTertiaryContainer : s.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// Finds one person to add to a list. [already] are shown as added and
/// can't be picked again.
Future<GodViewListedPerson?> showGodViewPersonSearch(
  BuildContext context, {
  required String title,
  required GodViewPersonSearch search,
  Set<String> already = const {},
}) => showAppDialog<GodViewListedPerson>(
  id: 'admin.god-view-person-add',
  context: context,
  builder: (_) => _PersonSearchDialog(title: title, search: search, already: already),
);

class _PersonSearchDialog extends StatefulWidget {
  const _PersonSearchDialog({required this.title, required this.search, required this.already});

  final String title;
  final GodViewPersonSearch search;
  final Set<String> already;

  @override
  State<_PersonSearchDialog> createState() => _PersonSearchDialogState();
}

class _PersonSearchDialogState extends State<_PersonSearchDialog> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<GodViewListedPerson>? _results;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(q));
  }

  Future<void> _run(String q) async {
    _debounce?.cancel();
    if (!isProfileUuid(q) && peopleSearchTerm(q) == null) {
      setState(() {
        _results = null;
        _error = null;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final rows = await widget.search(q.trim());
      if (!mounted || _query.text != q) return; // a newer search is on its way
      setState(() {
        _results = rows;
        _error = null;
      });
    } catch (e) {
      if (mounted && _query.text == q) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final results = _results;
    return AlertDialog(
      title: Text('Add to ${widget.title.toLowerCase()}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('gv-person-search'),
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Find a user or partner',
                helperText: 'Name, phone, email or display ID',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching ? const Padding(padding: EdgeInsets.all(12), child: BusySpinner(size: 16)) : null,
              ),
              onChanged: _changed,
              onSubmitted: _run,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: t.colorScheme.error)),
              )
            else if (results != null && results.isEmpty)
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('No one matches that search.'))
            else if (results != null)
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in results)
                      ListTile(
                        key: ValueKey('gv-person-result-${p.id}'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        enabled: !widget.already.contains(p.id),
                        leading: Icon(p.partner ? Icons.local_taxi_outlined : Icons.person_outline),
                        title: Text(p.label, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [if (widget.already.contains(p.id)) 'Already listed', _detailsOf(p)]
                              .where((s) => s.isNotEmpty)
                              .join(' · '),
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: _KindChip(partner: p.partner),
                        onTap: () => Navigator.pop(context, p),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}
