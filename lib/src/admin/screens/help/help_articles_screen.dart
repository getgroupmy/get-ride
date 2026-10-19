// Admin → Settings → Help articles (migration 0130): the articles the help
// assistant answers from, and the questions it could not answer.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/help_article.dart';
import '../../../data/help_repository.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import '../../../data/live_tables.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';

const helpArticlesPage = 'admin-settings-help-articles';

final helpArticlesProvider = FutureProvider.autoDispose<List<HelpArticle>>((ref) {
  ref.watchAdminLive('help_articles');
  return ref.watch(helpRepositoryProvider).articles();
});

final unansweredHelpQuestionsProvider = FutureProvider.autoDispose<List<HelpQuestion>>((ref) {
  ref.watchAdminLive('help_questions');
  return ref.watch(helpRepositoryProvider).unansweredQuestions();
});

class AdminHelpArticlesScreen extends ConsumerStatefulWidget {
  const AdminHelpArticlesScreen({super.key});

  @override
  ConsumerState<AdminHelpArticlesScreen> createState() => _AdminHelpArticlesScreenState();
}

class _AdminHelpArticlesScreenState extends ConsumerState<AdminHelpArticlesScreen> {
  String _query = '';

  Future<void> _edit(HelpArticle? article) async {
    final result = await showAppDialog<HelpArticle>(id: 'help-articles.edit',
      context: context,
      builder: (_) => HelpArticleDialog(article: article),
    );
    if (result == null || !mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(helpRepositoryProvider).save(result),
      success: 'Article saved',
    );
    if (ok) ref.invalidate(helpArticlesProvider);
  }

  Future<void> _setActive(HelpArticle a, bool active) async {
    final ok = await runAdminAction(context, () => ref.read(helpRepositoryProvider).setActive(a.id, active));
    if (ok) ref.invalidate(helpArticlesProvider);
  }

  Future<void> _delete(HelpArticle a) async {
    if (!await confirm(context, 'Delete article?', '"${a.title}" will no longer be answered.', ok: 'Delete')) return;
    if (!mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(helpRepositoryProvider).delete(a.id),
      success: 'Article deleted',
    );
    if (ok) ref.invalidate(helpArticlesProvider);
  }

  Future<void> _fromQuestion(HelpQuestion q) async {
    await _edit(helpArticleFromQuestion(q.question));
    ref.invalidate(unansweredHelpQuestionsProvider);
  }

  Future<void> _dismiss(HelpQuestion q) async {
    final ok = await runAdminAction(context, () => ref.read(helpRepositoryProvider).dismissQuestion(q.id));
    if (ok) ref.invalidate(unansweredHelpQuestionsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(helpArticlesPage)) == AccessLevel.edit;
    return DefaultTabController(
      length: 2,
      child: AdminPage(
        title: 'Help articles',
        page: helpArticlesPage,
        addAction: PageAddAction(
          key: const ValueKey('help-article-new'),
          onPressed: () => _edit(null),
          icon: const Icon(Icons.add),
          label: const Text('New article'),
        ),
        body: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Articles'),
                Tab(text: 'Unanswered questions'),
              ],
            ),
            Expanded(child: TabBarView(children: [_articles(canEdit), _questions(canEdit)])),
          ],
        ),
      ),
    );
  }

  Widget _articles(bool canEdit) => AsyncView(
    value: ref.watch(helpArticlesProvider),
    onRetry: () => ref.invalidate(helpArticlesProvider),
    data: (all) {
      final shown = filterHelpArticles(all, _query);
      return ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, addActionListBottomPadding(context)),
        children: [
          TextField(
            key: const ValueKey('help-article-search'),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search articles',
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 8),
          Text(
            '${shown.length} of ${all.length} articles · ${all.where((a) => !a.active).length} switched off',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No articles match.', textAlign: TextAlign.center),
            ),
          for (final a in shown)
            Card(
              child: ListTile(
                key: ValueKey('help-article-${a.id}'),
                title: Text(a.title),
                subtitle: Text(
                  [
                    if (a.category.isNotEmpty) a.category,
                    'For ${a.audience}',
                    if (a.actionRoute != null) 'Opens ${a.actionRoute}',
                  ].join(' · '),
                ),
                leading: Icon(
                  a.active ? Icons.live_help_outlined : Icons.visibility_off_outlined,
                  color: a.active ? null : Theme.of(context).colorScheme.outline,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      key: ValueKey('help-article-active-${a.id}'),
                      value: a.active,
                      onChanged: canEdit ? (v) => _setActive(a, v) : null,
                    ),
                    if (canEdit)
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(a),
                      ),
                  ],
                ),
                onTap: canEdit ? () => _edit(a) : null,
              ),
            ),
        ],
      );
    },
  );

  Widget _questions(bool canEdit) => AsyncView(
    value: ref.watch(unansweredHelpQuestionsProvider),
    onRetry: () => ref.invalidate(unansweredHelpQuestionsProvider),
    data: (questions) => questions.isEmpty
        ? const EmptyState(
            icon: Icons.task_alt,
            title: 'Nothing unanswered',
            message: 'Questions the assistant could not answer, or whose answer was marked unhelpful, show here.',
          )
        : ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, addActionListBottomPadding(context)),
            children: [
              for (final q in questions)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(q.question, key: ValueKey('help-question-${q.id}')),
                        const SizedBox(height: 4),
                        Text(
                          [
                            q.matchedArticleId == null ? 'No match' : 'Marked not helpful',
                            if (q.createdAt != null) formatTime(q.createdAt!),
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (canEdit)
                          OverflowBar(
                            alignment: MainAxisAlignment.end,
                            children: [
                              TextButton(onPressed: () => _dismiss(q), child: const Text('Dismiss')),
                              TextButton.icon(
                                key: ValueKey('help-question-create-${q.id}'),
                                icon: const Icon(Icons.add),
                                label: const Text('Create article from this'),
                                onPressed: () => _fromQuestion(q),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
  );
}

/// Creates or edits an article; pops the article to save.
class HelpArticleDialog extends StatefulWidget {
  const HelpArticleDialog({super.key, this.article});

  /// Null for a new article; one with an empty id is a draft to create.
  final HelpArticle? article;

  @override
  State<HelpArticleDialog> createState() => _HelpArticleDialogState();
}

class _HelpArticleDialogState extends State<HelpArticleDialog> {
  late final HelpArticle? _a = widget.article;
  late final _title = TextEditingController(text: _a?.title);
  late final _variants = TextEditingController(text: _a?.questionVariants.join('\n'));
  late final _answer = TextEditingController(text: _a?.answer);
  late final _keywords = TextEditingController(text: _a?.keywords.join(', '));
  late final _category = TextEditingController(text: _a?.category);
  late final _label = TextEditingController(text: _a?.actionLabel);
  late final _route = TextEditingController(text: _a?.actionRoute);
  late final _sort = TextEditingController(text: '${_a?.sort ?? 0}');
  late String _audience = _a?.audience ?? 'all';
  late bool _active = _a?.active ?? true;
  String? _problem;
  final _problemKey = GlobalKey();

  @override
  void dispose() {
    for (final c in [_title, _variants, _answer, _keywords, _category, _label, _route, _sort]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final route = _route.text.trim();
    final article = HelpArticle(
      id: _a?.id ?? '',
      title: _title.text.trim(),
      questionVariants: helpLines(_variants.text),
      answer: _answer.text.trim(),
      keywords: helpKeywords(_keywords.text),
      audience: _audience,
      category: _category.text.trim(),
      actionLabel: route.isEmpty ? null : _label.text.trim(),
      actionRoute: route.isEmpty ? null : route,
      sort: int.tryParse(_sort.text.trim()) ?? 0,
      active: _active,
    );
    final problem = helpArticleProblem(article);
    if (problem != null) {
      // On the field it is about, and that field brought into view (below
      // the fold on a phone, Save seemed to do nothing).
      setState(() => _problem = problem);
      final field = helpProblemField(problem);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = (field == null ? _problemKey : _fieldKeys[field]!).currentContext;
        if (c != null && c.mounted) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 200));
      });
      return;
    }
    Navigator.pop(context, article);
  }

  final _fieldKeys = {'question': GlobalKey(), 'answer': GlobalKey()};

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 12);
    final field = _problem == null ? null : helpProblemField(_problem!);
    return AlertDialog(
      title: Text(_a == null || _a.id.isEmpty ? 'New article' : 'Edit article'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              KeyedSubtree(
                key: _fieldKeys['question'],
                child: TextField(
                  key: const ValueKey('help-edit-title'),
                  controller: _title,
                  decoration: InputDecoration(
                    labelText: 'Question',
                    hintText: 'How do I cancel a ride?',
                    errorText: field == 'question' ? _problem : null,
                    errorMaxLines: 2,
                  ),
                ),
              ),
              gap,
              TextField(
                key: const ValueKey('help-edit-variants'),
                controller: _variants,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Other ways to ask it', helperText: 'One per line'),
              ),
              gap,
              KeyedSubtree(
                key: _fieldKeys['answer'],
                child: TextField(
                  key: const ValueKey('help-edit-answer'),
                  controller: _answer,
                  minLines: 4,
                  maxLines: 12,
                  decoration: InputDecoration(
                    labelText: 'Answer',
                    helperText: 'Plain text; a blank line starts a paragraph',
                    errorText: field == 'answer' ? _problem : null,
                    errorMaxLines: 2,
                  ),
                ),
              ),
              gap,
              TextField(
                key: const ValueKey('help-edit-keywords'),
                controller: _keywords,
                decoration: const InputDecoration(
                  labelText: 'Keywords',
                  helperText: 'Comma separated, Malay too (batal, tambang…)',
                  helperMaxLines: 2,
                ),
              ),
              gap,
              SearchableDropdownFormField<String>(
                isExpanded: true,
                key: const ValueKey('help-edit-audience'),
                initialValue: _audience,
                decoration: const InputDecoration(labelText: 'For'),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('Everyone')),
                  DropdownMenuItem(value: 'rider', child: Text('Riders (and partners)')),
                  DropdownMenuItem(value: 'partner', child: Text('Partners')),
                  DropdownMenuItem(value: 'admin', child: Text('Admins')),
                ],
                onChanged: (v) => setState(() => _audience = v ?? _audience),
              ),
              gap,
              TextField(
                controller: _category,
                decoration: const InputDecoration(labelText: 'Category'),
              ),
              gap,
              TextField(
                key: const ValueKey('help-edit-route'),
                controller: _route,
                decoration: const InputDecoration(
                  labelText: 'Action: in-app page (optional)',
                  hintText: '/account/settings/pin',
                ),
              ),
              gap,
              TextField(
                key: const ValueKey('help-edit-label'),
                controller: _label,
                decoration: const InputDecoration(labelText: 'Action button label', hintText: 'Change sign-in PIN'),
              ),
              gap,
              TextField(
                controller: _sort,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Order in the list'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                subtitle: const Text('Switched off, the assistant never answers with it'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
              // Said once: under its field, or here when it has none.
              if (_problem != null && field == null)
                Text(
                  _problem!,
                  key: const ValueKey('help-edit-problem'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              SizedBox(key: _problemKey, height: 1),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('help-edit-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
