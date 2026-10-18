/// How the app shows a link (pure): pages, pictures and PDFs open on a screen
/// of the app's own, with a back button, rather than in the phone's browser;
/// only what belongs to another app — a call, a text, an email, a map — is
/// handed off.
library;

enum LinkView { web, image, pdf, external }

const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'};

LinkView linkViewFor(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'data') {
    final type = uri.data?.mimeType ?? '';
    if (type.startsWith('image/')) return LinkView.image;
    if (type == 'application/pdf') return LinkView.pdf;
    return LinkView.external;
  }
  if (scheme != 'http' && scheme != 'https') return LinkView.external;
  final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.toLowerCase();
  final dot = last.lastIndexOf('.');
  final ext = dot < 0 ? '' : last.substring(dot + 1);
  if (_imageExts.contains(ext)) return LinkView.image;
  if (ext == 'pdf') return LinkView.pdf;
  return LinkView.web;
}

/// A title for the screen when the caller has none: the file name, else the
/// host.
String linkTitle(Uri uri) {
  final segs = uri.pathSegments.where((s) => s.isNotEmpty);
  if (segs.isNotEmpty && segs.last.contains('.')) return Uri.decodeComponent(segs.last);
  return uri.host.isEmpty ? 'Link' : uri.host;
}

/// Whether [uri] is a file the app's own storage serves, so it may be opened
/// from a record somebody else wrote (a document, an ID, a chat attachment):
/// https on the project's host under /storage/v1/, or on [allowedDomain] and
/// its subdomains (the fallback route); or a picture or PDF carried inline.
/// Anything else could be a look-alike page or another app's link.
bool isOwnStorageLink(Uri uri, {required String projectUrl, String allowedDomain = 'getride.my'}) {
  if (uri.scheme == 'data') return linkViewFor(uri) != LinkView.external;
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host.isEmpty) return false;
  final host = uri.host.toLowerCase();
  if (host == allowedDomain || host.endsWith('.$allowedDomain')) return true;
  return host == Uri.tryParse(projectUrl)?.host.toLowerCase() && uri.path.startsWith('/storage/v1/');
}
