// Keyboard focus that follows the screen's visual order on wide layouts:
// the rail, then the page's own content, then what floats over a map (its
// layers, credit and my-location buttons, a screen's floating shortcuts).
// Read top-to-bottom alone, buttons pinned to a map's top corner came
// before the rail and the panel (WCAG 2.4.3).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Marks [child]'s focusable widgets as floating over the content: under a
/// [ContentFirstTraversalPolicy] they are reached after everything else in
/// the page. Elsewhere it changes nothing.
class FocusLast extends InheritedWidget {
  const FocusLast({super.key, required super.child});

  static bool isMarked(BuildContext context) => context.getInheritedWidgetOfExactType<FocusLast>() != null;

  @override
  bool updateShouldNotify(FocusLast oldWidget) => false;
}

/// Reading order, with every node under a [FocusLast] moved after the rest
/// (each part keeping its reading order).
class ContentFirstTraversalPolicy extends ReadingOrderTraversalPolicy {
  ContentFirstTraversalPolicy({super.requestFocusCallback});

  @override
  Iterable<FocusNode> sortDescendants(Iterable<FocusNode> descendants, FocusNode currentNode) {
    final sorted = super.sortDescendants(descendants, currentNode).toList();
    bool last(FocusNode n) {
      final c = n.context;
      return c != null && c.mounted && FocusLast.isMarked(c);
    }

    return [...sorted.where((n) => !last(n)), ...sorted.where(last)];
  }
}

/// A wide layout's keyboard order: [rail] first, then [content] (where
/// what floats over a map comes last, [ContentFirstTraversalPolicy]). The
/// first Tab on a page with nothing focused yet goes to the rail too: the
/// page's own route otherwise held the focus and Tab began inside it, at
/// the buttons pinned to the map's top corner.
class ShellFocusOrder extends StatefulWidget {
  const ShellFocusOrder({super.key, required this.rail, required this.content, this.between});

  final Widget rail;
  final Widget content;

  /// Drawn between them (a divider); never focused.
  final Widget? between;

  @override
  State<ShellFocusOrder> createState() => _ShellFocusOrderState();
}

class _ShellFocusOrderState extends State<ShellFocusOrder> {
  final _rail = FocusNode(debugLabel: 'shell-rail', canRequestFocus: false, skipTraversal: true);

  @override
  void dispose() {
    _rail.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.tab || HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    // Nothing chosen yet (only a route's scope holds the focus): start at
    // the rail.
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary is! FocusScopeNode) return KeyEventResult.ignored;
    final first = _rail.traversalDescendants.where((n) => n.canRequestFocus && !n.skipTraversal).firstOrNull;
    if (first == null) return KeyEventResult.ignored;
    first.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _onKey,
    child: FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Row(children: [
        FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: Focus(focusNode: _rail, child: FocusTraversalGroup(child: widget.rail)),
        ),
        ?widget.between,
        Expanded(
          child: FocusTraversalOrder(
            order: const NumericFocusOrder(2),
            child: FocusTraversalGroup(policy: ContentFirstTraversalPolicy(), child: widget.content),
          ),
        ),
      ]),
    ),
  );
}
