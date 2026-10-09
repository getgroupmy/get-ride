// "Select your service mode" (Expo `PartnerModeSelectModal`): the rider
// menu's Partner Mode button asks which of the partner's assigned services
// to start before driver mode opens. TEKSI goes on to the meter (through the
// documents, vehicle and permit checks the driver screen holds it to); any
// other service opens the driver screen, ready to go online.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../admin/screens/people/people_logic.dart' show parseStringList;
import '../../core/partner_modes.dart';
import '../../data/partner_doc_check.dart' show partnerTypeEntriesProvider;
import '../../data/models.dart' show Partner;
import '../../providers.dart';
import 'partner_screen.dart' show partnerCanDrive;
import '../../widgets/net_image.dart';

/// What a partner with no assigned type is offered (Expo's defaults).
const defaultPartnerModeOptions = [
  PartnerModeOption(name: 'TEKSI', description: 'Traditional taxi service'),
  PartnerModeOption(name: 'eHailing', description: 'On-demand ride requests'),
];

/// The service the driver screen is to start once it opens; it takes it
/// and clears it.
class PendingPartnerMode extends Notifier<PartnerModeOption?> {
  @override
  PartnerModeOption? build() => null;

  void set(PartnerModeOption? mode) => state = mode;

  /// The pending mode, cleared.
  PartnerModeOption? take() {
    final m = state;
    state = null;
    return m;
  }
}

final pendingPartnerModeProvider = NotifierProvider<PendingPartnerMode, PartnerModeOption?>(PendingPartnerMode.new);

/// The Partner Mode button: a partner who can drive picks a service first;
/// anyone else goes to the driver screen, which takes them through sign-up
/// or shows why they can't drive yet. [beforeOpen] runs before navigating
/// (closing the menu).
Future<void> openPartnerMode(BuildContext context, WidgetRef ref, {VoidCallback? beforeOpen}) async {
  final router = GoRouter.of(context);
  void go() {
    beforeOpen?.call();
    router.go('/drive');
  }

  Partner? partner;
  List<PartnerTypeEntry> entries = const [];
  try {
    partner = await ref.read(partnerProvider.future);
    if (partner != null && partnerCanDrive(partner)) entries = await ref.read(partnerTypeEntriesProvider.future);
  } catch (_) {
    partner = null;
  }
  if (partner == null || !partnerCanDrive(partner) || !context.mounted) return go();
  final assigned = partnerModeOptions(parseStringList(partner.raw['partner_types']), entries);
  final picked = await showPartnerModePicker(context, assigned);
  if (picked == null) return;
  ref.read(pendingPartnerModeProvider.notifier).set(picked);
  go();
}

/// The picker; null when dismissed. [assigned] empty shows the defaults.
Future<PartnerModeOption?> showPartnerModePicker(BuildContext context, List<PartnerModeOption> assigned) {
  final options = assigned.isEmpty ? defaultPartnerModeOptions : assigned;
  return showDialog<PartnerModeOption>(
    context: context,
    builder: (c) {
      final t = Theme.of(c);
      final muted = t.colorScheme.onSurfaceVariant;
      return Dialog(
        key: const ValueKey('partner-mode-picker'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Select your service mode',
                        style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('partner-mode-close'),
                      tooltip: 'Close',
                      icon: Icon(Icons.close, color: muted),
                      onPressed: () => Navigator.pop(c),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 12),
                  child: Text(
                    assigned.isEmpty
                        ? 'Choose how do you want to earn today'
                        : 'Choose from the services assigned to you',
                    style: t.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(right: 8),
                    child: Column(
                      children: [
                        for (final o in options)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _ModeTile(option: o, onTap: () => Navigator.pop(c, o)),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.option, required this.onTap});

  final PartnerModeOption option;
  final VoidCallback onTap;

  IconData get _icon {
    final n = option.name.trim().toLowerCase();
    if (option.isTeksi || n.contains('taxi')) return Icons.local_taxi_outlined;
    if (n.contains('hail') || n.contains('ride')) return Icons.smartphone;
    return Icons.work_outline;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final accent = t.colorScheme.primary;
    final url = option.iconUrl;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: t.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('partner-mode-option-${option.name}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: url == null
                    ? Icon(_icon, color: accent)
                    : Image.network(
                        url,
                        fit: BoxFit.cover,
                        frameBuilder: boneUntilPainted(),
                        errorBuilder: (_, _, _) => Icon(_icon, color: accent),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (option.description != null)
                      Text(
                        option.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: t.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
