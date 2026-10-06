/// Photo and video attachments in support chat (Expo `utils/supportStore.ts`
/// `uploadSupportMedia` + `SupportChatView`). Files go to the public
/// `support-media` bucket under the ticket's folder; the message row carries
/// `type` (`image` / `video`) and `media_url`.
library;

/// Largest attachment accepted, in bytes. A phone video of a minute or so.
const supportMediaMaxBytes = 50 * 1024 * 1024;

const _imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'heic'};
const _videoExts = {'mp4', 'mov', 'm4v', 'webm', '3gp'};

/// The lower-case extension of [name], or '' when it has none.
String fileExt(String name) {
  final m = RegExp(r'\.([a-zA-Z0-9]{2,5})$').firstMatch(name.split('?').first);
  return m == null ? '' : m.group(1)!.toLowerCase();
}

/// `image` or `video` for a picked file, or null when it is neither.
String? supportMediaKind(String ext) {
  final e = ext.toLowerCase();
  if (_imageExts.contains(e)) return 'image';
  if (_videoExts.contains(e)) return 'video';
  return null;
}

/// Content type for the upload (Expo `contentTypeFor`).
String supportContentType(String kind, String ext) {
  final e = ext.toLowerCase();
  if (kind == 'image') {
    return switch (e) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'heic' => 'image/heic',
      _ => 'image/png',
    };
  }
  return switch (e) {
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    '3gp' => 'video/3gpp',
    _ => 'video/mp4',
  };
}

/// `<ticket>/<kind>-<ms>-<tag>.<ext>`, Expo's layout.
String supportMediaPath(String ticketId, String kind, String ext, DateTime now, String tag) =>
    '$ticketId/$kind-${now.millisecondsSinceEpoch}-$tag.$ext';

/// The ticket-list preview for a message (Expo `summaryText`).
String supportSummary(String type, String? body) => switch (type) {
  'image' => '📷 Photo',
  'video' => '🎬 Video',
  'audio' => '🎤 Voice message',
  'location' => '📍 Location',
  _ => (body ?? '').trim().isEmpty ? 'Message' : body!.trim(),
};

/// Why a picked file can't be sent, or null.
String? supportMediaProblem(String name, int bytes) {
  if (supportMediaKind(fileExt(name)) == null) return 'Send a photo or a video.';
  if (bytes <= 0) return "That file couldn't be read.";
  if (bytes > supportMediaMaxBytes) return 'Choose a file under 50 MB.';
  return null;
}
