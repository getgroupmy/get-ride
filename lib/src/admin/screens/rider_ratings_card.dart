// Admin → App Settings → Rider ratings (migration 0269): drivers rate riders
// after a trip; the rider's average is over their last N ratings, a rider
// with few ratings shows as "New rider", and a low average as "Low".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/rider_rating.dart';
import '../../data/city_ride_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';
import 'ride_offers_card.dart' show AdminNumberField;

class RiderRatingsCard extends ConsumerStatefulWidget {
  const RiderRatingsCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<RiderRatingsCard> createState() => _RiderRatingsCardState();
}

class _RiderRatingsCardState extends ConsumerState<RiderRatingsCard> {
  final _window = TextEditingController();
  final _newBelow = TextEditingController();
  final _lowBelow = TextEditingController();
  RiderRatingSettings? _loaded;

  @override
  void dispose() {
    _window.dispose();
    _newBelow.dispose();
    _lowBelow.dispose();
    super.dispose();
  }

  void _load(RiderRatingSettings s) {
    if (_loaded == s) return;
    _loaded = s;
    _window.text = '${s.window}';
    _newBelow.text = '${s.newBelow}';
    _lowBelow.text = s.lowBelow.toStringAsFixed(1);
  }

  RiderRatingSettings? _draft() {
    final w = AdminNumberField.read(_window, 5, 1000);
    final n = AdminNumberField.read(_newBelow, 0, 50);
    final l = AdminNumberField.read(_lowBelow, 1, 5, decimal: true);
    if (w == null || n == null || l == null) return null;
    return RiderRatingSettings(window: w.toInt(), newBelow: n.toInt(), lowBelow: (l * 10).round() / 10);
  }

  Future<void> _save() async {
    final d = _draft();
    if (d == null) {
      showInfo(context, 'Check the numbers: each must be within its limits.');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(cityRideRepositoryProvider).saveConfig('riderRating', d.toJson()),
      success: 'Rider ratings saved',
    );
    if (ok && mounted) ref.invalidate(cityRideConfigProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('rider-ratings-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(cityRideConfigProvider),
          onRetry: () => ref.invalidate(cityRideConfigProvider),
          data: (c) {
            _load(c.riderRating);
            final draft = _draft();
            void edited() => setState(() {});
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Rider ratings', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Drivers rate the rider after a trip (optional, up to 24 hours after). Drivers see the rider\'s '
                  'rating and trips on each request; riders see their own rating on Profile. The server works out '
                  'the average.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                AdminNumberField(
                  key: const ValueKey('rider-ratings-window'),
                  controller: _window,
                  label: 'Average over the last (ratings)',
                  min: 5,
                  max: 1000,
                  enabled: widget.canEdit,
                  onChanged: edited,
                ),
                const SizedBox(height: 8),
                AdminNumberField(
                  key: const ValueKey('rider-ratings-new'),
                  controller: _newBelow,
                  label: 'Show "New rider" until they have (ratings)',
                  min: 0,
                  max: 50,
                  enabled: widget.canEdit,
                  onChanged: edited,
                  width: 320,
                ),
                const SizedBox(height: 8),
                AdminNumberField(
                  key: const ValueKey('rider-ratings-low'),
                  controller: _lowBelow,
                  label: 'Mark rating as low below',
                  min: 1,
                  max: 5,
                  decimal: true,
                  enabled: widget.canEdit,
                  onChanged: edited,
                ),
                const SizedBox(height: 12),
                if (widget.canEdit)
                  BusyButton.filled(
                    key: const ValueKey('rider-ratings-save'),
                    onPressed: draft == c.riderRating ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save rider ratings'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
