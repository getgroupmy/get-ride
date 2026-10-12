// "My Ride" (rider): the favourite drivers a booking can go to first. A
// driver is added by their My Ride code or its QR; the page lists them with
// how to reach them, and its settings hold the distance limit and whether
// a booking starts with My Ride on.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/my_ride.dart';
import '../../data/my_ride_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_host.dart';
import '../wallet/wallet_qr_screens.dart' show scannerTorchProvider, scannerTorchAvailable;
import 'my_ride_parts.dart';
import 'my_ride_settings.dart';

class MyRideScreen extends ConsumerWidget {
  const MyRideScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(myFavouriteDriversProvider);
    final available = list.value != null;
    return Scaffold(
      appBar: AppBar(
        leading: context.canPop() ? null : sideMenuLeading(context),
        title: const Text('My Ride'),
        actions: [
          if (available)
            IconButton(
              key: const ValueKey('my-ride-settings'),
              tooltip: 'My Ride settings',
              icon: const Icon(Icons.tune),
              onPressed: () => context.push('/account/my-ride/settings'),
            ),
        ],
      ),
      floatingActionButton: available
          ? FloatingActionButton.extended(
              key: const ValueKey('my-ride-add'),
              onPressed: () => showAddFavouriteSheet(context),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add driver'),
            )
          : null,
      body: AsyncView(
        value: list,
        onRetry: () => ref.invalidate(myFavouriteDriversProvider),
        data: (drivers) {
          if (drivers == null) {
            return const EmptyState(
              key: ValueKey('my-ride-unavailable'),
              icon: Icons.favorite_border,
              title: "My Ride isn't available yet",
              message: 'Favourite drivers are coming soon. Please check back later.',
            );
          }
          if (drivers.isEmpty) return const _Empty();
          final ordered = myRidePickOrder(drivers);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myFavouriteDriversProvider),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                ResponsiveCenter(
                  maxWidth: 760,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: _Intro()),
                      Card(
                        margin: const EdgeInsets.all(12),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            for (final (i, d) in ordered.indexed) ...[
                              if (i > 0) const Divider(height: 1, indent: 76),
                              FavouriteDriverTile(
                                key: ValueKey('favourite-${d.driverId}'),
                                driver: d,
                                trailing: IconButton(
                                  key: ValueKey('favourite-remove-${d.driverId}'),
                                  tooltip: 'Remove ${d.name}',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _remove(context, ref, d),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          '${drivers.length} of $myRideMaxFavourites favourite drivers',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, FavouriteDriver d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: const Text("They won't get your My Ride requests any more. You can add them again with their code."),
        actions: [
          TextButton(
            key: const ValueKey('favourite-remove-cancel'),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('favourite-remove-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(myRideRepositoryProvider).remove(d.driverId);
      ref.invalidate(myFavouriteDriversProvider);
      if (context.mounted) showInfo(context, '${d.name} removed from My Ride.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Text(
      'Book with My Ride on and your request goes to these drivers first. '
      "If none of them takes it in time, it opens to every driver nearby.",
      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget step(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: t.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
        ],
      ),
    );
    return ListView(
      key: const ValueKey('my-ride-empty'),
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 96),
      children: [
        ResponsiveCenter(
          maxWidth: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.favorite_border, size: 56, color: t.colorScheme.outline),
              const SizedBox(height: 12),
              Text('Keep the drivers you like', style: t.textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              step(Icons.qr_code_2, 'Ask your driver for their My Ride code or QR.'),
              step(Icons.person_add_alt_1_outlined, 'Tap Add driver and enter the code, or scan the QR.'),
              step(
                Icons.favorite_outline,
                'When you book, turn on My Ride: your drivers see the request first, '
                'then it opens to everybody nearby.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Adding a driver -------------------------------------------------------------

/// The "Add driver" sheet: enter the code or scan its QR.
Future<void> showAddFavouriteSheet(BuildContext context, {String? code}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (c) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
    child: AddFavouriteSheet(initialCode: code),
  ),
);

class AddFavouriteSheet extends ConsumerStatefulWidget {
  const AddFavouriteSheet({super.key, this.initialCode});
  final String? initialCode;

  @override
  ConsumerState<AddFavouriteSheet> createState() => _AddFavouriteSheetState();
}

class _AddFavouriteSheetState extends ConsumerState<AddFavouriteSheet> {
  late final _code = TextEditingController(text: widget.initialCode ?? '');
  bool _busy = false;
  String? _error;
  FavouriteDriver? _added;
  bool _addedNoCard = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialCode != null) WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit([String? raw]) async {
    if (_busy) return;
    final input = raw ?? _code.text;
    final code = parseMyRideCode(input);
    if (code == null) {
      setState(() => _error = AddFavouriteError.invalidCode.message);
      return;
    }
    _code.text = formatMyRideCode(code);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(myRideRepositoryProvider).addByCode(code);
      if (!mounted) return;
      switch (result) {
        case FavouriteAdded(:final driver):
          ref.invalidate(myFavouriteDriversProvider);
          HapticFeedback.mediumImpact();
          setState(() {
            _added = driver;
            _addedNoCard = driver == null;
          });
        case FavouriteNotAdded(:final error, :final retryAfter):
          setState(() => _error = addFavouriteMessage(error, retryAfter: retryAfter));
        case MyRideNotAvailable():
          setState(() => _error = myRideUnavailableMessage);
      }
    } catch (e) {
      if (mounted) setState(() => _error = AddFavouriteError.unknown.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const MyRideScanScreen(), fullscreenDialog: true));
    if (raw == null || !mounted) return;
    await _submit(raw);
  }

  void _again() => setState(() {
    _added = null;
    _addedNoCard = false;
    _code.clear();
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final added = _added;
    if (added != null || _addedNoCard) {
      return ResponsiveCenter(
        maxWidth: 520,
        child: Padding(
          key: const ValueKey('favourite-added'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.check_circle, color: t.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      added == null ? 'Driver added to My Ride' : '${added.name} added to My Ride',
                      style: t.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              if (added != null) ...[
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: FavouriteDriverTile(driver: added),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('favourite-added-done'),
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
              TextButton(onPressed: _again, child: const Text('Add another')),
            ],
          ),
        ),
      );
    }
    return ResponsiveCenter(
      maxWidth: 520,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add a driver', style: t.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Ask your driver for their My Ride code: 8 letters and numbers.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('favourite-code'),
              controller: _code,
              enabled: !_busy,
              autofocus: widget.initialCode == null,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 40,
              style: t.textTheme.titleMedium?.copyWith(letterSpacing: 2),
              decoration: InputDecoration(
                labelText: 'My Ride code',
                hintText: 'ABCD EFGH',
                counterText: '',
                prefixIcon: const Icon(Icons.keyboard_outlined),
                errorText: _error,
                errorMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('favourite-code-add'),
              onPressed: _busy ? null : () => _submit(),
              child: _busy
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Add driver'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('favourite-scan'),
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Scanning -------------------------------------------------------------------

/// The camera view the scan screen shows; overridden in tests (there is
/// no camera there). Calls `onCode` with each code seen.
final myRideScanViewProvider =
    Provider<Widget Function(MobileScannerController controller, ValueChanged<String> onCode)>(
      (ref) =>
          (controller, onCode) => MobileScanner(
            controller: controller,
            onDetect: (c) {
              for (final b in c.barcodes) {
                final v = b.rawValue;
                if (v != null && v.trim().isNotEmpty) {
                  onCode(v);
                  break;
                }
              }
            },
            errorBuilder: (_, e) => ColoredBox(
              color: Colors.black,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    e.errorCode == MobileScannerErrorCode.permissionDenied
                        ? 'Camera access is off. Allow it in your settings to scan, or paste the code below.'
                        : 'The camera is not available here. Paste the code below instead.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
    );

/// Scans a driver's My Ride QR; pops with the code (or what was pasted).
class MyRideScanScreen extends ConsumerStatefulWidget {
  const MyRideScanScreen({super.key});

  @override
  ConsumerState<MyRideScanScreen> createState() => _MyRideScanScreenState();
}

class _MyRideScanScreenState extends ConsumerState<MyRideScanScreen> {
  final _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final _manual = TextEditingController();
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _scanner.dispose();
    _manual.dispose();
    super.dispose();
  }

  void _seen(String raw) {
    if (_done) return;
    final code = parseMyRideCode(raw);
    if (code == null) {
      setState(() => _error = "That isn't a My Ride QR. Ask your driver to show their My Ride code.");
      return;
    }
    _done = true;
    HapticFeedback.mediumImpact();
    Navigator.pop(context, code);
  }

  Future<void> _toggleTorch() async {
    try {
      await ref.read(scannerTorchProvider)(_scanner);
    } catch (_) {
      if (mounted) showInfo(context, "The flashlight isn't available right now.");
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (!mounted) return;
    _manual.text = text.trim();
    if (text.trim().isNotEmpty) _seen(text);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan My Ride QR'),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _scanner,
            builder: (_, state, _) {
              final on = state.torchState == TorchState.on;
              final available = scannerTorchAvailable(state);
              return IconButton(
                key: const ValueKey('my-ride-scan-torch'),
                tooltip: !available
                    ? 'No flashlight on this device'
                    : on
                    ? 'Turn flashlight off'
                    : 'Turn flashlight on',
                isSelected: on,
                icon: const Icon(Icons.flashlight_off_outlined),
                selectedIcon: const Icon(Icons.flashlight_on),
                onPressed: available ? _toggleTorch : null,
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ResponsiveCenter(
            maxWidth: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: ref.watch(myRideScanViewProvider)(_scanner, _seen),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  "Point the camera at your driver's My Ride QR.",
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    key: const ValueKey('my-ride-scan-error'),
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('my-ride-scan-manual'),
                  controller: _manual,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Or paste the code',
                    prefixIcon: IconButton(
                      key: const ValueKey('my-ride-scan-paste'),
                      tooltip: 'Paste',
                      icon: const Icon(Icons.content_paste),
                      onPressed: _paste,
                    ),
                    suffixIcon: IconButton(
                      key: const ValueKey('my-ride-scan-go'),
                      tooltip: 'Continue',
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: () => _seen(_manual.text),
                    ),
                  ),
                  onSubmitted: _seen,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Settings -------------------------------------------------------------------

class MyRideSettingsScreen extends ConsumerWidget {
  const MyRideSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final settings = ref.watch(myRideSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My Ride settings')),
      body: AsyncView(
        value: settings,
        onRetry: () => ref.invalidate(myRideSettingsProvider),
        data: (s) {
          void set(MyRideSettings Function(MyRideSettings current) change) {
            ref.read(myRideSettingsProvider.notifier).edit(change).catchError((Object e) {
              if (context.mounted) showError(context, e);
            });
          }

          return ListView(
            children: [
              ResponsiveCenter(
                maxWidth: 640,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      key: const ValueKey('my-ride-default-on'),
                      title: const Text('Turn on My Ride by default when booking'),
                      subtitle: const Text('Bookings start with your available drivers picked.'),
                      value: s.onByDefault,
                      onChanged: (v) => set((c) => c.copyWith(onByDefault: v)),
                    ),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text('Maximum distance', style: t.textTheme.titleMedium),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        'Only drivers this close to your pickup get your request first. '
                        'Drivers whose location is unknown still get it.',
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    RadioGroup<double?>(
                      groupValue: s.maxKm,
                      onChanged: (v) => set((c) => c.copyWith(maxKm: () => v)),
                      child: Column(
                        children: [
                          for (final km in myRideMaxKmChoices)
                            RadioListTile<double?>(
                              key: ValueKey('my-ride-max-${km?.round() ?? 0}'),
                              value: km,
                              title: Text(myRideMaxKmLabel(km)),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
