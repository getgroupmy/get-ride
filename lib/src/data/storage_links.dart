// Turns a stored document link into one that opens once its bucket is
// private: a signed link, made on demand and kept until shortly before it
// runs out.
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/storage_links.dart';

final _cache = <String, ({String url, DateTime until})>{};

/// A link to [url] that the signed-in caller can open: a fresh signed link
/// for a file in a private document bucket, [url] itself for anything else.
/// Falls back to [url] when no link can be made (no client, no session, no
/// right to the file), which still opens while the bucket is public.
Future<String> signedStorageUrl(String url, {SupabaseClient? client, DateTime? now}) async {
  final ref = privateStorageRef(url);
  if (ref == null) return url;
  final at = now ?? DateTime.now();
  final hit = _cache[url];
  if (hit != null && hit.until.isAfter(at)) return hit.url;
  try {
    final db = client ?? Supabase.instance.client;
    final signed = await db.storage.from(ref.bucket).createSignedUrl(ref.path, documentLinkTtl.inSeconds);
    // Handed out until ten minutes before it expires.
    _cache[url] = (url: signed, until: at.add(documentLinkTtl - const Duration(minutes: 10)));
    return signed;
  } catch (_) {
    return url;
  }
}
