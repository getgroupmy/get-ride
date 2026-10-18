import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/screens/meterapp/site_logic.dart' show brandingRowId, brandingTable;
import '../core/app_branding.dart';
import '../core/backend_network.dart';
import 'geo_service.dart' show adminStartCenter;
import 'realtime_backup.dart';

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
      if (b.splashImageUrl != null && f != null && await f.exists()) bytes = await f.readAsBytes();
      return CachedBranding(b, bytes);
    } catch (_) {
      return null;
    }
  }

  /// Only the cached Backend network settings (no image read), for the
  /// background push handler; null when none is cached.
  static Future<BackendNetwork?> loadNetwork() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return null;
      return BackendNetwork.fromJson((jsonDecode(raw) as Map)['network']);
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
        if (url == null) {
          if (await f.exists()) await f.delete();
        } else if (!sameImage || !await f.exists()) {
          final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
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

/// What the branding sets outside the widget tree: where maps open.
void applyBrandingGlobals(AppBranding? b) {
  final lat = b?.startLat, lng = b?.startLng;
  adminStartCenter = lat == null || lng == null ? null : LatLng(lat, lng);
}

/// One read shared by everyone who asks at about the same time: a caller
/// joins a read already under way, and (unless it asks for a [fresh] one)
/// takes a result younger than [maxAge]. A failed read is not kept.
class SharedRead<T> {
  SharedRead(this.maxAge, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Duration maxAge;
  final DateTime Function() _now;
  Future<T>? _inFlight;
  T? _last;
  DateTime? _at;

  Future<T> get(Future<T> Function() fetch, {bool fresh = false}) {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final at = _at;
    if (!fresh && at != null && _now().difference(at) < maxAge) return Future.value(_last as T);
    final read = Future.sync(fetch).then((v) {
      _last = v;
      _at = _now();
      return v;
    }).whenComplete(() => _inFlight = null);
    _inFlight = read;
    return read;
  }
}

final _brandingReads = SharedRead<Map<String, dynamic>?>(const Duration(minutes: 1));

/// The `app_branding` row, read once for everyone asking at launch (the
/// branding sync and the install page both want it). [fresh] skips a recent
/// result but still joins a read under way.
Future<Map<String, dynamic>?> readBrandingRow(SupabaseClient db, {bool fresh = false}) =>
    _brandingReads.get(() => db.from(brandingTable).select().eq('id', brandingRowId).maybeSingle(), fresh: fresh);

/// Keeps the cache in step with the `app_branding` row: once at launch, then
/// live while the app runs (and again on coming back to the foreground, in
/// case the socket dropped meanwhile), so an admin's change shows at once.
class BrandingSync {
  BrandingSync(this._db);
  final SupabaseClient _db;
  RealtimeChannel? _channel;
  RealtimeBackup? _backup;

  /// This launch's branding once fetched, for a splash still on screen.
  final latest = ValueNotifier<AppBranding?>(null);

  Future<void> _apply(AppBranding b) async {
    applyBrandingGlobals(b);
    latest.value = b;
    await BrandingCache.save(b);
  }

  /// Reads the row again.
  Future<void> resync() async {
    try {
      final row = await readBrandingRow(_db, fresh: true);
      await _apply(AppBranding.fromRow(row));
    } catch (_) {}
  }

  Future<void> start() async {
    await resync();
    _backup = RealtimeBackup(resync, every: const Duration(minutes: 1));
    try {
      _channel = _db
          .channel('app_branding_changes')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: brandingTable,
            callback: (p) {
              if (p.newRecord['id'] == brandingRowId) unawaited(_apply(AppBranding.fromRow(p.newRecord)));
            },
          )
          .subscribe(_backup!.onStatus);
    } catch (_) {}
  }

  void stop() {
    _backup?.dispose();
    _backup = null;
    final c = _channel;
    if (c != null) unawaited(_db.removeChannel(c));
    _channel = null;
    latest.dispose();
  }
}
