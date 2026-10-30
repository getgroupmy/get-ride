// myGiG on the driver's home (migration 0329): the button, the side-menu
// row and the line on the online card lead here. The button explains when
// myGiG is off for the driver or at the daily limit, asks for a pass when
// get.ride charges by the period, else opens the myGiG sheet: show the
// booking QR (GET.now), enter the trip, or the myGiG settings.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/mygig.dart';
import '../../data/mygig_repository.dart';
import '../../widgets/app_notice.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

/// Where myGiG lives in the driver app.
const mygigNewPath = '/drive/mygig';
const mygigSettingsPath = '/drive/mygig/settings';
const mygigPassPath = '/drive/mygig/pass';

/// The driver taps myGiG (button or menu) at [lat]/[lng].
Future<void> openMygig(BuildContext context, WidgetRef ref, {double? lat, double? lng}) async {
  MygigConfig c;
  try {
    c = await ref.read(mygigRepositoryProvider).config(lat: lat, lng: lng);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  ref.invalidate(mygigConfigProvider);
  final blocked = mygigBlockedDialog(c);
  if (blocked != null) {
    await showAppNotice(id: 'notice.mygig', context: context, title: blocked.title, message: blocked.message);
    return;
  }
  if (!c.offered) {
    await showAppNotice(
      id: 'notice.mygig',
      context: context,
      title: 'myGiG isn’t offered here',
      message: c.message ?? 'myGiG isn’t offered for your Partner Service type here.',
    );
    return;
  }
  if (c.needsPass) {
    await context.push(mygigPassPath);
    return;
  }
  await showMygigSheet(context, c);
}

/// The myGiG sheet: does the passenger have the app with them?
Future<void> showMygigSheet(BuildContext context, MygigConfig c) => showAppSheet<void>(
  id: 'mygig.start',
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheet) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        key: const ValueKey('mygig-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text('myGiG', style: Theme.of(sheet).textTheme.titleLarge),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text('A passenger stopped you. Do they have the get.ride app with them?'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Row(children: [
              Icon(Icons.verified_user_outlined, size: 16, color: Theme.of(sheet).colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(child: Text(mygigPlanLine(c.fee, c.pass), style: Theme.of(sheet).textTheme.bodySmall)),
            ]),
          ),
          if (c.settings.qrChoice)
            ListTile(
              key: const ValueKey('mygig-sheet-qr'),
              leading: const Icon(Icons.qr_code_2),
              title: const Text('Yes, show my booking QR'),
              subtitle: const Text('They scan it and book you in their app'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final router = GoRouter.of(sheet);
                Navigator.pop(sheet);
                router.push('/account/my-qr');
              },
            ),
          ListTile(
            key: const ValueKey('mygig-sheet-enter'),
            leading: const Icon(Icons.edit_location_alt_outlined),
            title: const Text('No, I\'ll enter the trip'),
            subtitle: const Text('Set the trip and send them the fare'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final router = GoRouter.of(sheet);
              Navigator.pop(sheet);
              router.push(mygigNewPath);
            },
          ),
          ListTile(
            key: const ValueKey('mygig-sheet-settings'),
            leading: const Icon(Icons.tune),
            title: const Text('myGiG settings'),
            subtitle: const Text('Fare, luggage, busy times, waiting, no-show'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final router = GoRouter.of(sheet);
              Navigator.pop(sheet);
              router.push(mygigSettingsPath);
            },
          ),
        ],
      ),
    ),
  ),
);

/// The line on the driver's online card: "myGiG today: 3 of 10 · Pass until …".
class MygigTodayLine extends ConsumerWidget {
  const MygigTodayLine({super.key, this.lat, this.lng});
  final double? lat, lng;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(mygigConfigProvider(mygigAt(lat, lng))).value;
    if (c == null || !c.offered) return const SizedBox.shrink();
    final t = Theme.of(context);
    final extra = c.offForDriver
        ? ' · Off for you'
        : c.fee.isPeriod
            ? (c.pass != null ? ' · Pass until ${formatDayDate(c.pass!.endsAt).replaceAll(RegExp(r' \d{4}$'), '')}' : ' · No pass')
            : '';
    final bad = c.atLimit || c.offForDriver;
    return ListTile(
      key: const ValueKey('mygig-today'),
      dense: true,
      leading: const Icon(Icons.hail),
      title: Text('${c.todayText}$extra',
          style: t.textTheme.bodyMedium?.copyWith(color: bad ? t.colorScheme.error : null)),
      onTap: () => openMygig(context, ref, lat: lat, lng: lng),
    );
  }
}

/// Whether the myGiG button and menu row show for the driver here: their
/// type allows myGiG and there is no active trip (the home has none).
bool mygigButtonShows(MygigConfig? c) => c != null && c.offered && c.code != 'ACTIVE_TRIP';

/// myGiG pass: when get.ride charges by the day, week, month, 6 months or
/// year, the first myGiG of the period buys one, from GET.credit or GET.wallet.
class MygigPassScreen extends ConsumerStatefulWidget {
  const MygigPassScreen({super.key});

  @override
  ConsumerState<MygigPassScreen> createState() => _MygigPassScreenState();
}

class _MygigPassScreenState extends ConsumerState<MygigPassScreen> {
  bool _wallet = false;

  Future<void> _buy(MygigConfig c) async {
    try {
      final pass = await ref.read(mygigRepositoryProvider).buyPass(fromWallet: _wallet);
      if (!mounted) return;
      ref.invalidate(mygigConfigProvider);
      await showAppNotice(
        id: 'notice.mygig',
        context: context,
        kind: NoticeKind.success,
        title: 'myGiG pass ready',
        message: '${mygigMoney(c.fee.amount)} paid. Take myGiG rides until '
            '${pass == null ? 'the end of the period' : formatDayDate(pass.endsAt)}'
            '${c.fee.mode == MygigFeeMode.day ? ', 11:59 pm' : ''}.',
      );
      if (!mounted) return;
      final fresh = await ref.read(mygigRepositoryProvider).config();
      if (!mounted) return;
      context.pop();
      await showMygigSheet(context, fresh);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(mygigConfigProvider(mygigAt(null, null)));
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('myGiG pass')),
      body: AsyncView(
        value: async,
        onRetry: () => ref.invalidate(mygigConfigProvider),
        data: (c) => ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(Icons.verified_user_outlined, size: 56, color: t.colorScheme.primary),
            const SizedBox(height: 12),
            Text('To take myGiG rides you need a pass.', textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
            const SizedBox(height: 12),
            Text(mygigMoney(c.fee.amount), key: const ValueKey('mygig-pass-amount'),
                textAlign: TextAlign.center, style: t.textTheme.displaySmall),
            Text('for ${mygigPassLength(c.fee.mode)}', textAlign: TextAlign.center, style: t.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'As many myGiG rides as you like until it ends. Daily limit and other rules still apply.'
              '${c.fee.own ? ' This is a rate get.ride set for you.' : ''}',
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('GET.credit')),
                ButtonSegment(value: true, label: Text('GET.wallet')),
              ],
              selected: {_wallet},
              onSelectionChanged: (s) => setState(() => _wallet = s.first),
            ),
            const SizedBox(height: 24),
            BusyButton.filled(
              key: const ValueKey('mygig-pass-buy'),
              icon: const Icon(Icons.check),
              onPressed: c.fee.isPeriod ? () => _buy(c) : null,
              child: Text('Get pass · ${mygigMoney(c.fee.amount)}'),
            ),
          ],
        ),
      ),
    );
  }
}
