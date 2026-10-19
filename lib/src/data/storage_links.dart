// Turns a stored document link into one that opens once its bucket is
// private: a signed link, made on demand and kept until shortly before it
// runs out. Screens showing the same file at once share one signing call.
//
// PERF-75: links asked for within one frame are signed together, one
// createSignedUrls call per bucket (a page of 25 thumbnails was 25 calls of
// ~250 ms each), and kept on the device until they expire, so a restart
// shows the same URL and the browser's image cache still answers.
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/doc_photo.dart' show docThumbUrl;
import '../core/storage_links.dart';

/// How long before a signed link runs out it stops being handed out.
const signedLinkRenewBefore = Duration(minutes: 10);

/// How long signing waits to gather the links asked for in one frame.
const signedLinkBatchWindow = Duration(milliseconds: 16);

/// The device store of signed document links (SharedPreferences).
const signedLinksPrefsKey = 'signed_links_v1';

/// The most links kept on the device; the oldest go first.
const signedLinksKeepMax = 500;

typedef SignedLink = ({String url, DateTime until});

final _cache = <String, SignedLink>{};
final _inFlight = <String, Future<SignedLink?>>{};

/// [make]'s link for [key], handed out again until its `until`; callers
/// asking while one is being made share that call. A failed or empty
/// answer is not kept.
Future<SignedLink?> _cachedLink(String key, Future<SignedLink?> Function() make, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final hit = _cache[key];
  if (hit != null && hit.until.isAfter(at)) return Future.value(hit);
  final pending = _inFlight[key];
  if (pending != null) return pending;
  final made = Future.sync(make)
      .then((link) {
        if (link != null) _cache[key] = link;
        return link;
      })
      .whenComplete(() {
        _inFlight.remove(key);
      });
  _inFlight[key] = made;
  return made;
}

/// A signed link for [key], made by [sign] (valid for [ttl]) and handed out
/// again until ten minutes before it expires. Callers asking while one is
/// being made share that call. A failed [sign] is not kept.
Future<String> cachedSignedLink(
  String key, {
  required Duration ttl,
  required Future<String> Function() sign,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  return _cachedLink(
    key,
    () async => (url: await sign(), until: at.add(ttl - signedLinkRenewBefore)),
    now: at,
  ).then((link) => link!.url);
}

/// Signs [paths] of [bucket] in one call: path → signed link, or null for a
/// path storage would not sign (no such file, no right to it).
typedef SignBatch = Future<Map<String, String?>> Function(String bucket, List<String> paths);

/// Signs the document links of one client: those asked for within
/// [signedLinkBatchWindow] go out as one call per bucket, and the answers
/// are kept on the device (for the signed-in account only) until shortly
/// before they expire.
class StorageLinkBatcher {
  /// A batcher over [signBatch] for whoever [user] says is signed in.
  /// [prefs] opens the device store (null: nothing is kept); [clock] is for
  /// tests. [StorageLinkBatcher.of] for a client.
  StorageLinkBatcher(
    this._signBatch, {
    String? Function()? user,
    DateTime Function()? clock,
    Future<SharedPreferences?> Function()? prefs,
    this.ttl = documentLinkTtl,
  }) : _user = user ?? (() => null),
       _clock = clock ?? DateTime.now,
       _openPrefs = prefs ?? _defaultPrefs;

  static final _batchers = Expando<StorageLinkBatcher>();

  /// The batcher of [db]. Its device store is wiped when [db] signs out.
  static StorageLinkBatcher of(SupabaseClient db) {
    final known = _batchers[db];
    if (known != null) return known;
    final b = StorageLinkBatcher(
      (bucket, paths) async {
        final answers = await db.storage.from(bucket).createSignedUrlsResult(paths, documentLinkTtl.inSeconds);
        return signedUrlsByPath(paths, answers);
      },
      user: () => db.auth.currentUser?.id,
    );
    try {
      db.auth.onAuthStateChange.listen((s) {
        if (s.event == AuthChangeEvent.signedOut) unawaited(b.clear());
      }, onError: (Object _) {});
    } catch (_) {}
    return _batchers[db] = b;
  }

  static Future<SharedPreferences?> _defaultPrefs() async {
    try {
      return await SharedPreferences.getInstance().timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  final SignBatch _signBatch;
  final String? Function() _user;
  final DateTime Function() _clock;
  final Future<SharedPreferences?> Function() _openPrefs;

  /// How long a link is signed for.
  final Duration ttl;

  /// bucket → path → callers waiting for the next batch.
  final _queued = <String, Map<String, Completer<SignedLink?>>>{};
  Timer? _flush;

  /// The device store as loaded: `bucket/path` → link, oldest first, for
  /// [_keptUser].
  final _kept = <String, SignedLink>{};
  String? _keptUser;
  SharedPreferences? _prefs;
  Future<void>? _loading;

  /// A link to [path] in [bucket], or null when storage would not sign it.
  /// One kept on the device for this account is used while it is good;
  /// otherwise it joins the batch going out this frame. Throws when the
  /// batch fails as a whole.
  Future<SignedLink?> link(String bucket, String path) async {
    final user = _user();
    await _keptFor(user);
    final kept = _kept['$bucket/$path'];
    if (kept != null && kept.until.isAfter(_clock())) return kept;
    final waiting = _queued.putIfAbsent(bucket, () => {});
    final c = waiting[path] ??= Completer<SignedLink?>();
    _flush ??= Timer(signedLinkBatchWindow, _send);
    return c.future;
  }

  void _send() {
    _flush = null;
    final batches = Map.of(_queued);
    _queued.clear();
    for (final MapEntry(key: bucket, value: waiting) in batches.entries) {
      final user = _user();
      final at = _clock();
      final paths = waiting.keys.toList();
      Future.sync(() => _signBatch(bucket, paths)).then(
        (signed) {
          final until = at.add(ttl - signedLinkRenewBefore);
          var changed = false;
          for (final MapEntry(key: path, value: c) in waiting.entries) {
            final url = signed[path];
            final link = url == null ? null : (url: url, until: until);
            if (link != null && user != null && user == _keptUser) {
              _kept.remove('$bucket/$path');
              _kept['$bucket/$path'] = link;
              changed = true;
            }
            c.complete(link);
          }
          if (changed) unawaited(_save());
        },
        onError: (Object e, StackTrace st) {
          for (final c in waiting.values) {
            c.completeError(e, st);
          }
        },
      );
    }
  }

  /// Loads the device store once, and empties it when it belongs to an
  /// account other than [user] (or nobody is signed in).
  Future<void> _keptFor(String? user) async {
    await (_loading ??= _load());
    if (_keptUser == user) return;
    _kept.clear();
    _keptUser = user;
    await _save();
  }

  Future<void> _load() async {
    final p = _prefs = await _openPrefs();
    if (p == null) return;
    try {
      final raw = p.getString(signedLinksPrefsKey);
      if (raw == null) return;
      final body = jsonDecode(raw);
      if (body is! Map || body['user'] is! String || body['links'] is! Map) return;
      final now = _clock();
      for (final MapEntry(:key, :value) in (body['links'] as Map).entries) {
        if (key is! String || value is! List || value.length != 2) continue;
        final url = value[0], until = value[1];
        if (url is! String || until is! int) continue;
        final at = DateTime.fromMillisecondsSinceEpoch(until);
        if (at.isAfter(now)) _kept[key] = (url: url, until: at);
      }
      _keptUser = body['user'] as String;
    } catch (_) {
      _kept.clear();
      _keptUser = null;
    }
  }

  Future<void> _save() async {
    final p = _prefs;
    if (p == null) return;
    final now = _clock();
    _kept.removeWhere((_, l) => !l.until.isAfter(now));
    while (_kept.length > signedLinksKeepMax) {
      _kept.remove(_kept.keys.first);
    }
    try {
      final user = _keptUser;
      if (user == null || _kept.isEmpty) {
        await p.remove(signedLinksPrefsKey);
        return;
      }
      await p.setString(
        signedLinksPrefsKey,
        jsonEncode({
          'user': user,
          'links': {for (final MapEntry(:key, :value) in _kept.entries) key: [value.url, value.until.millisecondsSinceEpoch]},
        }),
      );
    } catch (_) {}
  }

  /// Forgets every kept link, on the device too (sign-out).
  Future<void> clear() async {
    await (_loading ??= _load());
    _kept.clear();
    _keptUser = null;
    await _save();
  }
}

/// [answers] (createSignedUrlsResult) by requested path; an answer naming
/// no requested path is matched by its place in the list. Pure.
Map<String, String?> signedUrlsByPath(List<String> paths, List<SignedUrlResult> answers) {
  final out = <String, String?>{};
  for (var i = 0; i < answers.length; i++) {
    final a = answers[i];
    final path = paths.contains(a.path) ? a.path : (i < paths.length ? paths[i] : null);
    if (path == null) continue;
    out[path] = switch (a) {
      SignedUrlSuccess(:final signedUrl) => signedUrl,
      SignedUrlFailure() => null,
    };
  }
  return out;
}

/// The in-memory key of [url] for whoever is signed in to [db], so another
/// account on the same device never gets this one's link.
String _memoryKey(SupabaseClient db, String url) => '${db.auth.currentUser?.id ?? ''}|$url';

/// A link to [url] that the signed-in caller can open: a fresh signed link
/// for a file in a private document bucket, [url] itself for anything else.
/// Falls back to [url] when no link can be made (no client, no session, no
/// right to the file), which still opens while the bucket is public.
Future<String> signedStorageUrl(String url, {SupabaseClient? client, DateTime? now}) async {
  final ref = privateStorageRef(url);
  if (ref == null) return url;
  try {
    final db = client ?? Supabase.instance.client;
    final b = StorageLinkBatcher.of(db);
    final link = await _cachedLink(_memoryKey(db, url), () => b.link(ref.bucket, ref.path), now: now);
    return link?.url ?? url;
  } catch (_) {
    return url;
  }
}

/// Thumbnails found missing this session (uploads from before they were
/// made), so a list asks for each only once.
final _missingThumbs = <String>{};

/// Notes that the thumbnail at [thumbUrl] could not be shown, so the full
/// file is used from now on.
void markThumbMissing(String thumbUrl) => _missingThumbs.add(thumbUrl);

/// A link to the list thumbnail stored beside [url] (`<path>.thumb.jpg`,
/// core/doc_photo.dart), or null when there is none to show: not a
/// document image, an older upload without one, or no link could be made.
/// The caller then shows [url] itself (its link joins the next batch).
Future<String?> signedThumbUrl(String url, {SupabaseClient? client, DateTime? now}) async {
  final thumb = docThumbUrl(url);
  if (thumb == null || _missingThumbs.contains(thumb)) return null;
  final ref = privateStorageRef(thumb);
  if (ref == null) return null;
  try {
    final db = client ?? Supabase.instance.client;
    final b = StorageLinkBatcher.of(db);
    final link = await _cachedLink(_memoryKey(db, thumb), () => b.link(ref.bucket, ref.path), now: now);
    // Storage answers "Object not found" for an upload without a thumbnail.
    if (link == null) _missingThumbs.add(thumb);
    return link?.url;
  } catch (_) {
    return null;
  }
}
