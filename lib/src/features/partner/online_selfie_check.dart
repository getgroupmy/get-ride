// The selfie check when a partner goes online (migration 0290). On a phone
// the server says whether one is due (a new phone, a random check, the
// watch list, which reads as random); a modal says why, with "Take selfie"
// (the live camera: blink or turn, no file) and "Not now" (stay offline),
// and the time to answer (3 minutes, the admin's) counting down. Run out of
// time and they stay offline. Once the selfie is in they go online whatever
// the match: the server compares it with their profile photo and ID photo
// and alerts the admins on a low match. The web and desktops are never
// asked. Called by the Drive switch after its other checks.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/online_selfie.dart';
import '../../data/online_selfie_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/live_selfie.dart';
import '../../widgets/page_style_host.dart';

/// How long the "is a check due" question may take before going online
/// carries on without it (the server still holds a due check).
const onlineSelfieStartTimeout = Duration(seconds: 8);

/// Opens the live camera until [deadline]; null when they back out or the
/// time runs out.
typedef OnlineSelfieTaker = Future<LiveSelfie?> Function(BuildContext context, DateTime deadline);

/// The live camera, closed at the deadline (overridden in tests).
final onlineSelfieTakerProvider = Provider<OnlineSelfieTaker>((_) => takeLiveSelfieBefore);

Future<LiveSelfie?> takeLiveSelfieBefore(BuildContext context, DateTime deadline) async {
  final nav = Navigator.of(context);
  final route = AppPageRoute<LiveSelfie>(
    id: 'partner.online-selfie-camera',
    fullscreenDialog: true,
    builder: (_) => const LiveSelfieScreen(),
  );
  final left = deadline.difference(DateTime.now());
  final timer = Timer(left.isNegative ? Duration.zero : left, () {
    if (!route.isActive) return;
    // Anything the camera opened on top goes too.
    nav.popUntil((r) => r == route || r.isFirst);
    if (route.isCurrent) nav.pop();
  });
  try {
    return await nav.push(route);
  } finally {
    timer.cancel();
  }
}

/// True when the partner may go online now: nothing is due, or the selfie
/// is in (whatever the match). False keeps them offline; [onRefusal] hears
/// why (support's "Go online" reports it, 0286).
Future<bool> ensureOnlineSelfie(
  BuildContext context,
  WidgetRef ref, {
  ValueChanged<String>? onRefusal,
  Duration pollEvery = const Duration(seconds: 2),
  Duration pollFor = const Duration(seconds: 20),
}) async {
  final platform = ref.read(onlineSelfiePlatformProvider);
  final OnlineSelfieRepository repo;
  OnlineSelfieDue due;
  try {
    repo = ref.read(onlineSelfieRepositoryProvider);
    due = await repo.start(platform: platform).timeout(onlineSelfieStartTimeout);
  } catch (_) {
    // Unanswered lets them through, as the other checks do; the server
    // still keeps a due check offline.
    return true;
  }
  if (!context.mounted) return false;
  if (due.blocked) {
    final why = due.message ?? 'A selfie check is waiting on your phone.';
    onRefusal?.call(why);
    await showNotice(context, title: 'Selfie check on your phone', message: why);
    return false;
  }
  if (!due.due || due.id == null) return true;
  final id = due.id!;
  final deadline = DateTime.now().add(Duration(seconds: due.answerSeconds));

  Future<bool> timeUp() async {
    await repo.skip(id, 'timeout');
    onRefusal?.call('The selfie check ran out of time.');
    if (context.mounted) {
      await showNotice(
        context,
        title: 'Time is up',
        message: "You didn't take the selfie in time, so you stay offline. Tap Go online to try again.",
      );
    }
    return false;
  }

  final take = await showAppDialog<bool>(
    id: 'partner.online-selfie',
    context: context,
    barrierDismissible: false,
    builder: (_) => OnlineSelfieAskDialog(due: due, deadline: deadline),
  );
  if (take == null) return timeUp();
  if (take == false) {
    await repo.skip(id, 'not_now');
    onRefusal?.call('Not now: the partner stayed offline instead of taking the selfie check.');
    return false;
  }
  if (!context.mounted) return false;
  final selfie = await ref.read(onlineSelfieTakerProvider)(context, deadline);
  if (selfie == null || !selfie.live) {
    if (!DateTime.now().isBefore(deadline)) return timeUp();
    await repo.skip(id, 'not_now');
    onRefusal?.call('The partner closed the selfie camera and stayed offline.');
    return false;
  }
  if (!context.mounted) return false;
  final sent = await showAppDialog<_Sent>(
    id: 'partner.online-selfie-sending',
    context: context,
    barrierDismissible: false,
    builder: (_) => _SendingDialog(
      run: () async {
        await repo.submit(id, selfie);
        final until = DateTime.now().add(pollFor);
        while (true) {
          final row = await repo.result(id);
          final outcome = onlineSelfieOutcome(row);
          if (outcome != null) return _Sent(outcome: outcome, score: row['face_score'] as num?);
          if (!DateTime.now().isBefore(until)) return const _Sent(outcome: OnlineSelfieOutcome.notChecked);
          await Future<void>.delayed(pollEvery);
        }
      },
    ),
  );
  if (!context.mounted) return false;
  if (sent == null || sent.error != null) {
    onRefusal?.call("The selfie couldn't be sent.");
    await showErrorNotice(
      context,
      sent?.error ?? StateError("The selfie couldn't be sent. Try again."),
      title: "Couldn't send the selfie",
    );
    return false;
  }
  await showAppDialog<void>(
    id: 'partner.online-selfie-result',
    context: context,
    barrierDismissible: false,
    builder: (_) => OnlineSelfieResultDialog(outcome: sent.outcome!, score: sent.score),
  );
  return true;
}

/// The question: why, the time left, Take selfie or Not now. Pops true
/// (take it), false (not now) or null (the time ran out).
class OnlineSelfieAskDialog extends StatefulWidget {
  const OnlineSelfieAskDialog({super.key, required this.due, required this.deadline});
  final OnlineSelfieDue due;
  final DateTime deadline;

  @override
  State<OnlineSelfieAskDialog> createState() => _OnlineSelfieAskDialogState();
}

class _OnlineSelfieAskDialogState extends State<OnlineSelfieAskDialog> {
  Timer? _tick;
  late final Duration _start = widget.deadline.difference(DateTime.now());
  late Duration _left = _start;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _ticks++;
      // The clock, or the seconds counted when the clock lags behind them
      // (a test's clock stands still).
      final byClock = widget.deadline.difference(DateTime.now());
      final byTicks = _start - Duration(seconds: _ticks);
      final left = byClock < byTicks ? byClock : byTicks;
      if (left <= Duration.zero) {
        _tick?.cancel();
        Navigator.pop(context);
        return;
      }
      setState(() => _left = left);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return PopScope(
      // Back is "Not now".
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, false);
      },
      child: AlertDialog(
        key: const ValueKey('online-selfie-ask'),
        scrollable: true,
        icon: Icon(
          widget.due.newPhone ? Icons.phonelink_lock : Icons.verified_user_outlined,
          color: t.colorScheme.primary,
        ),
        title: const Text('Selfie check'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(onlineSelfiePrompt(widget.due.reason), key: const ValueKey('online-selfie-reason')),
            const SizedBox(height: 12),
            Text("Live check: blink or turn your head. Photos from a file can't be used.", style: muted),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.timer_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${answerClock(_left)} left to answer, then you stay offline',
                    key: const ValueKey('online-selfie-time'),
                    style: muted,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('online-selfie-later'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now (stay offline)'),
          ),
          FilledButton(
            key: const ValueKey('online-selfie-take'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Take selfie'),
          ),
        ],
      ),
    );
  }
}

class _Sent {
  const _Sent({this.outcome, this.score, this.error});
  final OnlineSelfieOutcome? outcome;
  final num? score;
  final Object? error;
}

/// "Checking your selfie": sends it and waits for the match, then pops.
class _SendingDialog extends StatefulWidget {
  const _SendingDialog({required this.run});
  final Future<_Sent> Function() run;

  @override
  State<_SendingDialog> createState() => _SendingDialogState();
}

class _SendingDialogState extends State<_SendingDialog> {
  @override
  void initState() {
    super.initState();
    unawaited(() async {
      _Sent r;
      try {
        r = await widget.run();
      } catch (e) {
        r = _Sent(error: e);
      }
      if (mounted) Navigator.pop(context, r);
    }());
  }

  @override
  Widget build(BuildContext context) => const PopScope(
    canPop: false,
    child: AlertDialog(
      key: ValueKey('online-selfie-sending'),
      content: Row(
        children: [
          SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          SizedBox(width: 16),
          Expanded(child: Text('Checking your selfie…')),
        ],
      ),
    ),
  );
}

/// After the selfie: the match in a word and "Start driving". Always online.
class OnlineSelfieResultDialog extends StatelessWidget {
  const OnlineSelfieResultDialog({super.key, required this.outcome, this.score});
  final OnlineSelfieOutcome outcome;
  final num? score;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final (icon, label, fg, bg) = switch (outcome) {
      OnlineSelfieOutcome.match => (
        Icons.check_circle,
        score == null ? 'It is you' : '${score!.round()}% match',
        cs.onPrimaryContainer,
        cs.primaryContainer,
      ),
      OnlineSelfieOutcome.low => (Icons.error_outline, 'Low match', cs.onErrorContainer, cs.errorContainer),
      OnlineSelfieOutcome.notChecked => (Icons.help_outline, 'Not checked', cs.onSurface, cs.surfaceContainerHighest),
    };
    return AlertDialog(
      key: ValueKey('online-selfie-result-${outcome.name}'),
      title: Align(
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  key: const ValueKey('online-selfie-badge'),
                  style: t.textTheme.labelLarge?.copyWith(color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
      content: Text(onlineSelfieOutcomeText(outcome), key: const ValueKey('online-selfie-result-text')),
      actions: [
        FilledButton(
          key: const ValueKey('online-selfie-start'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Start driving'),
        ),
      ],
    );
  }
}
