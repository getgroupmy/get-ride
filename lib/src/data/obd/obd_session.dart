import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/obd.dart';
import '../../core/obd_adapters.dart';
import '../../core/taxi_meter.dart' show obdStaleMs;
import 'obd_client.dart';
import 'obd_transport.dart';

/// The saved readers, on this device (Expo `canbusAdapterStore`).
class ObdAdapterStore {
  static const listKey = 'obd_adapters_v1';
  static const selectedKey = 'obd_selected_adapter_v1';

  Future<List<SavedObdAdapter>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(listKey);
      if (raw == null) return const [];
      final list = jsonDecode(raw);
      return list is List ? list.map(SavedObdAdapter.fromJson).whereType<SavedObdAdapter>().toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<SavedObdAdapter> list) async => (await SharedPreferences.getInstance())
      .setString(listKey, jsonEncode([for (final a in list) a.toJson()]));

  Future<String?> selectedId() async => (await SharedPreferences.getInstance()).getString(selectedKey);

  Future<void> select(String? id) async {
    final p = await SharedPreferences.getInstance();
    id == null ? await p.remove(selectedKey) : await p.setString(selectedKey, id);
  }

  /// The reader the meter connects to (Expo `pickDefaultAdapter`).
  Future<SavedObdAdapter?> current() async => pickDefaultAdapter(await load(), await selectedId());

  Future<void> markConnected(String id, int at) async =>
      save([for (final a in await load()) a.id == id ? a.copyWith(lastConnectedAt: at) : a]);
}

final obdAdapterStoreProvider = Provider((_) => ObdAdapterStore());

/// Builds the transport for a saved reader. A seam so tests can script one.
final obdTransportFactoryProvider = Provider<ObdTransport Function(SavedObdAdapter)>(
  (_) => (a) => switch (a.transport) {
        'wifi' => WifiObdTransport(a.host ?? wifiAdapterHost, a.port ?? wifiAdapterPort),
        _ => throw UnsupportedError(
            '${obdTransportLabels[a.transport] ?? a.transport} readers are not supported in this version of the app yet.'),
      },
);

/// Epoch milliseconds now, shared with the meter's clock seam.
final obdClockProvider = Provider<int Function()>((_) => () => DateTime.now().millisecondsSinceEpoch);

enum ObdPhase { idle, connecting, handshaking, online, error }

class ObdSessionState {
  const ObdSessionState({
    this.phase = ObdPhase.idle,
    this.adapter,
    this.device,
    this.protocol,
    this.bitrateKbps,
    this.telemetry = const {},
    this.lastUpdate,
    this.error,
  });

  final ObdPhase phase;
  final SavedObdAdapter? adapter;
  final String? device;
  final String? protocol;
  final int? bitrateKbps;
  final Telemetry telemetry;
  final int? lastUpdate;
  final String? error;

  bool get linked => phase == ObdPhase.online;

  /// The vehicle speed, when it is recent enough to bill on.
  double? freshSpeed(int now) {
    final at = lastUpdate, speed = telemetry['speed'];
    if (!linked || at == null || speed == null) return null;
    return now - at <= obdStaleMs ? speed : null;
  }

  ObdSessionState copyWith({
    ObdPhase? phase,
    SavedObdAdapter? adapter,
    String? Function()? device,
    String? Function()? protocol,
    int? Function()? bitrateKbps,
    Telemetry? telemetry,
    int? Function()? lastUpdate,
    String? Function()? error,
  }) =>
      ObdSessionState(
        phase: phase ?? this.phase,
        adapter: adapter ?? this.adapter,
        device: device == null ? this.device : device(),
        protocol: protocol == null ? this.protocol : protocol(),
        bitrateKbps: bitrateKbps == null ? this.bitrateKbps : bitrateKbps(),
        telemetry: telemetry ?? this.telemetry,
        lastUpdate: lastUpdate == null ? this.lastUpdate : lastUpdate(),
        error: error == null ? this.error : error(),
      );
}

/// The one live link to the reader (Expo `useCanbus`). A dongle serves one
/// client at a time, so the meter and the reader screen share this session
/// instead of each opening their own.
class ObdSession extends Notifier<ObdSessionState> {
  static const reconnectInterval = Duration(seconds: 4);

  ObdClient? _client;
  Timer? _retry;

  /// Whether the link should be kept up (reconnecting after a loss).
  bool _wanted = false;

  @override
  ObdSessionState build() {
    ref.onDispose(() {
      _retry?.cancel();
      _client?.stop();
    });
    return const ObdSessionState();
  }

  int _now() => ref.read(obdClockProvider)();

  /// Connects to the saved reader if there is one and nothing is connected
  /// (the meter calls this when it opens).
  Future<void> ensureConnected() async {
    if (_wanted || state.phase == ObdPhase.connecting || state.phase == ObdPhase.handshaking) return;
    final adapter = await ref.read(obdAdapterStoreProvider).current();
    if (adapter != null) await connect(adapter);
  }

  /// Connects to [adapter] and keeps the link up until [disconnect].
  Future<void> connect(SavedObdAdapter adapter) async {
    _wanted = true;
    _retry?.cancel();
    await _stopClient();
    state = ObdSessionState(phase: ObdPhase.connecting, adapter: adapter);
    try {
      final transport = ref.read(obdTransportFactoryProvider)(adapter);
      final device = await transport.connect();
      if (!_wanted) {
        await transport.disconnect();
        return;
      }
      state = state.copyWith(phase: ObdPhase.handshaking, device: () => device);
      final client = ObdClient(
        transport,
        now: _now,
        onTelemetry: (t, at) {
          if (_client != null) state = state.copyWith(telemetry: {...state.telemetry, ...t}, lastUpdate: () => at);
        },
        onProtocol: (name, kbps) => state = state.copyWith(protocol: () => name, bitrateKbps: () => kbps),
        onLinkLost: _linkLost,
      );
      _client = client;
      await client.start();
      if (_client != client) return;
      state = state.copyWith(phase: ObdPhase.online, error: () => null);
      unawaited(ref.read(obdAdapterStoreProvider).markConnected(adapter.id, _now()));
    } catch (e) {
      await _stopClient();
      state = state.copyWith(phase: ObdPhase.error, error: () => _describe(e));
      _scheduleRetry();
    }
  }

  void _linkLost() {
    state = state.copyWith(phase: ObdPhase.error, error: () => 'Lost the link to the reader.');
    unawaited(_stopClient());
    _scheduleRetry();
  }

  void _scheduleRetry() {
    final adapter = state.adapter;
    if (!_wanted || adapter == null) return;
    _retry?.cancel();
    _retry = Timer(reconnectInterval, () {
      if (_wanted) connect(adapter);
    });
  }

  /// Sends one command to the reader (an on-demand read such as the
  /// odometer). Null when no reader is online.
  Future<String?> request(String command) async {
    final c = _client;
    if (c == null || !state.linked) return null;
    return c.request(command);
  }

  Future<void> disconnect() async {
    _wanted = false;
    _retry?.cancel();
    await _stopClient();
    state = const ObdSessionState();
  }

  Future<void> _stopClient() async {
    final c = _client;
    _client = null;
    if (c != null) {
      try {
        await c.stop();
      } catch (_) {}
    }
  }

  static String _describe(Object e) {
    final text = '$e'.replaceFirst(RegExp(r'^(Exception|StateError|SocketException|UnsupportedError|Unsupported operation):\s*'), '');
    return text.isEmpty ? 'Could not reach the reader.' : text;
  }
}

final obdSessionProvider = NotifierProvider<ObdSession, ObdSessionState>(ObdSession.new);
