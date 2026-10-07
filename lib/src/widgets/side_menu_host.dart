import 'package:flutter/material.dart';

import 'side_menu_style.dart';

/// The rider side menu as the Expo app draws it (`MenuSideSheet` inline):
/// a panel on the left that pushes the whole page right to make room, with
/// the page dimmed behind it. It opens from any rider page's menu button
/// ([SideMenuButton]) or a swipe in from the left edge, and closes on a tap
/// on the page, a swipe back, or the system back.
class SideMenuHost extends StatefulWidget {
  const SideMenuHost({super.key, required this.menu, required this.child, this.enabled = true});

  /// The panel's content. It is handed [SideMenuHostState.close] by the
  /// [SideMenuHost.of] lookup, so a row can close the menu before it opens
  /// its page.
  final Widget menu;
  final Widget child;

  /// Off where another menu applies (driver mode) or the screen is wide
  /// enough for a rail: no edge swipe and no menu buttons.
  final bool enabled;

  /// The panel's width: [SideMenuStyle.widthFraction] of the screen.
  static double widthFor(double screen) => SideMenuStyle.widthFor(screen);

  /// The strip along the left edge a swipe in starts from.
  static const edge = 20.0;

  /// The host above [context], when there is one and its menu is on.
  static SideMenuHostState? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_SideMenuScope>();
    return scope != null && scope.enabled ? scope.state : null;
  }

  @override
  State<SideMenuHost> createState() => SideMenuHostState();
}

class SideMenuHostState extends State<SideMenuHost> with SingleTickerProviderStateMixin {
  late final AnimationController _open = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
  double _width = 0;

  bool get isOpen => _open.value > 0;

  void open() => _open.animateTo(1, curve: Curves.easeOutCubic);
  void close() => _open.animateTo(0, curve: Curves.easeOutCubic);

  @override
  void didUpdateWidget(covariant SideMenuHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _open.value > 0) _open.value = 0;
  }

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails d) {
    if (_width <= 0) return;
    _open.value = (_open.value + d.primaryDelta! / _width).clamp(0.0, 1.0);
  }

  void _settle(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v.abs() > 300) {
      v > 0 ? open() : close();
    } else {
      _open.value > 0.5 ? open() : close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = _SideMenuScope(state: this, enabled: widget.enabled, child: widget.child);
    if (!widget.enabled) return scope;
    return LayoutBuilder(
      builder: (context, c) {
        _width = SideMenuHost.widthFor(c.maxWidth);
        return AnimatedBuilder(
          animation: _open,
          builder: (context, page) {
            final v = _open.value;
            return PopScope(
              // Back closes an open menu before it leaves the page.
              canPop: v == 0,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) close();
              },
              child: Stack(
                children: [
                  if (v > 0)
                    Positioned(
                      left: -_width * (1 - v),
                      top: 0,
                      bottom: 0,
                      width: _width,
                      child: _SideMenuScope(state: this, enabled: true, child: widget.menu),
                    ),
                  Positioned(left: _width * v, top: 0, bottom: 0, width: c.maxWidth, child: page!),
                  if (v > 0)
                    Positioned(
                      left: _width * v,
                      top: 0,
                      bottom: 0,
                      width: c.maxWidth,
                      child: GestureDetector(
                        key: const ValueKey('side-menu-scrim'),
                        behavior: HitTestBehavior.opaque,
                        onTap: close,
                        onHorizontalDragUpdate: _drag,
                        onHorizontalDragEnd: _settle,
                        child: ColoredBox(color: Colors.black.withValues(alpha: 0.5 * v)),
                      ),
                    )
                  else
                    // A swipe in from the left edge opens the menu, over
                    // whatever the page does with a drag there.
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: SideMenuHost.edge,
                      child: GestureDetector(
                        key: const ValueKey('side-menu-edge'),
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragUpdate: _drag,
                        onHorizontalDragEnd: _settle,
                      ),
                    ),
                ],
              ),
            );
          },
          child: scope,
        );
      },
    );
  }
}

class _SideMenuScope extends InheritedWidget {
  const _SideMenuScope({required this.state, required this.enabled, required super.child});

  final SideMenuHostState state;
  final bool enabled;

  @override
  bool updateShouldNotify(_SideMenuScope old) => old.enabled != enabled || old.state != state;
}

/// The menu button a page off the side menu shows in place of its back
/// arrow (Expo's hamburger): opens the side menu. Null where there is no
/// menu to open, so the app bar keeps its usual back arrow.
Widget? sideMenuLeading(BuildContext context) {
  final host = SideMenuHost.of(context);
  if (host == null) return null;
  return IconButton(
    key: const ValueKey('side-menu-button'),
    tooltip: 'Menu',
    icon: const Icon(Icons.menu),
    onPressed: host.open,
  );
}
