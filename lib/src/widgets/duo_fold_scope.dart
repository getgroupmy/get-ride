import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/duo_fold.dart';

/// Dev harness (as DuoKit ships a labelled simulator): set this to a simulated
/// pose — `simulatedBookFold(size)` / `simulatedTabletopFold(size)` — to
/// exercise the fold layout on an ordinary phone, or null to turn it off. A
/// simulated pose overrides whatever the native side reports.
final ValueNotifier<DuoFoldSignal?> duoFoldSimulation = ValueNotifier<DuoFoldSignal?>(null);

/// The channel the iOS native plugin streams fold updates on (see
/// docs/iphone_duo_native_plugin.md — UIHingeInteraction + reservedRegions).
/// Not registered on any other platform, where the stream simply never emits.
const EventChannel duoFoldChannel = EventChannel('get_ride/duo_fold');

/// Wraps [child] so an iPhone Duo's crease (or a simulated one) shows up in
/// `MediaQuery.displayFeatures` — the same place an Android foldable's already
/// does — letting every fold-aware layout downstream (window_class.dart) stay
/// free of any platform branch. A no-op wherever no crease is reported, so it
/// changes nothing on current phones.
class DuoFoldScope extends StatefulWidget {
  const DuoFoldScope({super.key, required this.child});

  final Widget child;

  @override
  State<DuoFoldScope> createState() => _DuoFoldScopeState();
}

class _DuoFoldScopeState extends State<DuoFoldScope> {
  DuoFoldSignal? _native;
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    duoFoldSimulation.addListener(_onChange);
    // Only the iOS Duo plugin streams this; on every other platform the first
    // listen raises MissingPluginException, caught and ignored (stays null).
    try {
      _sub = duoFoldChannel.receiveBroadcastStream().listen(
        (event) {
          if (!mounted) return;
          setState(() => _native = event is Map ? duoFoldFromNative(event) : null);
          _publishHinge();
        },
        onError: (Object _) {},
      );
    } catch (_) {}
    _publishHinge();
  }

  @override
  void dispose() {
    duoFoldSimulation.removeListener(_onChange);
    _sub?.cancel();
    duoHingeNow.value = DuoHinge.none;
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
    _publishHinge();
  }

  /// Keeps the global [duoHingeNow] in step so the orientation lock can react
  /// to the fold pose (not just the laggy window size). A simulated pose wins
  /// over the native one, matching [build].
  void _publishHinge() {
    final signal = duoFoldSimulation.value ?? _native;
    duoHingeNow.value = signal?.hinge ?? DuoHinge.none;
  }

  @override
  Widget build(BuildContext context) {
    final signal = duoFoldSimulation.value ?? _native;
    final feature = signal == null ? null : displayFeatureFor(signal);
    if (feature == null) return widget.child;
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(displayFeatures: mergeFoldFeatures(mq.displayFeatures, feature)),
      child: widget.child,
    );
  }
}
