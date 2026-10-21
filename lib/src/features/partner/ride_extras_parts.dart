// The ride extras a driver takes (migration 0253): Settings → Ride extras I
// take, the "Passenger added extras" check before an offer or Accept, and
// the feed's "not shown" line. Everything is on until the driver turns it
// off; a request carrying an extra they turned off never reaches them.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../../core/driver_services.dart' show guideDogExtraKey;
import '../../core/ride_extras.dart';
import '../../data/driver_extras_repository.dart';
import '../../data/models.dart';
import '../../data/ride_option_providers.dart';
import '../../data/ride_pet_repository.dart' show petConfigProvider;
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';

/// Settings → Ride extras I take (partners only).
class RideExtrasSettingsTile extends ConsumerWidget {
  const RideExtrasSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(partnerProvider).value == null) return const SizedBox.shrink();
    final off = ref.watch(myExtrasOffProvider).value ?? const <String>{};
    return Card(
      child: ListTile(
        key: const ValueKey('ride-extras-settings'),
        leading: const Icon(Icons.pets_outlined),
        title: const Text('Ride extras I take'),
        subtitle: Text(off.isEmpty ? 'All of them' : '${off.length} turned off'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/account/settings/ride-extras'),
      ),
    );
  }
}

/// One switch for each pet type, each kind of help, a child safety seat
/// and more passengers. Each change is saved at once.
class RideExtrasScreen extends ConsumerWidget {
  const RideExtrasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = rideExtraGroups(
      ref.watch(rideOptionsConfigProvider),
      ref.watch(petConfigProvider),
      ref.watch(assistanceCatalogueProvider),
    );
    final count = groups.fold<int>(0, (n, g) => n + g.items.length);
    return Scaffold(
      appBar: AppBar(title: const Text('Ride extras I take')),
      body: AsyncView(
        value: ref.watch(myExtrasOffProvider),
        onRetry: () => ref.invalidate(myExtrasOffProvider),
        data: (off) {
          final t = Theme.of(context);
          Future<void> set(String key, bool on) async {
            try {
              await ref.read(driverExtrasRepositoryProvider).setMine(on ? ({...off}..remove(key)) : {...off, key});
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
            ref.invalidate(myExtrasOffProvider);
          }

          return ListView(padding: const EdgeInsets.symmetric(vertical: 12), children: [
            ResponsiveCenter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    'Requests with an extra you turn off are not offered to you. Everything is on until you turn it off.',
                    style: t.textTheme.bodyMedium?.copyWith(color: mutedTextColor(t)),
                  ),
                ),
                ListSearchFilter(
                  count: count,
                  hint: 'Search extras',
                  fieldKey: const ValueKey('ride-extras-search'),
                  builder: (context, q) {
                    final l = q.toLowerCase();
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final g in groups)
                        if (g.items.any((i) => l.isEmpty || i.label.toLowerCase().contains(l) || g.title.toLowerCase().contains(l)))
                          Card(
                            key: ValueKey('ride-extras-group-${g.option.id}'),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                                child: Text(g.title, style: t.textTheme.titleSmall),
                              ),
                              for (final i in g.items)
                                if (l.isEmpty || i.label.toLowerCase().contains(l) || g.title.toLowerCase().contains(l))
                                  BusySwitchListTile(
                                    key: ValueKey('ride-extra-${i.key}'),
                                    title: Text(g.items.length == 1 && i.label == g.title ? 'I take these' : i.label),
                                    // The guide dog is always taken (0263).
                                    subtitle: i.key == guideDogExtraKey ? const Text('Always on: required by law') : null,
                                    value: i.key == guideDogExtraKey || !off.contains(i.key),
                                    onChanged: i.key == guideDogExtraKey ? null : (v) => set(i.key, v),
                                  ),
                            ]),
                          ),
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

/// The driver's answer to "Passenger added extras": whether to go on, and
/// the extras to stop showing (saved either way).
typedef RideExtrasAnswer = ({bool go, Set<String> stop});

/// "Passenger added extras" before an offer ([accepting] false) or Accept
/// on [r]; null for a request without extras (go straight on).
Future<RideExtrasAnswer?> askRideExtras(BuildContext context, RideRequest r, {required bool accepting}) async {
  final extras = r.extras;
  if (extras.isEmpty) return null;
  final answer = await showAppDialog<RideExtrasAnswer>(
    id: 'partner.ride-extras',
    context: context,
    builder: (_) => RideExtrasDialog(extras: extras, accepting: accepting),
  );
  return answer ?? (go: false, stop: const <String>{});
}

class RideExtrasDialog extends StatefulWidget {
  const RideExtrasDialog({super.key, required this.extras, required this.accepting});

  final List<RideExtra> extras;
  final bool accepting;

  @override
  State<RideExtrasDialog> createState() => _RideExtrasDialogState();
}

class _RideExtrasDialogState extends State<RideExtrasDialog> {
  final _stop = <String>{};

  void _close(bool go) => Navigator.pop<RideExtrasAnswer>(context, (go: go, stop: {..._stop}));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final action = widget.accepting ? 'Accept' : 'Offer fare';
    return PopScope(
      canPop: false,
      // A tap outside or Back is Cancel: the ticked boxes are still saved.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close(false);
      },
      child: AlertDialog(
        key: const ValueKey('ride-extras-dialog'),
        title: const Text('Passenger added extras'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final x in widget.extras)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.info_outline, size: 20, color: t.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(x.line, key: ValueKey('ride-extras-line-${x.key}'))),
                  ]),
                ),
              const SizedBox(height: 8),
              Text(
                "Only ${widget.accepting ? 'accept' : 'offer'} if you can take these. Don't want rides like this? "
                "Turn them off and they won't show again.",
                style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t, background: t.dialogTheme.backgroundColor)),
              ),
              for (final x in widget.extras)
                if (x.key != guideDogExtraKey)
                CheckboxListTile(
                  key: ValueKey('ride-extras-stop-${x.key}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('Stop showing ${x.label} rides'),
                  value: _stop.contains(x.key),
                  onChanged: (v) => setState(() => v == true ? _stop.add(x.key) : _stop.remove(x.key)),
                ),
            ]),
          ),
        ),
        actions: [
          TextButton(key: const ValueKey('ride-extras-cancel'), onPressed: () => _close(false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('ride-extras-go'), onPressed: () => _close(true), child: Text(action)),
        ],
      ),
    );
  }
}

/// The extras in [keys] turned off for the signed-in driver; quiet on
/// failure (the answer to the request itself already went through).
Future<void> stopRideExtras(WidgetRef ref, Set<String> keys) async {
  if (keys.isEmpty) return;
  try {
    await ref.read(driverExtrasRepositoryProvider).turnOff(keys);
  } catch (_) {
    return;
  }
  ref.invalidate(myExtrasOffProvider);
}

/// How many open requests the feed leaves out for an extra the driver
/// turned off; read again with the feed.
final hiddenExtrasCountProvider = FutureProvider.autoDispose.family<int, String>((ref, feed) async {
  final off = await ref.watch(myExtrasOffProvider.future);
  if (off.isEmpty) return 0;
  return ref.read(driverExtrasRepositoryProvider).hiddenCount(DateTime.now().subtract(AppConfig.requestExpiry));
});

/// "1 request not shown: it includes an extra you turned off."
class HiddenExtrasLine extends ConsumerWidget {
  const HiddenExtrasLine({super.key, this.feed = ''});

  /// What the feed shows now (its request ids): a new list reads the count
  /// again.
  final String feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = hiddenExtrasText(ref.watch(hiddenExtrasCountProvider(feed)).value ?? 0);
    if (text == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return InkWell(
      key: const ValueKey('hidden-extras-line'),
      onTap: () => context.push('/account/settings/ride-extras'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Icon(Icons.visibility_off_outlined, size: 18, color: mutedTextColor(t)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)))),
        ]),
      ),
    );
  }
}
