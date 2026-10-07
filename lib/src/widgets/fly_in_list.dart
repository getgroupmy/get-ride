import 'package:flutter/material.dart';

/// A scrolling list whose items fly in from the right as they arrive and
/// fly back out (folding the gap) as they leave. Items are matched by
/// [idOf], so a list that is re-sorted keeps its cards rather than replaying
/// them.
class FlyInList<T> extends StatefulWidget {
  const FlyInList({
    super.key,
    required this.items,
    required this.idOf,
    required this.itemBuilder,
    this.padding = EdgeInsets.zero,
    this.duration = const Duration(milliseconds: 350),
  });

  final List<T> items;
  final String Function(T) idOf;
  final Widget Function(BuildContext, T) itemBuilder;
  final EdgeInsets padding;
  final Duration duration;

  @override
  State<FlyInList<T>> createState() => _FlyInListState<T>();
}

class _Entry<T> {
  _Entry(this.item, this.controller);
  T item;
  final AnimationController controller;
  bool leaving = false;
}

class _FlyInListState<T> extends State<FlyInList<T>> with TickerProviderStateMixin {
  final _entries = <String, _Entry<T>>{};

  /// The order on screen: the current items, with leaving ones kept where
  /// they were until they are gone.
  final _order = <String>[];

  @override
  void initState() {
    super.initState();
    _sync(animate: false);
  }

  @override
  void didUpdateWidget(covariant FlyInList<T> old) {
    super.didUpdateWidget(old);
    _sync(animate: true);
  }

  void _sync({required bool animate}) {
    final ids = [for (final i in widget.items) widget.idOf(i)];
    final current = ids.toSet();
    for (final item in widget.items) {
      final id = widget.idOf(item);
      final e = _entries[id];
      if (e == null) {
        final c = AnimationController(vsync: this, duration: widget.duration, value: animate ? 0 : 1);
        _entries[id] = _Entry(item, c);
        if (animate) c.forward();
      } else {
        e.item = item;
        if (e.leaving) {
          e.leaving = false;
          e.controller.forward();
        }
      }
    }
    for (final id in _order) {
      final e = _entries[id];
      if (e == null || current.contains(id) || e.leaving) continue;
      e.leaving = true;
      e.controller.reverse().whenComplete(() {
        if (!mounted || !e.leaving) return;
        setState(() {
          _entries.remove(id)?.controller.dispose();
          _order.remove(id);
        });
      });
    }
    // Current items in their order; a leaving one keeps its old place.
    final merged = [...ids];
    for (var i = 0; i < _order.length; i++) {
      final id = _order[i];
      if (current.contains(id) || !(_entries[id]?.leaving ?? false)) continue;
      merged.insert(i.clamp(0, merged.length), id);
    }
    _order
      ..clear()
      ..addAll(merged);
  }

  @override
  void dispose() {
    for (final e in _entries.values) {
      e.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // As tall as its cards (up to the room it is given), so the space
    // below them is left to whatever is underneath (the map).
    return Align(
      alignment: Alignment.topCenter,
      child: ListView(
        shrinkWrap: true,
        padding: widget.padding,
        children: [
          for (final id in _order)
            if (_entries[id] case final e?)
              _Fly(key: ValueKey('fly-$id'), animation: e.controller, child: widget.itemBuilder(context, e.item)),
        ],
      ),
    );
  }
}

class _Fly extends StatelessWidget {
  const _Fly({super.key, required this.animation, required this.child});
  final AnimationController animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return SizeTransition(
      sizeFactor: curved,
      alignment: Alignment.topCenter,
      child: SlideTransition(
        position: Tween(begin: const Offset(1.2, 0), end: Offset.zero).animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      ),
    );
  }
}
