// Which stored file links point into a document bucket that is (or is about
// to be) private (migration 0148 and after), and the bucket and path inside
// it. Pure.
//
// The database keeps storing the bucket's public-form URL
// (`…/storage/v1/object/public/<bucket>/<path>`), so rows written before and
// after the switch read the same way; the app turns it into a short-lived
// signed link when it shows or opens the file.

/// The buckets whose files need a signed link to be read.
/// 'airport-guides': the pickup guides' photos (migration 0249).
const privateDocumentBuckets = {'ID_Image', 'vehicle-documents', 'provider-documents', 'support-media', 'airport-guides'};

/// How long a signed document link stays good.
const documentLinkTtl = Duration(hours: 1);

typedef StorageRef = ({String bucket, String path});

/// The bucket and path of a Supabase Storage [url] in one of the
/// [privateDocumentBuckets] (public, signed or authenticated form); null for
/// anything else, which is shown as it is.
StorageRef? privateStorageRef(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) return null;
  final seg = uri.pathSegments;
  final i = seg.indexOf('object');
  // …/storage/v1/object/<public|sign|authenticated>/<bucket>/<path…>
  if (i < 2 || seg[i - 2] != 'storage' || seg.length < i + 4) return null;
  if (!const {'public', 'sign', 'authenticated'}.contains(seg[i + 1])) return null;
  final bucket = seg[i + 2];
  if (!privateDocumentBuckets.contains(bucket)) return null;
  final path = seg.sublist(i + 3).join('/');
  if (path.isEmpty) return null;
  return (bucket: bucket, path: path);
}
