// City to City (migration 0306): the settings, permits by country and route
// rules the admin keeps, and commission per service. The apps read the
// same rows (everyone signed in reads them); admins with EDIT write.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/city_to_city.dart';
import '../core/fare.dart' show ServiceRates;
import '../core/fare_tariff.dart';
import '../providers.dart';
import 'live_tables.dart';

/// A permit type an admin can ask for (permit_types, 0254).
typedef C2cPermitType = ({String id, String name, String country, String appliesTo});

/// The City to City Vehicle Service: its entry id, its master services
/// (ids) and its own rates, for the fare card.
typedef C2cService = ({String? id, Set<String> types, ServiceRates? rates, bool active});

class CityToCityRepository {
  CityToCityRepository(this._db);
  final SupabaseClient _db;

  Future<C2cSettings> settings() async =>
      C2cSettings.fromRow(await _db.from('city_to_city_settings').select().eq('id', 1).maybeSingle());

  Future<void> saveSettings(C2cSettings s) => _db.from('city_to_city_settings').update(s.toRow()).eq('id', 1);

  Future<List<C2cRule>> rules() async {
    final rows = await _db
        .from('c2c_route_rules')
        .select()
        .order('position', ascending: true)
        .order('created_at', ascending: true);
    return [for (final r in rows) C2cRule.fromRow(r)];
  }

  /// Adds [r] (no id) at the end of the list, or changes it.
  Future<void> saveRule(C2cRule r) async {
    final row = r.toRow();
    if (r.id == null) {
      await _db.from('c2c_route_rules').insert(row);
    } else {
      await _db.from('c2c_route_rules').update(row).eq('id', r.id!);
    }
  }

  Future<void> setRuleActive(String id, bool on) => _db.from('c2c_route_rules').update({'active': on}).eq('id', id);

  Future<void> deleteRule(String id) => _db.from('c2c_route_rules').delete().eq('id', id);

  Future<List<C2cCountryPermit>> countryPermits() async {
    final rows = await _db
        .from('c2c_country_permits')
        .select('id, country, permit_type_id, applies_to, position, permit_types(name)')
        .order('country', ascending: true)
        .order('position', ascending: true);
    return [for (final r in rows) C2cCountryPermit.fromRow(r)];
  }

  Future<void> addCountryPermit(String country, String permitTypeId, {int position = 0}) => _db
      .from('c2c_country_permits')
      .insert({'country': country.trim(), 'permit_type_id': permitTypeId, 'position': position});

  Future<void> removeCountryPermit(String id) => _db.from('c2c_country_permits').delete().eq('id', id);

  Future<List<C2cPermitType>> permitTypes() async {
    final rows = await _db
        .from('permit_types')
        .select('id, name, country, applies_to')
        .eq('active', true)
        .order('country', ascending: true)
        .order('position', ascending: true);
    return [
      for (final r in rows)
        (
          id: '${r['id']}',
          name: '${r['name'] ?? ''}',
          country: '${r['country'] ?? ''}',
          appliesTo: r['applies_to'] == 'driver' ? 'driver' : 'vehicle',
        ),
    ];
  }

  /// The service's own rate per Vehicle Service id.
  Future<Map<String, double>> serviceRates() async {
    final rows = await _db.from('commission_service_rates').select('service_id, rate, active');
    return {
      for (final r in rows)
        if (r['active'] != false && r['rate'] is num) '${r['service_id']}': (r['rate'] as num).toDouble(),
    };
  }

  /// Sets service [id]'s own rate (a fraction), or back to the place rate (null).
  Future<void> setServiceRate(String id, String name, double? rate) async {
    if (rate == null) {
      await _db.from('commission_service_rates').delete().eq('service_id', id);
    } else {
      await _db
          .from('commission_service_rates')
          .upsert({'service_id': id, 'service_name': name, 'rate': rate, 'active': true}, onConflict: 'service_id');
    }
  }

  Future<List<FareTariff>> fareCards() async {
    final rows = await _db.from('fare_tariffs').select().eq('active', true).order('level', ascending: true);
    return [for (final r in rows) FareTariff.fromRow(r)];
  }

  Future<C2cService> service() async {
    final rows = await _db
        .from('settings_entries')
        .select('id, category, values')
        .inFilter('category', ['vehicle-services', 'service-settings'])
        .order('position', ascending: true);
    Map<String, dynamic> values(Map r) => Map<String, dynamic>.from((r['values'] as Map?) ?? const {});
    final mine = rows
        .where((r) => r['category'] == 'vehicle-services' && '${values(r)['name'] ?? ''}'.trim() == c2cServiceName)
        .firstOrNull;
    if (mine == null) return (id: null, types: const <String>{}, rates: null, active: false);
    final v = values(mine);
    final typeNames = {
      for (final t in v['serviceTypes'] is List ? v['serviceTypes'] as List : const []) '$t'.trim().toLowerCase(),
    };
    final status = '${v['status'] ?? true}'.toLowerCase();
    return (
      id: '${mine['id']}',
      types: {
        for (final r in rows)
          if (r['category'] == 'service-settings' && typeNames.contains('${values(r)['name'] ?? ''}'.trim().toLowerCase()))
            '${r['id']}',
      },
      rates: ServiceRates.fromValues(v),
      active: !const {'false', '0', 'off', 'inactive'}.contains(status),
    );
  }
}

final cityToCityRepositoryProvider = Provider((ref) => CityToCityRepository(ref.watch(supabaseProvider)));

final c2cSettingsProvider = FutureProvider.autoDispose<C2cSettings>((ref) {
  ref.watchLive('city_to_city_settings');
  return ref.watch(cityToCityRepositoryProvider).settings();
});

final c2cRulesProvider = FutureProvider.autoDispose<List<C2cRule>>((ref) {
  ref.watchLive('c2c_route_rules');
  return ref.watch(cityToCityRepositoryProvider).rules();
});

final c2cCountryPermitsProvider = FutureProvider.autoDispose<List<C2cCountryPermit>>((ref) {
  ref.watchLive('c2c_country_permits');
  return ref.watch(cityToCityRepositoryProvider).countryPermits();
});

final c2cPermitTypesProvider = FutureProvider.autoDispose<List<C2cPermitType>>((ref) async {
  try {
    return await ref.watch(cityToCityRepositoryProvider).permitTypes();
  } catch (_) {
    return const [];
  }
});

final commissionServiceRatesProvider = FutureProvider.autoDispose<Map<String, double>>((ref) {
  ref.watchLive('commission_service_rates');
  return ref.watch(cityToCityRepositoryProvider).serviceRates();
});

/// The fare cards and the City to City service, for the rules page's example.
final c2cFareContextProvider =
    FutureProvider.autoDispose<({List<FareTariff> cards, C2cService service})>((ref) async {
  ref.watchLive('fare_tariffs');
  ref.watchLive('settings_entries');
  final repo = ref.watch(cityToCityRepositoryProvider);
  try {
    return (cards: await repo.fareCards(), service: await repo.service());
  } catch (_) {
    return (cards: const <FareTariff>[], service: (id: null, types: const <String>{}, rates: null, active: false));
  }
});
