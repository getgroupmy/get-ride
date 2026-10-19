// IO for Meter Digital rate cards (`meter_digital_settings`), mirroring the
// Expo `utils/meterSettingsStore.ts`: a read or write that trips on a column
// a later migration added (0084/0085/0086) is retried without that group, and
// the screen is told which groups are missing so it can say so.
//
// Unlike Expo there is no device-local fallback: an admin edit that cannot
// reach the shared table is reported as an error instead of being kept on
// this device only.
import 'package:supabase_flutter/supabase_flutter.dart';

import 'meter_logic.dart';

const meterSettingsTable = 'meter_digital_settings';

/// An update the database accepted but that changed no row: the card is
/// gone, or this account may not change it.
class MeterNotSavedException implements Exception {
  const MeterNotSavedException();

  @override
  String toString() => 'Not saved: no rate card was changed. It may have been deleted, or this account '
      'cannot edit rate cards. Reload the page and try again.';
}

class MeterSettingsStore {
  MeterSettingsStore(this._db);
  final SupabaseClient _db;

  /// Optional column groups this database has refused (kept for the session).
  static final List<String> _missing = [];

  List<String> get missingGroups => List.unmodifiable(_missing);

  static String _errorText(Object e) => e is PostgrestException ? '${e.message} ${e.code ?? ''}' : '$e';

  static bool _isMissingSchema(Object e) {
    final msg = _errorText(e);
    final lower = msg.toLowerCase();
    return msg.contains('42P01') ||
        msg.contains('42703') ||
        msg.contains('PGRST204') ||
        msg.contains('PGRST205') ||
        msg.contains('PGRST202') ||
        lower.contains('could not find') ||
        lower.contains('does not exist') ||
        lower.contains('schema cache');
  }

  static bool _isPermissionDenied(Object e) {
    final msg = _errorText(e);
    return msg.contains('42501') || msg.toLowerCase().contains('row-level security');
  }

  Future<T> _dropping<T>(Future<T> Function() run) async {
    for (;;) {
      try {
        return await run();
      } catch (e) {
        if (!_isMissingSchema(e)) rethrow;
        final group = meterOptionalGroupNamed(_errorText(e));
        if (group == null || _missing.contains(group.id)) rethrow;
        _missing.add(group.id);
      }
    }
  }

  /// An update by id that may match nothing: PostgREST answers 204 either
  /// way, so the changed row is asked back, and none is an error rather than
  /// a "saved" that saved nothing.
  Future<void> _updateOne(Map<String, dynamic> payload, String id) async {
    final rows = await _db.from(meterSettingsTable).update(payload).eq('id', id).select('id');
    if (rows.isEmpty) throw const MeterNotSavedException();
  }

  Exception _friendly(Object e, String what) {
    if (e is MeterNotSavedException) return e;
    if (_isPermissionDenied(e)) {
      return Exception('The database refused the $what. Rate cards are admin-only — sign in with an admin '
          'account and try again.');
    }
    if (e is PostgrestException && e.code == '23505') {
      return Exception('A rate card for this exact scope already exists.');
    }
    return e is Exception ? e : Exception('$e');
  }

  Future<List<MeterProfile>> fetch() async {
    final rows = await _dropping(() async => List<Map<String, dynamic>>.from(await _db
        .from(meterSettingsTable)
        .select(meterSettingsColumns(_missing))
        .order('updated_at', ascending: false)));
    return rows.map(normalizeMeterProfile).whereType<MeterProfile>().toList();
  }

  Future<String?> _masterId() async {
    final rows = await _db.from(meterSettingsTable).select('id').eq('level', 'master').limit(1);
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  /// Creates or updates a card. The master card is always the single global
  /// row, updated in place when it already exists.
  Future<void> save(MeterProfile profile) async {
    final row = meterProfileToRow(profile);
    final id = profile.id.trim();
    try {
      await _dropping(() async {
        final payload = meterRowWithoutGroups(row, _missing);
        if (id.isNotEmpty) {
          await _updateOne(payload, id);
        } else if (profile.level == 'master') {
          final existing = await _masterId();
          if (existing != null) {
            await _updateOne(payload, existing);
          } else {
            await _db.from(meterSettingsTable).insert(payload);
          }
        } else {
          await _db.from(meterSettingsTable).insert(payload);
        }
      });
    } catch (e) {
      throw _friendly(e, 'write');
    }
  }

  /// Writes only the ten panel columns (the live Show/Tap toggle), so a rate
  /// half-typed in the editor is never committed with it. Returns the id of
  /// the row written, which may be a master row this call just created.
  Future<String?> savePanels(MeterProfile profile, MeterPanels panels) async {
    final id = profile.id.trim();
    final panelRow = meterPanelsToRow(panels);
    try {
      if (id.isNotEmpty) {
        await _updateOne(panelRow, id);
        return id;
      }
      if (profile.level != 'master') {
        throw Exception('Create this rate card first — panel changes apply live once it exists.');
      }
      final existing = await _masterId();
      if (existing != null) {
        await _updateOne(panelRow, existing);
        return existing;
      }
      // No global row yet: the toggle creates it from the card on screen.
      final full = meterProfileToRow(profile.copyWith(panels: panels));
      return await _dropping(() async {
        final inserted = await _db
            .from(meterSettingsTable)
            .insert(meterRowWithoutGroups(full, _missing))
            .select('id')
            .limit(1);
        return inserted.isEmpty ? null : inserted.first['id'] as String?;
      });
    } catch (e) {
      throw _friendly(e, 'write');
    }
  }

  Future<void> delete(String id) async {
    try {
      await _db.from(meterSettingsTable).delete().eq('id', id);
    } catch (e) {
      throw _friendly(e, 'delete');
    }
  }
}
