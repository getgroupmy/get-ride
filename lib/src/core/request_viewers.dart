// "3 drivers are viewing your request" (inDrive's bar over the search
// sheet): what `ride_request_viewers` (migration 0112) answers, and how the
// bar words it. Pure.

/// How long a driver's app waits between "still looking at it" reports.
const requestViewHeartbeat = Duration(seconds: 10);

/// How often the rider's sheet asks who is looking.
const requestViewersPoll = Duration(seconds: 5);

/// Drivers who have had the request on screen ([viewed]), those who have it
/// there now ([viewing]), and a few of their photos.
class RequestViewers {
  const RequestViewers({this.viewed = 0, this.viewing = 0, this.photos = const []});

  final int viewed, viewing;
  final List<String> photos;

  static const none = RequestViewers();

  /// The RPC's rows (one row, or none for a stranger / an older database).
  static RequestViewers parse(Object? rows) {
    final row = rows is List && rows.isNotEmpty ? rows.first : rows;
    if (row is! Map) return none;
    int n(Object? v) => v is num ? v.toInt() : 0;
    final photos = row['photos'];
    return RequestViewers(
      viewed: n(row['viewed']),
      viewing: n(row['viewing']).clamp(0, n(row['viewed'])),
      photos: [
        if (photos is List)
          for (final p in photos)
            if (p is String && p.trim().isNotEmpty) p.trim(),
      ],
    );
  }

  /// Whether there is anything to show.
  bool get any => viewed > 0;

  /// "3 drivers are viewing your request" while some are looking, else
  /// "13 drivers viewed your request". Null for nobody yet.
  String? get label {
    if (viewing > 0) {
      return viewing == 1 ? '1 driver is viewing your request' : '$viewing drivers are viewing your request';
    }
    if (viewed > 0) return viewed == 1 ? '1 driver viewed your request' : '$viewed drivers viewed your request';
    return null;
  }

  /// Faces to draw (at most [max]) and the "+9" after them.
  ({List<String> faces, int more}) faces({int max = 4}) {
    final shown = photos.take(max).toList();
    final count = viewing > 0 ? viewing : viewed;
    // Viewers without a photo still count toward the "+N".
    return (faces: shown, more: count > shown.length ? count - shown.length : 0);
  }

  @override
  bool operator ==(Object other) =>
      other is RequestViewers &&
      other.viewed == viewed &&
      other.viewing == viewing &&
      other.photos.join('\n') == photos.join('\n');

  @override
  int get hashCode => Object.hash(viewed, viewing, photos.join('\n'));
}
