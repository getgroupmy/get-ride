import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/live_tables.dart';

void main() {
  test('the settings blob is read off the row, or the defaults without one', () {
    expect(
      displaySettingsFromRow({
        'settings': {'showSearchBar': false},
      }),
      {'showSearchBar': false},
    );
    expect(displaySettingsFromRow({'settings': null}), isEmpty);
    expect(displaySettingsFromRow(null), isEmpty);
  });

  test('a change moves only its own tables', () {
    final r = bumpRevisions({'a': 2}, ['a', 'b']);
    expect(r, {'a': 3, 'b': 1});
    expect(bumpRevisions(r, ['b']), {'a': 3, 'b': 2});
  });

  test('every settings table the app reads is watched', () {
    for (final t in ['admin_display_settings', 'settings_entries', 'get_coin_settings', 'meter_digital_settings']) {
      expect(liveSettingTables, contains(t));
    }
  });

  test('a provider watching a table re-reads it on a change to that table only', () async {
    var reads = 0;
    final watcher = FutureProvider<int>((ref) async {
      ref.watchLive('settings_entries');
      return ++reads;
    });
    // No Supabase client in tests: the channel fails quietly and changes are fed by hand.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sub = container.listen(watcher, (_, _) {});
    addTearDown(sub.close);
    expect(await container.read(watcher.future), 1);

    container.read(liveTablesProvider.notifier).changed(['app_branding']);
    await Future<void>.delayed(liveDebounce * 2);
    expect(await container.read(watcher.future), 1, reason: 'another table');

    // A burst of changes is one re-read.
    final live = container.read(liveTablesProvider.notifier)
      ..changed(['settings_entries'])
      ..changed(['settings_entries']);
    expect(live, isNotNull);
    await Future<void>.delayed(liveDebounce * 2);
    expect(await container.read(watcher.future), 2);
  });

  test('unreachable, the display settings fall back to the defaults', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(displaySettingsBlobProvider.future), isEmpty);
  });
}
