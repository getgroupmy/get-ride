import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/help_answer.dart';
import '../../core/help_article.dart';
import '../../data/help_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_host.dart';
import '../../widgets/side_menu_tiles.dart' show openRoute;

/// One question and the assistant's reply (null while it is being looked up).
class _Turn {
  _Turn(this.question, {this.reply});
  final String question;
  HelpReply? reply;

  /// The logged question's id, for the feedback buttons; null until (or
  /// unless) it is logged.
  String? questionId;
  bool? helpful;
}

/// Help assistant (Account → Help assistant, the side menus and Help &
/// support): answers questions about the app from the help articles. Every
/// reply is an article written by people, found by search; nothing is
/// generated and nothing leaves for an AI provider.
class HelpAssistantScreen extends ConsumerStatefulWidget {
  const HelpAssistantScreen({super.key});

  @override
  ConsumerState<HelpAssistantScreen> createState() => _HelpAssistantScreenState();
}

class _HelpAssistantScreenState extends ConsumerState<HelpAssistantScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <_Turn>[];

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  });

  Future<void> _log(_Turn turn) async {
    final id = await ref
        .read(helpRepositoryProvider)
        .logQuestion(turn.question, matchedArticleId: helpMatchedArticleId(turn.reply!));
    if (mounted && id != null) setState(() => turn.questionId = id);
  }

  Future<void> _ask(String question) async {
    final q = question.trim();
    if (q.isEmpty) return;
    final turn = _Turn(q);
    setState(() {
      _turns.add(turn);
      _text.clear();
    });
    _toBottom();
    final result = await ref.read(helpRepositoryProvider).search(q, viewer: ref.read(helpViewerProvider));
    if (!mounted) return;
    setState(() => turn.reply = composeHelpReply(result.hits, result.thresholds));
    _toBottom();
    await _log(turn);
  }

  /// A suggestion was tapped: its own answer, no search needed.
  Future<void> _pick(HelpArticle article) async {
    final turn = _Turn(article.title, reply: helpReplyFor(article));
    setState(() => _turns.add(turn));
    _toBottom();
    await _log(turn);
  }

  Future<void> _feedback(_Turn turn, bool helpful) async {
    setState(() => turn.helpful = helpful);
    final id = turn.questionId;
    if (id == null) return;
    try {
      await ref.read(helpRepositoryProvider).setHelpful(id, helpful);
    } catch (_) {
      // Feedback is a nicety; the conversation goes on without it.
    }
  }

  void _open(String route) => openRoute(GoRouter.of(context), route);

  @override
  Widget build(BuildContext context) {
    final viewer = ref.watch(helpViewerProvider);
    return Scaffold(
      appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Help assistant')),
      body: ResponsiveCenter(
        maxWidth: 760,
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                key: const ValueKey('help-conversation'),
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                children: [
                  const _Bubble(
                    mine: false,
                    child: Text(
                      "Hi! Ask me anything about GET.ride: booking, payments, your account or driving. "
                      'I answer from our help articles.',
                    ),
                  ),
                  if (_turns.isEmpty)
                    _Chips(
                      key: const ValueKey('help-starters'),
                      labels: helpStarterQuestions(viewer),
                      onTap: (i) => _ask(helpStarterQuestions(viewer)[i]),
                    ),
                  for (final turn in _turns) ...[
                    _Bubble(mine: true, child: Text(turn.question)),
                    if (turn.reply == null)
                      const _Bubble(
                        mine: false,
                        child: SizedBox(
                          key: ValueKey('help-thinking'),
                          width: 24,
                          height: 16,
                          child: LinearProgressIndicator(),
                        ),
                      )
                    else
                      _ReplyView(turn: turn, onOpen: _open, onPick: _pick, onFeedback: (h) => _feedback(turn, h)),
                  ],
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('help-input'),
                        controller: _text,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 500,
                        buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                        textInputAction: TextInputAction.send,
                        decoration: const InputDecoration(hintText: 'Ask a question'),
                        onSubmitted: _ask,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      key: const ValueKey('help-send'),
                      tooltip: 'Ask',
                      onPressed: () => _ask(_text.text),
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The assistant's side of a turn: the words, the action, the choices and
/// the feedback.
class _ReplyView extends StatelessWidget {
  const _ReplyView({required this.turn, required this.onOpen, required this.onPick, required this.onFeedback});

  final _Turn turn;
  final void Function(String route) onOpen;
  final void Function(HelpArticle article) onPick;
  final void Function(bool helpful) onFeedback;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = turn.reply!;
    final article = r.article;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Bubble(
          mine: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (r.tentative) Text(helpTentativeIntro, style: muted),
              if (article != null && r.kind == HelpReplyKind.answer)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(article.title, style: t.textTheme.titleSmall),
                ),
              Text(r.text),
              if (r.offersSupport && turn.questionId != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(helpNotedText, style: muted),
                ),
              if (article?.actionRoute != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: FilledButton.tonalIcon(
                    key: ValueKey('help-action-${article!.id}'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    icon: const Icon(Icons.arrow_forward),
                    label: Text(article.actionLabel ?? 'Open'),
                    onPressed: () => onOpen(article.actionRoute!),
                  ),
                ),
              if (r.offersSupport)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('help-chat-support'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    icon: const Icon(Icons.support_agent),
                    label: const Text('Chat with support'),
                    onPressed: () => onOpen(helpSupportRoute),
                  ),
                ),
            ],
          ),
        ),
        if (r.suggestions.isNotEmpty) ...[
          if (r.kind == HelpReplyKind.answer)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text('Related questions', style: muted),
            ),
          _Chips(labels: [for (final a in r.suggestions) a.title], onTap: (i) => onPick(r.suggestions[i])),
        ],
        if (r.kind == HelpReplyKind.answer)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: turn.helpful != null
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('Thanks for your feedback.', key: const ValueKey('help-thanks'), style: muted),
                  )
                : Row(
                    children: [
                      Text('Was this helpful?', style: muted),
                      IconButton(
                        key: const ValueKey('help-helpful-yes'),
                        tooltip: 'Helpful',
                        icon: const Icon(Icons.thumb_up_outlined, size: 20),
                        onPressed: () => onFeedback(true),
                      ),
                      IconButton(
                        key: const ValueKey('help-helpful-no'),
                        tooltip: 'Not helpful',
                        icon: const Icon(Icons.thumb_down_outlined, size: 20),
                        onPressed: () => onFeedback(false),
                      ),
                    ],
                  ),
          ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.mine, required this.child});
  final bool mine;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fg = mine ? t.colorScheme.onPrimary : t.colorScheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: fg),
          child: child,
        ),
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips({super.key, required this.labels, required this.onTap});
  final List<String> labels;
  final void Function(int index) onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (var i = 0; i < labels.length; i++) ActionChip(label: Text(labels[i]), onPressed: () => onTap(i))],
    ),
  );
}
