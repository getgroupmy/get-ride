// The Media Gallery's uploads (`media_assets`, files in the public `media`
// bucket; migration 0273): read by every app to show an icon or picture a
// setting points at (`media:<id>`), written by admins with edit rights on
// Display Settings.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/background_removal.dart' show ProcessedMedia;
import '../core/media_assets.dart';
import '../core/media_usage.dart' show MediaUsageInput;
import '../providers.dart';
import 'live_tables.dart';

class MediaRepository {
  MediaRepository(this._db);
  final SupabaseClient _db;

  /// Every upload, newest first.
  Future<List<MediaAsset>> list() async {
    final rows = await _db.from(mediaAssetsTable).select().order('created_at', ascending: false);
    return [for (final r in rows) ?MediaAsset.fromRow(Map<String, dynamic>.from(r))];
  }

  /// The public address of a file in the bucket.
  String publicUrl(String path) => _db.storage.from(mediaBucket).getPublicUrl(path);

  /// Uploads [light] (and a logo's [dark]) and records them as a new upload
  /// called [name]. Files already sent are taken back when the record is
  /// refused.
  Future<MediaAsset> save({
    required MediaKind kind,
    required String name,
    ProcessedMedia? light,
    ProcessedMedia? dark,
    bool tint = false,
  }) async {
    final main = light ?? dark;
    if (main == null) throw ArgumentError('Nothing to upload');
    final id = const Uuid().v4();
    final bucket = _db.storage.from(mediaBucket);
    final sent = <String>[];
    Future<String> put(ProcessedMedia f, {bool isDark = false}) async {
      final path = mediaPath(kind, id, f.mime, dark: isDark);
      await bucket.uploadBinary(path, f.bytes, fileOptions: FileOptions(contentType: f.mime, upsert: false));
      sent.add(path);
      return path;
    }

    try {
      final path = light == null ? null : await put(light);
      final darkPath = dark == null ? null : await put(dark, isDark: true);
      final asset = MediaAsset(
        id: id,
        kind: kind,
        name: name.trim(),
        path: path,
        darkPath: darkPath,
        mime: main.mime,
        width: main.width,
        height: main.height,
        bytes: main.bytes.length,
        tint: kind == MediaKind.icon && tint,
      );
      final row = await _db.from(mediaAssetsTable).insert(asset.toRow()).select().single();
      return MediaAsset.fromRow(row) ?? asset;
    } catch (_) {
      if (sent.isNotEmpty) {
        try {
          await bucket.remove(sent);
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Deletes [asset]: the server refuses while a setting still points at it
  /// (media_asset_delete), then its files go.
  Future<void> delete(MediaAsset asset) async {
    await _db.rpc('media_asset_delete', params: {'p_id': asset.id});
    final files = [?asset.path, ?asset.darkPath];
    if (files.isEmpty) return;
    try {
      await _db.storage.from(mediaBucket).remove(files);
    } catch (_) {
      // The record is gone; a file left behind is unreachable from the app.
    }
  }

  /// Everything the usage index reads (core/media_usage.dart).
  Future<MediaUsageInput> usageInput(List<MediaAsset> assets) async {
    final results = await Future.wait<Object?>([
      _db.from('admin_display_settings').select('settings').eq('id', 'global').maybeSingle(),
      _db
          .from('settings_entries')
          .select('id, category, values')
          .order('category', ascending: true)
          .order('position', ascending: true),
      _db.from('app_settings').select('key, value').order('key', ascending: true),
      _db.from('app_branding').select().eq('id', 'global').maybeSingle(),
    ]);
    Map<String, dynamic> map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    List<Map<String, dynamic>> rows(Object? v) => [if (v is List) for (final r in v) map(r)];
    return MediaUsageInput(
      display: map(map(results[0])['settings']),
      entries: rows(results[1]),
      appSettings: rows(results[2]),
      branding: map(results[3]),
      assets: assets,
    );
  }
}

final mediaRepositoryProvider = Provider((ref) => MediaRepository(ref.watch(supabaseProvider)));

/// Every upload, live (a new or deleted one shows on every open app).
final mediaAssetsProvider = FutureProvider<List<MediaAsset>>((ref) {
  ref.watchLive(mediaAssetsTable);
  return ref.watch(mediaRepositoryProvider).list();
});
