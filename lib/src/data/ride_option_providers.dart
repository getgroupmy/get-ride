// The rider's Options sheet as Admin → Display Settings → Ride Options sets
// it: which options show, in what order and under what name, the most child
// seats, and the assistance catalogue. Read live from the display settings
// blob; the defaults until an admin sets them.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ride_assistance.dart';
import '../core/ride_option_settings.dart';
import 'app_display_repository.dart' show displaySettingsBlobProvider;

final rideOptionsConfigProvider = Provider<RideOptionsConfig>(
  (ref) => RideOptionsConfig.fromSettings(ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{}),
);

/// Whether commission and promo codes apply to the option charges.
final optionChargeRulesProvider = Provider<OptionChargeRules>(
  (ref) => OptionChargeRules.fromSettings(ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{}),
);

final assistanceCatalogueProvider = Provider<AssistanceCatalogue>(
  (ref) => AssistanceCatalogue.fromSettings(ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{}),
);
