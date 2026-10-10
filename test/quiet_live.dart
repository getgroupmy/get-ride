// Live tables without a realtime socket, for widget tests that build screens
// reading live data (a socket would leave its reconnect timers pending).
import 'package:get_ride/src/data/live_tables.dart';

class QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

class QuietAdminLive extends AdminLiveTables {
  @override
  Map<String, int> build() => const {};
}

/// Both live channels, quiet.
final quietLiveOverrides = [
  liveTablesProvider.overrideWith(QuietLive.new),
  adminLiveTablesProvider.overrideWith(QuietAdminLive.new),
];
