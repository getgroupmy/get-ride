// Admin → God View (migration 0282): the details panel's "Update" beside
// the phone's last report, "Live now" with its lengths and countdown, the
// map's "Live · every 5 s" badge, and the pencil by Phone's dialog. The
// rules are in core/god_view_live.dart; the page keeps the state.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../core/auth_utils.dart' show composePhone;
import '../../core/dial_countries.dart';
import '../../core/god_view.dart' show GodViewPerson;
import '../../core/god_view_live.dart';
import '../../core/phone_input.dart' show NoTrunkZeroFormatter;
import '../../widgets/common.dart';
import '../../widgets/dial_country_picker.dart';

/// A person streaming "Live now": red, light or dark.
Color godViewLiveColor(Brightness b) => b == Brightness.dark ? const Color(0xFFFF5A5F) : const Color(0xFFE0262E);

/// The phone's details came: green, light or dark (as "Online, free").
Color _fresh(Brightness b) => b == Brightness.dark ? const Color(0xFF4FD39B) : const Color(0xFF17885E);

/// Text or an icon drawn on [c]: white on a dark colour, near-black on a light one.
Color _on(Color c) => ThemeData.estimateBrightnessForColor(c) == Brightness.dark ? Colors.white : const Color(0xFF05121C);

/// "Update" beside the phone's last report: greyed out for the same reasons
/// as Ping now (the phone reports live already).
class GodViewUpdateButton extends StatelessWidget {
  const GodViewUpdateButton({super.key, required this.busy, required this.onUpdate, this.blocked});
  final bool busy;
  final String? blocked;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const ValueKey('god-view-update'),
    style: TextButton.styleFrom(
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    ),
    onPressed: busy || blocked != null ? null : onUpdate,
    icon: busy
        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.refresh, size: 16),
    label: const Text('Update'),
  );
}

/// What came of Update, or why it is greyed out.
class GodViewUpdateNote extends StatelessWidget {
  const GodViewUpdateNote({super.key, required this.stage, required this.at, required this.now, this.blocked});
  final GodViewUpdateStage? stage;
  final DateTime? at;
  final DateTime now;
  final String? blocked;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = stage;
    final text = s != null ? godViewUpdateLine(s, at: at, now: now) : blocked;
    if (text == null) return const SizedBox.shrink();
    final color = switch (s) {
      GodViewUpdateStage.updated => _fresh(t.brightness),
      GodViewUpdateStage.failed || GodViewUpdateStage.noAnswer => t.colorScheme.error,
      _ => t.colorScheme.onSurfaceVariant,
    };
    return Text(text, key: const ValueKey('god-view-update-line'), style: t.textTheme.bodySmall?.copyWith(color: color));
  }
}

/// "Live · every 5 s" over the map while someone streams.
class GodViewLiveBadge extends StatelessWidget {
  const GodViewLiveBadge({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(99)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.sensors, size: 15, color: _on(color)),
      const SizedBox(width: 5),
      Text('Live · every 5 s', style: TextStyle(color: _on(color), fontWeight: FontWeight.w700, fontSize: 12)),
    ]),
  );
}

/// "Live now": the length, then Stop with the time left while it is on.
class GodViewLiveRow extends StatelessWidget {
  const GodViewLiveRow({
    super.key,
    required this.live,
    required this.now,
    required this.minutes,
    required this.busy,
    required this.onMinutes,
    required this.onStart,
    required this.onStop,
    this.problem,
  });

  final GodViewLiveView? live;
  final DateTime now;
  final int minutes;
  final bool busy;
  final String? problem;
  final ValueChanged<int> onMinutes;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final red = godViewLiveColor(t.brightness);
    final stage = live?.stageAt(now) ?? GodViewLiveStage.off;
    final session = live?.session;
    final muted = t.colorScheme.onSurfaceVariant;
    final spinner = SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: stage == GodViewLiveStage.off ? null : _on(red)),
    );
    final lineColor = switch (stage) {
      GodViewLiveStage.live => red,
      GodViewLiveStage.noAnswer => t.colorScheme.error,
      _ => muted,
    };
    return Column(key: const ValueKey('god-view-live'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (stage == GodViewLiveStage.off) ...[
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final m in godViewLiveChoices)
            ChoiceChip(
              key: ValueKey('god-view-live-$m'),
              label: Text(godViewLiveChoiceLabel(m)),
              selected: m == minutes,
              onSelected: busy ? null : (_) => onMinutes(m),
            ),
          FilledButton.icon(
            key: const ValueKey('god-view-live-start'),
            style: FilledButton.styleFrom(backgroundColor: red, foregroundColor: _on(red)),
            onPressed: busy ? null : onStart,
            icon: busy ? spinner : const Icon(Icons.sensors, size: 18),
            label: const Text('Live now'),
          ),
        ]),
      ] else
        FilledButton.icon(
          key: const ValueKey('god-view-live-stop'),
          style: FilledButton.styleFrom(backgroundColor: red, foregroundColor: _on(red)),
          onPressed: busy ? null : onStop,
          icon: busy ? spinner : const Icon(Icons.stop_circle_outlined, size: 18),
          label: Text(godViewLiveStopLabel(session!.endsAt, now.add(live!.skew))),
        ),
      const SizedBox(height: 6),
      Text(
        problem ?? godViewLiveNowLine(stage),
        key: const ValueKey('god-view-live-line'),
        style: t.textTheme.bodySmall?.copyWith(color: problem != null ? t.colorScheme.error : lineColor),
      ),
    ]);
  }
}

/// The pencil by Phone: the new number, typed as at sign-in (the country's
/// code, no leading 0). The server texts it a link; the number changes once
/// the person opens it.
class GodViewEditPhoneDialog extends StatefulWidget {
  const GodViewEditPhoneDialog({super.key, required this.person, required this.send});
  final GodViewPerson person;
  final Future<PhoneChangeStatus?> Function(String phone) send;

  @override
  State<GodViewEditPhoneDialog> createState() => _GodViewEditPhoneDialogState();
}

class _GodViewEditPhoneDialogState extends State<GodViewEditPhoneDialog> {
  final _number = TextEditingController();
  DialCountry _country = dialCountryFor(AppConfig.defaultDialCode);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  bool get _ready => _number.text.trim().isNotEmpty && composePhone(_country.dialCode, _number.text).length >= 9;

  Future<void> _send() async {
    if (!_ready || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await widget.send(composePhone(_country.dialCode, _number.text));
      if (mounted) Navigator.of(context).pop(s ?? const PhoneChangeStatus(status: 'waiting'));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      title: const Text('Change phone number'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '${widget.person.displayName} gets a text on the new number with a link to confirm. '
            'Until they open it, they sign in with the old one.',
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DialCountryButton(
              key: const ValueKey('god-view-edit-phone-country'),
              country: _country,
              height: 56,
              onPressed: _busy
                  ? null
                  : () async {
                      final picked = await showDialCountryPicker(context, selected: _country);
                      if (picked != null && mounted) setState(() => _country = picked);
                    },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('god-view-edit-phone-number'),
                controller: _number,
                enabled: !_busy,
                autofocus: true,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, const NoTrunkZeroFormatter()],
                decoration: const InputDecoration(labelText: 'New phone number'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _send(),
              ),
            ),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, key: const ValueKey('god-view-edit-phone-error'), style: TextStyle(color: t.colorScheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('god-view-edit-phone-send'),
          onPressed: _busy || !_ready ? null : _send,
          child: _busy
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Send SMS'),
        ),
      ],
    );
  }
}
