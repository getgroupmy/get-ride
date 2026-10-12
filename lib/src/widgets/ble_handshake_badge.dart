// The kerbside badge (reliability Phase D2): while a ride is accepted or
// arrived, runs the Bluetooth handshake (lib/src/data/ble_handshake.dart) and
// says what it found — "✓ Correct car" — or, on the driver's phone, counts
// down before a match starts the trip, with a moment to cancel. Shows
// nothing when the admin has it off; the trip code always still works.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ble_handshake.dart';
import '../data/ble_chat.dart';
import '../data/ble_handshake.dart';
import '../data/ride_chat_outbox.dart';
import '../data/reliability_repository.dart';
import '../providers.dart';

/// The handshake's server half for a ride; overridable in tests.
final bleHandshakeServerProvider = Provider.family<BleHandshakeServer, String>(
  (ref, rideId) => BleHandshakeServer.forRide(ref.watch(rideRepositoryProvider), rideId),
);

/// Which phone this is, for the admin's per-platform switches.
final blePlatformProvider = Provider<({bool android, bool ios})>(
  (_) => (
    android: !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
    ios: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
  ),
);

class BleHandshakeBadge extends ConsumerStatefulWidget {
  const BleHandshakeBadge({super.key, required this.rideId, required this.status, required this.driver});

  final String rideId;

  /// The ride's status (its db name).
  final String status;

  /// The driver's phone (else the rider's).
  final bool driver;

  @override
  ConsumerState<BleHandshakeBadge> createState() => _BleHandshakeBadgeState();
}

class _BleHandshakeBadgeState extends ConsumerState<BleHandshakeBadge> {
  BleHandshakeEngine? _engine;

  /// Where the chat screen finds this ride's Bluetooth chat (Phase D3).
  late final BleChatSessions _sessions;
  BleChatSession? _session;

  BleChatSession _newChat(BleTicket t, Uint8List key) => BleChatSession(
    transport: ref.read(bleChatTransportProvider)(),
    key: key,
    requestId: widget.rideId,
    driver: widget.driver,
    pending: () => ref.read(rideChatOutboxProvider),
    now: ref.read(bleClockProvider),
  );

  /// Publishes (or withdraws) the engine's chat, outside any build.
  void _publishChat(BleChatSession? s) {
    final old = _session;
    _session = s;
    Future.microtask(() {
      if (old != null) _sessions.remove(old);
      if (s != null) _sessions.put(s);
    });
  }

  void _sync(BleSettings settings) {
    final p = ref.read(blePlatformProvider);
    final wanted = settings.runsOn(isAndroid: p.android, isIos: p.ios);
    if (wanted && _engine == null) {
      final e = BleHandshakeEngine(
        radio: ref.read(bleRadioProvider),
        server: ref.read(bleHandshakeServerProvider(widget.rideId)),
        isAndroid: p.android,
        isIos: p.ios,
        status: widget.status,
        position: ref.read(blePositionProvider),
        now: ref.read(bleClockProvider),
        chatFactory: _newChat,
      );
      _engine = e;
      e.chat.addListener(() => _publishChat(e.chat.value));
      e.start();
    } else if (!wanted && _engine != null) {
      _engine!.dispose();
      _engine = null;
      _publishChat(null);
    }
  }

  @override
  void initState() {
    super.initState();
    _sessions = ref.read(bleChatSessionsProvider.notifier);
    _sync(ref.read(reliabilityProvider).ble);
    ref.listenManual(reliabilityProvider.select((s) => s.ble), (_, b) => setState(() => _sync(b)));
  }

  @override
  void didUpdateWidget(BleHandshakeBadge old) {
    super.didUpdateWidget(old);
    if (old.rideId != widget.rideId) {
      _engine?.dispose();
      _engine = null;
      _publishChat(null);
      _sync(ref.read(reliabilityProvider).ble);
    } else if (old.status != widget.status) {
      _engine?.updateStatus(widget.status);
    }
  }

  @override
  void dispose() {
    _engine?.dispose();
    _publishChat(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = _engine;
    if (e == null) return const SizedBox.shrink();
    return ValueListenableBuilder<BleHandshakePhase>(
      valueListenable: e.phase,
      builder: (context, phase, _) {
        final label = bleHandshakeLabel(phase, driver: widget.driver);
        if (label == null) return const SizedBox.shrink();
        final c = Theme.of(context).colorScheme;
        final good = phase == BleHandshakePhase.matched || phase == BleHandshakePhase.started;
        final quiet = phase == BleHandshakePhase.unavailable || phase == BleHandshakePhase.cancelled;
        final bg = good ? c.primaryContainer : (quiet ? c.surfaceContainerHighest : c.secondaryContainer);
        final fg = good ? c.onPrimaryContainer : (quiet ? c.onSurfaceVariant : c.onSecondaryContainer);
        final icon = switch (phase) {
          BleHandshakePhase.matched || BleHandshakePhase.started => Icons.verified,
          BleHandshakePhase.unavailable || BleHandshakePhase.cancelled => Icons.bluetooth_disabled,
          BleHandshakePhase.nearby || BleHandshakePhase.countdown => Icons.bluetooth_connected,
          _ => Icons.bluetooth_searching,
        };
        return Semantics(
          liveRegion: true,
          child: Container(
            key: const ValueKey('ble-badge'),
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 10),
                Expanded(
                  child: phase == BleHandshakePhase.countdown
                      ? ValueListenableBuilder<int>(
                          valueListenable: e.countdownLeft,
                          builder: (_, left, _) => Text(
                            '$label in $left…',
                            style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                          ),
                        )
                      : ValueListenableBuilder<int?>(
                          valueListenable: e.peerRssi,
                          builder: (_, rssi, _) {
                            // "Driver nearby (~X m)": a hint from the signal, while in range.
                            final near =
                                rssi != null &&
                                (phase == BleHandshakePhase.nearby || phase == BleHandshakePhase.matched);
                            return Text(
                              near ? '$label · ${bleDistanceLabel(bleDistanceM(rssi))}' : label,
                              key: const ValueKey('ble-label'),
                              style: TextStyle(color: fg, fontWeight: good ? FontWeight.w700 : FontWeight.w500),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        ),
                ),
                if (phase == BleHandshakePhase.countdown)
                  TextButton(
                    key: const ValueKey('ble-cancel'),
                    onPressed: e.cancel,
                    style: TextButton.styleFrom(foregroundColor: fg),
                    child: const Text('Cancel'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
