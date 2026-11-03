// Admin -> God View -> person detail (migration 0337): a device picker (which
// of a person's logged-in devices to centre the map on) and a read/edit
// control for the person's safety location case. Opening a case turns on that
// user's background location, and it is always disclosed to the user; the
// panel shows whether the user has actually been shown the indicator yet
// (notified_at). Who may do this is the server's (god_view_may_see + edit on
// God View); this only asks.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/god_view.dart';
import '../../data/god_view_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';

String _dateTime(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
}

/// The person's logged-in devices; tapping one centres the map on its last
/// known position. Hidden when the person has one device or none.
class GodViewDevicePanel extends ConsumerStatefulWidget {
  const GodViewDevicePanel({super.key, required this.profileId, required this.onCentre});

  final String profileId;
  final void Function(double lat, double lng) onCentre;

  @override
  ConsumerState<GodViewDevicePanel> createState() => _GodViewDevicePanelState();
}

class _GodViewDevicePanelState extends ConsumerState<GodViewDevicePanel> {
  List<GodViewDevice>? _devices;
  String? _for;

  @override
  void didUpdateWidget(GodViewDevicePanel old) {
    super.didUpdateWidget(old);
    if (old.profileId != widget.profileId) _devices = null;
  }

  Future<void> _load() async {
    _for = widget.profileId;
    try {
      final d = await ref.read(godViewRepositoryProvider).devices(widget.profileId);
      if (mounted) setState(() => _devices = d);
    } catch (_) {
      // A scoped admin, or a read that fails, just hides the picker.
      if (mounted) setState(() => _devices = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_for != widget.profileId) {
      _for = widget.profileId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final devices = _devices;
    // Only worth a picker when there is more than one located device.
    if (devices == null || devices.where((d) => d.hasPosition).length < 2) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Column(
      key: const ValueKey('god-view-device-picker'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Devices', style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final d in devices.where((d) => d.hasPosition))
              ActionChip(
                key: ValueKey('god-view-device-${d.tokenId}'),
                avatar: Icon(d.locationAlways ? Icons.location_on : Icons.phone_iphone, size: 16),
                label: Text(d.label),
                onPressed: () => widget.onCentre(d.lat!, d.lng!),
              ),
          ],
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}

/// The safety location case: its state, when the user was shown the indicator,
/// and (for an admin with edit on God View) open / close / change-style.
class GodViewSafetyCasePanel extends ConsumerStatefulWidget {
  const GodViewSafetyCasePanel({super.key, required this.profileId, required this.canEdit});

  final String profileId;
  final bool canEdit;

  @override
  ConsumerState<GodViewSafetyCasePanel> createState() => _GodViewSafetyCasePanelState();
}

class _GodViewSafetyCasePanelState extends ConsumerState<GodViewSafetyCasePanel> {
  SafetyCaseAdminState? _state;
  String? _for;
  bool _busy = false;

  @override
  void didUpdateWidget(GodViewSafetyCasePanel old) {
    super.didUpdateWidget(old);
    if (old.profileId != widget.profileId) _state = null;
  }

  Future<void> _load() async {
    _for = widget.profileId;
    try {
      final s = await ref.read(godViewRepositoryProvider).safetyCase(widget.profileId);
      if (mounted) setState(() => _state = s);
    } catch (_) {
      // A read-only or scoped admin may not read it; just hide the panel.
    }
  }

  Future<void> _open() async {
    final result = await showAppSheet<Map<String, String>>(
      id: 'godview.safety-case',
      context: context,
      builder: (c) => const _OpenCaseSheet(),
    );
    if (result == null || !mounted) return;
    await _apply(enabled: true, reason: result['reason'], style: result['style'] ?? 'modal');
  }

  Future<void> _close() async {
    final ok = await showAppDialog<bool>(
      id: 'godview.safety-case-close',
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Close safety case?'),
        content: const Text('Background location stops being allowed for this user, and the indicator is removed from their app.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('god-view-safety-close-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Close case'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _apply(enabled: false, style: _state?.style ?? 'modal');
  }

  Future<void> _setStyle(String style) => _apply(enabled: true, style: style);

  Future<void> _apply({required bool enabled, String? reason, required String style}) async {
    setState(() => _busy = true);
    try {
      final s = await ref.read(godViewRepositoryProvider).setSafetyCase(
            widget.profileId,
            enabled: enabled,
            reason: reason,
            style: style,
          );
      if (mounted) setState(() => _state = s);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_for != widget.profileId) {
      _for = widget.profileId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final s = _state;
    if (s == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final on = s.enabled;
    return Container(
      key: const ValueKey('god-view-safety-case'),
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(on ? Icons.location_on : Icons.location_off_outlined,
                size: 18, color: on ? const Color(0xFF1B7A3D) : t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('Safety location', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 4),
          Text(
            on
                ? 'Background location is ON for this user (always disclosed to them).'
                : 'Off. No background location for this user beyond the usual rules.',
            key: const ValueKey('god-view-safety-state'),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          if (on) ...[
            const SizedBox(height: 4),
            Text(
              s.notified
                  ? 'User shown / accepted: ${_dateTime(s.notifiedAt)}'
                  : 'Not yet shown (waiting for the user’s app to display it).',
              key: const ValueKey('god-view-safety-notified'),
              style: t.textTheme.bodySmall?.copyWith(
                color: s.notified ? t.colorScheme.onSurfaceVariant : t.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            if ((s.reason ?? '').trim().isNotEmpty)
              Text('Reason: ${s.reason}',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            Text('Style: ${s.style == 'banner' ? 'Banner' : 'One-time modal'}',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ],
          if (widget.canEdit) ...[
            const SizedBox(height: 8),
            if (!on)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: BusyButton.filled(
                  key: const ValueKey('god-view-safety-open'),
                  onPressed: _busy ? null : _open,
                  child: const Text('Open safety case'),
                ),
              )
            else
              Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SegmentedButton<String>(
                  key: const ValueKey('god-view-safety-style'),
                  segments: const [
                    ButtonSegment(value: 'modal', label: Text('Modal')),
                    ButtonSegment(value: 'banner', label: Text('Banner')),
                  ],
                  selected: {s.style},
                  onSelectionChanged: _busy ? null : (v) => _setStyle(v.first),
                ),
                BusyButton.text(
                  key: const ValueKey('god-view-safety-close'),
                  onPressed: _busy ? null : _close,
                  child: const Text('Close case'),
                ),
              ]),
          ],
        ],
      ),
    );
  }
}

/// The open-case form: a required reason and the disclosure style.
class _OpenCaseSheet extends StatefulWidget {
  const _OpenCaseSheet();

  @override
  State<_OpenCaseSheet> createState() => _OpenCaseSheetState();
}
// Returns {'reason': ..., 'style': 'modal'|'banner'}.

class _OpenCaseSheetState extends State<_OpenCaseSheet> {
  final _reason = TextEditingController();
  String _style = 'modal';

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Open safety case', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          'Turns on this user’s background location. The user is always shown an indicator; '
          'the reason below stays internal (a generic "a safety review" is shown to them).',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('god-view-safety-reason'),
          controller: _reason,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Reason (required, internal)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Text('How the user sees it', style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'modal', label: Text('One-time modal')),
            ButtonSegment(value: 'banner', label: Text('Standing banner')),
          ],
          selected: {_style},
          onSelectionChanged: (v) => setState(() => _style = v.first),
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('god-view-safety-open-confirm'),
          onPressed: () {
            final r = _reason.text.trim();
            if (r.isEmpty) {
              showError(context, 'Enter a reason for the safety case.');
              return;
            }
            Navigator.pop(context, {'reason': r, 'style': _style});
          },
          child: const Text('Open safety case'),
        ),
      ]),
    );
  }
}
