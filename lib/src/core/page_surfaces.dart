// The pages, sheets and modals App Page Settings lists (page_styles.dart).
// Plain Dart, so scripts/page_inventory.dart can run outside Flutter.

enum SurfaceKind { page, sheet, modal }

/// A page, sheet or modal in the app.
class SurfaceEntry {
  const SurfaceEntry(this.id, this.kind, this.title, this.file, {this.path});

  /// `route:/wallet`, `page:<id>`, `sheet:<id>` or `modal:<id>`.
  final String id;
  final SurfaceKind kind;
  final String title;

  /// Where it is in the code (`lib/...`).
  final String file;

  /// A router page's address pattern (`/ride/:id`).
  final String? path;

  /// Who sees it: the admin panel, drivers, or riders and everyone.
  String get area {
    if (file.contains('/admin/') || (path ?? '').startsWith('/admin')) return 'Admin panel';
    if (file.contains('/partner/') || file.contains('/meter/') || file.contains('/driver')) return 'Driver';
    return 'Rider & shared';
  }
}
