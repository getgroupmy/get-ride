// The Courier and Freight pages in the city ride's look: the address boxes
// as the route sheet's From / To rows, the chosen size or vehicle as the
// home vehicle bar's chosen card, the choices as the route sheet's pills,
// and the request button at the foot as "Find a driver" in its raised bar.
// Colours come from the theme and App Page Settings (the page's own values,
// `page_styles.dart`), never set here.
import 'package:flutter/material.dart';

import '../../core/page_styles.dart';
import '../../widgets/busy.dart' show BusySpinner;
import '../../widgets/common.dart' show inkOn, mutedTextColor;
import '../../widgets/page_style_host.dart';
import 'confirm_parts.dart' show accentFill;
import 'place_search.dart' show routeSheetFill;

/// The colours and sizes of the Courier or Freight page [context] is on.
class DeliveryLook {
  const DeliveryLook({
    required this.field,
    required this.onField,
    required this.mutedOnField,
    required this.fieldRadius,
    required this.fieldHeight,
    required this.chosen,
    required this.onChosen,
    required this.choiceRadius,
    required this.button,
    required this.onButton,
  });

  /// The address and detail boxes: their fill, words, label and size.
  final Color field, onField, mutedOnField;
  final double fieldRadius, fieldHeight;

  /// The chosen size or vehicle card, and its words.
  final Color chosen, onChosen;
  final double choiceRadius;

  /// The request button at the foot, "Find a driver"'s blue unless the
  /// admin sets another, and its words.
  final Color button, onButton;

  /// The page's values; off the Courier and Freight pages (a sheet opened
  /// from elsewhere), Freight's.
  factory DeliveryLook.of(BuildContext context) {
    final t = Theme.of(context);
    final b = t.brightness;
    final page = SurfaceStyle.ofPage(context);
    final s = page.id == courierSurface || page.id == freightSurface ? page : SurfaceStyle.of(context, freightSurface);
    final field = s.setColor('fieldColor', b) ?? routeSheetFill(t);
    final chosen = s.setColor('chosenColor', b) ??
        SurfaceStyle.of(context, homeSurface).color('vehicleSelected', b) ??
        t.colorScheme.secondaryContainer;
    final button = s.color('buttonColor', b) ?? accentFill;
    return DeliveryLook(
      field: field,
      onField: inkOn(field, preferred: t.colorScheme.onSurface),
      mutedOnField: mutedTextColor(t, background: field),
      fieldRadius: s.number('inputRadius'),
      fieldHeight: s.number('fieldHeight'),
      chosen: chosen,
      onChosen: inkOn(chosen, preferred: t.colorScheme.onSurface),
      choiceRadius: s.number('choiceRadius'),
      button: button,
      onButton: inkOn(button, preferred: Colors.white),
    );
  }

  /// A chosen or unchosen card's fill: the chosen colour, or none.
  Color cardFill(bool selected) => selected ? chosen : Colors.transparent;

  /// The words on a chosen or unchosen card, and their secondary line.
  Color cardInk(ThemeData t, bool selected) => selected ? onChosen : t.colorScheme.onSurface;
  Color cardMuted(ThemeData t, bool selected) => selected ? onChosen : mutedTextColor(t);
}

/// The choice chips and segmented buttons under [child] as the city ride's
/// choices: the route sheet's grey pill unchosen, the home vehicle bar's
/// chosen colour when chosen.
class DeliveryChoiceTheme extends StatelessWidget {
  const DeliveryChoiceTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = DeliveryLook.of(context);
    final fill = WidgetStateColor.resolveWith((s) => s.contains(WidgetState.selected) ? look.chosen : look.field);
    final ink = WidgetStateColor.resolveWith(
      (s) => s.contains(WidgetState.disabled)
          ? look.mutedOnField
          : s.contains(WidgetState.selected)
          ? look.onChosen
          : look.onField,
    );
    return Theme(
      data: t.copyWith(
        chipTheme: t.chipTheme.copyWith(
          color: fill,
          labelStyle: (t.textTheme.labelLarge ?? const TextStyle()).copyWith(color: ink),
          checkmarkColor: look.onChosen,
          iconTheme: IconThemeData(color: ink, size: 18),
          side: BorderSide.none,
          shape: const StadiumBorder(),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: fill,
            foregroundColor: ink,
            iconColor: ink,
            side: const WidgetStatePropertyAll(BorderSide.none),
          ),
        ),
      ),
      child: child,
    );
  }
}

/// The section heading over a group of boxes ("Where to pick up").
class DeliverySectionLabel extends StatelessWidget {
  const DeliverySectionLabel(this.text, {super.key, this.trailing, this.top = 16});
  final String text;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 8),
      child: Row(children: [
        Flexible(
          child: Text(
            text,
            style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: t.colorScheme.onSurface),
          ),
        ),
        ?trailing,
      ]),
    );
  }
}

/// The raised bar at the foot of the page, as the confirm sheet's: the
/// request button ("Find a driver"'s look, in the theme's colours) and,
/// while it waits, what is still missing under it.
class DeliveryFooter extends StatelessWidget {
  const DeliveryFooter({
    super.key,
    required this.buttonKey,
    required this.hintKey,
    required this.label,
    required this.busy,
    required this.problem,
    required this.onPressed,
  });

  final Key buttonKey, hintKey;
  final String label;
  final bool busy;

  /// The first thing missing; null when the request can go.
  final String? problem;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final look = DeliveryLook.of(context);
    final fg = look.onButton;
    return Material(
      color: t.colorScheme.surface,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FilledButton.icon(
              key: buttonKey,
              style: FilledButton.styleFrom(
                backgroundColor: look.button,
                foregroundColor: fg,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              onPressed: busy || problem != null ? null : onPressed,
              icon: busy ? BusySpinner(size: 20, color: fg) : const Icon(Icons.bolt),
              label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (problem != null && !busy)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  problem!,
                  key: hintKey,
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t, background: t.colorScheme.surface)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
