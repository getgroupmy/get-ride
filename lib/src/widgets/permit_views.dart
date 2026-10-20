// The permit boxes and sheet shared by the passenger's ride, the driver's
// trip and Vehicles > Permit, and the admin: the vehicle line, then one box
// per permit with its fields (each label in English with the local one
// under it), a status badge for the driver and "View permit". What a box
// says comes from the country's permit types (core/permits.dart).
import 'package:flutter/material.dart';

import '../config.dart';
import '../core/permits.dart';
import 'in_app_page.dart';
import 'plate_chip.dart';

/// The stored link of a permit's file, as openStoredFile takes it.
String? permitFileLink(PermitItem p) {
  if (p.fileUrl != null && p.fileUrl!.isNotEmpty) return p.fileUrl;
  if (!p.hasFile) return null;
  return '${AppConfig.supabaseUrl}/storage/v1/object/public/${p.bucket}/${p.path}';
}

/// The badge's colours in light and dark.
({Color bg, Color fg}) permitToneColours(PermitBadgeTone tone, Brightness b) {
  final dark = b == Brightness.dark;
  return switch (tone) {
    PermitBadgeTone.ok => dark
        ? (bg: const Color(0xFF10301F), fg: const Color(0xFF5AD08F))
        : (bg: const Color(0xFFDCF4E7), fg: const Color(0xFF0D7A45)),
    PermitBadgeTone.warn => dark
        ? (bg: const Color(0xFF3A2D0A), fg: const Color(0xFFF4C95D))
        : (bg: const Color(0xFFFFF1CC), fg: const Color(0xFF8A5A00)),
    PermitBadgeTone.bad => dark
        ? (bg: const Color(0xFF3D1416), fg: const Color(0xFFFF8A90))
        : (bg: const Color(0xFFFDE2E3), fg: const Color(0xFFB0232B)),
  };
}

class PermitBadge extends StatelessWidget {
  const PermitBadge({super.key, required this.text, required this.tone});
  final String text;
  final PermitBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final c = permitToneColours(tone, Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: c.fg, fontWeight: FontWeight.w600)),
    );
  }
}

/// The plate and car over the permits.
class PermitVehicleLine extends StatelessWidget {
  const PermitVehicleLine({super.key, this.plate, this.colours, this.label, this.detail});
  final String? plate;
  final PlateColours? colours;
  final String? label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      children: [
        if (plate != null && plate!.isNotEmpty) ...[
          PlateChip(key: const ValueKey('permit-plate'), plate: plate!, fontSize: 15, colours: colours),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (label != null && label!.isNotEmpty)
                Text(label!, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              if (detail != null && detail!.isNotEmpty)
                Text(detail!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

/// One permit: its name, the driver's badge, every field and View permit.
class PermitBox extends StatelessWidget {
  const PermitBox({super.key, required this.permit, this.badge, this.onView});
  final PermitItem permit;
  final ({String text, PermitBadgeTone tone})? badge;

  /// Overrides opening the file (tests).
  final VoidCallback? onView;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final link = permitFileLink(permit);
    return Container(
      key: ValueKey('permit-box-${permit.typeId}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(permit.name, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    if (permit.nameLocal.isNotEmpty)
                      Text(permit.nameLocal, style: t.textTheme.bodySmall?.copyWith(color: muted)),
                  ],
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 8),
                PermitBadge(key: ValueKey('permit-badge-${permit.typeId}'), text: badge!.text, tone: badge!.tone),
              ],
            ],
          ),
          const SizedBox(height: 8),
          for (final f in permit.fields)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(f.field.label, style: t.textTheme.bodySmall?.copyWith(color: muted)),
                        if (f.field.labelLocal.isNotEmpty)
                          Text(f.field.labelLocal, style: t.textTheme.labelSmall?.copyWith(color: muted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      f.shown,
                      key: ValueKey('permit-field-${permit.typeId}-${f.field.key}'),
                      textAlign: TextAlign.end,
                      style: t.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (link != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: ValueKey('permit-view-${permit.typeId}'),
                onPressed: onView ?? () => openStoredFile(context, link, title: permit.name),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('View permit'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The sheet's content: the vehicle line and the permit boxes.
class PermitSheetBody extends StatelessWidget {
  const PermitSheetBody({
    super.key,
    required this.permits,
    this.plate,
    this.colours,
    this.vehicleLabel,
    this.vehicleDetail,
    this.badges = false,
    this.today,
    this.bypassUntil,
    this.onClose,
  });

  final List<PermitItem> permits;
  final String? plate;
  final PlateColours? colours;
  final String? vehicleLabel;
  final String? vehicleDetail;

  /// The driver's view: each permit's status badge.
  final bool badges;
  final DateTime? today;
  final DateTime? bypassUntil;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final now = today ?? DateTime.now();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          key: const ValueKey('permit-sheet'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(permitSheetTitle(permits), style: t.textTheme.titleMedium)),
                if (onClose != null)
                  TextButton(key: const ValueKey('permit-sheet-close'), onPressed: onClose, child: const Text('Close')),
              ],
            ),
            const SizedBox(height: 8),
            PermitVehicleLine(plate: plate, colours: colours, label: vehicleLabel, detail: vehicleDetail),
            for (final p in permits) ...[
              const SizedBox(height: 10),
              PermitBox(permit: p, badge: badges ? permitBadge(p, now, bypassUntil: bypassUntil) : null),
            ],
          ],
        ),
      ),
    );
  }
}

/// The small button that opens them.
class PermitButton extends StatelessWidget {
  const PermitButton({super.key, required this.label, required this.onPressed, this.note});
  final String label;
  final String? note;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.verified_user_outlined, size: 18),
      label: Text(note == null ? label : '$label · $note'),
    ),
  );
}
