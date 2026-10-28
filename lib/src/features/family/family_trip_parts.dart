// Family on a trip screen (migration 0317), any module: the "Shared with
// family" chip and who can see the trip (only while the host can see it),
// "Paid with Family", the child's pickup code for the parent, and the
// driver's check of a child passenger (photo and code, with tries).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/family.dart';
import '../../core/format.dart' show formatMoney;
import '../../data/family_repository.dart';
import '../../data/rider_live_map_repository.dart' show riderLiveMapRepositoryProvider;
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/net_image.dart';

String _m(num v) => formatMoney(v);

/// The chip: shown exactly while the family host can see this trip. A tap
/// shows or hides who can see it.
class SharedWithFamilyChip extends StatelessWidget {
  const SharedWithFamilyChip({super.key, required this.onTap, this.open = false});
  final VoidCallback onTap;
  final bool open;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      expanded: open,
      child: ActionChip(
        key: const ValueKey('family-shared-chip'),
        avatar: Icon(Icons.family_restroom, size: 18, color: c.primary),
        label: const Text('Shared with family'),
        labelStyle: TextStyle(color: c.primary, fontWeight: FontWeight.w600),
        backgroundColor: c.primaryContainer.withValues(alpha: 0.5),
        side: BorderSide(color: c.primary),
        onPressed: onTap,
      ),
    );
  }
}

/// "Who can see this ride".
class WhoCanSeeCard extends StatelessWidget {
  const WhoCanSeeCard({super.key, required this.status, this.onStop});
  final FamilyTripStatus status;

  /// Stops sharing the trip; shown to the member on it.
  final Future<void> Function()? onStop;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('family-who-can-see'),
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Who can see this ride', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (final l in whoCanSeeLines(status))
            Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(l, style: t.textTheme.bodyMedium)),
          // The member stops sharing this trip at once (rider live map, 0322).
          if (status.mine && onStop != null)
            Align(
              alignment: Alignment.centerLeft,
              child: BusyButton.text(
                key: const ValueKey('family-stop-sharing'),
                onPressed: onStop,
                child: const Text('Stop sharing this trip'),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Family on a trip screen of any module: nothing unless the trip is a
/// family one.
class FamilyTripStrip extends ConsumerStatefulWidget {
  const FamilyTripStrip({super.key, required this.tripId, this.host = false});
  final String tripId;

  /// The screen is the booker's (the host's for a child's trip): shows the pickup code.
  final bool host;

  @override
  ConsumerState<FamilyTripStrip> createState() => _FamilyTripStripState();
}

class _FamilyTripStripState extends ConsumerState<FamilyTripStrip> {
  bool _who = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(familyTripStatusProvider(widget.tripId)).value;
    if (s == null || !s.family) return const SizedBox.shrink();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      key: const ValueKey('family-trip-strip'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (s.shared) ...[
          SharedWithFamilyChip(open: _who, onTap: () => setState(() => _who = !_who)),
          if (_who)
            WhoCanSeeCard(
              status: s,
              onStop: () async {
                try {
                  await ref.read(riderLiveMapRepositoryProvider).stopSharing(widget.tripId);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                  return;
                }
                ref.invalidate(familyTripStatusProvider(widget.tripId));
                if (mounted) setState(() => _who = false);
              },
            ),
        ],
        if (s.familyPays && s.payer != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Paid with ${familyPayLabel(s.payer!)}${s.left == null ? '' : ' (${_m(s.left!)} left this month)'}',
              key: const ValueKey('family-paid-line'),
              style: TextStyle(color: muted),
            ),
          ),
        if (s.child && widget.host) FamilyChildCodeCard(tripId: widget.tripId),
      ]),
    );
  }
}

/// The parent's view of their child's pickup code.
class FamilyChildCodeCard extends ConsumerWidget {
  const FamilyChildCodeCard({super.key, required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(familyChildCodeProvider(tripId)).value;
    if (c == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final who = c.name?.split(' ').first ?? 'Your child';
    return Card(
      key: const ValueKey('family-child-code'),
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          Text('$who\'s pickup code', style: TextStyle(color: muted)),
          const SizedBox(height: 4),
          Text(
            c.spaced,
            key: const ValueKey('family-child-code-digits'),
            style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 8),
          ),
          const SizedBox(height: 4),
          Text(
            c.verified
                ? 'Code checked. You get a message at pickup and drop-off.'
                : c.locked
                    ? 'The code was wrong too many times. Call the driver, then give a new code.'
                    : 'The ride can\'t start without the code. You get a message at pickup and drop-off.',
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: muted),
          ),
          if (!c.verified)
            BusyButton.text(
              key: const ValueKey('family-child-code-new'),
              onPressed: () async {
                try {
                  await ref.read(familyRepositoryProvider).newChildCode(tripId);
                  ref.invalidate(familyChildCodeProvider(tripId));
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: const Text('New code'),
            ),
        ]),
      ),
    );
  }
}

/// The driver's check of a child passenger before the trip starts: the
/// photo, who booked, and the 4-digit code (a few tries, then the parent is
/// called and the trip waits). [onVerified] once the code is right.
class DriverChildCheck extends ConsumerStatefulWidget {
  const DriverChildCheck({super.key, required this.tripId, this.onVerified});
  final String tripId;
  final VoidCallback? onVerified;

  @override
  ConsumerState<DriverChildCheck> createState() => _DriverChildCheckState();
}

class _DriverChildCheckState extends ConsumerState<DriverChildCheck> {
  final _code = TextEditingController();
  String? _line;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final code = _code.text.trim();
    if (!isPickupCode(code)) {
      setState(() => _line = 'Enter the 4 digits.');
      return;
    }
    try {
      final r = await ref.read(familyRepositoryProvider).verifyPickupCode(widget.tripId, code);
      if (!mounted) return;
      ref.invalidate(familyDriverChildProvider(widget.tripId));
      setState(() {
        _line = r.ok
            ? 'Code correct. The parent is following this ride.'
            : r.locked
                ? 'Wrong code too many times: the parent gets a call and the ride waits.'
                : 'Wrong code. ${r.triesLeft} ${r.triesLeft == 1 ? 'try' : 'tries'} left.';
      });
      _code.clear();
      if (r.ok) widget.onVerified?.call();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = ref.watch(familyDriverChildProvider(widget.tripId)).value;
    if (child == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final warm = t.brightness == Brightness.dark ? const Color(0xFF3A2A12) : const Color(0xFFFDF2E3);
    return Card(
      key: const ValueKey('family-driver-child'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Child passenger', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: warm, borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              if (child.photoUrl != null) ...[
                NetImage(child.photoUrl!, width: 56, height: 56, circle: true),
                const SizedBox(width: 12),
              ],
              Expanded(child: Text(child.intro, style: t.textTheme.bodyMedium)),
            ]),
          ),
          const SizedBox(height: 10),
          if (child.verified)
            Text('Code correct. The parent is following this ride.',
                key: const ValueKey('family-driver-child-ok'), style: TextStyle(color: t.colorScheme.primary))
          else if (child.locked)
            Text('Wrong code too many times: the parent gets a call and the ride waits for a new code.',
                key: const ValueKey('family-driver-child-locked'), style: TextStyle(color: t.colorScheme.error))
          else ...[
            CodeField(
              key: const ValueKey('family-driver-child-code'),
              controller: _code,
              length: 4,
              autofocus: false,
              label: 'Pickup code',
            ),
            const SizedBox(height: 8),
            BusyButton.filled(
              key: const ValueKey('family-driver-child-check'),
              onPressed: _check,
              child: const Text('Check code'),
            ),
          ],
          if (_line != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_line!, key: const ValueKey('family-driver-child-line')),
            ),
        ]),
      ),
    );
  }
}
