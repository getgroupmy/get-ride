// Admin → Settings → Display (Expo `admin-settings-display`).
//
// Edits the global `admin_display_settings` blob every device reads: home
// sections, connection popups, map / ride-confirm / ride-tracking layout
// offsets, service switch, mock toggles, the five home service boxes, the
// vehicle type bar and both side menus. Each change is written straight
// through, as in Expo.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'display_logic.dart';
import 'display_store.dart';
import 'pick_image.dart';

const displayPage = 'admin-settings-display';

/// Material stand-ins for the lucide icon names stored in the blob.
const lucideIcons = <String, IconData>{
  'ShoppingBag': Icons.shopping_bag_outlined,
  'Car': Icons.directions_car_outlined,
  'Building2': Icons.apartment,
  'Package': Icons.inventory_2_outlined,
  'Truck': Icons.local_shipping_outlined,
  'Bike': Icons.pedal_bike,
  'Bus': Icons.directions_bus_outlined,
  'Plane': Icons.flight,
  'MapPin': Icons.place_outlined,
  'Navigation': Icons.navigation_outlined,
  'Clock': Icons.schedule,
  'Bell': Icons.notifications_outlined,
  'BookOpen': Icons.menu_book_outlined,
  'FileText': Icons.description_outlined,
  'Gift': Icons.card_giftcard,
  'HelpCircle': Icons.help_outline,
  'Heart': Icons.favorite_border,
  'Mail': Icons.mail_outline,
  'MessageCircle': Icons.chat_bubble_outline,
  'Phone': Icons.phone_outlined,
  'Settings': Icons.settings_outlined,
  'Shield': Icons.shield_outlined,
  'Star': Icons.star_border,
  'Tag': Icons.sell_outlined,
  'User': Icons.person_outline,
  'Wallet': Icons.account_balance_wallet_outlined,
};

IconData lucide(String? name) => lucideIcons[name] ?? Icons.star_border;

const _defaultMenuIcons = <String, Map<String, String>>{
  'user': {
    'city': 'Car',
    'request-history': 'Clock',
    'freight': 'Truck',
    'notifications': 'Bell',
    'safety': 'Shield',
    'settings': 'Settings',
    'user-guide': 'BookOpen',
    'support': 'MessageCircle',
    'logout': 'User',
  },
  'partner': {
    'dashboard': 'Settings',
    'earnings': 'Wallet',
    'trip-history': 'Clock',
    'vehicle': 'Car',
    'documents': 'FileText',
    'notifications': 'Bell',
    'safety': 'Shield',
    'support': 'HelpCircle',
    'settings': 'Settings',
    'sign-out': 'User',
  },
};

/// Shared write helper for the display / mock screens.
Future<void> applyDisplay(BuildContext context, WidgetRef ref, DisplayEdit edit) =>
    runAdminAction(context, () => ref.read(displaySettingsProvider.notifier).apply(edit));

/// Picks an Expo route path (or none); returns `''` for none, null if cancelled.
Future<String?> pickRoute(BuildContext context, {String? current, String noneLabel = 'None (no navigation)'}) =>
    showAdminSheet<String>(
      context,
      title: 'Link to page',
      builder: (ctx) => _RoutePicker(current: current, noneLabel: noneLabel),
    );

class _RoutePicker extends StatefulWidget {
  const _RoutePicker({this.current, required this.noneLabel});
  final String? current;
  final String noneLabel;

  @override
  State<_RoutePicker> createState() => _RoutePickerState();
}

class _RoutePickerState extends State<_RoutePicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final list = allAppRoutes.where((r) => q.isEmpty || r.contains(q) || routeLabel(r).toLowerCase().contains(q));
    return Column(children: [
      TextField(
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search pages', isDense: true),
        onChanged: (v) => setState(() => _q = v.trim()),
      ),
      ListTile(
        title: Text(widget.noneLabel),
        trailing: (widget.current ?? '').isEmpty ? const Icon(Icons.check) : null,
        onTap: () => Navigator.pop(context, ''),
      ),
      for (final r in list)
        ListTile(
          dense: true,
          title: Text(routeLabel(r)),
          subtitle: Text(r),
          trailing: widget.current == r ? const Icon(Icons.check) : null,
          onTap: () => Navigator.pop(context, r),
        ),
    ]);
  }
}

class AdminDisplaySettingsScreen extends ConsumerWidget {
  const AdminDisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    return AdminPage(
      title: 'Display Settings',
      page: displayPage,
      actions: [
        if (canEdit)
          BusyIconButton(
            tooltip: 'Reset to defaults',
            icon: const Icon(Icons.restart_alt),
            onPressed: () async {
              if (!await confirm(context, 'Reset Display Settings', 'Restore all defaults?', ok: 'Reset')) return;
              if (context.mounted) await applyDisplay(context, ref, (_) => defaultDisplaySettings());
            },
          ),
      ],
      body: AsyncView(
        value: ref.watch(displaySettingsProvider),
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (s) => _DisplayBody(settings: s, canEdit: canEdit),
      ),
    );
  }
}

class _DisplayBody extends ConsumerWidget {
  const _DisplayBody({required this.settings, required this.canEdit});
  final Map<String, dynamic> settings;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = settings;
    Future<void> set(String key, Object? v) => applyDisplay(context, ref, (x) => setDisplayValue(x, key, v));

    Widget toggle(String label, String desc, bool value, Future<void> Function(bool) onChanged) => BusySwitchListTile(
          title: Text(label),
          subtitle: Text(desc),
          value: value,
          onChanged: canEdit ? onChanged : null,
        );

    Widget stepper(LayoutItem item) => _StepperTile(
          label: item.label,
          description: item.description,
          value: displayNum(s, item.key),
          unit: 'px',
          min: item.min,
          max: item.max,
          onChanged: canEdit
              ? (v) => applyDisplay(context, ref, (x) => setDisplayNumber(x, item.key, v, item.min, item.max))
              : null,
          step: item.step,
        );

    return ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
      ResponsiveCenter(
        maxWidth: 820,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const _Section('Home Screen Sections'),
          Card(
            child: Column(children: [
              for (final (key, label, desc) in homeSectionToggles)
                toggle(label, desc, displayBool(s, key), (v) => set(key, v)),
            ]),
          ),
          const _Section('Sign-in Screen'),
          Card(
            child: Column(children: [
              toggle(
                  'Allow new registrations',
                  'When off, a phone number not already in the user list is shown a "New registrations are closed" '
                      'page asking them to contact the Administrator. Existing accounts still sign in.',
                  displayBool(s, 'registrationEnabled'),
                  (v) => set('registrationEnabled', v)),
              toggle('Show logo', 'Show the GET.ride logo at the top of the sign-in screen',
                  displayBool(s, 'signInLogo'), (v) => set('signInLogo', v)),
            ]),
          ),
          const _Section('Connection Status Popups'),
          Card(
            child: Column(children: [
              toggle('Show "Connected" popup', 'On app launch, show the success popup when Supabase is reachable',
                  displayBool(s, 'connectedPopupEnabled'), (v) => set('connectedPopupEnabled', v)),
              toggle('Show "Not Connected" popup', "On app launch, show the failure popup when Supabase can't be reached",
                  displayBool(s, 'connectionFailedPopupEnabled'), (v) => set('connectionFailedPopupEnabled', v)),
            ]),
          ),
          const _Section('Recent Locations'),
          Card(
            child: _StepperTile(
              label: 'Suggested locations count',
              description: 'How many recent places to suggest ($recentLocationsMin-$recentLocationsMax)',
              value: displayNum(s, 'recentLocationsCount'),
              min: recentLocationsMin,
              max: recentLocationsMax,
              step: 1,
              onChanged: canEdit
                  ? (v) => applyDisplay(
                      context, ref, (x) => setDisplayNumber(x, 'recentLocationsCount', v, recentLocationsMin, recentLocationsMax))
                  : null,
            ),
          ),
          const _Section('Map Layout'),
          Card(child: Column(children: [for (final i in mapLayoutItems) stepper(i)])),
          const _Section('Ride Confirm Layout'),
          Card(
            child: Column(children: [
              toggle('Show discount bar', 'Toggle the promo/discount bar on the ride-confirm screen',
                  displayBool(s, 'discountBar'), (v) => set('discountBar', v)),
              toggle('Discount bar in front', 'On = promo bar sits in front of the bottom sheet. Off = sent behind it.',
                  displayBool(s, 'discountBarInFront'), (v) => set('discountBarInFront', v)),
              for (final i in rideConfirmLayoutItems) stepper(i),
            ]),
          ),
          const _Section('Ride Tracking Layout'),
          Card(child: Column(children: [for (final i in rideTrackingLayoutItems) stepper(i)])),
          const _Section('Service'),
          Card(
            child: Column(children: [
              toggle(
                  'Service available',
                  'When off, booking actions on the home screen show a "Coming Soon" popup instead of opening ride '
                      'confirmation',
                  displayBool(s, 'serviceEnabled'),
                  (v) => set('serviceEnabled', v)),
            ]),
          ),
          const _Section('Demo / Mockup Data'),
          Card(
            child: Column(children: [
              toggle(
                  'Turn off Mockup (User)',
                  'When on, passengers no longer see demo driver offers, bids, and "viewing" avatars while searching '
                      'for a ride',
                  !displayBool(s, 'userMockEnabled'),
                  (v) => set('userMockEnabled', !v)),
              toggle('Turn off Mockup (Partner)',
                  'When on, drivers no longer receive demo/auto-generated incoming ride requests while online',
                  !displayBool(s, 'partnerMockEnabled'), (v) => set('partnerMockEnabled', !v)),
            ]),
          ),
          const _Section('Service Boxes'),
          Card(
            child: toggle('Show "NEW" badge', 'Toggle the NEW badge on the featured (large) service box',
                displayBool(s, 'serviceBoxBadge'), (v) => set('serviceBoxBadge', v)),
          ),
          for (var i = 0; i < serviceBoxCount; i++) _ServiceBoxCard(settings: s, index: i, canEdit: canEdit),
          const _Section('Vehicle Type Bar'),
          Card(
            child: Column(children: [
              toggle('On-map vehicle icons', 'Show available vehicle markers on the map',
                  displayBool(s, 'showVehicleMarkers'), (v) => set('showVehicleMarkers', v)),
              ListTile(
                leading: const Icon(Icons.layers_outlined),
                title: const Text('Manage vehicles in bar'),
                subtitle: const Text('Pick a service to toggle which vehicles appear on the home bar'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showAdminSheet<void>(context,
                    title: 'Vehicle Type Bar', builder: (_) => _VehicleBarServices(canEdit: canEdit)),
              ),
              ListTile(
                leading: const Icon(Icons.swap_vert),
                title: const Text('Icon in bar arrangement'),
                subtitle: const Text('Reorder how visible vehicle icons appear on the home bar'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showAdminSheet<void>(context,
                    title: 'Icon in Bar Arrangement', builder: (_) => _VehicleArrangement(canEdit: canEdit)),
              ),
            ]),
          ),
          const _Section('Side Menus'),
          Card(
            child: Column(children: [
              for (final (menu, label, icon) in [
                ('user', 'User side menu', Icons.person_outline),
                ('partner', 'Partner side menu', Icons.work_outline),
              ])
                ListTile(
                  leading: Icon(icon),
                  title: Text(label),
                  subtitle: const Text('Rename, hide, reorder, link pages or add custom entries'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SideMenuEditorScreen(menu: menu),
                  )),
                ),
            ]),
          ),
          const _Section('Ride Confirm Screen'),
          Card(
            child: Column(children: [
              toggle('Est. Toll Booth Count', 'Show AI-estimated number of toll booths on the route',
                  displayBool(s, 'showAiTollBooths'), (v) => set('showAiTollBooths', v)),
              toggle('Est. Toll Charges', 'Show AI-estimated total toll cost on the route',
                  displayBool(s, 'showAiTollCharges'), (v) => set('showAiTollCharges', v)),
            ]),
          ),
          const SizedBox(height: 32),
        ]),
      ),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _StepperTile extends StatelessWidget {
  const _StepperTile({
    required this.label,
    required this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.unit,
  });

  final String label;
  final String description;
  final num value;
  final int min;
  final int max;
  final int step;
  final String? unit;
  final Future<void> Function(num)? onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(label),
        subtitle: Text(description),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          BusyIconButton(
            icon: const Icon(Icons.remove),
            onPressed: onChanged == null || value <= min ? null : () => onChanged!(value - step),
          ),
          SizedBox(
            width: 64,
            child: Text('$value${unit ?? ''}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          BusyIconButton(
            icon: const Icon(Icons.add),
            onPressed: onChanged == null || value >= max ? null : () => onChanged!(value + step),
          ),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Service boxes
// ---------------------------------------------------------------------------

class _ServiceBoxCard extends ConsumerWidget {
  const _ServiceBoxCard({required this.settings, required this.index, required this.canEdit});
  final Map<String, dynamic> settings;
  final int index;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boxes = normalizeBoxes(settings['serviceBoxes']);
    final cfg = boxes[index];
    final services = [...(ref.watch(settingsEntriesProvider('service-settings')).value ?? const <Map<String, dynamic>>[])]
      ..sort((a, b) => _prio(a).compareTo(_prio(b)));
    final linked = services.where((x) => x['id'] == cfg['serviceId']).firstOrNull;
    final name = (cfg['name'] as String?)?.trim();
    final label = (name != null && name.isNotEmpty)
        ? name
        : linked != null
            ? '${(linked['values'] as Map?)?['name'] ?? 'Box ${index + 1}'}'
            : 'Box ${index + 1}';
    final iconName = (cfg['iconName'] as String?) ?? defaultServiceBoxIcons[index];
    final route = cfg['route'] as String?;
    final image = cfg['imageUri'] as String?;

    Future<void> patch(Map<String, dynamic> p) => applyDisplay(context, ref, (x) => updateServiceBox(x, index, p));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            SizedBox(width: 56, height: 56, child: _BoxPreview(image: image, icon: lucide(iconName))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Box ${index + 1}', style: Theme.of(context).textTheme.bodySmall),
                Text(label, style: Theme.of(context).textTheme.titleMedium),
              ]),
            ),
          ]),
          BusyListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Service'),
            subtitle: Text(linked != null ? '${(linked['values'] as Map?)?['name'] ?? 'Unnamed'}' : 'Default'),
            trailing: const Icon(Icons.arrow_drop_down),
            enabled: canEdit,
            onTap: () async {
              final picked = await showAdminSheet<String>(
                context,
                title: 'Choose Service',
                builder: (ctx) => Column(children: [
                  ListTile(title: const Text('Default'), onTap: () => Navigator.pop(ctx, '')),
                  if (services.isEmpty) const ListTile(title: Text('No record. Add services in Service Settings.')),
                  for (final svc in services)
                    ListTile(
                      title: Text('${(svc['values'] as Map?)?['name'] ?? 'Unnamed'}'),
                      trailing: svc['id'] == cfg['serviceId'] ? const Icon(Icons.check) : null,
                      onTap: () => Navigator.pop(ctx, svc['id'] as String),
                    ),
                ]),
              );
              if (picked != null) await patch({'serviceId': picked.isEmpty ? null : picked});
            },
          ),
          TextFormField(
            key: ValueKey('box-name-$index-${cfg['name']}'),
            initialValue: name ?? '',
            enabled: canEdit,
            decoration: const InputDecoration(labelText: 'Custom label (optional)', isDense: true),
            onFieldSubmitted: (v) => patch({'name': v.trim().isEmpty ? null : v.trim()}),
          ),
          BusyListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(lucide(iconName)),
            title: const Text('Icon'),
            subtitle: Text(iconName),
            trailing: const Icon(Icons.arrow_drop_down),
            enabled: canEdit,
            onTap: () async {
              final picked = await showAdminSheet<String>(
                context,
                title: 'Choose Icon',
                builder: (ctx) => Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final n in serviceBoxIcons)
                    ChoiceChip(
                      avatar: Icon(lucide(n), size: 18),
                      label: Text(n),
                      selected: n == iconName,
                      onSelected: (_) => Navigator.pop(ctx, n),
                    ),
                ]),
              );
              if (picked != null) await patch({'iconName': picked});
            },
          ),
          BusyListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Opens'),
            subtitle: Text(route != null ? routeLabelFor(route) : 'Nothing yet — shows Coming Soon'),
            trailing: const Icon(Icons.arrow_drop_down),
            enabled: canEdit,
            onTap: () async {
              final picked = await pickRoute(context, current: route, noneLabel: 'None — tapping shows Coming Soon');
              if (picked == null) return;
              await patch(picked.isEmpty ? {'route': null} : {'route': picked, 'comingSoon': false});
            },
          ),
          BusySwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Coming soon'),
            subtitle: Text(route != null
                ? 'Show the Coming Soon notice instead of opening the page'
                : 'Always on while no page is linked'),
            value: cfg['comingSoon'] == true || route == null,
            onChanged: canEdit && route != null ? (v) => patch({'comingSoon': v}) : null,
          ),
          Wrap(spacing: 8, children: [
            BusyButton.outlined(
              icon: const Icon(Icons.upload),
              onPressed: canEdit
                  ? () async {
                      final f = await pickImage();
                      if (f == null) return;
                      await patch({'imageUri': 'data:${f.contentType};base64,${base64Encode(f.bytes)}'});
                    }
                  : null,
              child: Text(image != null ? 'Replace image' : 'Upload image'),
            ),
            if (image != null)
              BusyButton.text(
                icon: const Icon(Icons.close),
                onPressed: canEdit ? () => patch({'imageUri': null}) : null,
                child: const Text('Remove'),
              )
            else
              const Padding(padding: EdgeInsets.only(top: 10), child: Text('Image overrides icon')),
          ]),
        ]),
      ),
    );
  }
}

num _prio(Map<String, dynamic> e) => num.tryParse('${(e['values'] as Map?)?['displayPriority'] ?? 9999}') ?? 9999;

class _BoxPreview extends StatelessWidget {
  const _BoxPreview({this.image, required this.icon});
  final String? image;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.primaryContainer;
    Widget fallback() => Icon(icon, size: 28);
    Widget? img;
    final src = image;
    if (src != null && src.startsWith('data:') && src.contains(',')) {
      try {
        img = Image.memory(base64Decode(src.substring(src.indexOf(',') + 1)), fit: BoxFit.cover);
      } catch (_) {}
    } else if (src != null && src.startsWith('http')) {
      img = Image.network(src, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback());
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(color: bg, child: Center(child: img ?? fallback())),
    );
  }
}

// ---------------------------------------------------------------------------
// Vehicle type bar
// ---------------------------------------------------------------------------

List<String> _serviceTypes(Map<String, dynamic> e) {
  final t = (e['values'] as Map?)?['serviceTypes'];
  return t is List ? t.map((x) => '$x').toList() : const [];
}

class _VehicleBarServices extends ConsumerStatefulWidget {
  const _VehicleBarServices({required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<_VehicleBarServices> createState() => _VehicleBarServicesState();
}

class _VehicleBarServicesState extends ConsumerState<_VehicleBarServices> {
  String? _service;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(displaySettingsProvider).value ?? defaultDisplaySettings();
    final hidden = ((s['hiddenVehicleServiceIds'] as List?) ?? const []).toSet();
    final services = [...(ref.watch(settingsEntriesProvider('service-settings')).value ?? const <Map<String, dynamic>>[])]
      ..sort((a, b) => _prio(a).compareTo(_prio(b)));
    final vehicles = ref.watch(settingsEntriesProvider('vehicle-services')).value ?? const <Map<String, dynamic>>[];

    if (_service != null) {
      final linked = vehicles.where((v) => _serviceTypes(v).contains(_service)).toList();
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextButton.icon(
          onPressed: () => setState(() => _service = null),
          icon: const Icon(Icons.arrow_back),
          label: Text(_service!),
        ),
        if (linked.isEmpty) const ListTile(title: Text('No vehicles linked to this service.')),
        for (final v in linked)
          BusySwitchListTile(
            title: Text('${(v['values'] as Map?)?['name'] ?? 'Unnamed'}'),
            value: !hidden.contains(v['id']),
            onChanged: widget.canEdit
                ? (on) => applyDisplay(context, ref, (x) => setVehicleServiceVisibility(x, v['id'] as String, on))
                : null,
          ),
      ]);
    }
    return Column(children: [
      if (services.isEmpty) const ListTile(title: Text('No record. Add services in Service Settings.')),
      for (final svc in services)
        () {
          final name = '${(svc['values'] as Map?)?['name'] ?? ''}';
          final linked = vehicles.where((v) => _serviceTypes(v).contains(name)).toList();
          final visible = linked.where((v) => !hidden.contains(v['id'])).length;
          return ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: Text(name.isEmpty ? 'Unnamed' : name),
            subtitle: Text(linked.isEmpty ? 'No vehicles linked' : '$visible/${linked.length} visible'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _service = name),
          );
        }(),
    ]);
  }
}

class _VehicleArrangement extends ConsumerWidget {
  const _VehicleArrangement({required this.canEdit});
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(displaySettingsProvider).value ?? defaultDisplaySettings();
    final vehicles = ref.watch(settingsEntriesProvider('vehicle-services')).value ?? const <Map<String, dynamic>>[];
    final list = arrangeVehicles<Map<String, dynamic>>(vehicles, s,
        id: (e) => e['id'] as String, values: (e) => Map<String, dynamic>.from((e['values'] as Map?) ?? const {}));
    final ids = [for (final e in list) e['id'] as String];
    if (list.isEmpty) {
      return const ListTile(title: Text('No visible vehicles. Turn some on in "Manage vehicles in bar".'));
    }
    return Column(children: [
      for (var i = 0; i < list.length; i++)
        ListTile(
          leading: const Icon(Icons.directions_car_outlined),
          title: Text('${(list[i]['values'] as Map?)?['name'] ?? 'Unnamed'}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            BusyIconButton(
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: !canEdit || i == 0 ? null : () => applyDisplay(context, ref, (x) => moveVehicleInBar(x, ids[i], -1, ids)),
            ),
            BusyIconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: !canEdit || i == list.length - 1
                  ? null
                  : () => applyDisplay(context, ref, (x) => moveVehicleInBar(x, ids[i], 1, ids)),
            ),
          ]),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Side menu editor
// ---------------------------------------------------------------------------

class SideMenuEditorScreen extends ConsumerWidget {
  const SideMenuEditorScreen({super.key, required this.menu});
  final String menu;

  Future<void> _edit(BuildContext context, WidgetRef ref, String itemId, String label, String? route) async {
    final res = await showDialog<(String, String?, String)>(
      context: context,
      builder: (_) => _MenuItemDialog(title: 'Edit item', label: label, route: route, showIcon: false),
    );
    if (res == null || !context.mounted) return;
    await applyDisplay(
        context, ref, (x) => setMenuItemRoute(renameMenuItem(x, menu, itemId, res.$1), menu, itemId, res.$2));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final value = ref.watch(displaySettingsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(menu == 'user' ? 'User Side Menu' : 'Partner Side Menu')),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('Add new item'),
              onPressed: () async {
                final res = await showDialog<(String, String?, String)>(
                  context: context,
                  builder: (_) => const _MenuItemDialog(title: 'Add Menu Item', label: '', showIcon: true),
                );
                if (res == null || !context.mounted) return;
                final id = 'custom-${DateTime.now().millisecondsSinceEpoch}-${const Uuid().v4().substring(0, 5)}';
                await applyDisplay(context, ref, (x) => addCustomMenuItem(x, menu, res.$1, res.$3, res.$2, id: id));
              },
            )
          : null,
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (s) {
          final cfg = menuOf(s, menu);
          final ordered = menuItemOrder(menu, cfg);
          final hidden = ((cfg['hidden'] as List?) ?? const []).toSet();
          final soon = ((cfg['comingSoon'] as List?) ?? const []).toSet();
          final renames = Map<String, dynamic>.from(cfg['renames'] as Map);
          final routes = Map<String, dynamic>.from(cfg['routes'] as Map);
          final custom = {for (final c in cfg['customItems'] as List) (c as Map)['id'] as String: c};
          final defaults = {for (final d in defaultMenuItems(menu)) d.$1: d.$2};
          final footerId = menu == 'user' ? partnerModeMenuItemId : passengerModeMenuItemId;
          final footerLabel = (renames[footerId] as String?) ??
              (menu == 'user' ? partnerModeDefaultLabel : passengerModeDefaultLabel);

          Widget row({
            required String id,
            required IconData icon,
            required String title,
            required String subtitle,
            Widget? leadingExtra,
            Future<void> Function()? onEdit,
            Future<void> Function()? onDelete,
          }) =>
              Card(
                child: ListTile(
                  leading: Row(mainAxisSize: MainAxisSize.min, children: [?leadingExtra, Icon(icon)]),
                  title: Text(title),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(subtitle),
                    const SizedBox(height: 4),
                    FilterChip(
                      label: const Text('Coming Soon'),
                      selected: soon.contains(id),
                      onSelected: canEdit
                          ? (v) => applyDisplay(context, ref, (x) => setMenuItemComingSoon(x, menu, id, v))
                          : null,
                    ),
                  ]),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (onEdit != null && canEdit) BusyIconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
                    if (onDelete != null && canEdit)
                      BusyIconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: onDelete),
                    BusySwitch(
                      value: !hidden.contains(id),
                      onChanged: canEdit
                          ? (v) => applyDisplay(context, ref, (x) => setMenuItemVisibility(x, menu, id, v))
                          : null,
                    ),
                  ]),
                ),
              );

          return ListView(padding: const EdgeInsets.fromLTRB(0, 16, 0, 96), children: [
            ResponsiveCenter(
              maxWidth: 820,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  'Toggle items off to hide them, use the arrows to reorder, and the pencil to rename or link a page. '
                  'Changes apply to every device.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                row(id: profileMenuItemId, icon: Icons.person_outline, title: 'Profile', subtitle: 'Profile header at the top of the sheet'),
                for (var i = 0; i < ordered.length; i++)
                  () {
                    final o = ordered[i];
                    final c = custom[o.id];
                    final label = o.isCustom ? '${c?['label'] ?? 'Item'}' : (renames[o.id] as String?) ?? defaults[o.id] ?? o.id;
                    final iconName = o.isCustom ? ((c?['iconName'] as String?) ?? 'Star') : (_defaultMenuIcons[menu]![o.id] ?? 'Settings');
                    final route = o.isCustom ? (c?['route'] as String?) : (routes[o.id] as String?);
                    final defRoute = o.isCustom ? null : defaultMenuRoutes[menu]![o.id];
                    final effective = route ?? defRoute;
                    final tags = [
                      if (route == null && defRoute != null) 'Default',
                      if (o.isCustom) 'Custom',
                    ];
                    return row(
                      id: o.id,
                      icon: lucide(iconName),
                      title: label,
                      subtitle: 'Page: ${routeLabelFor(effective)}${tags.isEmpty ? '' : '  ·  ${tags.join('  ·  ')}'}',
                      leadingExtra: Column(mainAxisSize: MainAxisSize.min, children: [
                        InkWell(
                          onTap: !canEdit || i == 0 ? null : () => applyDisplay(context, ref, (x) => moveMenuItem(x, menu, o.id, -1)),
                          child: const Icon(Icons.keyboard_arrow_up, size: 18),
                        ),
                        InkWell(
                          onTap: !canEdit || i == ordered.length - 1
                              ? null
                              : () => applyDisplay(context, ref, (x) => moveMenuItem(x, menu, o.id, 1)),
                          child: const Icon(Icons.keyboard_arrow_down, size: 18),
                        ),
                      ]),
                      onEdit: () => _edit(context, ref, o.id, label, route),
                      onDelete: o.isCustom
                          ? () async {
                              if (!await confirm(context, 'Remove item', 'Remove "$label"?', ok: 'Remove')) return;
                              if (context.mounted) await applyDisplay(context, ref, (x) => removeCustomMenuItem(x, menu, o.id));
                            }
                          : null,
                    );
                  }(),
                row(
                  id: footerId,
                  icon: menu == 'user' ? Icons.directions_car_outlined : Icons.person_outline,
                  title: footerLabel,
                  subtitle: menu == 'user' ? 'Partner Mode button in the footer' : 'Passenger Mode button in the footer',
                  onEdit: () async {
                    final res = await showDialog<(String, String?, String)>(
                      context: context,
                      builder: (_) => _MenuItemDialog(title: 'Rename Item', label: footerLabel, showIcon: false, showRoute: false),
                    );
                    if (res == null || !context.mounted) return;
                    await applyDisplay(context, ref, (x) => renameMenuItem(x, menu, footerId, res.$1));
                  },
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

class _MenuItemDialog extends StatefulWidget {
  const _MenuItemDialog({required this.title, required this.label, this.route, required this.showIcon, this.showRoute = true});
  final String title;
  final String label;
  final String? route;
  final bool showIcon;
  final bool showRoute;

  @override
  State<_MenuItemDialog> createState() => _MenuItemDialogState();
}

class _MenuItemDialogState extends State<_MenuItemDialog> {
  late final _label = TextEditingController(text: widget.label);
  late String? _route = widget.route;
  String _icon = 'Star';

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: _label,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Label', hintText: 'e.g. Refer a friend'),
              ),
              if (widget.showIcon) ...[
                const SizedBox(height: 12),
                Text('Icon', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final n in sideMenuIcons)
                    ChoiceChip(
                      avatar: Icon(lucide(n), size: 16),
                      label: Text(n),
                      selected: _icon == n,
                      onSelected: (_) => setState(() => _icon = n),
                    ),
                ]),
              ],
              if (widget.showRoute)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Linked page'),
                  subtitle: Text(routeLabelFor(_route)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if ((_route ?? '').isNotEmpty)
                      IconButton(tooltip: 'Clear page link', icon: const Icon(Icons.close), onPressed: () => setState(() => _route = null)),
                    const Icon(Icons.arrow_drop_down),
                  ]),
                  onTap: () async {
                    final r = await pickRoute(context, current: _route);
                    if (r != null) setState(() => _route = r.isEmpty ? null : r);
                  },
                ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: !widget.showIcon || _label.text.trim().isNotEmpty
                ? () => Navigator.pop(context, (_label.text, _route, _icon))
                : null,
            child: Text(widget.showIcon ? 'Add' : 'Save'),
          ),
        ],
      );
}
