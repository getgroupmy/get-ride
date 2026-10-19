// A page's "Add …" button: a floating button over the list on a phone, an
// app-bar action from 600 wide, where a floating button sat over the first
// cards of a short, wide window (915 × 412) and their buttons.
import 'package:flutter/material.dart';

/// From this width the add button is an app-bar action.
const addActionAppBarWidth = 600.0;

/// Whether [context]'s window puts the add button in the app bar.
bool addActionInAppBar(BuildContext context) => MediaQuery.sizeOf(context).width >= addActionAppBarWidth;

/// What the add button does and says.
@immutable
class PageAddAction {
  const PageAddAction({
    this.key,
    required this.onPressed,
    required this.label,
    this.icon = const Icon(Icons.add),
  });

  final Key? key;
  final VoidCallback? onPressed;
  final Widget label;
  final Widget icon;

  /// The floating button (under [addActionAppBarWidth]).
  Widget fab() => FloatingActionButton.extended(key: key, onPressed: onPressed, icon: icon, label: label);

  /// The app-bar action (from [addActionAppBarWidth]).
  Widget appBarAction() => Padding(
    padding: const EdgeInsets.only(left: 4, right: 8),
    child: FilledButton.tonalIcon(
      key: key,
      // Its own width (the app's filled buttons are otherwise full width).
      style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
      onPressed: onPressed,
      icon: icon,
      label: label,
    ),
  );
}

/// The floating button for [action], or null where it sits in the app bar.
Widget? pageAddFab(BuildContext context, PageAddAction? action) =>
    action == null || addActionInAppBar(context) ? null : action.fab();

/// The app-bar actions for [action]: none where it floats.
List<Widget> pageAddActions(BuildContext context, PageAddAction? action) =>
    action == null || !addActionInAppBar(context) ? const [] : [action.appBarAction()];

/// The room under a list for the floating button over its foot: the
/// button (as tall as the text makes it) and its margin above and below,
/// the home bar, and a gap, so the last row scrolls whole above it at any
/// width or text size.
double fabListBottomPadding(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
  return kFloatingActionButtonMargin * 2 + 56 * scale + MediaQuery.viewPaddingOf(context).bottom + 16;
}

/// The room under a list on a page with [PageAddAction]: the floating
/// button's on a phone, a plain 16 where the button is in the app bar.
double addActionListBottomPadding(BuildContext context) =>
    addActionInAppBar(context) ? 16 + MediaQuery.viewPaddingOf(context).bottom : fabListBottomPadding(context);
