// The single `app_branding` row (`id = 'global'`) that Admin → App Settings
// edits (Expo `admin-settings-app-icon`, `admin-settings-splash`): images
// are uploaded to the public `app-branding` bucket as `<icon|splash>-<ms>.<ext>`
// and stored by public URL, as in Expo.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../providers.dart';
import 'pick_image.dart';
import 'site_logic.dart';
import '../../../data/live_tables.dart';

class BrandingStore {
  BrandingStore(this._db);
  final SupabaseClient _db;

  /// The row, every column: one this database lacks reads as unset.
  Future<Map<String, dynamic>> fetch() async =>
      await _db.from(brandingTable).select().eq('id', brandingRowId).maybeSingle() ?? const {};

  Future<String> upload(PickedImage img, String kind) async {
    final path = brandingPath(kind, img.ext, DateTime.now());
    await _db.storage.from(brandingBucket).uploadBinary(
          path,
          img.bytes,
          fileOptions: FileOptions(upsert: true, contentType: img.contentType),
        );
    return _db.storage.from(brandingBucket).getPublicUrl(path);
  }

  Future<void> update(Map<String, dynamic> patch) => _db.from(brandingTable).upsert({
        'id': brandingRowId,
        ...patch,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');
}

final brandingStoreProvider = Provider((ref) => BrandingStore(ref.watch(supabaseProvider)));
final brandingProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('app_branding');
  return ref.watch(brandingStoreProvider).fetch();
});

/// Shows a picked (not yet uploaded) image or a stored URL.
class BrandingImageBox extends StatelessWidget {
  const BrandingImageBox({super.key, this.bytes, this.url, required this.size, required this.radius});
  final Uint8List? bytes;
  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget fallback() => Icon(Icons.apps, size: size * 0.4, color: t.colorScheme.outline);
    final child = bytes != null
        ? Image.memory(bytes!, fit: BoxFit.cover)
        : url != null
            ? Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback())
            : fallback();
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Center(child: child),
    );
  }
}
