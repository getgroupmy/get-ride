// Admin → App Settings → Trip cancellation (migration 0191): how long a
// cancellation request waits for the other side before it lapses (the ride
// carries on), and whether one declined or not answered opens a support
// ticket.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ride_cancel.dart';
import '../../data/ride_cancel_config.dart';
import '../../providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

class TripCancellationCard extends ConsumerStatefulWidget {
  const TripCancellationCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  ConsumerState<TripCancellationCard> createState() => _TripCancellationCardState();
}

class _TripCancellationCardState extends ConsumerState<TripCancellationCard> {
  final _minutes = TextEditingController();
  bool? _openTicket;
  CancelRequestConfig? _loaded;

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  void _load(CancelRequestConfig c) {
    if (_loaded == c) return;
    _loaded = c;
    final m = c.timeout.inSeconds / 60;
    _minutes.text = m == m.roundToDouble() ? '${m.round()}' : m.toStringAsFixed(1);
    _openTicket = c.openTicket;
  }

  CancelRequestConfig? _draft() {
    final m = double.tryParse(_minutes.text.trim());
    if (m == null || m < 0.5 || m > 30) return null;
    return CancelRequestConfig(
      timeout: Duration(seconds: (m * 60).round()),
      openTicket: _openTicket ?? true,
    );
  }

  Future<void> _save() async {
    final c = _draft();
    if (c == null) {
      showInfo(context, 'The wait must be between 0.5 and 30 minutes.');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => saveCancelRequestConfig(ref.read(supabaseProvider), c),
      success: 'Trip cancellation saved',
    );
    if (ok && mounted) ref.invalidate(cancelRequestConfigProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('trip-cancellation-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(cancelRequestConfigProvider),
          onRetry: () => ref.invalidate(cancelRequestConfigProvider),
          data: (stored) {
            _load(stored);
            final draft = _draft();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Trip cancellation', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Once a driver has the ride, a request to cancel waits for the other side to answer. If nobody '
                  'answers in time it lapses: the ride carries on and the person who asked can ask again, contact '
                  'support or use SOS.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: 240,
                    child: TextField(
                      key: const ValueKey('trip-cancel-minutes'),
                      controller: _minutes,
                      enabled: widget.canEdit,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Wait for an answer (minutes)',
                        helperText: '0.5–30',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
                SwitchListTile(
                  key: const ValueKey('trip-cancel-ticket'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Open a support ticket'),
                  subtitle: const Text('When a request is declined or not answered, so ops sees the disputed trip.'),
                  value: _openTicket ?? true,
                  onChanged: widget.canEdit ? (v) => setState(() => _openTicket = v) : null,
                ),
                if (widget.canEdit)
                  BusyButton.filled(
                    key: const ValueKey('trip-cancel-save'),
                    onPressed: draft == stored ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save trip cancellation'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
