import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/support_call.dart';
import '../../../data/support_call_repository.dart';
import '../../../providers.dart';
import 'call_session.dart';

/// A support call in progress (Expo `support-call`, now with audio): who is
/// on the other end, the state of the call or its running time, and mute,
/// speaker and hang-up. The same screen for the user and the agent, and for
/// either direction; the call row says which end this is.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.callId, this.peerName});
  final String callId;

  /// Shown until the row loads (an agent ringing a user knows their name).
  final String? peerName;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  CallSession? _session;
  String? _loadError;
  Timer? _tick;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_session?.connected ?? false)) setState(() {});
    });
  }

  Future<void> _open() async {
    final repo = ref.read(supportCallRepositoryProvider);
    final me = ref.read(currentUserIdProvider);
    try {
      final call = await repo.fetch(widget.callId);
      if (!mounted) return;
      if (call == null || me == null) {
        setState(() => _loadError = 'This call is no longer available.');
        return;
      }
      final s = CallSession(
        repo: repo,
        media: ref.read(callMediaFactoryProvider)(),
        me: me,
        call: call,
        clock: ref.read(callClockProvider),
      )..addListener(_changed);
      setState(() => _session = s);
      await s.start();
    } catch (_) {
      if (mounted) setState(() => _loadError = "Couldn't connect the call. Please try again.");
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final s = _session;
    if (s != null && s.isOver && !_leaving) {
      _leaving = true;
      // Long enough to read "Call ended" or the reason it didn't connect.
      Future<void>.delayed(Duration(milliseconds: s.error == null ? 1200 : 2500), _leave);
    }
  }

  void _leave() {
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _session?.removeListener(_changed);
    // Leaving the screen any other way still hangs up.
    final s = _session;
    if (s != null && !s.isOver) unawaited(s.hangUp());
    s?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = _session;
    final me = ref.watch(currentUserIdProvider);
    final call = s?.call;
    final asAgent = call != null && call.profileId != me;
    final name = call == null
        ? (widget.peerName ?? 'Support')
        : callPeerName(call, asAgent: asAgent, userName: widget.peerName);
    final headline =
        _loadError ??
        s?.error ??
        (s == null
            ? 'Connecting…'
            : callHeadline(s.status, outgoing: s.outgoing, connected: s.connected, elapsed: s.elapsed));
    final live = s != null && !s.isOver;
    return PopScope(
      canPop: !live,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && live) unawaited(s.hangUp());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF101418),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Spacer(),
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: t.colorScheme.primary,
                      child: Icon(
                        asAgent ? Icons.person : Icons.support_agent,
                        size: 48,
                        color: t.colorScheme.onPrimary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      name,
                      key: const ValueKey('call-peer'),
                      textAlign: TextAlign.center,
                      style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      headline,
                      key: const ValueKey('call-headline'),
                      textAlign: TextAlign.center,
                      style: t.textTheme.titleMedium?.copyWith(color: Colors.white70),
                    ),
                    const Spacer(flex: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _RoundKey(
                          key: const ValueKey('call-mute'),
                          icon: (s?.muted ?? false) ? Icons.mic_off : Icons.mic,
                          label: (s?.muted ?? false) ? 'Unmute' : 'Mute',
                          selected: s?.muted ?? false,
                          onTap: live ? s.toggleMute : null,
                        ),
                        _RoundKey(
                          key: const ValueKey('call-end'),
                          icon: Icons.call_end,
                          label: 'End',
                          color: Colors.red,
                          onTap: live ? s.hangUp : (_loadError != null ? _leave : null),
                        ),
                        _RoundKey(
                          key: const ValueKey('call-speaker'),
                          icon: Icons.volume_up,
                          label: 'Speaker',
                          selected: s?.speaker ?? false,
                          onTap: live ? s.toggleSpeaker : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundKey extends StatelessWidget {
  const _RoundKey({super.key, required this.icon, required this.label, this.onTap, this.selected = false, this.color});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (selected ? Colors.white : Colors.white24);
    final fg = color != null ? Colors.white : (selected ? Colors.black : Colors.white);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          selected: selected,
          label: label,
          child: Material(
            color: onTap == null ? bg.withValues(alpha: 0.4) : bg,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox.square(dimension: 68, child: Icon(icon, color: fg, size: 30)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ExcludeSemantics(
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}

/// Rings support from [ticketId] and opens the call. A failure (signed out,
/// an older database) is reported where the button was.
Future<void> callSupport(BuildContext context, WidgetRef ref, {String? ticketId, String? name}) async {
  try {
    final c = await ref.read(supportCallRepositoryProvider).ringSupport(ticketId: ticketId, callerName: name);
    if (context.mounted) unawaited(context.push('/call/${c.id}'));
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Couldn't place the call. Please try again.")));
    }
  }
}

/// An agent rings the user [profileId] about [ticketId] and opens the call.
Future<void> callUser(
  BuildContext context,
  WidgetRef ref, {
  required String profileId,
  String? ticketId,
  String? userName,
  String? agentName,
}) async {
  try {
    final c = await ref
        .read(supportCallRepositoryProvider)
        .ringUser(profileId: profileId, ticketId: ticketId, agentName: agentName);
    if (context.mounted) {
      unawaited(context.push(Uri(path: '/call/${c.id}', queryParameters: {'name': ?userName}).toString()));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Couldn't place the call. Please try again.")));
    }
  }
}
