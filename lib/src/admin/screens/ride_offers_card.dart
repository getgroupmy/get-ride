// Admin → App Settings → Ride offers (migration 0269): how many drivers'
// offers the rider sees at once (the rest wait in line), how long each
// lasts, the first sort, and whether a driver may offer again after a
// decline.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ride_offers.dart';
import '../../data/city_ride_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/search_select.dart';
import '../widgets/admin_widgets.dart';

/// A whole-number field of an admin card, with its limits in the helper.
class AdminNumberField extends StatelessWidget {
  const AdminNumberField({
    super.key,
    required this.controller,
    required this.label,
    required this.min,
    required this.max,
    this.enabled = true,
    this.decimal = false,
    this.onChanged,
    this.width = 240,
  });

  final TextEditingController controller;
  final String label;
  final num min, max;
  final bool enabled, decimal;
  final VoidCallback? onChanged;
  final double width;

  /// The value when it is a number within the limits, else null.
  static num? read(TextEditingController c, num min, num max, {bool decimal = false}) {
    final v = decimal ? double.tryParse(c.text.trim()) : int.tryParse(c.text.trim());
    return v == null || v < min || v > max ? null : v;
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        decoration: InputDecoration(labelText: label, helperText: '$min to $max'),
        onChanged: (_) => onChanged?.call(),
      ),
    ),
  );
}

class RideOffersCard extends ConsumerStatefulWidget {
  const RideOffersCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<RideOffersCard> createState() => _RideOffersCardState();
}

class _RideOffersCardState extends ConsumerState<RideOffersCard> {
  final _shown = TextEditingController();
  final _lifetime = TextEditingController();
  OfferSort _sort = OfferSort.cheapest;
  bool _reoffer = true;
  OfferSettings? _loaded;

  @override
  void dispose() {
    _shown.dispose();
    _lifetime.dispose();
    super.dispose();
  }

  void _load(OfferSettings s) {
    if (_loaded == s) return;
    _loaded = s;
    _shown.text = '${s.shown}';
    _lifetime.text = '${s.lifetime.inSeconds}';
    _sort = s.sort;
    _reoffer = s.reofferAfterDecline;
  }

  OfferSettings? _draft() {
    final shown = AdminNumberField.read(_shown, OfferSettings.minShown, OfferSettings.maxShown);
    final life = AdminNumberField.read(_lifetime, OfferSettings.minLifetime, OfferSettings.maxLifetime);
    if (shown == null || life == null) return null;
    return OfferSettings(
      shown: shown.toInt(),
      lifetime: Duration(seconds: life.toInt()),
      sort: _sort,
      reofferAfterDecline: _reoffer,
    );
  }

  Future<void> _save() async {
    final d = _draft();
    if (d == null) {
      showInfo(context, 'Check the numbers: each must be within its limits.');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(cityRideRepositoryProvider).saveConfig('offers', d.toJson()),
      success: 'Ride offers saved',
    );
    if (ok && mounted) ref.invalidate(cityRideConfigProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('ride-offers-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(cityRideConfigProvider),
          onRetry: () => ref.invalidate(cityRideConfigProvider),
          data: (c) {
            _load(c.offers);
            final draft = _draft();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Ride offers', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Several drivers can offer on one request at once. When the rider accepts one, the others are '
                  'told the ride is taken and their cards slide away.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                AdminNumberField(
                  key: const ValueKey('ride-offers-shown'),
                  controller: _shown,
                  label: 'Offers shown at once',
                  min: OfferSettings.minShown,
                  max: OfferSettings.maxShown,
                  enabled: widget.canEdit,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: 8),
                AdminNumberField(
                  key: const ValueKey('ride-offers-lifetime'),
                  controller: _lifetime,
                  label: 'Each offer lasts (seconds)',
                  min: OfferSettings.minLifetime,
                  max: OfferSettings.maxLifetime,
                  enabled: widget.canEdit,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: 240,
                    child: SearchableDropdownFormField<OfferSort>(
                      key: const ValueKey('ride-offers-sort'),
                      initialValue: _sort,
                      decoration: const InputDecoration(labelText: 'Sort first by', helperText: 'The rider can change it'),
                      items: [for (final s in OfferSort.values) DropdownMenuItem(value: s, child: Text(s.label))],
                      onChanged: widget.canEdit ? (v) => setState(() => _sort = v ?? _sort) : null,
                    ),
                  ),
                ),
                SwitchListTile(
                  key: const ValueKey('ride-offers-reoffer'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Driver can offer again after a decline'),
                  subtitle: const Text('Once. A second decline is final for that request.'),
                  value: _reoffer,
                  onChanged: widget.canEdit ? (v) => setState(() => _reoffer = v) : null,
                ),
                if (widget.canEdit)
                  BusyButton.filled(
                    key: const ValueKey('ride-offers-save'),
                    onPressed: draft == c.offers ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save ride offers'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
