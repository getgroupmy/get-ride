// Turns a stored document link into one that opens once its bucket is
// private: a signed link, made on demand and kept until shortly before it
// runs out. Screens showing the same file at once share one signing call.
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/doc_photo.dart' show docThumbUrl;
import '../core/storage_links.dart';

final _cache = <String, ({String url, DateTime until})>{};
final _inFlight = <String, Future<String>>{};

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
  final hit = _cache[key];
  if (hit != null && hit.until.isAfter(at)) return Future.value(hit.url);
  final pending = _inFlight[key];
  if (pending != null) return pending;
  final made = Future.sync(sign)
      .then((signed) {
        _cache[key] = (url: signed, until: at.add(ttl - const Duration(minutes: 10)));
        return signed;
      })
      .whenComplete(() {
        _inFlight.remove(key);
      });
  _inFlight[key] = made;
  return made;
}

/// A link to [url] that the signed-in caller can open: a fresh signed link
/// for a file in a private document bucket, [url] itself for anything else.
/// Falls back to [url] when no link can be made (no client, no session, no
/// right to the file), which still opens while the bucket is public.
Future<String> signedStorageUrl(String url, {SupabaseClient? client, DateTime? now}) async {
  final ref = privateStorageRef(url);
  if (ref == null) return url;
  try {
    final db = client ?? Supabase.instance.client;
    return await cachedSignedLink(
      url,
      ttl: documentLinkTtl,
      now: now,
      sign: () => db.storage.from(ref.bucket).createSignedUrl(ref.path, documentLinkTtl.inSeconds),
    );
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
/// The caller then shows [url] itself.
Future<String?> signedThumbUrl(String url, {SupabaseClient? client, DateTime? now}) async {
  final thumb = docThumbUrl(url);
  if (thumb == null || _missingThumbs.contains(thumb)) return null;
  final ref = privateStorageRef(thumb);
  if (ref == null) return null;
  try {
    final db = client ?? Supabase.instance.client;
    return await cachedSignedLink(
      thumb,
      ttl: documentLinkTtl,
      now: now,
      sign: () => db.storage.from(ref.bucket).createSignedUrl(ref.path, documentLinkTtl.inSeconds),
    );
  } on StorageException {
    // Storage answers "Object not found" for an upload without a thumbnail.
    _missingThumbs.add(thumb);
    return null;
  } catch (_) {
    return null;
  }
}
