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

import '../../../core/option_charge.dart';
import '../../../core/ride_assistance.dart';
import '../../../core/ride_option_settings.dart';
import '../../../core/ride_pets.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'demo_accounts.dart';
import 'display_logic.dart';
import '../../../core/demo_mode.dart' show demoDriverIdsKey, demoRiderIdsKey;
import 'display_store.dart';
import 'ride_option_places_screen.dart' show RideOptionPlacesScreen;
import '../../../core/ride_option_places.dart' show OptionChargeKey;
import '../../../data/ride_option_places_repository.dart' show rideOptionPlacesRepositoryProvider;
import 'pick_image.dart';
import '../../../core/raise_nudge.dart';
import '../../../core/sheet_min_height.dart';
import 'test_accounts.dart';
import '../../../widgets/net_image.dart';
import '../../../widgets/page_style_host.dart';
import '../../../widgets/search_select.dart';

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
    'teksi-ev': 'Car',
    'wallet': 'Wallet',
    'emergency-contacts': 'Phone',
    'invite-friends': 'Gift',
    'city': 'Car',
    'request-history': 'Clock',
    'scheduled-rides': 'Clock',
    'my-ride': 'Heart',
    'my-qr': 'Tag',
    'freight': 'Truck',
    'notifications': 'Bell',
    'safety': 'Shield',
    'settings': 'Settings',
    'user-guide': 'BookOpen',
    'support': 'MessageCircle',
    'logout': 'User',
  },
  'partner': {
    'teksi-ev': 'Car',
    'wallet': 'Wallet',
    'vehicle-information': 'Car',
    'my-qr': 'Tag',
    'dashboard': 'Settings',
    'my-ride-code': 'Star',
    'earnings': 'Wallet',
    'trip-history': 'Clock',
    'scheduled-rides': 'Clock',
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

    // Bottom sheet minimum height: the estimate follows the switches above,
    // and only the admin's adjustment is stored.
    Widget sheetMin(String key) => SheetMinHeightTile(
          settingKey: key,
          settings: s,
          onChanged: canEdit
              ? (v) => applyDisplay(
                  context, ref, (x) => setDisplayNumber(x, key, v, sheetMinAdjustMinFor(key), sheetMinAdjustMax))
              : null,
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
              const Divider(height: 1),
              sheetMin(homeSheetMinAdjustKey),
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
          const _Section('Ride Search'),
          Card(
            child: _StepperTile(
              label: 'Offer a fare raise after',
              description: 'Seconds with no driver offer before a bidding ride\'s search sheet suggests raising the fare '
                  '($raiseNudgeMinSeconds-$raiseNudgeMaxSeconds)',
              value: displayNum(s, raiseNudgeKey),
              min: raiseNudgeMinSeconds,
              max: raiseNudgeMaxSeconds,
              step: 5,
              unit: 's',
              onChanged: canEdit
                  ? (v) => applyDisplay(
                      context, ref, (x) => setDisplayNumber(x, raiseNudgeKey, v, raiseNudgeMinSeconds, raiseNudgeMaxSeconds))
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
              toggle(
                  'Ask before adding a stop',
                  'On = after working out a new stop, show its additional cost and time with Add or Cancel. '
                      'Off = the stop is added straight away.',
                  displayBool(s, 'addStopConfirm'),
                  (v) => set('addStopConfirm', v)),
              toggle('Show "Use GET.coin"', 'Let riders pay part of the fare with their coins',
                  displayBool(s, 'confirmShowCoin'), (v) => set('confirmShowCoin', v)),
              toggle('Show "Book for someone else"', "Let riders book with another person's name and phone",
                  displayBool(s, 'confirmShowBookForOther'), (v) => set('confirmShowBookForOther', v)),
              toggle('Show "My Ride"', 'Let riders offer the ride to their favourite drivers first',
                  displayBool(s, 'confirmShowMyRide'), (v) => set('confirmShowMyRide', v)),
              toggle('Show "Auto-accept offer"', 'Let riders accept a driver offer at their fare without tapping (bidding rides)',
                  displayBool(s, 'confirmShowAutoAccept'), (v) => set('confirmShowAutoAccept', v)),
              for (final i in rideConfirmLayoutItems) stepper(i),
              sheetMin(confirmSheetMinAdjustKey),
            ]),
          ),
          const _Section('Ride Options'),
          RideOptionsCard(settings: s, canEdit: canEdit),
          const _Section('Ride Tracking Layout'),
          Card(
            child: Column(children: [
              for (final i in rideTrackingLayoutItems) stepper(i),
              sheetMin(trackingSheetMinAdjustKey),
            ]),
          ),
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
                  'When on, nobody sees demo driver offers, bids, and "viewing" avatars while searching for a ride. '
                      'When off, only the demo riders below get them',
                  !displayBool(s, 'userMockEnabled'),
                  (v) => set('userMockEnabled', !v)),
              DemoAccountsSection(
                settings: s,
                listKey: demoRiderIdsKey,
                title: 'Demo riders',
                help: 'With Mockup (User) on, Find driver for these accounts books a demo request on their phone '
                    'alone: demo drivers answer it and the trip is a demo. Nothing is saved, sent or seen by a real '
                    'driver. No one listed means no one gets demo offers (before, every rider did).',
                canEdit: canEdit,
              ),
              const Divider(height: 1),
              toggle(
                  'Turn off Mockup (Partner)',
                  'When on, no driver receives demo/auto-generated incoming ride requests. When off, only the demo '
                      'drivers below get them while online',
                  !displayBool(s, 'partnerMockEnabled'),
                  (v) => set('partnerMockEnabled', !v)),
              DemoAccountsSection(
                settings: s,
                listKey: demoDriverIdsKey,
                title: 'Demo drivers',
                help: 'With Mockup (Partner) on, these accounts get demo incoming requests while online. No one '
                    'listed means no one gets them (before, every online driver did).',
                canEdit: canEdit,
              ),
            ]),
          ),
          TestAccountsCard(canEdit: canEdit),
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
                  onTap: () => Navigator.of(context).push(AppPageRoute(id: 'display.stepper',
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
            tooltip: 'Decrease',
            icon: const Icon(Icons.remove),
            onPressed: onChanged == null || value <= min ? null : () => onChanged!(value - step),
          ),
          SizedBox(
            width: 64,
            child: Text('$value${unit ?? ''}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          BusyIconButton(
            tooltip: 'Increase',
            icon: const Icon(Icons.add),
            onPressed: onChanged == null || value >= max ? null : () => onChanged!(value + step),
          ),
        ]),
      );
}

/// "Bottom sheet minimum height" for one sheet: the estimated least height
/// (what the shown items need, plus the admin's adjustment), how it adds
/// up, − and + to change the adjustment and "Back to automatic" to clear it.
class SheetMinHeightTile extends StatelessWidget {
  const SheetMinHeightTile({super.key, required this.settingKey, required this.settings, required this.onChanged});

  /// One of the `…SheetMinAdjust` display keys.
  final String settingKey;
  final Map<String, dynamic> settings;

  /// Stores a new adjustment; null for a viewer.
  final Future<void> Function(num)? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = sheetMinEstimate(settings, settingKey);
    final change = onChanged;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        title: const Text('Bottom sheet minimum height'),
        subtitle: const Text('How much of the sheet shows when pulled all the way down. It follows the items shown; '
            'the minus and plus buttons add to or take from it'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          BusyIconButton(
            key: ValueKey('$settingKey-decrease'),
            tooltip: 'Decrease',
            icon: const Icon(Icons.remove),
            onPressed: change == null || e.atFloor || e.adjust <= sheetMinAdjustMinFor(settingKey)
                ? null
                : () => change(e.adjust - sheetMinAdjustStep),
          ),
          SizedBox(
            width: 72,
            child: Text(
              '${e.total} px',
              key: ValueKey('$settingKey-value'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          BusyIconButton(
            key: ValueKey('$settingKey-increase'),
            tooltip: 'Increase',
            icon: const Icon(Icons.add),
            onPressed: change == null || e.adjust >= sheetMinAdjustMax
                ? null
                : () => change(e.adjust + sheetMinAdjustStep),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          e.breakdown,
          key: ValueKey('$settingKey-breakdown'),
          style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t, background: cardSurfaceColor(t))),
        ),
      ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: BusyButton.text(
            key: ValueKey('$settingKey-reset'),
            onPressed: change == null || e.adjust == 0 ? null : () => change(0),
            child: const Text('Back to automatic'),
          ),
        ),
      ),
    ]);
  }
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
              final picked = await showSearchPicker<String>(
                context,
                title: 'Choose Service',
                selected: (cfg['serviceId'] as String?) ?? '',
                choices: [
                  (value: '', label: 'Default', subtitle: null, leading: null),
                  for (final svc in services)
                    (
                      value: svc['id'] as String,
                      label: '${(svc['values'] as Map?)?['name'] ?? 'Unnamed'}',
                      subtitle: null,
                      leading: null,
                    ),
                ],
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
      img = Image.network(src, fit: BoxFit.cover, frameBuilder: boneUntilPainted(), errorBuilder: (_, _, _) => fallback());
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
              tooltip: 'Move up',
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: !canEdit || i == 0 ? null : () => applyDisplay(context, ref, (x) => moveVehicleInBar(x, ids[i], -1, ids)),
            ),
            BusyIconButton(
              tooltip: 'Move down',
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
    final add = canEdit
        ? PageAddAction(
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
        : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(menu == 'user' ? 'User Side Menu' : 'Partner Side Menu'),
        actions: pageAddActions(context, add),
      ),
      floatingActionButton: pageAddFab(context, add),
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

          return ListView(padding: EdgeInsets.fromLTRB(0, 16, 0, addActionListBottomPadding(context)), children: [
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

// ---------------------------------------------------------------------------
// Ride Options
// ---------------------------------------------------------------------------

/// Where the charges went: Ride Options → Charges and where offered.
class _ChargesByPlaceNote extends StatelessWidget {
  const _ChargesByPlaceNote();

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          key: const ValueKey('charges-by-place'),
          leading: const Icon(Icons.payments_outlined),
          title: const Text('Charges and where offered'),
          subtitle: const Text('Set by place: Default (everywhere), or a country, state, city or suburb.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openOptionPlaces(context),
        ),
      );
}

/// Ride Options → Charges and where offered.
Future<void> _openOptionPlaces(BuildContext context) => Navigator.of(context).push(AppPageRoute(id: 'display.ride-option-places',
      builder: (_) => const RideOptionPlacesScreen(),
    ));

/// One line of text in a dialog: the trimmed text when saved, null when
/// cancelled.
class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.label, required this.initial, this.helper, this.problem});
  final String title;
  final String label;
  final String initial;
  final String? helper;
  final String? Function(String)? problem;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _text = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final e = widget.problem?.call(_text.text);
    if (e != null) return setState(() => _error = e);
    Navigator.pop(context, _text.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 420,
          child: TextField(
            key: const ValueKey('text-dialog-field'),
            controller: _text,
            autofocus: true,
            decoration: InputDecoration(labelText: widget.label, helperText: widget.helper, errorText: _error),
            onSubmitted: (_) => _save(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('text-dialog-save'), onPressed: _save, child: const Text('Save')),
        ],
      );
}

/// Up and down arrows for a row that can be moved.
Widget _moveArrows({required String key, VoidCallback? up, VoidCallback? down}) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(key: ValueKey('$key-up'), onTap: up, child: const Icon(Icons.keyboard_arrow_up, size: 20)),
        InkWell(key: ValueKey('$key-down'), onTap: down, child: const Icon(Icons.keyboard_arrow_down, size: 20)),
      ],
    );

/// Admin → Display Settings → Ride Options: each option on the rider's
/// Options sheet shown or hidden, renamed and moved, with its own settings
/// under it. With every option hidden the Options button goes.
class RideOptionsCard extends ConsumerWidget {
  const RideOptionsCard({super.key, required this.settings, required this.canEdit});
  final Map<String, dynamic> settings;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final c = rideOptionsOf(settings);
    final pets = petConfigOf(settings);
    final help = assistanceOf(settings);
    final rules = OptionChargeRules.fromSettings(settings);
    final muted = mutedTextColor(t, background: cardSurfaceColor(t));
    Future<void> edit(DisplayEdit e) => applyDisplay(context, ref, e);

    Widget settingsRow(String key, String title, String subtitle, VoidCallback onTap) => ListTile(
          key: ValueKey(key),
          contentPadding: const EdgeInsets.only(left: 56, right: 16),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        );

    return Card(
      key: const ValueKey('ride-options-card'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'The options riders pick beside Find a driver. Switch one off to hide it, use the arrows to reorder and '
            'the pencil to rename it; riders and drivers both see the new name. Comments always stays, so the '
            'Options button is always there.',
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
        for (var i = 0; i < c.order.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          () {
            final k = c.order[i];
            final renamed = c.labels.containsKey(k);
            return ListTile(
              key: ValueKey('ride-option-${k.id}'),
              leading: _moveArrows(
                key: 'ride-option-${k.id}',
                up: !canEdit || i == 0 ? null : () => edit((x) => moveRideOption(x, k, -1)),
                down: !canEdit || i == c.order.length - 1 ? null : () => edit((x) => moveRideOption(x, k, 1)),
              ),
              title: Text(c.labelOf(k), key: ValueKey('ride-option-label-${k.id}')),
              subtitle: renamed ? Text('Built-in name: ${k.defaultLabel}') : null,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (canEdit)
                  BusyIconButton(
                    key: ValueKey('ride-option-rename-${k.id}'),
                    tooltip: 'Rename',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () async {
                      final name = await showAppDialog<String>(id: 'display.rename-ride-option',
                        context: context,
                        builder: (_) => _TextDialog(
                          title: 'Rename option',
                          label: 'Name riders see',
                          initial: c.labelOf(k),
                          helper: 'Leave it empty for "${k.defaultLabel}".',
                          problem: (v) => v.trim().length > RideOptionsConfig.labelMax
                              ? 'Keep it under ${RideOptionsConfig.labelMax} characters.'
                              : null,
                        ),
                      );
                      if (name != null && context.mounted) await edit((x) => renameRideOption(x, k, name));
                    },
                  ),
                BusySwitch(
                  key: ValueKey('ride-option-shown-${k.id}'),
                  value: c.isShown(k),
                  onChanged: canEdit ? (v) => edit((x) => setRideOptionShown(x, k, v)) : null,
                ),
              ]),
            );
          }(),
          if (c.order[i] == RideOptionKind.childSeat)
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: KeyedSubtree(
                key: const ValueKey('child-seat-max'),
                child: _StepperTile(
                  label: 'Most seats a rider can ask for',
                  description: 'Above 1 the rider picks how many seats instead of a switch; the driver sees the '
                      'number (1-${RideOptionsConfig.childSeatLimit})',
                  value: c.childSeatMax,
                  min: 1,
                  max: RideOptionsConfig.childSeatLimit,
                  step: 1,
                  onChanged: canEdit ? (v) => edit((x) => setChildSeatMax(x, v)) : null,
                ),
              ),
            ),
          if (c.order[i] == RideOptionKind.pet)
            settingsRow(
              'ride-option-pet-settings',
              'Pet types and sizes',
              '${pets.types.length} ${pets.types.length == 1 ? 'type' : 'types'} · sizes ${pets.sizes.join(', ')} · '
                  'up to ${pets.maxPerType} of a type · photo ${pets.photoRequired ? 'required' : 'optional'}',
              () => Navigator.of(context).push(AppPageRoute(id: 'display.pet-options',
                builder: (_) => const PetOptionsScreen(),
              )),
            ),
          if (c.order[i] == RideOptionKind.assistance)
            settingsRow(
              'ride-option-assistance-settings',
              'Help offered',
              '${help.items.length} ${help.items.length == 1 ? 'item' : 'items'}, ${help.visible.length} shown',
              () => Navigator.of(context).push(AppPageRoute(id: 'display.assistance-options',
                builder: (_) => const AssistanceOptionsScreen(),
              )),
            ),
        ],
        const Divider(height: 1),
        // Comments can't be hidden: riders can always write to the driver.
        const ListTile(
          key: ValueKey('ride-option-comments'),
          leading: SizedBox(width: 20),
          title: Text('Comments'),
          subtitle: Text('Always shown: riders can always leave the driver a note'),
          trailing: Icon(Icons.lock_outline),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Charges', style: t.textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: Text(
            'Option charges are part of the fare. Set them, switch an option off or block it on some services for '
            'everywhere or for a country, state, city or suburb.',
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
        ListTile(
          key: const ValueKey('ride-option-places'),
          leading: const Icon(Icons.map_outlined),
          title: const Text('Charges and where offered'),
          subtitle: const Text('By place: Default (everywhere), then each country, state, city or suburb'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openOptionPlaces(context),
        ),
        BusySwitchListTile(
          key: const ValueKey('option-charges-commission'),
          title: const Text('Commission applies to option charges'),
          subtitle: const Text('Off: commission is worked out on the fare less the option charges'),
          value: rules.commission,
          onChanged: canEdit ? (v) => edit((x) => setOptionChargeRules(x, commission: v)) : null,
        ),
        BusySwitchListTile(
          key: const ValueKey('option-charges-promo'),
          title: const Text('Promo codes discount option charges'),
          subtitle: const Text('Off: a promo code discounts the fare less the option charges'),
          value: rules.promo,
          onChanged: canEdit ? (v) => edit((x) => setOptionChargeRules(x, promo: v)) : null,
        ),
      ]),
    );
  }
}

/// Pet types (add, rename, remove, reorder; names only), the sizes offered
/// and their extras, the most of one type, whether a photo is a must, and
/// each type's charge. Writes PetConfig's keys.
class PetOptionsScreen extends ConsumerWidget {
  const PetOptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    return Scaffold(
      appBar: AppBar(title: const Text('Pet with me')),
      body: AsyncView(
        value: ref.watch(displaySettingsProvider),
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (s) {
          final t = Theme.of(context);
          final c = petConfigOf(s);
          Future<void> edit(DisplayEdit e) => applyDisplay(context, ref, e);
          return ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            ResponsiveCenter(
              maxWidth: 820,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const _ChargesByPlaceNote(),
                const _Section('Pet types'),
                Card(
                  child: ListSearchFilter(
                    count: c.types.length,
                    hint: 'Search pet types',
                    fieldKey: const ValueKey('pet-types-search'),
                    builder: (context, q) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (var i = 0; i < c.types.length; i++)
                        if (q.isEmpty || c.types[i].toLowerCase().contains(q.toLowerCase()))
                          ListTile(
                            key: ValueKey('pet-type-${c.types[i]}'),
                            leading: _moveArrows(
                              key: 'pet-type-${c.types[i]}',
                              up: !canEdit || i == 0 ? null : () => edit((x) => movePetType(x, c.types[i], -1)),
                              down: !canEdit || i == c.types.length - 1
                                  ? null
                                  : () => edit((x) => movePetType(x, c.types[i], 1)),
                            ),
                            title: Text(c.types[i]),
                            trailing: canEdit
                                ? Row(mainAxisSize: MainAxisSize.min, children: [
                                    BusyIconButton(
                                      key: ValueKey('pet-type-edit-${c.types[i]}'),
                                      tooltip: 'Edit',
                                      icon: const Icon(Icons.edit_outlined),
                                      onPressed: () async {
                                        final type = c.types[i];
                                        final name = await _editPetType(context, c, type: type);
                                        if (name != null && context.mounted) {
                                          await edit((x) => updatePetType(x, type, name: name));
                                          // Its charges by place go with it.
                                          if (name != type && context.mounted) {
                                            await runAdminAction(
                                              context,
                                              () => ref.read(rideOptionPlacesRepositoryProvider)
                                                  .renameCharge(OptionChargeKey.pet(type), OptionChargeKey.pet(name)),
                                            );
                                          }
                                        }
                                      },
                                    ),
                                    BusyIconButton(
                                      key: ValueKey('pet-type-remove-${c.types[i]}'),
                                      tooltip: 'Remove',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: c.types.length <= 1
                                          ? null
                                          : () async {
                                              final type = c.types[i];
                                              if (!await confirm(context, 'Remove pet type', 'Remove "$type"?',
                                                  ok: 'Remove')) {
                                                return;
                                              }
                                              if (context.mounted) await edit((x) => removePetType(x, type));
                                            },
                                    ),
                                  ])
                                : null,
                          ),
                    ]),
                  ),
                ),
                if (canEdit)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: BusyButton.text(
                      key: const ValueKey('pet-type-add'),
                      icon: const Icon(Icons.add),
                      onPressed: c.types.length >= PetConfig.maxTypes
                          ? null
                          : () async {
                              final name = await _editPetType(context, c);
                              if (name != null && context.mounted) await edit((x) => addPetType(x, name));
                            },
                      child: const Text('Add pet type'),
                    ),
                  ),
                const _Section('Sizes'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('Sizes offered', style: t.textTheme.labelLarge),
                      const SizedBox(height: 6),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final z in PetConfig.defaultSizes)
                          FilterChip(
                            key: ValueKey('pet-size-offered-$z'),
                            label: Text(z),
                            selected: c.sizes.contains(z),
                            onSelected: canEdit ? (v) => edit((x) => setPetSizeOffered(x, z, v)) : null,
                          ),
                      ]),
                    ]),
                  ),
                ),
                const _Section('Pets on a ride'),
                Card(
                  child: Column(children: [
                    KeyedSubtree(
                      key: const ValueKey('pet-max-per-type'),
                      child: _StepperTile(
                        label: 'Most pets of one type',
                        description: 'How many of one type a rider can bring (1-${PetConfig.maxPerTypeLimit})',
                        value: c.maxPerType,
                        min: 1,
                        max: PetConfig.maxPerTypeLimit,
                        step: 1,
                        onChanged: canEdit ? (v) => edit((x) => setPetMaxPerType(x, v)) : null,
                      ),
                    ),
                    BusySwitchListTile(
                      key: const ValueKey('pet-photo-required'),
                      title: const Text('Photo of each pet required'),
                      subtitle: const Text('When on, Done waits for a photo of every pet'),
                      value: c.photoRequired,
                      onChanged: canEdit ? (v) => edit((x) => setPetPhotoRequired(x, v)) : null,
                    ),
                  ]),
                ),
                const SizedBox(height: 32),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}


/// The pet type dialog: its name (a new type when [type] is null). Null
/// when cancelled. Its charges are set by place (Charges and where offered).
Future<String?> _editPetType(BuildContext context, PetConfig c, {String? type}) =>
    showAppDialog<String>(id: 'display.pet-type',
      context: context,
      builder: (_) => _PetTypeDialog(config: c, type: type),
    );

class _PetTypeDialog extends StatefulWidget {
  const _PetTypeDialog({required this.config, this.type});
  final PetConfig config;
  final String? type;

  @override
  State<_PetTypeDialog> createState() => _PetTypeDialogState();
}

class _PetTypeDialogState extends State<_PetTypeDialog> {
  late final _name = TextEditingController(text: widget.type ?? '');
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final others = [for (final o in widget.config.types) if (o != widget.type) o];
    final problem = petTypeProblem(_name.text, others);
    if (problem != null) return setState(() => _error = problem);
    Navigator.pop(context, cleanPetTypeName(_name.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.type == null ? 'Add pet type' : 'Edit pet type'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              key: const ValueKey('pet-type-name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Bird',
                helperText: 'A name only, no emoji',
                errorText: _error,
              ),
              onSubmitted: (_) => _save(),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('pet-type-save'), onPressed: _save, child: const Text('Save')),
        ],
      );
}

/// The assistance catalogue: every kind of help offered, by group, each
/// with an emoji, a name, a short description and optional choices; added,
/// edited, hidden, reordered and removed here. Charges are set by place.
class AssistanceOptionsScreen extends ConsumerWidget {
  const AssistanceOptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(pageAccessProvider(displayPage)) == AccessLevel.edit;
    final value = ref.watch(displaySettingsProvider);
    final add = canEdit
        ? PageAddAction(
            icon: const Icon(Icons.add),
            label: const Text('Add help'),
            onPressed: () async {
              final s = value.value;
              if (s == null) return;
              final item = await _editAssistanceItem(context, assistanceOf(s));
              if (item != null && context.mounted) await applyDisplay(context, ref, (x) => addAssistanceItem(x, item));
            },
          )
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Assistance required'), actions: pageAddActions(context, add)),
      floatingActionButton: pageAddFab(context, add),
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(displaySettingsProvider),
        data: (s) {
          final t = Theme.of(context);
          final muted = mutedTextColor(t, background: cardSurfaceColor(t));
          final c = assistanceOf(s);
          Future<void> edit(DisplayEdit e) => applyDisplay(context, ref, e);
          return ListView(padding: EdgeInsets.fromLTRB(0, 16, 0, addActionListBottomPadding(context)), children: [
            ResponsiveCenter(
              maxWidth: 820,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const _ChargesByPlaceNote(),
                Text(
                  'What riders can ask for under "Assistance required". Each one shows its emoji on the rider\'s sheet; '
                  'choices make the rider pick one. A guide or service dog is always free.',
                  style: t.textTheme.bodySmall,
                ),
                if (c.items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No help offered: the option is hidden from riders until you add some.'),
                  ),
                ListSearchFilter(
                  count: c.items.length,
                  hint: 'Search help',
                  fieldKey: const ValueKey('assist-admin-search'),
                  builder: (context, q) {
                    final l = q.toLowerCase();
                    final shown = [
                      for (final i in c.items)
                        if (l.isEmpty || i.name.toLowerCase().contains(l) || i.group.toLowerCase().contains(l)) i,
                    ];
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final g in AssistanceCatalogue.byGroup(shown).entries) ...[
                        _Section(g.key),
                        for (final item in g.value)
                          () {
                            final inGroup = [for (final i in c.items) if (i.group == item.group) i.id];
                            final at = inGroup.indexOf(item.id);
                            return Card(
                              key: ValueKey('assist-admin-${item.id}'),
                              child: ListTile(
                                leading: Text(item.emoji, style: const TextStyle(fontSize: 24)),
                                title: Text(item.name),
                                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  if (item.description.isNotEmpty) Text(item.description),
                                  if (item.choices.isNotEmpty)
                                    Text('Choices: ${item.choices.join(' / ')}', style: TextStyle(color: muted)),
                                  if (item.isGuideDog)
                                    Text(
                                      'Always free',
                                      key: ValueKey('assist-admin-charge-${item.id}'),
                                      style: TextStyle(color: muted),
                                    ),
                                  Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                                    BusyIconButton(
                                      key: ValueKey('assist-admin-up-${item.id}'),
                                      tooltip: 'Move up',
                                      icon: const Icon(Icons.keyboard_arrow_up),
                                      onPressed: !canEdit || at <= 0
                                          ? null
                                          : () => edit((x) => moveAssistanceItem(x, item.id, -1)),
                                    ),
                                    BusyIconButton(
                                      key: ValueKey('assist-admin-down-${item.id}'),
                                      tooltip: 'Move down',
                                      icon: const Icon(Icons.keyboard_arrow_down),
                                      onPressed: !canEdit || at >= inGroup.length - 1
                                          ? null
                                          : () => edit((x) => moveAssistanceItem(x, item.id, 1)),
                                    ),
                                    if (canEdit)
                                      BusyIconButton(
                                        key: ValueKey('assist-admin-edit-${item.id}'),
                                        tooltip: 'Edit',
                                        icon: const Icon(Icons.edit_outlined),
                                        onPressed: () async {
                                          final next = await _editAssistanceItem(context, c, item: item);
                                          if (next != null && context.mounted) {
                                            await edit((x) => updateAssistanceItem(x, next));
                                          }
                                        },
                                      ),
                                    if (canEdit)
                                      BusyIconButton(
                                        key: ValueKey('assist-admin-remove-${item.id}'),
                                        tooltip: 'Remove',
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () async {
                                          if (!await confirm(context, 'Remove help', 'Remove "${item.name}"? Rides '
                                              'already booked keep it.', ok: 'Remove')) {
                                            return;
                                          }
                                          if (context.mounted) await edit((x) => removeAssistanceItem(x, item.id));
                                        },
                                      ),
                                  ]),
                                ]),
                                trailing: BusySwitch(
                                  key: ValueKey('assist-admin-shown-${item.id}'),
                                  value: !item.hidden,
                                  onChanged: canEdit ? (v) => edit((x) => setAssistanceItemShown(x, item.id, v)) : null,
                                ),
                              ),
                            );
                          }(),
                      ],
                    ]);
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

/// The help item dialog: a new item when [item] is null. Null when
/// cancelled.
Future<AssistanceItem?> _editAssistanceItem(
  BuildContext context,
  AssistanceCatalogue c, {
  AssistanceItem? item,
}) =>
    showAppDialog<AssistanceItem>(id: 'display.assistance-item',
      context: context,
      builder: (_) => _AssistanceItemDialog(catalogue: c, item: item),
    );

class _AssistanceItemDialog extends StatefulWidget {
  const _AssistanceItemDialog({required this.catalogue, this.item});
  final AssistanceCatalogue catalogue;
  final AssistanceItem? item;

  @override
  State<_AssistanceItemDialog> createState() => _AssistanceItemDialogState();
}

class _AssistanceItemDialogState extends State<_AssistanceItemDialog> {
  late final AssistanceItem? _i = widget.item;
  late final _emoji = TextEditingController(text: _i?.emoji ?? '');
  late final _name = TextEditingController(text: _i?.name ?? '');
  late final _description = TextEditingController(text: _i?.description ?? '');
  late final _newGroup = TextEditingController();
  late final List<TextEditingController> _choices = [
    for (final c in _i?.choices ?? const <String>[]) TextEditingController(text: c),
  ];
  late String? _group = _i?.group ?? assistanceDefaultGroups.first;
  String? _error;

  bool get _guideDog => _i?.isGuideDog ?? false;

  /// The groups to pick from: the starting ones and any the admin made.
  List<String> get _groups => [
    ...assistanceDefaultGroups,
    for (final g in widget.catalogue.groups)
      if (!assistanceDefaultGroups.contains(g)) g,
  ];

  @override
  void dispose() {
    for (final c in [_emoji, _name, _description, _newGroup, ..._choices]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final group = (_group ?? _newGroup.text).trim();
    final choices = <String>[];
    for (final c in _choices) {
      final t = c.text.trim();
      if (t.isNotEmpty && !choices.contains(t)) choices.add(t);
    }
    final item = AssistanceItem(
      id: _i?.id ?? 'custom-${const Uuid().v4().substring(0, 8)}',
      name: _name.text.trim(),
      emoji: _emoji.text.trim(),
      description: _description.text.trim(),
      group: group,
      choices: choices,
      hidden: _i?.hidden ?? false,
      // Kept as it was: charges are set by place now.
      charge: _guideDog ? OptionCharge.none : (_i?.charge ?? OptionCharge.none),
    );
    final problem = assistanceItemProblem(item);
    if (problem != null) return setState(() => _error = problem);
    Navigator.pop(context, item);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      title: Text(_i == null ? 'Add help' : 'Edit help'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 72,
                child: TextField(
                  key: const ValueKey('assist-emoji'),
                  controller: _emoji,
                  maxLength: 8,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22),
                  decoration: const InputDecoration(labelText: 'Emoji', counterText: ''),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const ValueKey('assist-name'),
                  controller: _name,
                  autofocus: _i == null,
                  maxLength: assistanceNameMax,
                  decoration: const InputDecoration(labelText: 'Name', counterText: ''),
                ),
              ),
            ]),
            TextField(
              key: const ValueKey('assist-description'),
              controller: _description,
              maxLength: assistanceDescriptionMax,
              decoration: const InputDecoration(labelText: 'Short description', counterText: ''),
            ),
            const SizedBox(height: 12),
            Text('Group', style: t.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final g in _groups)
                ChoiceChip(
                  key: ValueKey('assist-group-chip-$g'),
                  label: Text(g),
                  selected: _group == g,
                  onSelected: (_) => setState(() => _group = g),
                ),
              ChoiceChip(
                key: const ValueKey('assist-group-new'),
                label: const Text('New group'),
                selected: _group == null,
                onSelected: (_) => setState(() => _group = null),
              ),
            ]),
            if (_group == null)
              TextField(
                key: const ValueKey('assist-group-name'),
                controller: _newGroup,
                maxLength: assistanceNameMax,
                decoration: const InputDecoration(labelText: 'New group name', counterText: ''),
              ),
            const SizedBox(height: 12),
            Text('Choices (optional)', style: t.textTheme.labelLarge),
            Text(
              'With choices the rider must pick one, e.g. the kind of wheelchair.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            for (var i = 0; i < _choices.length; i++)
              Row(children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('assist-choice-field-$i'),
                    controller: _choices[i],
                    maxLength: assistanceChoiceMax,
                    decoration: InputDecoration(labelText: 'Choice ${i + 1}', counterText: ''),
                  ),
                ),
                IconButton(
                  key: ValueKey('assist-choice-remove-$i'),
                  tooltip: 'Remove choice',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _choices.removeAt(i).dispose()),
                ),
              ]),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('assist-choice-add'),
                icon: const Icon(Icons.add),
                label: const Text('Add a choice'),
                onPressed: _choices.length >= 8 ? null : () => setState(() => _choices.add(TextEditingController())),
              ),
            ),
            const SizedBox(height: 8),
            if (_guideDog)
              Text(
                'A guide or service dog is always free.',
                key: const ValueKey('assist-always-free'),
                style: t.textTheme.bodyMedium,
              )
            else
              Text(
                'Its charge is set by place: Ride Options > Charges and where offered.',
                key: const ValueKey('assist-charge-by-place'),
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, key: const ValueKey('assist-error'), style: TextStyle(color: t.colorScheme.error)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('assist-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
