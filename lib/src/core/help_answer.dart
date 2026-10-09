/// What the help assistant replies, decided from the ranked articles alone
/// (no generated text): the best article's answer when it clearly wins, a
/// short list to choose from when it doesn't, and an honest "I don't know"
/// with a way to support when nothing matches. Pure.
library;

import 'help_article.dart';
import 'help_search.dart';

/// Where the support chat is (Account → Help & support).
const helpSupportRoute = '/account/support';

/// How sure a score has to be. The server's scores (`help_search`) and the
/// device's (BM25) run on different scales, so each has its own.
class HelpThresholds {
  const HelpThresholds({required this.minimum, required this.confident, this.closeRatio = 0.8});

  /// Below this an article is not worth showing at all.
  final double minimum;

  /// At or above this the best article is answered outright, unless the
  /// runner-up is within [closeRatio] of it.
  final double confident;
  final double closeRatio;

  static const server = HelpThresholds(minimum: 0.5, confident: 1.2);
  static const device = HelpThresholds(minimum: 2.5, confident: 8.0);
}

enum HelpReplyKind {
  /// One article answers the question.
  answer,

  /// A few might: the asker picks one.
  suggestions,

  /// Nothing matched.
  unknown,
}

class HelpReply {
  const HelpReply({
    required this.kind,
    required this.text,
    this.article,
    this.suggestions = const [],
    this.tentative = false,
  });

  final HelpReplyKind kind;

  /// What the assistant says.
  final String text;

  /// The article answered with ([HelpReplyKind.answer]).
  final HelpArticle? article;

  /// Articles to offer: the choices ([HelpReplyKind.suggestions]) or related
  /// questions under an answer.
  final List<HelpArticle> suggestions;

  /// An answer given on a weak match ("This might help").
  final bool tentative;

  /// The support chat is offered when the assistant had no answer.
  bool get offersSupport => kind == HelpReplyKind.unknown;
}

const helpUnknownText = "Sorry, I don't know the answer to that yet. Our support team can help you in a chat.";

/// Said under [helpUnknownText] once the question is in the admins' list.
const helpNotedText = "I've passed your question on so we can add an answer.";
const helpSuggestionsText = 'I found a few things that might help:';
const helpTentativeIntro = 'This might help:';

/// The reply to a question whose ranked articles are [hits] (best first).
HelpReply composeHelpReply(List<HelpHit> hits, HelpThresholds th) {
  final ok = [
    for (final h in hits)
      if (h.score >= th.minimum && h.article.answer.trim().isNotEmpty) h,
  ];
  if (ok.isEmpty) return const HelpReply(kind: HelpReplyKind.unknown, text: helpUnknownText);
  final top = ok.first;
  final close = ok.length > 1 && ok[1].score >= top.score * th.closeRatio;
  if (ok.length == 1 || (top.score >= th.confident && !close)) {
    return HelpReply(
      kind: HelpReplyKind.answer,
      text: top.article.answer,
      article: top.article,
      suggestions: [for (final h in ok.skip(1).take(2)) h.article],
      tentative: top.score < th.confident,
    );
  }
  return HelpReply(
    kind: HelpReplyKind.suggestions,
    text: helpSuggestionsText,
    suggestions: [for (final h in ok.take(3)) h.article],
  );
}

/// The reply when the asker picks [article] (a suggestion or a starter).
HelpReply helpReplyFor(HelpArticle article) =>
    HelpReply(kind: HelpReplyKind.answer, text: article.answer, article: article);

/// The questions offered on an empty conversation, for [viewer].
List<String> helpStarterQuestions(String viewer) => switch (viewer) {
  'partner' => const [
    'How do I go online and take requests?',
    'How does Meter Digital work?',
    'Why was commission taken from GET.credit?',
    'How do I upload or renew my documents?',
  ],
  'admin' => const [
    'How do I add help articles?',
    'How do I review partner documents?',
    'How do I book a ride?',
    'How do I contact support?',
  ],
  _ => const ['How do I book a ride?', 'How do I cancel a ride?', 'How do I top up my wallet?', 'I forgot my PIN'],
};

/// The article logged as answering a reply: only a clear answer counts, so
/// a list of guesses or "I don't know" goes to the admin's unanswered list.
String? helpMatchedArticleId(HelpReply r) => r.kind == HelpReplyKind.answer ? r.article?.id : null;
