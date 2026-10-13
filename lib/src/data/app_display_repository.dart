import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../admin/screens/meterapp/display_logic.dart' show displaySettingsTable, displaySettingsRowId;
import '../core/app_display.dart';
import '../core/fare.dart';
import '../core/payment_types.dart';
import '../core/recent_places.dart';
import '../core/ride_services.dart';
import 'geo_service.dart';
import 'live_tables.dart';
import '../providers.dart';

/// The admin display settings the rider app honours (public read of
/// `admin_display_settings`, row `global`). Unreachable or missing means the
/// defaults: the service stays on and sign-up stays open. Live: an admin's
/// change re-reads it on every open app (see `live_tables.dart`); a failed
/// re-read keeps the last one.
final displaySettingsBlobProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  ref.watchLive(displaySettingsTable);
  try {
    final row = await ref
        .watch(supabaseProvider)
        .from(displaySettingsTable)
        .select('settings')
        .eq('id', displaySettingsRowId)
        .maybeSingle()
        .timeout(appSettingsReadTimeout);
    final blob = _lastDisplayBlob = displaySettingsFromRow(row);
    unawaited(_store(_displayBlobKey, jsonEncode(blob)));
    return blob;
  } catch (_) {
    // A refetch that fails or stalls (the app back from the background
    // before its connection is, a slow API) keeps what the admin last set --
    // this session's, else the copy kept on the device -- rather than
    // snapping every switch back to its default until the next change.
    return _lastDisplayBlob ?? decodeDisplayBlob(await _stored(_displayBlobKey)) ?? const {};
  }
});

/// How long the home screen waits on a settings read before it uses what it
/// already has. A read that hangs (a slow API, a stalled connection) would
/// otherwise hold the booking sheet's skeleton up until it gives up.
const appSettingsReadTimeout = Duration(seconds: 8);

const _displayBlobKey = 'admin_display_settings_v1';
const _rideCatalogueKey = 'ride_catalogue_v1';

Future<String?> _stored(String key) async {
  try {
    return (await SharedPreferences.getInstance()).getString(key);
  } catch (_) {
    return null;
  }
}

Future<void> _store(String key, String value) async {
  try {
    await (await SharedPreferences.getInstance()).setString(key, value);
  } catch (_) {}
}

/// A display blob kept on the device, or null when there is none. Pure.
Map<String, dynamic>? decodeDisplayBlob(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final j = jsonDecode(raw);
    return j is Map ? Map<String, dynamic>.from(j) : null;
  } catch (_) {
    return null;
  }
}

/// The Vehicle Services catalogue and the display arrangement it was last
/// shown with, as kept on the device. Pure.
String encodeRideCatalogue(List<CatalogueEntry> entries, Map<String, dynamic> display) => jsonEncode({
  'entries': [
    for (final e in entries) {'id': e.id, 'values': e.values},
  ],
  'display': display,
});

/// [encodeRideCatalogue] read back, or null for nothing (or anything else). Pure.
({List<CatalogueEntry> entries, Map<String, dynamic> display})? decodeRideCatalogue(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final j = jsonDecode(raw);
    if (j is! Map || j['entries'] is! List) return null;
    final entries = <CatalogueEntry>[
      for (final e in j['entries'] as List)
        if (e is Map && e['values'] is Map) (id: '${e['id']}', values: Map<String, dynamic>.from(e['values'] as Map)),
    ];
    final display = j['display'] is Map ? Map<String, dynamic>.from(j['display'] as Map) : <String, dynamic>{};
    return (entries: entries, display: display);
  } catch (_) {
    return null;
  }
}

/// The ride services this device last showed, from its own copy (null when
/// it has none): what the vehicle bar draws at once on a later launch while
/// [rideServicesProvider] reads the current catalogue.
final cachedRideServicesProvider = FutureProvider<List<RideService>?>((ref) async {
  final kept = decodeRideCatalogue(await _stored(_rideCatalogueKey));
  if (kept == null || kept.entries.isEmpty) return null;
  return rideServicesFromCatalogue(kept.entries, kept.display);
});

/// The last blob read, for a failed refetch.
Map<String, dynamic>? _lastDisplayBlob;

/// The settings blob off a row, or the defaults (empty) without one.
Map<String, dynamic> displaySettingsFromRow(Map<String, dynamic>? row) {
  final raw = row?['settings'];
  return raw is Map ? Map<String, dynamic>.from(raw) : const {};
}

final appDisplayProvider = FutureProvider<AppDisplay>(
  (ref) async => AppDisplay.fromSettings(await ref.watch(displaySettingsBlobProvider.future)),
);

/// What the booking sheet offers: the admin Vehicle Services catalogue
/// (public read of `settings_entries`), arranged by Admin → Display. When the
/// catalogue cannot be read, the built-in list keeps booking working.
final rideServicesProvider = FutureProvider<List<RideService>>((ref) async {
  ref.watchLive('settings_entries');
  // The catalogue and the arrangement are read side by side, not one after
  // the other, and neither may hold the sheet up past its timeout.
  Future<List<Map<String, dynamic>>?> catalogue() async {
    try {
      final rows = await ref
          .watch(supabaseProvider)
          .from('settings_entries')
          .select('id, values, position')
          .eq('category', 'vehicle-services')
          .order('position')
          .timeout(appSettingsReadTimeout);
      return [for (final r in rows) Map<String, dynamic>.from(r)];
    } catch (_) {
      return null;
    }
  }

  final rowsRead = catalogue();
  final display = await ref.watch(displaySettingsBlobProvider.future);
  final rows = await rowsRead;
  if (rows == null) {
    // Unreadable: the last catalogue this session or this device had, and
    // the built-in list only when there has never been one.
    final List<RideService>? kept = await ref.read(cachedRideServicesProvider.future);
    return _lastRideServices ?? kept ?? rideServices;
  }
  final entries = <CatalogueEntry>[
    for (final r in rows)
      (id: '${r['id']}', values: r['values'] is Map ? Map<String, dynamic>.from(r['values'] as Map) : <String, dynamic>{}),
  ];
  unawaited(_store(_rideCatalogueKey, encodeRideCatalogue(entries, display)));
  return _lastRideServices = rideServicesFromCatalogue(entries, display);
});

/// The last catalogue read this session, for a read that fails.
List<RideService>? _lastRideServices;

/// The rider's recent destinations for the place picker, as many as Admin →
/// Display allows. Empty when switched off, signed out or unreachable.
final recentPlacesProvider = FutureProvider.autoDispose<List<Place>>((ref) async {
  final display = await ref.watch(appDisplayProvider.future);
  if (!display.recentLocations || display.recentLocationsCount == 0) return const [];
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return const [];
  try {
    final rides = await ref.watch(rideRepositoryProvider).history(limit: 40);
    return recentPlaces(rides, riderId: uid, max: display.recentLocationsCount);
  } catch (_) {
    return const [];
  }
});

/// Names of the admin services a home service box can be linked to (public
/// read of `settings_entries`, category `service-settings`), by entry id.
final serviceBoxNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  ref.watchLive('settings_entries');
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('settings_entries')
        .select('id, values')
        .eq('category', 'service-settings');
    return {
      for (final r in rows)
        if (r['values'] is Map && '${(r['values'] as Map)['name'] ?? ''}'.trim().isNotEmpty)
          '${r['id']}': '${(r['values'] as Map)['name']}'.trim(),
    };
  } catch (_) {
    return const {};
  }
});

/// The payment methods the confirm sheet offers: Admin → Payment Type's
/// enabled entries in its order (public read of `settings_entries`, category
/// `payment-type`), live. The built-in Cash / GET.wallet pair when the admin
/// list is empty or cannot be read.
final paymentChoicesProvider = FutureProvider<List<PaymentChoice>>((ref) async {
  ref.watchLive('settings_entries');
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('settings_entries')
        .select('values, position')
        .eq('category', 'payment-type')
        .order('position');
    final choices = paymentChoicesFrom([
      for (final r in rows) if (r['values'] is Map) Map<String, dynamic>.from(r['values'] as Map),
    ]);
    return choices.isEmpty ? builtInPayments : choices;
  } catch (_) {
    return builtInPayments;
  }
});
