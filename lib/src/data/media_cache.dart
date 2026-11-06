// A durable, version-gated cache of the uploaded Media Gallery files on this
// device (migration 0354). The app already loads the whole media_assets set
// live; this keeps the files themselves on disk so an icon or picture paints
// from local storage (fast, and offline) instead of the network.
//
// How it stays current without re-downloading every launch: media_version()
// is a cheap server hash of the whole uploaded set. The cache keeps the last
// hash; when it is unchanged nothing is fetched, and when it changes only the
// added / re-uploaded files are downloaded and the removed ones deleted — so
// adds appear, removals disappear, and a re-upload refreshes. The planning is
// pure (mediaCachePlan) and tested; the IO mirrors BrandingCache. On web the
// browser cache does this job, so the cache is a no-op there.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../core/backend_route.dart';
import '../core/media_assets.dart';
import '../providers.dart';
import 'media_repository.dart' show mediaAssetsProvider;

/// How a file is fetched; overridable in tests.
typedef MediaFetch = Future<({int status, Uint8List bytes})> Function(String url);

/// The public address of [path] on the active backend — the same URL
/// media_image.dart's `mediaUrlOf` builds (kept here so the data layer does
/// not import the widget layer).
String mediaCacheUrlOf(String path) => onActiveBackend(
      mediaPublicUrl(AppConfig.supabaseUrl, path),
      AppConfig.supabaseUrl,
      activeBackendUrl(AppConfig.supabaseUrl),
    );

/// What a sync must do: download the files whose fingerprint is new or
/// changed, and remove the ones no longer wanted. Pure.
({Set<String> download, Set<String> remove}) mediaCachePlan(
  Map<String, String> wanted,
  Map<String, String> have,
) {
  final download = <String>{
    for (final e in wanted.entries)
      if (have[e.key] != e.value) e.key,
  };
  final remove = <String>{
    for (final k in have.keys)
      if (!wanted.containsKey(k)) k,
  };
  return (download: download, remove: remove);
}

/// The files the current [assets] want cached, each mapped to a fingerprint
/// that changes when the file's bytes do (so a re-upload re-downloads). All of
/// an asset's files (light, dark, every map-icon frame) share its fingerprint.
Map<String, String> mediaCacheWanted(List<MediaAsset> assets) {
  final wanted = <String, String>{};
  for (final a in assets) {
    final fp = '${a.mime}|${a.bytes ?? 0}|${a.angles.length}';
    for (final path in a.files) {
      wanted[path] = fp;
    }
  }
  return wanted;
}

/// The on-device media cache. [onChanged] fires after a file is downloaded or
/// removed, so the UI can rebuild and pick it up.
class MediaCache {
  MediaCache({MediaFetch? fetch, this.onChanged}) : _fetch = fetch ?? _defaultFetch;

  static const _indexKey = 'media_cache_index_v1';
  static const _versionKey = 'media_cache_version_v1';
  static const _dirName = 'media_cache';

  final MediaFetch _fetch;
  final void Function()? onChanged;

  static Future<({int status, Uint8List bytes})> _defaultFetch(String url) async {
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    return (status: res.statusCode, bytes: res.bodyBytes);
  }

  Directory? _dir;
  String? _version;
  bool _ready = false;
  bool _syncing = false;

  /// path → its fingerprint (what is cached and at which version of the file).
  final Map<String, String> _index = {};

  /// path → the local file, for a synchronous lookup during build.
  final Map<String, File> _files = {};

  /// Load the stored index so the first paint can use what the last run kept.
  Future<void> init() async {
    if (kIsWeb || _ready) {
      _ready = true;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _version = prefs.getString(_versionKey);
      _dir = Directory('${(await getApplicationSupportDirectory()).path}/$_dirName');
      final raw = prefs.getString(_indexKey);
      if (raw != null) {
        final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
        for (final e in map.entries) {
          final v = (e.value as Map).cast<String, dynamic>();
          final file = v['f'] as String?;
          final fp = v['v'] as String?;
          if (file == null || fp == null) continue;
          _index[e.key] = fp;
          _files[e.key] = File('${_dir!.path}/$file');
        }
      }
    } catch (_) {
      // A broken cache is simply an empty one; rendering falls back to network.
    }
    _ready = true;
  }

  /// The local file for a bucket [path], or null when it is not cached.
  File? fileForPath(String? path) => path == null ? null : _files[path];

  String _fileNameFor(String path) => '${md5.convert(utf8.encode(path))}${_ext(path)}';

  String _ext(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    return dot > slash ? path.substring(dot) : '';
  }

  /// Bring the cache to [assets] when [serverVersion] differs from the stored
  /// one (or something wanted is missing). Never throws.
  Future<void> maybeSync(String? serverVersion, List<MediaAsset> assets) async {
    if (kIsWeb || _syncing) return;
    if (!_ready) await init();
    final wanted = mediaCacheWanted(assets);
    final covered = wanted.keys.every((p) => _index[p] == wanted[p] && _files[p] != null);
    // Nothing changed and everything wanted is already cached → no work.
    if (serverVersion != null && serverVersion == _version && covered) return;

    _syncing = true;
    try {
      final dir = _dir ??= Directory('${(await getApplicationSupportDirectory()).path}/$_dirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      final plan = mediaCachePlan(wanted, _index);
      var changed = false;

      for (final path in plan.download) {
        try {
          final res = await _fetch(mediaCacheUrlOf(path));
          if (res.status != 200 || res.bytes.isEmpty) continue;
          final file = File('${dir.path}/${_fileNameFor(path)}');
          await file.writeAsBytes(res.bytes, flush: true);
          _index[path] = wanted[path]!;
          _files[path] = file;
          changed = true;
        } catch (_) {
          // Leave it uncached; the widget falls back to the network URL.
        }
      }
      for (final path in plan.remove) {
        final f = _files.remove(path);
        _index.remove(path);
        changed = true;
        try {
          if (f != null && await f.exists()) await f.delete();
        } catch (_) {}
      }

      _version = serverVersion;
      await _persist();
      if (changed) onChanged?.call();
    } catch (_) {
      // A failed sync keeps whatever was already cached.
    } finally {
      _syncing = false;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = {
        for (final e in _index.entries)
          e.key: {'v': e.value, 'f': _files[e.key]!.uri.pathSegments.last},
      };
      await prefs.setString(_indexKey, jsonEncode(map));
      if (_version != null) {
        await prefs.setString(_versionKey, _version!);
      } else {
        await prefs.remove(_versionKey);
      }
    } catch (_) {}
  }
}

/// Holds the [MediaCache] and bumps an int generation whenever its files
/// change, so widgets that watch the provider rebuild and pick up a cached
/// file. Widgets read the file via [fileForPath] on the notifier.
class MediaCacheController extends Notifier<int> {
  late final MediaCache cache;

  @override
  int build() {
    cache = MediaCache(onChanged: () => state = state + 1);
    unawaited(cache.init());
    return 0;
  }

  /// The cached file for a bucket [path], or null.
  File? fileForPath(String? path) => cache.fileForPath(path);

  Future<void> maybeSync(String? serverVersion, List<MediaAsset> assets) => cache.maybeSync(serverVersion, assets);
}

final mediaCacheProvider = NotifierProvider<MediaCacheController, int>(MediaCacheController.new);

/// Fetches the server fingerprint and syncs the cache to the current media
/// set. Called at launch and on returning to the foreground.
Future<void> syncMediaCache(WidgetRef ref) async {
  if (kIsWeb) return;
  try {
    final db = ref.read(supabaseProvider);
    final version = await db.rpc('media_version') as String?;
    final assets = await ref.read(mediaAssetsProvider.future);
    await ref.read(mediaCacheProvider.notifier).maybeSync(version, assets);
  } catch (_) {
    // Offline or the RPC isn't deployed yet: keep whatever is cached.
  }
}
