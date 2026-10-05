import 'package:flutter/material.dart';

import '../../core/user_guide.dart';
import '../../widgets/common.dart';

/// Account → User guide: how each part of the app works, searchable.
class UserGuideScreen extends StatefulWidget {
  const UserGuideScreen({super.key});

  @override
  State<UserGuideScreen> createState() => _UserGuideScreenState();
}

class _UserGuideScreenState extends State<UserGuideScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final query = _query.text.trim();
    final sections = searchGuide(query);
    return Scaffold(
      appBar: AppBar(title: const Text('User guide')),
      body: ListView(
        children: [
          ResponsiveCenter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('guide-search'),
                  controller: _query,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search the guide'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                if (sections.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Nothing matches "$query".',
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyMedium,
                    ),
                  ),
                for (final s in sections)
                  Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(s.title, style: t.textTheme.titleMedium),
                        ),
                        for (final topic in s.topics)
                          ExpansionTile(
                            key: ValueKey('guide-${s.title}-${topic.title}-${query.isNotEmpty}'),
                            initiallyExpanded: query.isNotEmpty,
                            title: Text(topic.title),
                            expandedCrossAxisAlignment: CrossAxisAlignment.start,
                            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            children: [Text(topic.body, style: t.textTheme.bodyMedium)],
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
