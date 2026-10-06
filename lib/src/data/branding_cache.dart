import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/screens/meterapp/site_logic.dart' show brandingRowId, brandingTable;
import '../core/app_branding.dart';

/// What the splash shows on this launch: the branding cached by the previous
/// one, with the image's bytes on disk so it paints on the first frame
/// without waiting on the network. On web the browser cache does that job,
/// so only the URL is kept.
class CachedBranding {
  const CachedBranding(this.branding, [this.imageBytes]);
  final AppBranding branding;
  final Uint8List? imageBytes;
}

class BrandingCache {
  static const _key = 'app_branding_v1';
  static const _file = 'splash_image';

  static Future<File?> _imageFile() async {
    if (kIsWeb) return null;
    try {
      return File('${(await getApplicationSupportDirectory()).path}/$_file');
    } catch (_) {
      return null;
    }
  }

  /// The cached branding, or null on a first launch. Never throws: a launch
  /// is never held up by a broken cache.
  static Future<CachedBranding?> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return null;
      final b = AppBranding.fromRow((jsonDecode(raw) as Map).cast<String, dynamic>());
      Uint8List? bytes;
      final f = await _imageFile();
      if (b.showsSplash && f != null && await f.exists()) bytes = await f.readAsBytes();
      return CachedBranding(b, bytes);
    } catch (_) {
      return null;
    }
  }

  /// Stores [b] for the next launch, downloading its image when it changed.
  static Future<void> save(AppBranding b) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getString(_key);
      final f = await _imageFile();
      if (f != null) {
        final url = b.splashImageUrl;
        final sameImage =
            previous != null &&
            AppBranding.fromRow((jsonDecode(previous) as Map).cast<String, dynamic>()).splashImageUrl == url;
        if (!b.showsSplash) {
          if (await f.exists()) await f.delete();
        } else if (!sameImage || !await f.exists()) {
          final res = await http.get(Uri.parse(url!)).timeout(const Duration(seconds: 20));
          // Without the image on disk, the next launch falls back to the network.
          if (res.statusCode == 200) {
            await f.writeAsBytes(res.bodyBytes, flush: true);
          } else if (await f.exists()) {
            await f.delete();
          }
        }
      }
      await prefs.setString(_key, jsonEncode(b.toJson()));
    } catch (_) {}
  }
}

/// Keeps the cache in step with the `app_branding` row: once at launch, then
/// live while the app runs, so an admin's change shows on the next launch.
class BrandingSync {
  BrandingSync(this._db);
  final SupabaseClient _db;
  RealtimeChannel? _channel;

  Future<void> start() async {
    try {
      final row = await _db
          .from(brandingTable)
          .select('splash_image_url, splash_bg_color')
          .eq('id', brandingRowId)
          .maybeSingle();
      await BrandingCache.save(AppBranding.fromRow(row));
    } catch (_) {}
    try {
      _channel = _db
          .channel('app_branding_changes')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: brandingTable,
            callback: (p) {
              if (p.newRecord['id'] == brandingRowId) unawaited(BrandingCache.save(AppBranding.fromRow(p.newRecord)));
            },
          )
          .subscribe();
    } catch (_) {}
  }

  void stop() {
    final c = _channel;
    if (c != null) unawaited(_db.removeChannel(c));
    _channel = null;
  }
}
