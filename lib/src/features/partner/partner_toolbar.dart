import 'package:material_ui/material_ui.dart';

/// Pure: whether the shortcuts are revealed (open and not force-collapsed).
/// See test/partner_toolbar_test.dart.
bool partnerToolbarShowsActions({required bool open, required bool forceCollapsed}) => open && !forceCollapsed;

/// The driver map's collapsible shortcuts toolbar: a toggle button that reveals
/// the [actions] to its right — wrapping within the screen and scrolling if they
/// don't fit, so they never overflow or sit behind the card below. [open] and
/// [onToggle] are owned by the partner screen (so each shortcut's tap can
/// collapse it), and [forceCollapsed] keeps it tucked away while a ride request
/// is showing. The menu (hamburger) button is positioned separately.
class PartnerActionToolbar extends StatelessWidget {
  const PartnerActionToolbar({
    super.key,
    required this.open,
    required this.onToggle,
    required this.actions,
    this.forceCollapsed = false,
  });

  final bool open;
  final VoidCallback onToggle;
  final List<Widget> actions;

  /// A ride request is showing: keep the shortcuts collapsed.
  final bool forceCollapsed;

  @override
  Widget build(BuildContext context) {
    final show = partnerToolbarShowsActions(open: open, forceCollapsed: forceCollapsed);
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FloatingActionButton.small(
            key: const ValueKey('partner-toolbar-toggle'),
            heroTag: null,
            tooltip: show ? 'Hide actions' : 'Show actions',
            backgroundColor: show ? scheme.primary : null,
            foregroundColor: show ? scheme.onPrimary : null,
            onPressed: onToggle,
            child: Icon(show ? Icons.close : Icons.apps),
          ),
          if (show) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Material(
                color: scheme.surface.withValues(alpha: 0.96),
                elevation: 6,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(6),
                    child: Wrap(spacing: 8, runSpacing: 8, children: actions),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
