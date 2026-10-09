// The help assistant's on-device ranker and its replies (core/help_search.dart,
// core/help_answer.dart): no network, no model, just the built-in articles.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/help_answer.dart';
import 'package:get_ride/src/core/help_article.dart';
import 'package:get_ride/src/core/help_kb.dart';
import 'package:get_ride/src/core/help_search.dart';

final _index = HelpIndex(helpKnowledgeBase);

String? _top(String q, {String viewer = 'rider'}) =>
    _index.search(q, viewer: viewer, limit: 1).firstOrNull?.article.title;

HelpReply _reply(String q, {String viewer = 'rider'}) =>
    composeHelpReply(_index.search(q, viewer: viewer), HelpThresholds.device);

HelpArticle _a(String id, {String audience = 'all', bool active = true}) =>
    HelpArticle(id: id, title: 'Title $id', answer: 'Answer $id', audience: audience, active: active);

void main() {
  group('terms', () {
    test('lower-cased, punctuation and stop words gone, suffixes cut', () {
      expect(helpTerms('How do I cancel my ride?'), ['cancel', 'ride']);
      expect(helpTerms('Cancelling, cancelled!'), ['cancel', 'cancel']);
      expect(helpTerms('Macam mana nak tempah teksi?'), ['book', 'taxi']);
    });

    test('synonyms fold onto one word, in both languages', () {
      expect(helpTerms('password'), helpTerms('PIN'));
      expect(helpTerms('batal'), helpTerms('cancel'));
      expect(helpTerms('dompet'), helpTerms('wallet'));
      expect(helpTerms('pemandu'), helpTerms('driver'));
      expect(helpTerms('partner'), helpTerms('driver'));
      expect(helpTerms('tambang'), helpTerms('fare'));
      expect(helpTerms('price'), helpTerms('fare'));
      expect(helpTerms('top up'), helpTerms('reload'));
      expect(helpTerms('GET.coin'), ['coin']);
    });

    test('stems', () {
      expect(helpStem('receipts'), 'receipt');
      expect(helpStem('cities'), 'city');
      expect(helpStem('cancellation'), 'cancel');
      expect(helpStem('batalkan'), 'batal');
      expect(helpStem('pass'), 'pass');
      expect(helpStem('bus'), 'bus');
    });

    test('edit distance counts a swap as one', () {
      expect(helpEditDistance('cancle', 'cancel'), 1);
      expect(helpEditDistance('walet', 'wallet'), 1);
      expect(helpEditDistance('recipt', 'receipt'), 1);
      expect(helpEditDistance('wallet', 'wallet'), 0);
      expect(helpEditDistance('wallet', 'ticket'), greaterThan(1));
    });
  });

  group('ranking the built-in articles', () {
    const expected = {
      'how do I cancel my ride': 'How do I cancel a ride?',
      'I forgot my password': 'I forgot my PIN',
      'lupa pin': 'I forgot my PIN',
      'how to top up wallet': 'How do I top up my wallet?',
      'how much is the fare': 'How is the fare calculated?',
      'where is my receipt': 'Where are my past trips and receipts?',
      'change phone number': 'How do I change my phone number?',
      'dark mode': 'How do I switch to dark mode?',
      'my driver cancelled': 'My driver cancelled',
      'send coins to friend': 'How do I send GET.coin to someone?',
      'book for my mother': 'How do I book a ride for someone else?',
      'add a stop': 'Can I add stops on the way?',
      'share my trip': 'How do I share my ride with family?',
      'is my ride recorded': 'What is VoiceProtection?',
      'how do i become a driver': 'How do I become a driver?',
      'delete my account': 'How do I delete my account?',
      'promo code': 'Do promo codes work?',
      'batal tempahan': 'How do I cancel a ride?',
      'macam mana nak tempah teksi': 'How do I book a ride?',
      // Typos
      'cancle my ride': 'How do I cancel a ride?',
      'recipt': 'Where are my past trips and receipts?',
      'chnage pin': 'How do I change my PIN?',
    };
    for (final e in expected.entries) {
      test('"${e.key}"', () => expect(_top(e.key), e.value));
    }

    test('partners get the drivers\' articles', () {
      expect(_top('how to go online', viewer: 'partner'), 'How do I go online and take requests?');
      expect(_top('meter not counting', viewer: 'partner'), 'How does Meter Digital work?');
      expect(_top('obd reader', viewer: 'partner'), 'How do I connect an OBD-II reader?');
      expect(_top('komisen', viewer: 'partner'), 'Why was commission taken from GET.credit?');
      expect(_top('how do i register my car', viewer: 'partner'), 'How do I register my vehicle?');
    });

    test('nothing for questions the app has no article on', () {
      expect(_index.search('what is the weather today'), isEmpty);
      expect(_index.search('pizza'), isEmpty);
      expect(_index.search('   '), isEmpty);
      expect(_index.search('hello'), isEmpty);
    });
  });

  test('audiences and switched-off articles', () {
    final index = HelpIndex([
      _a('1', audience: 'all'),
      _a('2', audience: 'rider'),
      _a('3', audience: 'partner'),
      _a('4', audience: 'admin'),
      _a('5', active: false),
    ]);
    Set<String> ids(String viewer) => {for (final h in index.search('title answer', viewer: viewer)) h.article.id};
    expect(ids('rider'), {'1', '2'});
    expect(ids('partner'), {'1', '2', '3'});
    expect(ids('admin'), {'1', '2', '3', '4'});
    expect(helpAudienceAllows('admin', 'partner'), isFalse);
    expect(helpAudienceAllows('partner', 'someone'), isFalse);
  });

  group('replies', () {
    test('a clear winner is answered, with its action and related questions', () {
      final r = _reply('how do I change my PIN');
      expect(r.kind, HelpReplyKind.answer);
      expect(r.article!.title, 'How do I change my PIN?');
      expect(r.text, r.article!.answer);
      expect(r.article!.actionRoute, '/account/settings/pin');
      expect(r.tentative, isFalse);
      expect(r.suggestions.length, lessThanOrEqualTo(2));
      expect(helpMatchedArticleId(r), r.article!.id);
    });

    test('close or weak matches become a choice of three', () {
      final r = _reply('walet');
      expect(r.kind, HelpReplyKind.suggestions);
      expect(r.text, helpSuggestionsText);
      expect(r.suggestions, hasLength(3));
      expect(r.suggestions.map((a) => a.title), contains('What are GET.wallet, GET.credit and GET.coin?'));
      // A guess is not an answer: the question stays on the unanswered list.
      expect(helpMatchedArticleId(r), isNull);
    });

    test('nothing matching is said honestly, with support offered', () {
      final r = _reply('what is the weather today');
      expect(r.kind, HelpReplyKind.unknown);
      expect(r.text, helpUnknownText);
      expect(r.offersSupport, isTrue);
      expect(helpMatchedArticleId(r), isNull);
    });

    test('thresholds', () {
      const th = HelpThresholds(minimum: 1, confident: 5);
      HelpHit hit(String id, double s) => HelpHit(_a(id), s);
      expect(composeHelpReply([hit('a', 6), hit('b', 2)], th).kind, HelpReplyKind.answer);
      // The runner-up within 80 %: let the asker choose.
      expect(composeHelpReply([hit('a', 6), hit('b', 5)], th).kind, HelpReplyKind.suggestions);
      // Weak, but the only one: answered, as a maybe.
      final alone = composeHelpReply([hit('a', 2), hit('b', 0.5)], th);
      expect(alone.kind, HelpReplyKind.answer);
      expect(alone.tentative, isTrue);
      expect(alone.suggestions, isEmpty);
      // Weak and several: a choice.
      expect(
        composeHelpReply([hit('a', 2), hit('b', 1.5), hit('c', 1.2), hit('d', 1.1)], th).suggestions,
        hasLength(3),
      );
      expect(composeHelpReply([hit('a', 0.9)], th).kind, HelpReplyKind.unknown);
      expect(composeHelpReply(const [], th).kind, HelpReplyKind.unknown);
    });

    test('a picked article is its own answer', () {
      final a = helpKnowledgeBase.first;
      final r = helpReplyFor(a);
      expect((r.kind, r.text, r.article), (HelpReplyKind.answer, a.answer, a));
    });

    test('starter questions are answered by the built-in articles', () {
      for (final viewer in ['rider', 'partner', 'admin']) {
        for (final q in helpStarterQuestions(viewer)) {
          expect(_top(q, viewer: viewer), q, reason: viewer);
        }
      }
    });
  });

  group('admin helpers', () {
    test('lines and keywords', () {
      expect(helpLines(' a \n\n b\n'), ['a', 'b']);
      expect(helpKeywords('Batal, cancel,\nbatal ,, '), ['batal', 'cancel']);
    });

    test('validation says what is wrong', () {
      const ok = HelpArticle(id: '', title: 'Q?', answer: 'A.');
      expect(helpArticleProblem(ok), isNull);
      expect(helpArticleProblem(const HelpArticle(id: '', title: ' ', answer: 'A')), contains('question'));
      expect(helpArticleProblem(const HelpArticle(id: '', title: 'Q', answer: '')), contains('answer'));
      expect(
        helpArticleProblem(
          const HelpArticle(id: '', title: 'Q', answer: 'A', actionRoute: 'account', actionLabel: 'Go'),
        ),
        contains('in-app path'),
      );
      expect(
        helpArticleProblem(const HelpArticle(id: '', title: 'Q', answer: 'A', actionRoute: '/account')),
        contains('label'),
      );
      expect(
        helpArticleProblem(const HelpArticle(id: '', title: 'Q', answer: 'A', audience: 'drivers')),
        contains('who'),
      );
    });

    test('a row without an action keeps no label', () {
      const a = HelpArticle(id: 'x', title: 'Q', answer: 'A', actionLabel: 'Go');
      expect(a.toRow()['action_label'], isNull);
      expect(a.toRow().containsKey('id'), isFalse);
    });

    test('search and drafting from a question', () {
      expect(
        filterHelpArticles(helpKnowledgeBase, 'tambang').map((a) => a.title),
        contains('How is the fare calculated?'),
      );
      expect(filterHelpArticles(helpKnowledgeBase, ''), helpKnowledgeBase);
      final draft = helpArticleFromQuestion('  Can I ride a zebra? ');
      expect((draft.id, draft.title), ('', 'Can I ride a zebra?'));
      expect(draft.questionVariants, ['Can I ride a zebra?']);
    });

    test('logged questions', () {
      final q = HelpQuestion.fromJson({'id': '1', 'question': 'Hi', 'matched_article_id': null, 'helpful': null});
      expect(q.unanswered, isTrue);
      expect(
        HelpQuestion.fromJson({'id': '2', 'question': 'x', 'matched_article_id': 'a', 'helpful': false}).unanswered,
        isTrue,
      );
      expect(
        HelpQuestion.fromJson({'id': '3', 'question': 'x', 'matched_article_id': 'a', 'helpful': true}).unanswered,
        isFalse,
      );
    });

    test('a search row has no variants or keywords and still reads', () {
      final a = HelpArticle.fromJson({
        'id': 'i',
        'title': 'T',
        'answer': 'A',
        'action_label': 'Go',
        'action_route': '/wallet',
        'category': 'C',
        'score': 1.2,
      });
      expect((a.title, a.actionRoute, a.audience, a.active), ('T', '/wallet', 'all', true));
      expect(a.questionVariants, isEmpty);
    });
  });
}
