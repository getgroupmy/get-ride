// Partner registration (0288): the pieces the steps are built from, shared
// by partner_onboarding_screen.dart and registration_steps.dart: the
// coloured notice boxes, the upload tiles, the Partner Service type cards
// with the citizens-only notice, and the eligibility modal.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/screens/people/people_logic.dart';
import '../../core/document_text.dart';
import '../../core/partner_registration.dart';
import '../../core/partner_type_rules.dart';
import '../../data/geo_service.dart' show currentPosition;
import '../../providers.dart' show geoServiceProvider;
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';

/// Where the phone is, as country, state and city names; null when it
/// can't be told (no permission, no fix, no geocoder). Overridden in tests.
typedef RegistrationLocate = Future<({String? country, String? state, String? city})?> Function();

final registrationLocatorProvider = Provider<RegistrationLocate>((ref) {
  return () async {
    final p = await currentPosition();
    if (p == null) return null;
    final a = await ref.read(geoServiceProvider).reverseArea(p);
    return a == null ? null : (country: a.country, state: a.state, city: a.city);
  };
});

enum NoticeTone { info, done, warn }

/// A coloured box with an icon: "Read from your MyKad", "Some services are
/// for citizens only", "Owner matches your ID".
class RegNotice extends StatelessWidget {
  const RegNotice({super.key, required this.icon, required this.children, this.tone = NoticeTone.info});
  final IconData icon;
  final List<Widget> children;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (bg, fg, ic) = switch (tone) {
      NoticeTone.info => (c.surfaceContainerHigh, c.onSurface, c.primary),
      NoticeTone.done => (c.primaryContainer, c.onPrimaryContainer, c.primary),
      NoticeTone.warn => (c.tertiaryContainer, c.onTertiaryContainer, c.onTertiaryContainer),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: fg),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 20, color: ic),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: children),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One line with a tick or a warning, in a notice.
class CheckLine extends StatelessWidget {
  const CheckLine({super.key, required this.ok, required this.text, this.paused = false});
  final bool ok;
  final bool paused;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(
        ok ? Icons.check_circle : (paused ? Icons.pause_circle : Icons.error),
        size: 18,
        color: ok ? c.primary : c.error,
      ),
      const SizedBox(width: 6),
      Expanded(child: Text(text)),
    ]);
  }
}

/// An upload button that turns into a tick once its file is in.
class UploadTile extends StatelessWidget {
  const UploadTile({
    super.key,
    required this.label,
    required this.done,
    required this.onTap,
    this.subtitle,
    this.icon = Icons.add_a_photo_outlined,
    this.busy = false,
  });
  final String label;
  final String? subtitle;
  final bool done;
  final bool busy;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: done ? c.primary : c.outlineVariant),
      ),
      child: ListTile(
        leading: busy
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(done ? Icons.check_circle : icon, color: done ? c.primary : null),
        title: Text(label),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: const Icon(Icons.chevron_right),
        onTap: busy ? null : onTap,
      ),
    );
  }
}

/// A labelled text field the step reads into and the driver can correct.
class RegField extends StatelessWidget {
  const RegField({
    super.key,
    required this.controller,
    required this.label,
    this.enabled = true,
    this.maxLines = 1,
    this.keyboard,
    this.mono = false,
    this.caps = true,
  });
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final int maxLines;
  final TextInputType? keyboard;
  final bool mono;
  final bool caps;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          enabled: enabled,
          maxLines: maxLines,
          minLines: 1,
          keyboardType: keyboard,
          textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.none,
          style: mono ? const TextStyle(fontFamily: 'monospace', letterSpacing: 0.5) : null,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );
}

// ---- Partner Service types ------------------------------------------------------------------------

/// "Some services are for citizens only": which are, in the area, and which
/// are open to everyone. Nothing when none is citizens-only there.
class CitizensNotice extends StatelessWidget {
  const CitizensNotice({super.key, required this.offered, required this.entries, required this.area});
  final List<String> offered;
  final Iterable<Map<String, dynamic>> entries;
  final ServiceArea area;

  @override
  Widget build(BuildContext context) {
    final only = citizensOnlyTypes(offered, entries, area);
    if (only.isEmpty) return const SizedBox.shrink();
    final open = openToEveryoneTypes(offered, entries, area);
    final where = area.states.isNotEmpty
        ? area.states.map(areaLabel).join(', ')
        : (area.countries.isEmpty ? 'your area' : area.countries.join(', '));
    final t = Theme.of(context).textTheme;
    return RegNotice(
      key: const ValueKey('citizens-notice'),
      icon: Icons.info_outline,
      tone: NoticeTone.warn,
      children: [
        Text('Some services are for citizens only', style: t.titleSmall),
        Text.rich(TextSpan(children: [
          TextSpan(text: 'Citizens only in $where: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(text: '${only.join(', ')}.'),
        ])),
        if (open.isNotEmpty)
          Text.rich(TextSpan(children: [
            const TextSpan(text: 'Open to everyone: ', style: TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(text: '${open.join(', ')}.'),
          ])),
        Text('Your nationality is checked against your ID in the next steps.', style: t.bodySmall),
      ],
    );
  }
}

/// The Partner Service types offered in the area as cards to pick (several
/// may be picked): each with its icon, documents and vehicle age limit, and
/// whether it is a vehicle service or citizens-only. A long list gets a
/// search box.
class ServiceTypeCards extends StatelessWidget {
  const ServiceTypeCards({
    super.key,
    required this.options,
    required this.value,
    required this.entries,
    required this.area,
    required this.docsFor,
    required this.onChanged,
    this.enabled = true,
  });
  final List<String> options;
  final List<String> value;
  final Iterable<Map<String, dynamic>> entries;
  final ServiceArea area;

  /// The service documents a type needs in the area, by name.
  final List<String> Function(String type) docsFor;
  final ValueChanged<List<String>> onChanged;
  final bool enabled;

  IconData _icon(EffectiveTypeRules r) {
    final k = r.key;
    if (k.contains('teksi') || k.contains('taxi')) return Icons.local_taxi;
    if (k.contains('phailing') || k.contains('bike') || k.contains('motor')) return Icons.two_wheeler;
    if (k.contains('deliver') || k.contains('courier') || k.contains('freight')) return Icons.local_shipping;
    if (k.contains('dealer')) return Icons.storefront;
    if (k.contains('fleet')) return Icons.garage;
    if (k.contains('service')) return Icons.handyman;
    return r.vehicleRequired ? Icons.directions_car : Icons.work_outline;
  }

  Widget _card(BuildContext context, String type) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final r = EffectiveTypeRules.of(type, entries);
    final selected = value.contains(type);
    final only = citizensOnlyTypes([type], entries, area).isNotEmpty;
    final permit = driverPermitFor([type], entries, area).firstOrNull;
    final permitName = permit == null
        ? null
        : '${permit.name.isEmpty ? 'Driver permit' : permit.name}${permit.issuer.isEmpty ? '' : ' (${permit.issuer})'}';
    final text = serviceCardText(type: type, entries: entries, area: area, documents: docsFor(type), driverPermit: permitName);
    return Card(
      key: ValueKey('service-card-$type'),
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? c.primaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? c.primary : c.outlineVariant, width: selected ? 2 : 1),
      ),
      // One tick box per service for a screen reader: its name, words and
      // whether it needs a vehicle, ticked or not (not a group with an
      // unticked box inside).
      child: MergeSemantics(
        child: Semantics(
        checked: selected,
        hint: r.vehicleRequired ? 'Vehicle service' : 'No vehicle',
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => onChanged(selected ? value.where((v) => v != type).toList() : [...value, type]) : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                backgroundColor: selected ? c.primary : c.surfaceContainerHighest,
                foregroundColor: selected ? c.onPrimary : c.onSurfaceVariant,
                child: Icon(selected ? Icons.check : _icon(r)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.name.isEmpty ? type : r.name, style: t.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(only ? '$text · Citizens only' : text, style: t.textTheme.bodySmall),
                ]),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: Chip(
                  label: Text(r.vehicleRequired ? 'Vehicle service' : 'No vehicle'),
                  visualDensity: VisualDensity.compact,
                  labelStyle: t.textTheme.labelSmall,
                ),
              ),
            ]),
          ),
        ),
      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) {
      return const Text('No Partner Service type is offered in this area yet. Change the service area, or contact support.');
    }
    if (options.length < 8) return Column(children: [for (final o in options) _card(context, o)]);
    return ListSearchFilter(
      count: options.length,
      hint: 'Search Partner Service types',
      builder: (context, q) => Column(children: [
        for (final o in options)
          if (q.isEmpty || searchSelectMatches(o, q) || value.contains(o)) _card(context, o),
      ]),
    );
  }
}

/// "You may not be eligible to join some services" (Continue / Change my
/// services). True when they chose to change their services.
Future<bool> showEligibilityModal(BuildContext context, EligibilityNotice n, IdDocType? idType) async {
  final changed = await showAppDialog<bool>(
    id: 'partner-registration.eligibility',
    context: context,
    builder: (c) {
      final t = Theme.of(c).textTheme;
      return AlertDialog(
        key: const ValueKey('eligibility-modal'),
        icon: Icon(Icons.warning_amber, color: Theme.of(c).colorScheme.tertiary),
        title: const Text('You may not be eligible to join some services'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, spacing: 8, children: [
            Text('${eligibilityLead(idType)} These services are for citizens only in your area:'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in n.citizensOnly) Chip(label: Text(s), visualDensity: VisualDensity.compact),
            ]),
            if (n.picked.isNotEmpty)
              Text.rich(TextSpan(children: [
                const TextSpan(text: 'You picked: ', style: TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: '${n.picked.join(', ')}. You can carry on; the admin decides when reviewing your application.'),
              ])),
            if (n.open.isNotEmpty) Text('Open to you: ${n.open.join(', ')}.', style: t.bodyMedium),
          ]),
        ),
        actions: [
          TextButton(
            key: const ValueKey('eligibility-change'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Change my services'),
          ),
          FilledButton(
            key: const ValueKey('eligibility-continue'),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Continue'),
          ),
        ],
      );
    },
  );
  return changed == true;
}

/// A yes / no question as a modal; true for [yes]. [id] names its buttons
/// in tests (`<id>-yes`).
Future<bool> askRegistration(
  BuildContext context, {
  required String id,
  required String title,
  required String message,
  required String yes,
  String no = 'Cancel',
}) async =>
    await showAppDialog<bool>(
      id: 'partner-registration.confirm',
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(no)),
          FilledButton(key: ValueKey('$id-yes'), onPressed: () => Navigator.pop(c, true), child: Text(yes)),
        ],
      ),
    ) ==
    true;
