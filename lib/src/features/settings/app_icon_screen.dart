// Settings → App icon: "Automatic" (the admin's seasons and sales) or any
// icon, kept on the phone (data/app_icon_service.dart). Only on iPhone and
// Android, only when the admin shows it, and locked when the admin doesn't
// let passengers and drivers choose.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_icons.dart';
import '../../data/app_icon_service.dart';

/// The Settings row: what is chosen, opening the page.
class AppIconTile extends ConsumerWidget {
  const AppIconTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(appIconPlatformProvider).supported) return const SizedBox.shrink();
    final config = ref.watch(appIconConfigProvider).value ?? AppIconConfig.standard;
    // Admin → App Settings → Home-screen icon can hide the row.
    if (!config.showInSettings) return const SizedBox.shrink();
    final choice = ref.watch(appIconChoiceProvider);
    final mine = config.userChoiceApplies && choice != automaticAppIcon ? appIconById(choice) : null;
    return Card(
      child: ListTile(
        key: const ValueKey('settings-app-icon'),
        leading: const Icon(Icons.apps),
        title: const Text('App icon'),
        subtitle: Text(mine?.name ?? 'Automatic'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/account/settings/app-icon'),
      ),
    );
  }
}

class AppIconScreen extends ConsumerWidget {
  const AppIconScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final config = ref.watch(appIconConfigProvider).value ?? AppIconConfig.standard;
    final choice = ref.watch(appIconChoiceProvider);
    final regions = ref.watch(appIconRegionsProvider).value ?? const <String>{};
    final now = DateTime.now();
    final automatic = config.automatic ? scheduledAppIcon(config, now, regions: regions) : config.fixedIcon;
    final canChoose = config.userChoiceApplies;
    final selected = canChoose ? choice : automaticAppIcon;

    void pick(String id) => ref.read(appIconChoiceProvider.notifier).set(id);

    Widget section(String title, AppIconGroup group) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 16,
          children: [
            for (final icon in appIcons.where((i) => i.group == group))
              _IconChoice(icon: icon, selected: selected == icon.id, onTap: canChoose ? () => pick(icon.id) : null),
          ],
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('App icon')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!canChoose)
            Container(
              key: const ValueKey('app-icon-locked'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text('GET.ride chooses the app icon for now.', style: t.textTheme.bodyLarge),
            ),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const ValueKey('app-icon-automatic'),
              contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              leading: _Preview(icon: appIconById(automatic)!, size: 48),
              title: const Text('Automatic'),
              subtitle: Text(
                config.automatic
                    ? 'Changes with festivals, seasons and sales. Now: ${endSentence(appIconById(automatic)!.name)}'
                    : 'The icon GET.ride chooses: ${endSentence(appIconById(automatic)!.name)}',
              ),
              trailing: selected == automaticAppIcon
                  ? Icon(Icons.check_circle, color: t.colorScheme.primary)
                  : const Icon(Icons.radio_button_unchecked),
              onTap: canChoose ? () => pick(automaticAppIcon) : null,
            ),
          ),
          section('GET.ride', AppIconGroup.brand),
          section('Festivals and seasons', AppIconGroup.festival),
          section('Sales and payday', AppIconGroup.sale),
          const SizedBox(height: 20),
          Text(
            Theme.of(context).platform == TargetPlatform.iOS
                ? 'Your iPhone says so when the icon changes. In dark mode the icon turns dark too.'
                : 'The new icon shows on your home screen once you leave the app. In dark mode the icon turns '
                      'dark too.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({required this.icon, required this.selected, required this.onTap});

  final AppIconDef icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: icon.name,
      // The name once: not again from the caption or the picture.
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        key: ValueKey('app-icon-${icon.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          width: 80,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(19),
                  border: Border.all(color: selected ? t.colorScheme.primary : Colors.transparent, width: 2.5),
                ),
                child: _Preview(icon: icon, size: 64),
              ),
              const SizedBox(height: 6),
              // Always two lines high, so the tiles of a row line up
              // whether a name takes one line or two.
              SizedBox(
                height: MediaQuery.textScalerOf(context).scale(2 * 12 * 1.4),
                child: Text(
                  icon.name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected ? t.colorScheme.primary : t.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [text] ending a sentence: one full stop, never two ("G." stays "G.").
String endSentence(String text) {
  final t = text.trim();
  return RegExp(r'[.!?]$').hasMatch(t) ? t : '$t.';
}

/// The icon as the home screen shows it in the app's current mode.
class _Preview extends StatelessWidget {
  const _Preview({required this.icon, required this.size});

  final AppIconDef icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .225),
        border: Border.all(color: t.colorScheme.outlineVariant, width: .5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        icon.preview(dark: dark),
        excludeFromSemantics: true,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => ColoredBox(
          color: t.colorScheme.surfaceContainerHighest,
          child: Icon(Icons.apps, color: t.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
