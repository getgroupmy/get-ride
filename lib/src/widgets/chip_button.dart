// An action chip as a screen reader should hear it: a button named by its
// label, never a checkbox. Material chips carry selected/checked state in
// their semantics, which web screen readers announced as "checkbox, not
// checked" for chips that simply do something (quick replies, amount
// presets, suggestions). Every action chip in the app is this one.
import 'package:flutter/material.dart';

/// [ActionChip] with button semantics: its label (or [semanticLabel]),
/// enabled when [onPressed] is set, a tap action, and no checked state.
class ActionChipButton extends ActionChip {
  const ActionChipButton({
    super.key,
    super.avatar,
    required super.label,
    super.labelStyle,
    super.labelPadding,
    super.onPressed,
    super.tooltip,
    super.side,
    super.shape,
    super.backgroundColor,
    super.padding,
    super.visualDensity,
    super.materialTapTargetSize,
    super.avatarBoxConstraints,
    this.semanticLabel,
    this.semanticHint,
  });

  /// The name read out; the label's text when null.
  final String? semanticLabel;

  /// What a tap does, read after the name.
  final String? semanticHint;

  /// The words of [label] (a [Text]), for the name read out.
  static String? textOf(Widget label) => switch (label) {
    Text(:final data?) => data,
    Text(:final textSpan?) => textSpan.toPlainText(),
    _ => null,
  };

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    enabled: onPressed != null,
    label: semanticLabel ?? textOf(label) ?? tooltip,
    hint: semanticHint,
    onTap: onPressed,
    excludeSemantics: true,
    child: super.build(context),
  );
}
