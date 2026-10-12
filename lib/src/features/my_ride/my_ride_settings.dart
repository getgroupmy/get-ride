// My Ride settings, kept on the device: the farthest a favourite may be from
// the pickup to be offered a ride first, and whether a booking starts with
// My Ride on. The distance goes on the request (`my_ride_max_km`), where the
// server applies the smaller of it and the vehicle service's own cap.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The distance choices the settings page offers; null is no limit.
const myRideMaxKmChoices = <double?>[null, 2, 5, 10, 20, 50];

/// "No limit", "5 km".
String myRideMaxKmLabel(double? km) => km == null || km <= 0 ? 'No limit' : '${km.round()} km';

class MyRideSettings {
  const MyRideSettings({this.maxKm, this.onByDefault = false});

  /// Null is no limit.
  final double? maxKm;

  /// A booking starts with My Ride on (when the rider has a favourite to
  /// offer it to).
  final bool onByDefault;

  MyRideSettings copyWith({double? Function()? maxKm, bool? onByDefault}) =>
      MyRideSettings(maxKm: maxKm == null ? this.maxKm : maxKm(), onByDefault: onByDefault ?? this.onByDefault);

  @override
  bool operator ==(Object other) => other is MyRideSettings && other.maxKm == maxKm && other.onByDefault == onByDefault;

  @override
  int get hashCode => Object.hash(maxKm, onByDefault);
}

/// Reads and writes [MyRideSettings] in SharedPreferences. Overridden in
/// tests.
class MyRideSettingsStore {
  static const maxKmKey = 'my_ride_max_km';
  static const onByDefaultKey = 'my_ride_on_by_default';

  /// The saved settings; the defaults when nothing is saved or the store
  /// can't be read.
  Future<MyRideSettings> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final km = p.getDouble(maxKmKey);
      return MyRideSettings(
        maxKm: km != null && km > 0 && km.isFinite ? km : null,
        onByDefault: p.getBool(onByDefaultKey) ?? false,
      );
    } catch (_) {
      return const MyRideSettings();
    }
  }

  Future<void> save(MyRideSettings s) async {
    final p = await SharedPreferences.getInstance();
    final km = s.maxKm;
    if (km == null || km <= 0) {
      await p.remove(maxKmKey);
    } else {
      await p.setDouble(maxKmKey, km);
    }
    await p.setBool(onByDefaultKey, s.onByDefault);
  }
}

final myRideSettingsStoreProvider = Provider<MyRideSettingsStore>((_) => MyRideSettingsStore());

class MyRideSettingsNotifier extends AsyncNotifier<MyRideSettings> {
  @override
  Future<MyRideSettings> build() => ref.watch(myRideSettingsStoreProvider).load();

  /// Applies [change] to the latest settings, shows the result at once and
  /// saves it.
  Future<void> edit(MyRideSettings Function(MyRideSettings current) change) async {
    final next = change(state.value ?? const MyRideSettings());
    state = AsyncData(next);
    await ref.read(myRideSettingsStoreProvider).save(next);
  }
}

final myRideSettingsProvider = AsyncNotifierProvider<MyRideSettingsNotifier, MyRideSettings>(
  MyRideSettingsNotifier.new,
);
