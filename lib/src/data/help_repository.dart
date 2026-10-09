import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/admin_providers.dart' show adminAccessProvider;
import '../core/help_answer.dart';
import '../core/help_article.dart';
import '../core/help_kb.dart';
import '../core/help_search.dart';
import '../providers.dart';

/// Articles ranked for one question, and which ranker ranked them.
class HelpSearchResult {
  const HelpSearchResult(this.hits, {required this.offline});
  final List<HelpHit> hits;

  /// Ranked on the device from the built-in articles ([helpKnowledgeBase]),
  /// because `help_search` could not be reached.
  final bool offline;

  HelpThresholds get thresholds => offline ? HelpThresholds.device : HelpThresholds.server;
}

/// The help assistant's articles and question log (`help_articles`,
/// `help_questions`, migration 0130).
class HelpRepository {
  HelpRepository(this._db, {this.offline = helpKnowledgeBase});
  final SupabaseClient _db;

  /// The articles ranked on the device when the RPC cannot be reached.
  final List<HelpArticle> offline;
  late final HelpIndex _index = HelpIndex(offline);

  /// The articles that best answer [query] for [viewer]: the `help_search`
  /// RPC, else the device's own ranker over the built-in articles.
  Future<HelpSearchResult> search(String query, {required String viewer}) async {
    try {
      final rows = await _db.rpc('help_search', params: {'p_query': query, 'p_audience': viewer, 'p_limit': 5});
      return HelpSearchResult([
        for (final r in (rows as List).cast<Map<String, dynamic>>())
          HelpHit(HelpArticle.fromJson(r), (r['score'] as num?)?.toDouble() ?? 0),
      ], offline: false);
    } catch (_) {
      return HelpSearchResult(_index.search(query, viewer: viewer), offline: true);
    }
  }

  /// Logs [question] and the article that answered it (null: none did);
  /// returns the row's id for the feedback buttons, or null when it could
  /// not be logged (signed out, or a database before 0130).
  Future<String?> logQuestion(String question, {String? matchedArticleId}) async {
    final q = question.trim();
    if (q.isEmpty || _db.auth.currentUser == null) return null;
    try {
      final row = await _db
          .from('help_questions')
          .insert({'question': q.length > 500 ? q.substring(0, 500) : q, 'matched_article_id': matchedArticleId})
          .select('id')
          .single();
      return row['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Whether the answer to a logged question helped.
  Future<void> setHelpful(String questionId, bool helpful) =>
      _db.from('help_questions').update({'helpful': helpful}).eq('id', questionId);

  // ---- Admin ----

  /// Every article, inactive ones included (admins only, by RLS).
  Future<List<HelpArticle>> articles() async {
    final rows = await _db.from('help_articles').select().order('sort').order('title');
    return [for (final r in rows) HelpArticle.fromJson(r)];
  }

  /// Adds [a] (no id) or updates it.
  Future<HelpArticle> save(HelpArticle a) async {
    final row = a.id.isEmpty
        ? await _db.from('help_articles').insert(a.toRow()).select().single()
        : await _db.from('help_articles').update(a.toRow()).eq('id', a.id).select().single();
    return HelpArticle.fromJson(row);
  }

  Future<void> setActive(String id, bool active) => _db.from('help_articles').update({'active': active}).eq('id', id);

  Future<void> delete(String id) => _db.from('help_articles').delete().eq('id', id);

  /// Questions nothing answered, or whose answer was marked unhelpful,
  /// newest first.
  Future<List<HelpQuestion>> unansweredQuestions() async {
    final rows = await _db
        .from('help_questions')
        .select('id, question, matched_article_id, helpful, created_at')
        .or('matched_article_id.is.null,helpful.eq.false')
        .order('created_at', ascending: false)
        .limit(200);
    return [for (final r in rows) HelpQuestion.fromJson(r)];
  }

  /// Takes a question off the unanswered list.
  Future<void> dismissQuestion(String id) => _db.from('help_questions').delete().eq('id', id);
}

final helpRepositoryProvider = Provider((ref) => HelpRepository(ref.watch(supabaseProvider)));

/// Who is asking, for the articles they see: an admin sees every article, a
/// partner the drivers' as well as the riders', anyone else the riders'.
final helpViewerProvider = Provider<String>((ref) {
  if (ref.watch(adminAccessProvider).value?.isAdmin ?? false) return 'admin';
  if (ref.watch(partnerProvider).value != null) return 'partner';
  return 'rider';
});
