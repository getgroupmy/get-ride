/// Help assistant articles (`help_articles`, migration 0130): the question an
/// article answers, other ways of asking it, the answer, and an optional
/// in-app screen the answer can open. Pure.
library;

/// Who an article is for.
const helpAudiences = ['all', 'rider', 'partner', 'admin'];

/// Whether a [viewer] ('rider', 'partner' or 'admin') sees an article for
/// [audience]. A partner can book rides too, so they see riders' articles;
/// an admin sees everything; anyone else is treated as a rider. The same
/// rule as `help_search`.
bool helpAudienceAllows(String audience, String viewer) => switch (viewer) {
  'admin' => true,
  'partner' => audience != 'admin',
  _ => audience == 'all' || audience == 'rider',
};

class HelpArticle {
  const HelpArticle({
    required this.id,
    required this.title,
    this.questionVariants = const [],
    required this.answer,
    this.keywords = const [],
    this.audience = 'all',
    this.category = '',
    this.actionLabel,
    this.actionRoute,
    this.sort = 0,
    this.active = true,
  });

  /// A `help_articles` row, a `help_search` row (no variants or keywords) or
  /// an entry of assets/help/help_articles.json.
  factory HelpArticle.fromJson(Map<String, dynamic> j) {
    List<String> list(Object? v) => [
      if (v is List)
        for (final e in v)
          if (e is String && e.trim().isNotEmpty) e.trim(),
    ];
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    final audience = text(j['audience']) ?? 'all';
    return HelpArticle(
      id: '${j['id'] ?? ''}',
      title: text(j['title']) ?? '',
      questionVariants: list(j['question_variants']),
      answer: text(j['answer']) ?? '',
      keywords: list(j['keywords']),
      audience: helpAudiences.contains(audience) ? audience : 'all',
      category: text(j['category']) ?? '',
      actionLabel: text(j['action_label']),
      actionRoute: text(j['action_route']),
      sort: (j['sort'] as num?)?.toInt() ?? 0,
      active: j['active'] != false,
    );
  }

  final String id;
  final String title;
  final List<String> questionVariants;
  final String answer;
  final List<String> keywords;
  final String audience;
  final String category;
  final String? actionLabel;
  final String? actionRoute;
  final int sort;
  final bool active;

  /// The columns an admin writes (the id is kept apart: a new article has
  /// none until the database gives it one).
  Map<String, dynamic> toRow() => {
    'title': title.trim(),
    'question_variants': questionVariants,
    'answer': answer.trim(),
    'keywords': keywords,
    'audience': audience,
    'category': category.trim(),
    'action_label': actionRoute == null ? null : actionLabel,
    'action_route': actionRoute,
    'sort': sort,
    'active': active,
  };

  HelpArticle copyWith({bool? active}) => HelpArticle(
    id: id,
    title: title,
    questionVariants: questionVariants,
    answer: answer,
    keywords: keywords,
    audience: audience,
    category: category,
    actionLabel: actionLabel,
    actionRoute: actionRoute,
    sort: sort,
    active: active ?? this.active,
  );
}

/// One entry per non-empty line (question variants in the admin form).
List<String> helpLines(String raw) => [
  for (final l in raw.split('\n'))
    if (l.trim().isNotEmpty) l.trim(),
];

/// Comma- or line-separated keywords, lower-cased, without repeats.
List<String> helpKeywords(String raw) {
  final out = <String>[];
  for (final k in raw.split(RegExp(r'[,\n]'))) {
    final t = k.trim().toLowerCase();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }
  return out;
}

/// What stops [a] being saved, or null when it can be (the database's own
/// checks, said in words).
String? helpArticleProblem(HelpArticle a) {
  if (a.title.trim().isEmpty) return 'Enter the question this article answers.';
  if (a.title.trim().length > 200) return 'The question is too long (200 characters at most).';
  if (a.answer.trim().isEmpty) return 'Enter the answer.';
  if (a.answer.trim().length > 4000) return 'The answer is too long (4000 characters at most).';
  if (!helpAudiences.contains(a.audience)) return 'Choose who the article is for.';
  final route = a.actionRoute;
  if (route != null) {
    if (!RegExp(r'^/[A-Za-z0-9/_-]*$').hasMatch(route)) {
      return 'The action must be an in-app path such as /account/settings/pin.';
    }
    final label = a.actionLabel?.trim() ?? '';
    if (label.isEmpty) return 'Give the action button a label.';
    if (label.length > 60) return 'The action label is too long (60 characters at most).';
  }
  return null;
}

/// A logged question (`help_questions`), for the admin's unanswered list.
class HelpQuestion {
  const HelpQuestion({required this.id, required this.question, this.matchedArticleId, this.helpful, this.createdAt});

  factory HelpQuestion.fromJson(Map<String, dynamic> j) => HelpQuestion(
    id: '${j['id'] ?? ''}',
    question: '${j['question'] ?? ''}'.trim(),
    matchedArticleId: j['matched_article_id'] as String?,
    helpful: j['helpful'] as bool?,
    createdAt: DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal(),
  );

  final String id;
  final String question;
  final String? matchedArticleId;
  final bool? helpful;
  final DateTime? createdAt;

  /// Nothing answered it, or the asker said the answer did not help.
  bool get unanswered => matchedArticleId == null || helpful == false;
}

/// The articles whose question, variants, keywords, category or answer
/// contain [query] (any case), for the admin list.
List<HelpArticle> filterHelpArticles(List<HelpArticle> articles, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return articles;
  bool has(String s) => s.toLowerCase().contains(q);
  return [
    for (final a in articles)
      if (has(a.title) || a.questionVariants.any(has) || a.keywords.any(has) || has(a.category) || has(a.answer)) a,
  ];
}

/// A new article drafted from a question nobody's article answered.
HelpArticle helpArticleFromQuestion(String question) {
  final q = question.trim();
  return HelpArticle(id: '', title: q, questionVariants: [q], answer: '');
}
