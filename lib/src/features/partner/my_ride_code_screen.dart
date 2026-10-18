// The driver's My Ride code (migration 0160): the QR passengers scan (or the
// code they type) to add the driver as a favourite, Share / Copy / Change
// code, and the riders who have added them, each of whom can be hidden.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/image_share.dart';
import '../../core/my_ride.dart';
import '../../data/my_ride_repository.dart';
import '../../providers.dart' show partnerProvider;
import '../../widgets/common.dart';
import '../../widgets/image_share.dart';
import '../../widgets/back_or_go_button.dart';
import '../../widgets/page_style_host.dart';

/// What a passenger is told the code is for.
const myRideCodeExplainer = 'Passengers scan this or type the code in My Ride to add you as their driver.';

/// The text shared with the QR image.
String myRideShareText(String code) =>
    'Add me as your driver on GET.ride: open My Ride and enter my code ${formatMyRideCode(code)}.\n'
    '${myRideQrPayload(code)}';

/// "Added 3 Oct 2026 · 4 rides together".
String favouriteRiderSubtitle(FavouriteRider r) => [
  if (r.addedAt != null) 'Added ${DateFormat('d MMM yyyy').format(r.addedAt!.toLocal())}',
  switch (r.ridesTogether) {
    0 => 'No rides together yet',
    1 => '1 ride together',
    final n => '$n rides together',
  },
].join(' · ');

class MyRideCodeScreen extends ConsumerStatefulWidget {
  const MyRideCodeScreen({super.key});

  @override
  ConsumerState<MyRideCodeScreen> createState() => _MyRideCodeScreenState();
}

class _MyRideCodeScreenState extends ConsumerState<MyRideCodeScreen> {
  /// The code just made by Change code, shown at once rather than after a
  /// refetch.
  String? _rotated;
  bool _rotating = false;

  /// Riders whose hide switch is on its way to the server.
  final _saving = <String>{};

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) showInfo(context, 'Code copied');
  }

  Future<void> _rotate() async {
    final ok = await showAppDialog<bool>(id: 'my-ride-code.rotate',
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('my-ride-rotate-confirm'),
        title: const Text('Change your code?'),
        content: const Text(
          'Your current code and QR stop working, so new passengers will need the new one.\n\n'
          'Passengers who already added you keep you: they are linked to you, not to the code.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('my-ride-rotate-ok'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Change code'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _rotating = true);
    try {
      final next = await ref.read(myRideRepositoryProvider).rotateCode();
      if (!mounted) return;
      if (next == null) {
        showInfo(context, "My Ride isn't available yet.");
        return;
      }
      setState(() => _rotated = next);
      ref.invalidate(myRideCodeProvider);
      showInfo(context, 'Your new code is ${formatMyRideCode(next)}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _rotating = false);
    }
  }

  Future<void> _setHidden(FavouriteRider r, bool hidden) async {
    if (hidden) {
      final ok = await showAppDialog<bool>(id: 'my-ride-code.set-hidden',
        context: context,
        builder: (c) => AlertDialog(
          key: const ValueKey('my-ride-hide-confirm'),
          title: Text('Hide ${r.name}?'),
          content: const Text(
            "Their requests won't be sent to you first and won't be starred for you. "
            "They aren't told: you just show as unavailable to them.\n\n"
            'You can unhide them here at any time.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('my-ride-hide-ok'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Hide'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _saving.add(r.riderId));
    try {
      final done = await ref.read(myRideRepositoryProvider).hideRider(r.riderId, hidden: hidden);
      if (!mounted) return;
      if (done == null) {
        showInfo(context, "My Ride isn't available yet.");
      } else if (!done) {
        showInfo(context, 'This passenger no longer has you as a favourite.');
      } else {
        showInfo(context, hidden ? '${r.name} is hidden' : '${r.name} can find you again');
      }
      ref.invalidate(myFavouriteRidersProvider);
      ref.invalidate(favouriteRiderIdsProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving.remove(r.riderId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = ref.watch(myRideCodeProvider);
    return Scaffold(
      appBar: AppBar(leading: const BackOrGoButton(fallback: '/drive'), title: const Text('My Ride code')),
      body: AsyncView<String?>(
        value: code,
        onRetry: () => ref.invalidate(myRideCodeProvider),
        data: (fetched) {
          final c = _rotated ?? fetched;
          // Riders can't add a driver who isn't approved yet: no code to show.
          if (!(ref.watch(partnerProvider).value?.approved ?? true)) {
            return const EmptyState(
              key: ValueKey('my-ride-after-approval'),
              icon: Icons.qr_code_2,
              title: 'Available after approval',
              message: 'Your My Ride code appears here once an admin approves your partner account.',
            );
          }
          if (c == null) {
            return const EmptyState(
              key: ValueKey('my-ride-unavailable'),
              icon: Icons.qr_code_2,
              title: 'My Ride is not available yet',
              message: 'Your My Ride code will appear here once it is switched on for your account.',
            );
          }
          return ListView(
            key: const ValueKey('my-ride-code-screen'),
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              ResponsiveCenter(child: _codeCard(c)),
              const SizedBox(height: 16),
              ResponsiveCenter(child: _riders()),
            ],
          );
        },
      ),
    );
  }

  Widget _codeCard(String code) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              myRideCodeExplainer,
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, box) {
                // Big, but never wider than the card leaves room for.
                final size = (box.maxWidth - 32).clamp(140.0, 260.0);
                return Center(
                  // White in dark mode too, with a quiet zone, so it scans.
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: QrImageView(
                      key: const ValueKey('my-ride-qr'),
                      data: myRideQrPayload(code),
                      size: size,
                      padding: EdgeInsets.zero,
                      backgroundColor: Colors.white,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Text('YOUR CODE', textAlign: TextAlign.center, style: t.textTheme.labelSmall?.copyWith(letterSpacing: 1.5)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: SelectableText(
                formatMyRideCode(code),
                key: const ValueKey('my-ride-code'),
                textAlign: TextAlign.center,
                style: t.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ShareSaveImageButtons(
              keyPrefix: 'my-ride',
              image: (origin) async => ShareableImage(
                png: await ref.read(qrPngRendererProvider)(
                  myRideQrPayload(code),
                  caption: 'My Ride code ${formatMyRideCode(code)}',
                ),
                fileName: pngFileName('getride-my-ride-$code'),
                text: myRideShareText(code),
                subject: 'My GET.ride code',
                origin: origin,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('my-ride-copy'),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy code'),
                  onPressed: () => _copy(code),
                ),
                // Not a busy button: it would spin behind the confirm dialog.
                OutlinedButton.icon(
                  key: const ValueKey('my-ride-rotate'),
                  icon: const Icon(Icons.autorenew),
                  label: const Text('Change code'),
                  onPressed: _rotating ? null : _rotate,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _riders() {
    final t = Theme.of(context);
    final riders = ref.watch(myFavouriteRidersProvider);
    return Card(
      key: const ValueKey('my-ride-riders'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: Text('Passengers who added you', style: t.textTheme.titleMedium),
            subtitle: const Text("Hide one and their requests aren't sent to you first or starred."),
          ),
          ...riders.when(
            skipLoadingOnReload: true,
            loading: () => const [
              Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
            error: (e, _) => [
              ListTile(
                leading: const Icon(Icons.cloud_off),
                title: const Text("Couldn't load your passengers"),
                trailing: TextButton(
                  onPressed: () => ref.invalidate(myFavouriteRidersProvider),
                  child: const Text('Retry'),
                ),
              ),
            ],
            data: (list) => list == null || list.isEmpty
                ? [
                    const ListTile(
                      key: ValueKey('my-ride-no-riders'),
                      leading: Icon(Icons.people_outline),
                      title: Text('No passengers yet'),
                      subtitle: Text('Share your code and they will show here once they add you.'),
                    ),
                  ]
                : [for (final r in list) _riderTile(r)],
          ),
        ],
      ),
    );
  }

  Widget _riderTile(FavouriteRider r) {
    final t = Theme.of(context);
    final saving = _saving.contains(r.riderId);
    return ListTile(
      key: ValueKey('my-ride-rider-${r.riderId}'),
      leading: CircleAvatar(child: Icon(r.hidden ? Icons.visibility_off_outlined : Icons.person_outline)),
      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        r.hidden ? 'Hidden · ${favouriteRiderSubtitle(r)}' : favouriteRiderSubtitle(r),
        style: r.hidden ? t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant) : null,
      ),
      // On: hidden.
      trailing: Tooltip(
        message: r.hidden ? 'Unhide ${r.name}' : 'Hide ${r.name}',
        child: Switch(
          key: ValueKey('my-ride-hide-${r.riderId}'),
          value: r.hidden,
          onChanged: saving ? null : (v) => _setHidden(r, v),
        ),
      ),
    );
  }
}
