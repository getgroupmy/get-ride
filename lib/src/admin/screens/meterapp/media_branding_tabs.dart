// The Media Gallery's App icon and Splash tabs: what App Settings has now
// (the `app_branding` row), set from the gallery (pick an upload, or upload
// one there) and written back to the same row, so App Settings and every
// app read it as before. The home-screen icons built into the app (the
// native icon-switch artwork, assets/app_icons) are listed with which the
// schedule or the admin's choice uses.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app_branding.dart';
import '../../../core/app_icons.dart';
import '../../../core/media_assets.dart';
import '../../../core/media_usage.dart';
import '../../../features/shell/brand_splash.dart' show SplashView;
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'branding_screens.dart';
import 'media_gallery_screen.dart' show MediaGalleryData;
import 'media_picker_sheet.dart';
import 'site_screen.dart' show sitePage;

/// The pages whose EDIT grant writes `app_branding` (0223).
const _brandingPages = [sitePage, 'admin-settings-app-icon', 'admin-settings-splash'];

bool _canEditBranding(WidgetRef ref) =>
    _brandingPages.any((p) => ref.watch(pageAccessProvider(p)) == AccessLevel.edit);

Widget _box(BuildContext context, Widget child, {double w = 120, double h = 120, double radius = 24}) {
  final cs = Theme.of(context).colorScheme;
  return Container(
    width: w,
    height: h,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: cs.outlineVariant),
    ),
    child: Center(child: child),
  );
}

Widget _heading(BuildContext context, String title, String note) {
  final t = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: t.textTheme.titleMedium),
      const SizedBox(height: 2),
      Text(note, style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
    ]),
  );
}

/// The App icon tab.
class MediaAppIconTab extends ConsumerWidget {
  const MediaAppIconTab({super.key, required this.data});
  final MediaGalleryData data;

  Future<void> _set(BuildContext context, WidgetRef ref, String? url) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(brandingStoreProvider).update({
        'app_icon_url': url,
        'icon_changed_at': DateTime.now().toUtc().toIso8601String(),
      }),
      success: url == null ? 'Back to the built-in icon' : 'Published: every user sees the new icon',
    );
    if (ok) ref.invalidate(brandingProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canEdit = _canEditBranding(ref);
    return AsyncView(
      value: ref.watch(brandingProvider),
      onRetry: () => ref.invalidate(brandingProvider),
      data: (row) {
        final b = AppBranding.fromRow(row);
        final url = b.appIconUrl;
        return ListView(key: const ValueKey('media-app-icon-tab'), padding: const EdgeInsets.all(16), children: [
          _heading(context, 'Current app icon',
              "The website's tab icon and the one-time \"App icon updated\" popup. Phones' home screens take it with the next App Release build."),
          Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _box(
              context,
              url == null
                  ? Image.asset('assets/branding/icon.png', key: const ValueKey('media-app-icon-builtin'), width: 96, height: 96)
                  : BrandingImageBox(key: const ValueKey('media-app-icon-current'), url: url, size: 118, radius: 24),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(url == null ? 'Built-in GET.ride icon' : 'Uploaded icon', style: t.textTheme.titleSmall),
              const SizedBox(height: 8),
              if (canEdit)
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('media-app-icon-choose'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: () async {
                      final v = await showMediaPicker(
                        context,
                        kind: MediaKind.logo,
                        alsoKinds: const {MediaKind.image, MediaKind.icon},
                        current: url,
                        title: 'App icon',
                        offerDefault: false,
                        store: MediaStore.url,
                      );
                      if (v == null || v.isEmpty || !context.mounted) return;
                      if (!await confirm(context, 'Publish app icon',
                          'Every user gets the new icon now (the website tab, and a one-time popup).', ok: 'Publish')) {
                        return;
                      }
                      if (context.mounted) await _set(context, ref, v);
                    },
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Choose from gallery'),
                  ),
                  if (url != null)
                    TextButton.icon(
                      key: const ValueKey('media-app-icon-default'),
                      onPressed: () => _set(context, ref, null),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Use the built-in icon'),
                    ),
                ])
              else
                Text('Only admins who can edit App Settings can change it.',
                    style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
            ]),
          ]),
          const SizedBox(height: 24),
          _heading(context, 'Home-screen icons built into the app',
              "Switched on phones by App Settings' schedule or the admin's choice. New ones need a new build."),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final i in appIcons)
              () {
                final uses = data.usage[appIconKey(i.id)] ?? const <MediaUse>[];
                return SizedBox(
                  width: 96,
                  child: Column(key: ValueKey('media-home-icon-${i.id}'), children: [
                    _box(context, Image.asset(i.preview(dark: t.brightness == Brightness.dark), width: 60, height: 60),
                        w: 72, h: 72, radius: 16),
                    const SizedBox(height: 4),
                    Text(i.name, textAlign: TextAlign.center, maxLines: 2, style: t.textTheme.bodySmall),
                    Text(uses.isEmpty ? 'Unused' : 'In use',
                        style: t.textTheme.labelSmall?.copyWith(color: uses.isEmpty ? mutedTextColor(t) : t.colorScheme.primary)),
                  ]),
                );
              }(),
          ]),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => context.push('/admin/m/site?highlight=app-icon'),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Schedule and options in App Settings'),
            ),
          ),
        ]);
      },
    );
  }
}

/// The Splash tab.
class MediaSplashTab extends ConsumerWidget {
  const MediaSplashTab({super.key});

  Future<void> _set(BuildContext context, WidgetRef ref, String? url) async {
    final ok = await runAdminAction(
      context,
      () => ref.read(brandingStoreProvider).update({'splash_image_url': url}),
      success: url == null ? 'Splash picture removed' : 'Splash picture set for every user',
    );
    if (ok) ref.invalidate(brandingProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canEdit = _canEditBranding(ref);
    return AsyncView(
      value: ref.watch(brandingProvider),
      onRetry: () => ref.invalidate(brandingProvider),
      data: (row) {
        final b = AppBranding.fromRow(row);
        Widget phone(bool dark, String label) => Column(children: [
          Container(
            width: 120,
            height: 212,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: t.colorScheme.outlineVariant),
            ),
            child: FittedBox(child: SizedBox(width: 390, height: 690, child: SplashView(latest: b, dark: dark))),
          ),
          const SizedBox(height: 4),
          Text(label, style: t.textTheme.labelMedium),
        ]);
        return ListView(key: const ValueKey('media-splash-tab'), padding: const EdgeInsets.all(16), children: [
          _heading(context, 'Current splash screen',
              'Shown while the Android and iOS apps start. Without a picture "GET." is shown. Its backgrounds are set in App Settings.'),
          Wrap(spacing: 16, runSpacing: 12, children: [phone(false, 'Light mode'), phone(true, 'Dark mode')]),
          const SizedBox(height: 12),
          Text(b.splashImageUrl == null ? 'No picture: the app shows "GET."' : 'Picture set',
              key: const ValueKey('media-splash-state'), style: t.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (canEdit)
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                key: const ValueKey('media-splash-choose'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: () async {
                  final v = await showMediaPicker(
                    context,
                    kind: MediaKind.image,
                    alsoKinds: const {MediaKind.logo},
                    current: b.splashImageUrl,
                    title: 'Splash picture',
                    offerDefault: false,
                    store: MediaStore.url,
                  );
                  if (v != null && v.isNotEmpty && context.mounted) await _set(context, ref, v);
                },
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose from gallery'),
              ),
              if (b.splashImageUrl != null)
                TextButton.icon(
                  key: const ValueKey('media-splash-clear'),
                  onPressed: () => _set(context, ref, null),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove picture'),
                ),
            ])
          else
            Text('Only admins who can edit App Settings can change it.',
                style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t))),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => context.push('/admin/m/site?highlight=splash'),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Backgrounds in App Settings'),
            ),
          ),
        ]);
      },
    );
  }
}
