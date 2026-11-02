// The store review account's chat, calls and SOS (0333 follow-up): each
// works end to end on the phone alone. A demo driver, passenger or support
// agent answers the chat; a demo call rings and connects with no real call
// (no VoIP, no microphone); SOS shows every step and says plainly that
// nothing was sent.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/demo/demo_script.dart';
import '../../data/safety_incident_repository.dart';
import '../../widgets/page_style_host.dart';
import '../ride/demo_ride.dart' show DemoChip;

/// The "Demo" bar on top of every simulated page.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, this.text = demoNothingSent});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      key: const ValueKey('demo-banner'),
      width: double.infinity,
      color: t.colorScheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        const DemoChip(),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onTertiaryContainer)),
        ),
      ]),
    );
  }
}

// ---- Chat ----------------------------------------------------------------------------------------------

/// Opens a demo chat with [name] ([peer]).
Future<void> openDemoChat(BuildContext context, {required DemoPeer peer, required String name}) =>
    Navigator.of(context).push<void>(
      AppPageRoute(id: 'review.demo-chat', builder: (_) => DemoChatScreen(peer: peer, name: name)),
    );

class DemoChatScreen extends StatefulWidget {
  const DemoChatScreen({super.key, required this.peer, required this.name, this.replyAfter = demoChatReplyAfter});

  final DemoPeer peer;
  final String name;
  final Duration replyAfter;

  @override
  State<DemoChatScreen> createState() => _DemoChatScreenState();
}

class _DemoChatScreenState extends State<DemoChatScreen> {
  final _text = TextEditingController();
  late final _messages = <({bool mine, String text})>[(mine: false, text: demoChatGreeting(widget.peer, widget.name))];
  final _timers = <Timer>[];
  int _turn = 0;
  bool _typing = false;

  List<String> get _quick => switch (widget.peer) {
    DemoPeer.support => const ['I was charged twice', 'I left something in the car', 'Thank you'],
    DemoPeer.passenger => const ['I\'m outside', 'Where are you?', 'Thank you'],
    _ => const ['Where are you?', 'Please wait 2 minutes', 'Thank you'],
  };

  void _send([String? quick]) {
    final text = (quick ?? _text.text).trim();
    if (text.isEmpty) return;
    _text.clear();
    setState(() {
      _messages.add((mine: true, text: text));
      _typing = true;
    });
    final turn = _turn++;
    _timers.add(Timer(widget.replyAfter, () {
      if (!mounted) return;
      setState(() {
        _typing = false;
        _messages.add((mine: false, text: demoChatReply(text, widget.peer, turn: turn)));
      });
    }));
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(widget.name, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          const DemoChip(),
        ]),
        actions: [
          IconButton(
            key: const ValueKey('demo-chat-call'),
            tooltip: 'Call',
            icon: const Icon(Icons.call_outlined),
            onPressed: () => openDemoCall(context, name: widget.name, role: switch (widget.peer) {
              DemoPeer.support => 'Support',
              DemoPeer.passenger => 'Passenger',
              DemoPeer.courier => 'Courier',
              DemoPeer.driver => 'Driver',
            }),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          const DemoBanner(text: 'Demo chat: the replies are simulated. No message is sent to anyone.'),
          Expanded(
            child: ListView(
              key: const ValueKey('demo-chat-list'),
              padding: const EdgeInsets.all(12),
              children: [
                for (final m in _messages)
                  Align(
                    alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 320),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: m.mine ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        m.text,
                        style: TextStyle(color: m.mine ? t.colorScheme.onPrimary : t.colorScheme.onSurface),
                      ),
                    ),
                  ),
                if (_typing)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text('${widget.name} is typing…',
                        key: const ValueKey('demo-chat-typing'), style: t.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              for (final q in _quick)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(label: Text(q), onPressed: () => _send(q)),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('demo-chat-input'),
                  controller: _text,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(hintText: 'Message', border: OutlineInputBorder()),
                ),
              ),
              IconButton(
                key: const ValueKey('demo-chat-send'),
                tooltip: 'Send',
                icon: const Icon(Icons.send),
                onPressed: _send,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---- Calls ---------------------------------------------------------------------------------------------

/// Opens a demo call with [name]: it rings, then connects. No real call.
Future<void> openDemoCall(BuildContext context, {required String name, String role = 'Driver'}) =>
    Navigator.of(context).push<void>(
      AppPageRoute(id: 'review.demo-call', builder: (_) => DemoCallScreen(name: name, role: role)),
    );

class DemoCallScreen extends StatefulWidget {
  const DemoCallScreen({super.key, required this.name, this.role = 'Driver', this.tick = const Duration(seconds: 1)});

  final String name;
  final String role;
  final Duration tick;

  @override
  State<DemoCallScreen> createState() => _DemoCallScreenState();
}

class _DemoCallScreenState extends State<DemoCallScreen> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  bool _ended = false, _muted = false, _speaker = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.tick, (_) {
      if (mounted) setState(() => _elapsed += widget.tick);
    });
  }

  void _hangUp() {
    _timer?.cancel();
    setState(() => _ended = true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final state = demoCallStateAt(_elapsed, hungUp: _ended);
    final status = switch (state) {
      DemoCallState.ringing => 'Ringing…',
      DemoCallState.connected => 'Connected · ${demoCallClock(_elapsed)}',
      DemoCallState.ended => 'Call ended',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Call'), SizedBox(width: 8), DemoChip()]),
      ),
      body: SafeArea(
        child: Column(children: [
          const DemoBanner(text: 'Demo call: simulated on this phone. No real call is made and the microphone is not used.'),
          const Spacer(),
          CircleAvatar(
            radius: 44,
            backgroundColor: t.colorScheme.primaryContainer,
            child: Text(widget.name.isEmpty ? '?' : widget.name[0],
                style: t.textTheme.headlineMedium?.copyWith(color: t.colorScheme.onPrimaryContainer)),
          ),
          const SizedBox(height: 12),
          Text(widget.name, style: t.textTheme.headlineSmall),
          Text(widget.role, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text(status, key: const ValueKey('demo-call-status'), style: t.textTheme.titleMedium),
          if (state == DemoCallState.connected)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '"Hello, this is ${widget.name}. I can hear you." (demo voice)',
                textAlign: TextAlign.center,
                style: t.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          const Spacer(),
          if (state != DemoCallState.ended)
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              IconButton.filledTonal(
                tooltip: _muted ? 'Unmute' : 'Mute',
                icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                onPressed: () => setState(() => _muted = !_muted),
              ),
              IconButton.filled(
                key: const ValueKey('demo-call-end'),
                tooltip: 'End call',
                style: IconButton.styleFrom(backgroundColor: const Color(0xFFE53935), foregroundColor: Colors.white),
                iconSize: 32,
                icon: const Icon(Icons.call_end),
                onPressed: _hangUp,
              ),
              IconButton.filledTonal(
                tooltip: _speaker ? 'Speaker off' : 'Speaker',
                icon: Icon(_speaker ? Icons.volume_up : Icons.volume_down),
                onPressed: () => setState(() => _speaker = !_speaker),
              ),
            ])
          else
            FilledButton(
              key: const ValueKey('demo-call-close'),
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Close'),
            ),
          const SizedBox(height: 32),
        ]),
      ),
    );
  }
}

// ---- SOS -----------------------------------------------------------------------------------------------

/// The SOS sheet as a real trip shows it, for the demo account: each choice
/// then says what a real SOS would do, and that nothing was sent.
Future<void> showDemoSos(BuildContext context, WidgetRef ref, {String? rideId}) async {
  final choice = await showAppSheet<String>(
    id: 'review.demo-sos',
    context: context,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const DemoBanner(text: 'Demo SOS: you see every step, but nothing is sent to anyone.'),
          ListTile(
            key: const ValueKey('sos-ops'),
            leading: const Icon(Icons.support_agent),
            title: const Text('Alert the GET.ride safety team'),
            subtitle: const Text('They see your trip and location, and get in touch'),
            onTap: () => Navigator.pop(c, 'ops'),
          ),
          ListTile(
            key: const ValueKey('sos-call'),
            leading: const Icon(Icons.call),
            title: const Text('Call 999'),
            subtitle: const Text('Police, ambulance and fire'),
            onTap: () => Navigator.pop(c, 'call'),
          ),
          ListTile(
            key: const ValueKey('sos-contacts'),
            leading: const Icon(Icons.sms_outlined),
            title: const Text('Alert my emergency contacts'),
            subtitle: const Text('SMS with your location, driver and car'),
            onTap: () => Navigator.pop(c, 'contacts'),
          ),
        ]),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  // Counted on the phone (the demo repository): nobody is alerted.
  try {
    await ref.read(safetyIncidentRepositoryProvider).raise(rideId: rideId);
  } catch (_) {}
  if (!context.mounted) return;
  final what = switch (choice) {
    'call' => 'In a real emergency this calls 999 from your phone.',
    'contacts' => 'In a real emergency this opens a text to your emergency contacts with your location.',
    _ => 'In a real emergency GET.ride\'s safety team is alerted at once.',
  };
  await showAppDialog<void>(
    id: 'review.demo-sos-done',
    context: context,
    builder: (c) => AlertDialog(
      key: const ValueKey('demo-sos-done'),
      title: const Row(children: [Expanded(child: Text('SOS (demo)')), DemoChip()]),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(what),
          const SizedBox(height: 8),
          const Text('Whichever you choose, a real SOS also does this:'),
          for (final s in demoSosSteps) Text('• $s'),
          const SizedBox(height: 8),
          const Text(demoSosNothingSent, style: TextStyle(fontWeight: FontWeight.w700)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
    ),
  );
}
