// Admin → Settings → App Icon / Splash Screen (Expo `admin-settings-app-icon`,
// `admin-settings-splash`). Both edit the single `app_branding` row
// (`id = 'global'`); images are uploaded to the public `app-branding` bucket
// as `<icon|splash>-<ms>.<ext>` and stored by public URL, as in Expo.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'pick_image.dart';
import 'site_logic.dart';
import '../../../core/app_branding.dart';
import '../../../data/branding_cache.dart';
import '../../../features/shell/brand_splash.dart';
import '../../../data/live_tables.dart';

const appIconPage = 'admin-settings-app-icon';
const splashPage = 'admin-settings-splash';

class BrandingStore {
  BrandingStore(this._db);
  final SupabaseClient _db;

  static const _cols = 'splash_image_url, splash_bg_color, app_icon_url, icon_changed_at, updated_at';

  Future<Map<String, dynamic>> fetch() async =>
      await _db.from(brandingTable).select(_cols).eq('id', brandingRowId).maybeSingle() ??
      {'splash_bg_color': defaultSplashBgColor};

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
class _ImageBox extends StatelessWidget {
  const _ImageBox({this.bytes, this.url, required this.size, required this.radius});
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

// ---------------------------------------------------------------------------
// App icon
// ---------------------------------------------------------------------------

class AdminAppIconScreen extends ConsumerStatefulWidget {
  const AdminAppIconScreen({super.key});

  @override
  ConsumerState<AdminAppIconScreen> createState() => _AdminAppIconScreenState();
}

class _AdminAppIconScreenState extends ConsumerState<AdminAppIconScreen> {
  PickedImage? _picked;

  /// True once "Use default" was pressed (publishing then clears the icon).
  bool _cleared = false;
  bool _saving = false;

  Future<void> _publish(String? stored) async {
    if (_picked == null && !(_cleared && stored != null)) {
      showInfo(context, 'Pick a new icon image first.');
      return;
    }
    setState(() => _saving = true);
    final store = ref.read(brandingStoreProvider);
    final ok = await runAdminAction(context, () async {
      final url = _picked != null ? await store.upload(_picked!, 'icon') : null;
      await store.update({'app_icon_url': url, 'icon_changed_at': DateTime.now().toUtc().toIso8601String()});
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      setState(() {
        _picked = null;
        _cleared = false;
      });
      ref.invalidate(brandingProvider);
      await _published();
    }
  }

  Future<void> _published() => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle_outline),
          title: const Text('App icon updated'),
          content: const Text('The new app icon has been published. Every user will see a confirmation popup the next '
              'time they relaunch the app.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
        ),
      );

  Future<void> _reset() async {
    if (!await confirm(context, 'Reset icon', 'Restore the default app icon for all users?', ok: 'Reset')) return;
    if (!mounted) return;
    setState(() => _saving = true);
    final ok = await runAdminAction(
      context,
      () => ref
          .read(brandingStoreProvider)
          .update({'app_icon_url': null, 'icon_changed_at': DateTime.now().toUtc().toIso8601String()}),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        _picked = null;
        _cleared = false;
      }
    });
    if (ok) {
      ref.invalidate(brandingProvider);
      await _published();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(appIconPage)) == AccessLevel.edit;
    return AdminPage(
      title: 'App Icon',
      page: appIconPage,
      actions: [
        if (canEdit) BusyIconButton(tooltip: 'Reset to default', icon: const Icon(Icons.restart_alt), onPressed: _saving ? null : _reset),
      ],
      body: AsyncView(
        value: ref.watch(brandingProvider),
        onRetry: () => ref.invalidate(brandingProvider),
        data: (row) {
          final stored = row['app_icon_url'] as String?;
          final url = _cleared ? null : stored;
          final bytes = _picked?.bytes;
          final hasIcon = bytes != null || url != null;
          return ListView(padding: const EdgeInsets.symmetric(vertical: 24), children: [
            ResponsiveCenter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _ImageBox(bytes: bytes, url: url, size: 160, radius: 36),
                  const SizedBox(width: 16),
                  Column(children: [
                    _ImageBox(bytes: bytes, url: url, size: 72, radius: 18),
                    const SizedBox(height: 12),
                    _ImageBox(bytes: bytes, url: url, size: 44, radius: 10),
                  ]),
                ]),
                const SizedBox(height: 8),
                Text('Preview at three sizes — home screen, settings list, and small chip.'
                    '${hasIcon ? '' : ' No custom icon: the built-in app icon is used.'}',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  BusyButton.tonal(
                    icon: const Icon(Icons.upload),
                    onPressed: canEdit && !_saving
                        ? () async {
                            final img = await pickImage();
                            if (img != null) setState(() => _picked = img);
                          }
                        : null,
                    child: Text(hasIcon ? 'Replace icon' : 'Upload icon'),
                  ),
                  if (hasIcon)
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Use default'),
                      onPressed: canEdit && !_saving
                          ? () => setState(() {
                                _picked = null;
                                _cleared = true;
                              })
                          : null,
                    ),
                ]),
                const SizedBox(height: 4),
                Text('Recommended: a square PNG, 1024×1024, no transparency.', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('Changes take effect after each user relaunches the app. They will see a one-time '
                        'popup informing them that the app icon has been updated.'),
                  ),
                ),
                const SizedBox(height: 16),
                if (canEdit)
                  BusyButton.filled(
                    icon: const Icon(Icons.publish),
                    onPressed: _saving ? null : () => _publish(stored),
                    child: Text(_saving ? 'Publishing…' : 'Publish to all users'),
                  ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Splash
// ---------------------------------------------------------------------------

class AdminSplashScreen extends ConsumerStatefulWidget {
  const AdminSplashScreen({super.key});

  @override
  ConsumerState<AdminSplashScreen> createState() => _AdminSplashScreenState();
}

class _AdminSplashScreenState extends ConsumerState<AdminSplashScreen> {
  bool _loaded = false;
  PickedImage? _picked;
  String? _url;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final store = ref.read(brandingStoreProvider);
    final ok = await runAdminAction(context, () async {
      final url = _picked != null ? await store.upload(_picked!, 'splash') : _url;
      await store.update({'splash_image_url': url});
      _url = url;
      _picked = null;
    }, success: 'Splash saved');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) ref.invalidate(brandingProvider);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(splashPage)) == AccessLevel.edit;
    return AdminPage(
      title: 'Splash Screen',
      page: splashPage,
      body: AsyncView(
        value: ref.watch(brandingProvider),
        onRetry: () => ref.invalidate(brandingProvider),
        data: (row) {
          if (!_loaded) {
            _loaded = true;
            _url = AppBranding.fromRow(row).splashImageUrl;
          }
          // The previews are the real splash, on both backgrounds it sits on.
          final picked = _picked;
          final preview = picked != null
              ? CachedBranding(const AppBranding(splashImageUrl: 'https://preview'), picked.bytes)
              : CachedBranding(AppBranding(splashImageUrl: _url));
          Widget phone(bool dark, String label) => Column(children: [
                Container(
                  width: 150,
                  height: 270,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: SplashView(cached: preview, dark: dark),
                ),
                const SizedBox(height: 6),
                Text(label, style: Theme.of(context).textTheme.labelMedium),
              ]);
          return ListView(padding: const EdgeInsets.symmetric(vertical: 24), children: [
            ResponsiveCenter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  'Shown for ${splashHold.inSeconds} seconds when the Android and iOS apps start, on white — or '
                  'black in dark mode. Without a picture "GET." is shown in the brand blue. The website has no '
                  'splash screen.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Wrap(alignment: WrapAlignment.center, spacing: 16, runSpacing: 16, children: [
                  phone(false, 'Light mode'),
                  phone(true, 'Dark mode'),
                ]),
                const SizedBox(height: 16),
                Wrap(spacing: 8, children: [
                  BusyButton.tonal(
                    key: const ValueKey('splash-upload'),
                    icon: const Icon(Icons.upload),
                    onPressed: canEdit
                        ? () async {
                            final img = await pickImage();
                            if (img != null) setState(() => _picked = img);
                          }
                        : null,
                    child: Text(_picked != null || _url != null ? 'Replace image' : 'Upload image'),
                  ),
                  if (_picked != null || _url != null)
                    TextButton.icon(
                      key: const ValueKey('splash-clear'),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove image'),
                      onPressed: canEdit
                          ? () => setState(() {
                                _picked = null;
                                _url = null;
                              })
                          : null,
                    ),
                ]),
                const SizedBox(height: 24),
                if (canEdit)
                  BusyButton.filled(
                    icon: const Icon(Icons.save_outlined),
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save'),
                  ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}
