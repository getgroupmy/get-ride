import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ev_profile.dart';
import '../../core/obd.dart';
import '../../core/obd_adapters.dart';
import '../../core/taxi_meter.dart' show obdStaleMs;
import '../ev_profile_repository.dart';
import 'obd_ble_transport.dart';
import 'obd_client.dart';
import 'obd_transport.dart';
import 'obd_mfi_transport.dart';

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
        'bluetooth' when a.deviceId != null => BleObdTransport(a.deviceId!, name: a.name),
        'mfi' when a.deviceId != null => MfiObdTransport(a.deviceId!, name: a.name),
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
    this.vehicleSilent = false,
    this.evProfile,
    this.ev,
    this.evCandidates = const [],
    this.evSearching = false,
  });

  final ObdPhase phase;
  final SavedObdAdapter? adapter;
  final String? device;
  final String? protocol;
  final int? bitrateKbps;
  final Telemetry telemetry;
  final int? lastUpdate;
  final String? error;

  /// The reader is connected but the vehicle answers nothing standard
  /// (most electric cars, or an engine car with the ignition off).
  final bool vehicleSilent;

  /// The EV profile this car answered (Admin → EV profiles), while the
  /// vehicle is silent on standard OBD-II.
  final EvProfile? evProfile;

  /// What [evProfile] last read.
  final EvSnapshot? ev;

  /// More than one profile answered: the driver says which car this is.
  final List<EvProfile> evCandidates;

  /// The car is being asked whether an EV profile fits.
  final bool evSearching;

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
    bool? vehicleSilent,
    EvProfile? Function()? evProfile,
    EvSnapshot? Function()? ev,
    List<EvProfile>? evCandidates,
    bool? evSearching,
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
        vehicleSilent: vehicleSilent ?? this.vehicleSilent,
        evProfile: evProfile == null ? this.evProfile : evProfile(),
        ev: ev == null ? this.ev : ev(),
        evCandidates: evCandidates ?? this.evCandidates,
        evSearching: evSearching ?? this.evSearching,
      );
}

/// The one live link to the reader (Expo `useCanbus`). A dongle serves one
/// client at a time, so the meter and the reader screen share this session
/// instead of each opening their own.
class ObdSession extends Notifier<ObdSessionState> {
  static const reconnectInterval = Duration(seconds: 4);

  /// How often an EV profile's values are read.
  static const evPollInterval = Duration(seconds: 2);

  /// How long after no profile fitted a silent car it is asked again (it
  /// may not have been on, or a profile may have been added since).
  static const evRetryInterval = Duration(seconds: 60);

  /// Passes in a row with no value before the profile is let go.
  static const evMissLimit = 5;

  ObdClient? _client;
  Timer? _retry;

  /// Whether the link should be kept up (reconnecting after a loss).
  bool _wanted = false;

  /// A live link dropped and is being brought back: the attempts show as
  /// "reconnecting", not as an unreachable reader (Expo `handleLinkLost`).
  bool _lost = false;

  /// The 1 Hz sweep is held while the vehicle scan or a print job needs
  /// the radio; either can hold it, and it runs again once both let go.
  bool _scanPaused = false;
  int _printHolds = 0;

  // EV profiles: the sweep is held while profiles are tried and while one
  // is read (both change the reader's header), and given back after.
  bool _evHold = false;
  bool _evSearchRunning = false;
  bool _evPolling = false;
  bool _evNeedsInit = false;
  int _evMisses = 0;
  EvBus? _evBus;
  Timer? _evTimer;
  Timer? _evRetry;
  int _captureHolds = 0;

  @override
  ObdSessionState build() {
    ref.onDispose(() {
      _retry?.cancel();
      _resetEv();
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
    _resetEv();
    await _stopClient();
    state = ObdSessionState(
      phase: ObdPhase.connecting,
      adapter: adapter,
      error: _lost ? obdReconnectingMessage : null,
    );
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
        onVehicleSilent: (silent) {
          if (_client == null) return;
          state = state.copyWith(vehicleSilent: silent);
          if (silent) unawaited(_findEvProfile());
        },
      );
      _client = client;
      await client.start();
      if (_client != client) return;
      _lost = false;
      _applyPause();
      state = state.copyWith(phase: ObdPhase.online, error: () => null);
      unawaited(ref.read(obdAdapterStoreProvider).markConnected(adapter.id, _now()));
    } catch (e) {
      await _stopClient();
      state = _lost && _wanted
          ? state.copyWith(phase: ObdPhase.connecting, error: () => obdReconnectingMessage)
          : state.copyWith(phase: ObdPhase.error, error: () => _describe(e));
      _scheduleRetry();
    }
  }

  void _linkLost() {
    _lost = true;
    _resetEv();
    state = state.copyWith(
      phase: ObdPhase.connecting,
      error: () => obdReconnectingMessage,
      vehicleSilent: false,
      telemetry: const {},
      lastUpdate: () => null,
      evProfile: () => null,
      ev: () => null,
      evCandidates: const [],
      evSearching: false,
    );
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

  /// Holds the 1 Hz sweep while something else needs the reader to itself
  /// (the vehicle scan): the adapter answers one command at a time.
  void setPollingPaused(bool paused) {
    _scanPaused = paused;
    // The scan asks standard questions: give the reader back its own
    // settings first (queued ahead of the scan), and set the profile's
    // again after.
    if (paused && _evHold) _releaseEvSettings();
    _applyPause();
  }

  /// Keeps the reader quiet while [job] runs: a receipt printing shares the
  /// phone's radio, and a reply missed meanwhile must not read as a lost
  /// link mid-hire. The sweep picks up again when the job is done.
  Future<T> holdWhile<T>(Future<T> Function() job) async {
    _printHolds++;
    _applyPause();
    try {
      return await job();
    } finally {
      _printHolds--;
      _applyPause();
    }
  }

  /// Only a print job's hold forgives missed replies: a scan that keeps
  /// timing out is a reader that has gone.
  void _applyPause() => _client?.setPollingPaused(
    _scanPaused || _printHolds > 0 || _evHold || _captureHolds > 0,
    ignoreFailures: _printHolds > 0,
  );

  /// Something else is using the reader: the EV profile waits.
  bool get _evHeld => _scanPaused || _printHolds > 0 || _captureHolds > 0;

  /// Gives [job] the reader to itself (Record for support): the sweep and
  /// any EV profile wait, and the profile's settings are set again after.
  /// [job]'s commands fail with a [StateError] once the reader is gone.
  Future<T> exclusive<T>(Future<T> Function(EvSend send) job) async {
    _captureHolds++;
    _applyPause();
    // An EV pass under way stops between commands; let it.
    while (_evPolling) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    try {
      return await job(
        (command) async => await request(command) ?? (throw StateError('The OBD-II reader is not connected.')),
      );
    } finally {
      _captureHolds--;
      if (state.evProfile != null) {
        _evBus?.forget();
        _evNeedsInit = true;
      }
      _applyPause();
    }
  }

  // ---- EV profiles ------------------------------------------------------------------

  /// Asks a silent car whether one of the active EV profiles fits it. One
  /// fits: it is read from then on. Several: the driver chooses (and the
  /// choice is kept for this reader and these matches). None: the car is
  /// asked again in [evRetryInterval].
  Future<void> _findEvProfile() async {
    final client = _client;
    if (client == null || _evSearchRunning || state.evProfile != null || state.evCandidates.isNotEmpty) return;
    _evSearchRunning = true;
    _evRetry?.cancel();
    try {
      List<EvProfile> profiles;
      try {
        profiles = await ref.read(evProfilesProvider.future);
      } catch (_) {
        profiles = const [];
      }
      profiles = [
        for (final p in profiles)
          if (p.active && p.detect != null && p.signals.isNotEmpty) p,
      ];
      if (_client != client) return;
      // None yet (or none kept for offline use): an admin may add one.
      if (profiles.isEmpty || !state.linked || !state.vehicleSilent) return _scheduleEvRetry(client);
      _evHold = true;
      _applyPause();
      state = state.copyWith(evSearching: true);
      final bus = EvBus(client.request);
      final matches = await detectEvProfiles(bus, profiles, shouldContinue: () => _client == client && !_evHeld);
      if (_client != client) return;
      if (matches.isEmpty) {
        await _restoreReader(client);
        _evHold = false;
        _applyPause();
        state = state.copyWith(evSearching: false);
        _scheduleEvRetry(client);
        return;
      }
      if (matches.length == 1) return await _useEvProfile(matches.single);
      final readerId = state.adapter?.id ?? '';
      final chosen = await ref.read(evChoiceStoreProvider).chosen(readerId, [for (final m in matches) _evKey(m)]);
      final pick = matches.where((m) => _evKey(m) == chosen).firstOrNull;
      if (pick != null) return await _useEvProfile(pick);
      state = state.copyWith(evCandidates: matches, evSearching: false);
    } finally {
      _evSearchRunning = false;
      if (_client == client && state.evSearching) state = state.copyWith(evSearching: false);
    }
  }

  static String _evKey(EvProfile p) => p.id ?? p.title;

  void _scheduleEvRetry(ObdClient client) {
    _evRetry?.cancel();
    _evRetry = Timer(evRetryInterval, () {
      if (_client == client && state.linked && state.vehicleSilent) unawaited(_findEvProfile());
    });
  }

  /// The driver's answer when several profiles fit: remembered for this
  /// reader and these matches.
  Future<void> chooseEvProfile(EvProfile profile) async {
    final candidates = state.evCandidates;
    if (candidates.isEmpty) return;
    await ref.read(evChoiceStoreProvider).remember(state.adapter?.id ?? '', [
      for (final m in candidates) _evKey(m),
    ], _evKey(profile));
    await _useEvProfile(profile);
  }

  Future<void> _useEvProfile(EvProfile p) async {
    final client = _client;
    if (client == null) return;
    _evHold = true;
    _applyPause();
    _evBus = EvBus(client.request);
    _evNeedsInit = true;
    _evMisses = 0;
    state = state.copyWith(evProfile: () => p, ev: () => null, evCandidates: const [], evSearching: false);
    _evTimer?.cancel();
    _evTimer = Timer.periodic(evPollInterval, (_) => _pollEv());
    unawaited(_pollEv());
  }

  Future<void> _pollEv() async {
    final client = _client, bus = _evBus, p = state.evProfile;
    if (client == null || bus == null || p == null || _evPolling || _evHeld) return;
    _evPolling = true;
    try {
      if (_evNeedsInit) {
        bus.forget();
        await sendEvInit(bus, p);
        _evNeedsInit = false;
      }
      final snap = await readEvSnapshot(bus, p, at: _now(), shouldContinue: () => _client == client && !_evHeld);
      if (_client != client || state.evProfile != p) return;
      if (snap.isEmpty) {
        if (_evHeld) return;
        if (++_evMisses >= evMissLimit) await _dropEv(client);
        return;
      }
      _evMisses = 0;
      // A verified profile's speed is the vehicle speed the meter bills on,
      // while Admin → EV profiles allows it (followed live).
      EvSettings settings;
      try {
        settings = await ref.read(evSettingsProvider.future);
      } catch (_) {
        settings = const EvSettings();
      }
      if (_client != client || state.evProfile != p) return;
      final speed = evBillingSpeed(p, snap, settings);
      state = state.copyWith(
        ev: () => snap,
        telemetry: speed == null ? null : {...state.telemetry, 'speed': speed},
        lastUpdate: speed == null ? null : () => snap.at,
      );
    } catch (_) {
      // An init command unanswered: sent again next pass.
      _evNeedsInit = true;
    } finally {
      _evPolling = false;
    }
  }

  /// The car stopped answering the profile: back to the standard sweep,
  /// and the profiles are tried again later.
  Future<void> _dropEv(ObdClient client) async {
    _evTimer?.cancel();
    _evTimer = null;
    _evBus = null;
    state = state.copyWith(evProfile: () => null, ev: () => null);
    await _restoreReader(client);
    _evHold = false;
    _applyPause();
    _scheduleEvRetry(client);
  }

  /// Queues the reader's own settings ahead of whatever comes next.
  void _releaseEvSettings() {
    final client = _client;
    if (client == null) return;
    _evBus?.forget();
    _evNeedsInit = true;
    unawaited(_restoreReader(client));
  }

  Future<void> _restoreReader(ObdClient client) async {
    for (final c in evRestoreCommands) {
      try {
        await client.request(c);
      } catch (_) {}
    }
  }

  void _resetEv() {
    _evTimer?.cancel();
    _evTimer = null;
    _evRetry?.cancel();
    _evRetry = null;
    _evBus = null;
    _evHold = false;
    _evMisses = 0;
    _evNeedsInit = false;
  }

  Future<void> disconnect() async {
    _wanted = false;
    _lost = false;
    _retry?.cancel();
    _resetEv();
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
    final text = '$e'.replaceFirst(RegExp(r'^(Exception|StateError|Bad state|SocketException|TimeoutException|UnsupportedError|Unsupported operation):\s*'), '');
    return text.isEmpty ? 'Could not reach the reader.' : text;
  }
}

/// What a dropped link shows while it is brought back.
const obdReconnectingMessage = 'Reader disconnected — reconnecting…';

final obdSessionProvider = NotifierProvider<ObdSession, ObdSessionState>(ObdSession.new);
