// Every booking module works with Family (CLAUDE.md; migration 0317): the
// owner's rule that Family works with every module, today's and any added
// later. Like test/page_styles_test.dart, this reads the source and fails
// when a module could forget Family.
//
// How a booking module is found, kept simple on purpose:
//   * On the server, a booking table is a table a migration creates with a
//     `rider_id`, a `status` and a `fare`, `price` or `agreed_fare` column
//     (ride_requests, scheduled_rides, c2c_bookings today). Each must belong
//     to a module in lib/src/core/booking_modules.dart and have a trigger
//     that runs a family function (registering the trip, the child's code,
//     women drivers, the host told), unless it is on [notBookingTables] with
//     the reason.
//   * In the app, a file in lib/src/data that inserts into a booking table
//     (or calls schedule_ride) must be one of a module's repositories, unless
//     it is on [notBookingFiles] with the reason.
//   * Every module key in booking_modules.dart is registered in a migration
//     (family_register_module, which Admin › People › Family's matrix lists,
//     switched off until the admin turns it on), and every registered key is
//     in booking_modules.dart.
//   * A module that is built shows the Family payment row on its booking
//     screens (familyPayOptionProvider).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/booking_modules.dart';

/// Tables that look like bookings but are not, and why.
const notBookingTables = {
  'rides': 'the Expo app\'s old table; nothing books into it (ride_requests replaced it)',
};

/// App files that write a booking table without booking for a rider, and why.
const notBookingFiles = {
  'lib/src/data/dispatch_repository.dart':
      'a taxi stand\'s counter books for walk-in customers; Family is for riders\' own accounts',
};

String _migrations() {
  final files = Directory('supabase/migrations').listSync().whereType<File>().where((f) => f.path.endsWith('.sql')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final f in files) f.readAsStringSync()].join('\n');
}

/// The booking tables the migrations create.
Set<String> bookingTables(String sql) {
  final out = <String>{};
  final create = RegExp(r'create table (?:if not exists )?public\.(\w+)\s*\((.*?)\n\);', caseSensitive: false, dotAll: true);
  for (final m in create.allMatches(sql)) {
    final cols = {for (final c in RegExp(r'^\s*([a-z_0-9]+)\s', multiLine: true).allMatches(m.group(2)!)) c.group(1)!};
    if (cols.contains('rider_id') && cols.contains('status') && cols.intersection({'fare', 'price', 'agreed_fare'}).isNotEmpty) {
      out.add(m.group(1)!);
    }
  }
  return out;
}

/// The module keys the migrations register.
Set<String> registeredKeys(String sql) => {
  for (final m in RegExp(r"family_register_module\('([a-z0-9_]+)'").allMatches(sql)) m.group(1)!,
};

/// Whether a migration has a trigger on [table] that runs a family function.
bool hasFamilyTrigger(String sql, String table) => RegExp(
  r'create trigger \w+\s+(?:before|after)[^;]*?\s+on public\.' + table + r'\s+for each row\s+execute function public\.\w*family\w*\(',
  caseSensitive: false,
).hasMatch(sql);

void main() {
  final sql = _migrations();
  final dart = {for (final m in bookingModules) m.key: m};

  test('the detection finds today\'s booking tables', () {
    expect(bookingTables(sql), containsAll(['ride_requests', 'scheduled_rides', 'c2c_bookings']));
    expect(registeredKeys(sql), containsAll(['ride', 'scheduled_ride', 'city_to_city', 'freight', 'courier', 'tips']));
    expect(hasFamilyTrigger(sql, 'ride_requests'), isTrue);
    expect(hasFamilyTrigger(sql, 'wallets'), isFalse);
  });

  test('module keys are unique', () {
    expect(dart.length, bookingModules.length);
  });

  test('every module key is registered with Family on the server, and every registered key is listed here', () {
    final reg = registeredKeys(sql);
    for (final m in bookingModules) {
      expect(reg, contains(m.key),
          reason: '${m.key}: register it in its migration with family_register_module(\'${m.key}\', \'${m.name}\')');
    }
    for (final k in reg) {
      expect(dart.keys, contains(k), reason: '$k is registered on the server: add it to bookingModules');
    }
  });

  test('every booking table belongs to a module and runs Family', () {
    final claimed = {for (final m in bookingModules) ...m.tables};
    for (final t in bookingTables(sql)) {
      if (notBookingTables.containsKey(t)) continue;
      expect(claimed, contains(t),
          reason: '$t looks like a booking table (rider_id, status, fare): add its module to bookingModules '
              '(lib/src/core/booking_modules.dart) or explain it in notBookingTables');
      expect(hasFamilyTrigger(sql, t), isTrue,
          reason: '$t has no Family trigger: call family_attach_trip from a trigger (as ride_requests_family, 0317)');
    }
    for (final t in claimed) {
      expect(bookingTables(sql), contains(t), reason: 'bookingModules names $t, which no migration creates as a booking');
    }
  });

  test('every app file that books is a module\'s repository', () {
    final tables = bookingTables(sql).difference(notBookingTables.keys.toSet());
    final repos = {for (final m in bookingModules) ...m.repositories};
    for (final f in Directory('lib/src/data').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final path = f.path.replaceAll('\\', '/');
      final src = f.readAsStringSync();
      final writes = (src.contains('.insert(') || src.contains('.upsert(')) &&
              tables.any((t) => src.contains("'$t'")) ||
          src.contains("'schedule_ride'");
      if (!writes || notBookingFiles.containsKey(path)) continue;
      expect(repos, contains(path),
          reason: '$path books a ride or a trip: list it in its module\'s repositories and pass Family '
              '(payment Family, the family passenger)');
    }
  });

  test('a built module\'s repositories exist and its booking screens show the Family row', () {
    for (final m in bookingModules.where((m) => m.built)) {
      expect(m.screens, isNotEmpty, reason: '${m.key}: name its booking screens');
      for (final r in m.repositories) {
        expect(File(r).existsSync(), isTrue, reason: '${m.key}: $r is gone');
      }
      for (final s in m.screens) {
        expect(File(s).readAsStringSync(), contains('familyPayOptionProvider'),
            reason: '${m.key}: $s has no "Family · <host>\'s GET.wallet" row');
      }
    }
  });

  test('the ride request module is read as the server reads it', () {
    expect(rideBookingModule(), 'ride');
    expect(rideBookingModule(scheduled: true), 'scheduled_ride');
    expect(rideBookingModule(scheduled: true, freight: true), 'freight');
    expect(rideBookingModule(courier: true, freight: true), 'courier');
    expect(bookingModule('city_to_city')?.name, 'City to City');
    expect(bookingModule('nope'), isNull);
  });
}
