import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../admin/admin_access.dart';
import '../../../admin/admin_providers.dart';
import '../../../app.dart' show routerProvider;
import '../../../core/support_call.dart';
import '../../../data/support_call_repository.dart';
import '../../../providers.dart';
import 'mic_gate.dart';

/// Rings on any screen (Expo `SupportCallListener`, which only ever rang
/// users): a user sees an agent calling them; an agent with access to
/// Support sees users ringing support, and the first agent to answer takes
/// the call (it stops ringing for the rest). Drawn as an overlay above the
/// router, like the coin-transfer card.
class IncomingCallListener extends ConsumerStatefulWidget {
  const IncomingCallListener({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<IncomingCallListener> createState() => _IncomingCallListenerState();
}

class _IncomingCallListenerState extends ConsumerState<IncomingCallListener> {
  StreamSubscription<SupportCall>? _userSub;
  StreamSubscription<SupportCall>? _agentSub;
  String? _uid;
  bool _agent = false;

  /// Ringing calls, oldest first; the first is the one on screen.
  final _ringing = <SupportCall>[];

  /// Calls this agent dismissed (they keep ringing for the other agents).
  final _dismissed = <String>{};
  String? _answering;
  Timer? _ringOut;

  @override
  void dispose() {
    unawaited(_userSub?.cancel());
    unawaited(_agentSub?.cancel());
    _ringOut?.cancel();
    super.dispose();
  }

  void _watch(String? uid, bool agent) {
    if (uid == _uid && agent == _agent) return;
    final repo = ref.read(supportCallRepositoryProvider);
    if (uid != _uid) {
      _uid = uid;
      unawaited(_userSub?.cancel());
      _userSub = uid == null ? null : repo.watchIncomingForUser(uid).listen(_onCall, onError: (Object _) {});
    }
    if (agent != _agent || uid == null) {
      _agent = agent && uid != null;
      unawaited(_agentSub?.cancel());
      _agentSub = _agent ? repo.watchIncomingForAgents().listen(_onCall, onError: (Object _) {}) : null;
    }
    if (uid == null) _ringing.clear();
  }

  void _onCall(SupportCall c) {
    if (!mounted) return;
    final now = DateTime.now();
    final stillRinging = c.status == CallStatus.ringing && !rangOut(c, now) && c.callerId != _uid;
    setState(() {
      final i = _ringing.indexWhere((r) => r.id == c.id);
      if (stillRinging && !_dismissed.contains(c.id)) {
        if (i < 0) {
          _ringing.add(c);
          unawaited(HapticFeedback.heavyImpact());
        } else {
          _ringing[i] = c;
        }
      } else if (i >= 0 && c.id != _answering) {
        _ringing.removeAt(i);
      }
    });
    _armRingOut();
  }

  /// Drops the card on screen once its call has rung out.
  void _armRingOut() {
    _ringOut?.cancel();
    final c = _ringing.firstOrNull;
    final at = c?.createdAt;
    if (c == null || at == null) return;
    final left = callRingTimeout - DateTime.now().difference(at);
    _ringOut = Timer(left.isNegative ? Duration.zero : left, () {
      if (!mounted || _answering == c.id) return;
      setState(() => _ringing.removeWhere((r) => r.id == c.id));
      _armRingOut();
    });
  }

  Future<void> _answer(SupportCall c) async {
    if (!await ensureMicForCall(context, ref) || !mounted) return;
    setState(() => _answering = c.id);
    final repo = ref.read(supportCallRepositoryProvider);
    var ok = false;
    try {
      ok = await repo.answer(c, agentName: ref.read(profileProvider).value?.name);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _answering = null;
      _ringing.removeWhere((r) => r.id == c.id);
    });
    _armRingOut();
    if (ok) {
      unawaited(ref.read(routerProvider).push('/call/${c.id}'));
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(c.fromUser ? 'Another agent answered this call.' : 'This call has ended.')),
      );
    }
  }

  Future<void> _decline(SupportCall c) async {
    setState(() {
      _ringing.removeWhere((r) => r.id == c.id);
      _dismissed.add(c.id);
    });
    _armRingOut();
    // A user turning an agent down ends the call; an agent passing on a
    // user's call leaves it ringing for the other agents.
    if (!c.fromUser) {
      try {
        await ref.read(supportCallRepositoryProvider).finish(c.id, CallStatus.declined);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(currentUserIdProvider);
    final agent = ref.watch(moduleAccessProvider('support')) != AccessLevel.none;
    _watch(uid, agent);
    final c = _ringing.firstOrNull;
    return Stack(
      children: [
        widget.child,
        if (c != null)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: SafeArea(
              child: Center(
                child: _IncomingCard(
                  key: ValueKey('incoming-call-${c.id}'),
                  call: c,
                  busy: _answering == c.id,
                  onAnswer: () => _answer(c),
                  onDecline: () => _decline(c),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _IncomingCard extends StatelessWidget {
  const _IncomingCard({
    super.key,
    required this.call,
    required this.busy,
    required this.onAnswer,
    required this.onDecline,
  });

  final SupportCall call;
  final bool busy;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final title = call.fromUser
        ? '${call.callerName ?? 'A customer'} is calling support'
        : '${call.callerName ?? 'Support'} is calling';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        color: t.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.green.shade600,
                child: const Icon(Icons.call, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    Text('Voice call', style: t.textTheme.bodySmall),
                  ],
                ),
              ),
              // Labels rather than tooltips: this card sits above the
              // navigator, where there is no Overlay for a tooltip to open in.
              IconButton.filled(
                key: const ValueKey('incoming-decline'),
                style: IconButton.styleFrom(backgroundColor: Colors.red),
                onPressed: busy ? null : onDecline,
                icon: Icon(Icons.call_end, color: Colors.white, semanticLabel: call.fromUser ? 'Dismiss' : 'Decline'),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const ValueKey('incoming-answer'),
                style: IconButton.styleFrom(backgroundColor: Colors.green.shade600),
                onPressed: busy ? null : onAnswer,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.call, color: Colors.white, semanticLabel: 'Answer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
