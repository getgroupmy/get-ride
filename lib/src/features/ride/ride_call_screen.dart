import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart' show routerProvider;
import '../../core/ride_call.dart';
import '../../core/support_call.dart';
import '../../data/models.dart';
import '../../data/ride_call_repository.dart';
import '../../providers.dart';
import '../support/call/call_session.dart';
import 'ride_tracking_screen.dart' show rideStreamProvider;

/// Opens the phone's dialer for the fallback phone call (overridden in tests).
final rideCallDialerProvider = Provider<Future<bool> Function(Uri)>((ref) => launchUrl);

/// A call between a rider and their driver (migration 0131), full screen:
/// an incoming call with answer and decline, then the call itself with mute,
/// speaker and hang-up. The same screen for both sides and both directions;
/// the call row says which end this is. The call ends by itself when the
/// ride does.
class RideCallScreen extends ConsumerStatefulWidget {
  const RideCallScreen({super.key, required this.callId});
  final String callId;

  @override
  ConsumerState<RideCallScreen> createState() => _RideCallScreenState();
}

class _RideCallScreenState extends ConsumerState<RideCallScreen> {
  /// The call before this end joins it (an incoming call still ringing, or
  /// one already over); the session's call after.
  RideCall? _call;
  CallSession<RideCall>? _session;
  StreamSubscription<RideCall>? _ringSub;
  Timer? _ringOut;
  Timer? _tick;
  String? _error;
  bool _answering = false;
  bool _leaving = false;

  RideCall? get _current => _session?.call ?? _call;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_session?.connected ?? false)) setState(() {});
    });
  }

  Future<void> _open() async {
    final repo = ref.read(rideCallRepositoryProvider);
    final me = ref.read(currentUserIdProvider);
    try {
      final call = await repo.fetch(widget.callId);
      if (!mounted) return;
      if (call == null || !call.involves(me)) {
        setState(() => _error = 'This call is no longer available.');
        return;
      }
      final now = ref.read(callClockProvider)();
      if (call.startedBy(me) && !call.status.isOver) {
        await _join(call);
      } else if (canAnswerRideCall(call, me, now)) {
        setState(() => _call = call);
        _ringSub = repo.watch(call.id).listen(_onRinging, onError: (Object _) {});
        final left = callRingTimeout - now.difference(call.createdAt ?? now);
        _ringOut = Timer(left.isNegative ? Duration.zero : left, () {
          if (_session == null && !_answering) _over(call.withStatus(CallStatus.missed));
        });
      } else if (call.status == CallStatus.accepted) {
        // Back on a call this end had already answered.
        await _join(call);
      } else {
        _over(call.status == CallStatus.ringing ? call.withStatus(CallStatus.missed) : call);
      }
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't connect the call. Please try again.");
    }
  }

  /// The incoming call changed while it rang: the caller gave up, or it
  /// timed out.
  void _onRinging(RideCall c) {
    if (!mounted || _session != null || _answering) return;
    if (c.status.isOver) {
      _over(c);
    } else {
      setState(() => _call = c);
    }
  }

  Future<void> _join(RideCall call) async {
    final s = CallSession<RideCall>(
      repo: ref.read(rideCallRepositoryProvider),
      media: ref.read(callMediaFactoryProvider)(),
      me: ref.read(currentUserIdProvider) ?? '',
      call: call,
      clock: ref.read(callClockProvider),
    )..addListener(_changed);
    setState(() => _session = s);
    await s.start();
  }

  Future<void> _answer() async {
    final c = _call;
    if (c == null || _answering) return;
    setState(() => _answering = true);
    var ok = false;
    try {
      ok = await ref.read(rideCallRepositoryProvider).answer(c);
    } catch (_) {}
    if (!mounted) return;
    _ringOut?.cancel();
    unawaited(_ringSub?.cancel());
    _ringSub = null;
    if (ok) {
      setState(() => _answering = false);
      await _join(c.withStatus(CallStatus.accepted));
    } else {
      _answering = false;
      _over(c.withStatus(CallStatus.missed));
    }
  }

  Future<void> _decline() async {
    final c = _call;
    if (c == null || _session != null) return;
    _over(c.withStatus(CallStatus.declined));
    try {
      await ref.read(rideCallRepositoryProvider).finish(c.id, CallStatus.declined);
    } catch (_) {}
  }

  /// The call is over before this end joined it: say how, then leave.
  void _over(RideCall c) {
    if (!mounted) return;
    _ringOut?.cancel();
    unawaited(_ringSub?.cancel());
    _ringSub = null;
    setState(() => _call = c);
    _leaveSoon();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final s = _session;
    if (s != null && s.isOver) _leaveSoon(error: s.error != null);
  }

  void _leaveSoon({bool error = false}) {
    if (_leaving) return;
    _leaving = true;
    // Long enough to read "Call ended" or the reason it didn't connect.
    Future<void>.delayed(Duration(milliseconds: error ? 2500 : 1200), _leave);
  }

  void _leave() {
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
      return;
    }
    final c = _current;
    context.go(c == null ? '/' : rideCallHome(c, ref.read(currentUserIdProvider)));
  }

  /// The ride ended or went back to the queue: so does its call.
  void _rideOver() {
    final s = _session;
    if (s != null) {
      if (!s.isOver) unawaited(s.hangUp());
    } else if (_call != null && !_call!.status.isOver) {
      _over(_call!.withStatus(CallStatus.cancelled));
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ringOut?.cancel();
    unawaited(_ringSub?.cancel());
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
    final scheme = t.colorScheme;
    final me = ref.watch(currentUserIdProvider);
    final call = _current;
    final s = _session;
    RideRequest? ride;
    if (call != null) {
      final rideId = call.requestId;
      ref.listen(rideStreamProvider(rideId), (_, next) {
        final r = next.value;
        if (r != null && rideCallMustEnd(r.status)) _rideOver();
      });
      ride = ref.watch(rideStreamProvider(rideId)).value;
    }
    final incoming = s == null && call != null && call.status == CallStatus.ringing && !call.startedBy(me);
    final headline =
        _error ??
        s?.error ??
        (call == null
            ? 'Connecting…'
            : s == null
            ? callHeadline(call.status, outgoing: call.startedBy(me), connected: false)
            : callHeadline(s.status, outgoing: s.outgoing, connected: s.connected, elapsed: s.elapsed));
    final live = s != null && !s.isOver;
    return PopScope(
      canPop: !live && !incoming,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Back on a ringing call turns it down; on a call, hangs up.
        if (live) {
          unawaited(s.hangUp());
        } else if (incoming) {
          unawaited(_decline());
        }
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
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
                      backgroundColor: scheme.primaryContainer,
                      child: Icon(Icons.person, size: 48, color: scheme.onPrimaryContainer),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      call == null ? 'Call' : rideCallPeerName(call, me),
                      key: const ValueKey('ride-call-peer'),
                      textAlign: TextAlign.center,
                      style: t.textTheme.headlineSmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700),
                    ),
                    if (call != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        rideCallContext(call, me, ride: ride),
                        key: const ValueKey('ride-call-context'),
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        headline,
                        key: const ValueKey('ride-call-headline'),
                        textAlign: TextAlign.center,
                        style: t.textTheme.titleMedium?.copyWith(color: scheme.onSurface),
                      ),
                    ),
                    const Spacer(flex: 2),
                    if (incoming)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _CallKey(
                            key: const ValueKey('ride-call-decline'),
                            icon: Icons.call_end,
                            label: 'Decline',
                            tone: _Tone.danger,
                            onTap: _answering ? null : _decline,
                          ),
                          _CallKey(
                            key: const ValueKey('ride-call-accept'),
                            icon: Icons.call,
                            label: 'Accept',
                            tone: _Tone.go,
                            busy: _answering,
                            onTap: _answering ? null : _answer,
                          ),
                        ],
                      )
                    else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _CallKey(
                            key: const ValueKey('ride-call-mute'),
                            icon: (s?.muted ?? false) ? Icons.mic_off : Icons.mic,
                            label: (s?.muted ?? false) ? 'Unmute' : 'Mute',
                            selected: s?.muted ?? false,
                            onTap: live ? s.toggleMute : null,
                          ),
                          _CallKey(
                            key: const ValueKey('ride-call-end'),
                            icon: Icons.call_end,
                            label: 'End',
                            tone: _Tone.danger,
                            onTap: live ? s.hangUp : (_error != null ? _leave : null),
                          ),
                          _CallKey(
                            key: const ValueKey('ride-call-speaker'),
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

enum _Tone { plain, danger, go }

/// One round key under the call, in the theme's colours.
class _CallKey extends StatelessWidget {
  const _CallKey({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.selected = false,
    this.tone = _Tone.plain,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final _Tone tone;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      _Tone.danger => (scheme.error, scheme.onError),
      _Tone.go => (scheme.primary, scheme.onPrimary),
      _Tone.plain => selected ? (scheme.primary, scheme.onPrimary) : (scheme.surfaceContainerHighest, scheme.onSurface),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          selected: selected,
          label: label,
          child: Material(
            color: onTap == null && !busy ? bg.withValues(alpha: 0.4) : bg,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox.square(
                dimension: 68,
                child: busy
                    ? Padding(
                        padding: const EdgeInsets.all(22),
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: fg),
                      )
                    : Icon(icon, color: fg, size: 30),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ExcludeSemantics(
          child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      ],
    );
  }
}

/// The Call button on the rider's and the driver's trip screens. A tap calls
/// the other person in the app; a long press offers an ordinary phone call
/// as well when their number is known (an in-app call needs data on both
/// phones). With no in-app call possible, a tap is the phone call.
class RideCallButton extends ConsumerWidget {
  const RideCallButton({super.key, required this.ride, required this.peerName, this.phone, this.compact = false});

  final RideRequest ride;

  /// Who is called, for the label read out ("Call Aina").
  final String peerName;

  /// Their phone number, when this side may see it.
  final String? phone;

  /// An icon only (the driver's passenger row) rather than "Call".
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Signed out, or no backend (as in a test of the screen around it): no
    // in-app call, only the phone.
    String? me;
    try {
      me = ref.watch(currentUserIdProvider);
    } catch (_) {
      me = null;
    }
    final inApp = rideCallsAvailable(ride) && me != null && (me == ride.riderId || me == ride.partnerId);
    final number = phone?.trim();
    final hasPhone = number != null && number.isNotEmpty;
    if (!inApp && !hasPhone) return const SizedBox.shrink();
    void dial() => unawaited(ref.read(rideCallDialerProvider)(Uri(scheme: 'tel', path: number)));
    void call() => inApp ? unawaited(startRideCall(context, ref, ride, phone: hasPhone ? number : null)) : dial();
    VoidCallback? more = inApp && hasPhone
        ? () => unawaited(_options(context, onInApp: call, onPhone: dial, number: number))
        : null;
    final label = 'Call $peerName';
    return Semantics(
      onLongPressHint: more == null ? null : 'More ways to call',
      child: compact
          // A tooltip that a long press doesn't open: the long press is the
          // phone-call menu.
          ? Tooltip(
              message: label,
              triggerMode: TooltipTriggerMode.manual,
              child: TextButton(
                key: const ValueKey('ride-call'),
                style: TextButton.styleFrom(
                  shape: const CircleBorder(),
                  minimumSize: const Size(48, 48),
                  padding: EdgeInsets.zero,
                ),
                onPressed: call,
                onLongPress: more,
                child: const Icon(Icons.call),
              ),
            )
          : TextButton.icon(
              key: const ValueKey('ride-call'),
              icon: const Icon(Icons.call),
              onPressed: call,
              onLongPress: more,
              label: Semantics(label: label, excludeSemantics: true, child: const Text('Call')),
            ),
    );
  }

  static Future<void> _options(
    BuildContext context, {
    required VoidCallback onInApp,
    required VoidCallback onPhone,
    required String number,
  }) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('ride-call-in-app'),
              leading: const Icon(Icons.wifi_calling_3),
              title: const Text('Call in the app'),
              subtitle: const Text('Uses mobile data or Wi-Fi'),
              onTap: () => Navigator.pop(c, 'app'),
            ),
            ListTile(
              key: const ValueKey('ride-call-phone'),
              leading: const Icon(Icons.phone_outlined),
              title: const Text('Phone call'),
              subtitle: Text(number),
              onTap: () => Navigator.pop(c, 'phone'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'app') onInApp();
    if (choice == 'phone') onPhone();
  }
}

/// Rings the other person on [ride] and opens the call. If they rang at the
/// same moment, their call is opened instead. A failure is reported where
/// the button was, offering the phone call when [phone] is known.
Future<void> startRideCall(BuildContext context, WidgetRef ref, RideRequest ride, {String? phone}) async {
  final repo = ref.read(rideCallRepositoryProvider);
  final dialer = ref.read(rideCallDialerProvider);
  try {
    final c = await repo.ring(ride.id);
    if (context.mounted) unawaited(context.push('/ride-call/${Uri.encodeComponent(c.id)}'));
  } catch (e) {
    try {
      final live = await repo.live(ride.id);
      if (live != null && context.mounted) {
        unawaited(context.push('/ride-call/${Uri.encodeComponent(live.id)}'));
        return;
      }
    } catch (_) {}
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(rideCallFailure(e)),
        action: phone == null
            ? null
            : SnackBarAction(
                label: 'Phone call',
                onPressed: () => dialer(Uri(scheme: 'tel', path: phone)),
              ),
      ),
    );
  }
}

/// Rings on any screen: a call from the other person on a ride opens the
/// full-screen incoming call over whatever is showing. Ride calls only; the
/// support card is [IncomingCallListener].
class RideCallListener extends ConsumerStatefulWidget {
  const RideCallListener({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<RideCallListener> createState() => _RideCallListenerState();
}

class _RideCallListenerState extends ConsumerState<RideCallListener> {
  StreamSubscription<RideCall>? _sub;
  String? _uid;

  /// Calls already put on screen (each rings once, however often its row
  /// changes).
  final _shown = <String>{};

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _watch(String? uid) {
    if (uid == _uid) return;
    _uid = uid;
    unawaited(_sub?.cancel());
    _sub = null;
    if (uid == null) return;
    try {
      _sub = ref.read(rideCallRepositoryProvider).watchIncoming(uid).listen(_onCall, onError: (Object _) {});
    } catch (_) {}
  }

  void _onCall(RideCall c) {
    if (!mounted || !canAnswerRideCall(c, _uid, ref.read(callClockProvider)()) || !_shown.add(c.id)) return;
    final router = ref.read(routerProvider);
    final path = '/ride-call/${Uri.encodeComponent(c.id)}';
    // Already open (the notification was tapped first).
    if (router.routerDelegate.currentConfiguration.uri.path == path) return;
    unawaited(HapticFeedback.heavyImpact());
    unawaited(router.push(path));
  }

  @override
  Widget build(BuildContext context) {
    _watch(ref.watch(currentUserIdProvider));
    return widget.child;
  }
}
