/// Browser Back for sheets, modals and side menus on the web (tester
/// finding #48).
///
/// A sheet, modal or side menu adds no entry to the browser's history, so on
/// the web the browser's Back left the page under it (or the site) instead
/// of closing it. While one is open, an entry for the same address sits on
/// top of the page's own one, carrying a marker: Back lands on the page's
/// entry again, and the overlay above it closes instead of the router
/// moving. When an overlay closes any other way (Cancel, a tap outside,
/// Escape, a swipe, the app closing it), its entry is taken off again, so
/// the next Back still leaves the page.
///
/// Pure bookkeeping over an [OverlayHistory]; the browser's side is in
/// widgets/web_overlay_back.dart. Off the web it is switched off and does
/// nothing at all.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// The key the marker sits under in a history entry's state.
const overlayBackMarkerKey = 'getRideOverlay';

/// The marker in a history entry's [state], if it is an overlay's entry.
String? overlayMarkerIn(Object? state) {
  if (state is! Map) return null;
  final m = state[overlayBackMarkerKey];
  return m is String ? m : null;
}

/// The browser's history as [OverlayBackStack] uses it.
abstract interface class OverlayHistory {
  /// The address shown now, to tell a Back to this page from one further.
  String get page;

  /// Adds an entry for the address shown now carrying [marker], on top.
  Future<void> push(String marker);

  /// Moves [delta] entries through the history (negative is back). The
  /// move lands later, through [OverlayBackStack.onPop].
  void go(int delta);

  /// After a move [OverlayBackStack] made has landed: puts back the router's
  /// address if a navigation in the meantime was undone by it.
  Future<void> settled();
}

/// One open overlay's history entry.
class OverlayBackEntry {
  OverlayBackEntry._(this.marker, this._close, this.page);

  final String marker;
  final VoidCallback _close;

  /// The address it was opened on.
  final String page;

  bool _open = true;
  bool _pushed = false;

  bool get isOpen => _open;
}

/// The open overlays' history entries, bottom to top.
class OverlayBackStack {
  OverlayBackStack(this._history, {this.enabled = true, String? session})
    : _session = session ?? DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  final OverlayHistory _history;

  /// Off off the web: nothing is pushed, nothing intercepted.
  final bool enabled;

  /// Tells this run's markers from an earlier one's (before a reload).
  final String _session;
  int _next = 0;

  final _entries = <OverlayBackEntry>[];

  /// History changes run one after the other: a push made while a move
  /// back is still on its way would be undone by it.
  Future<void> _queue = Future<void>.value();
  Completer<void>? _landing;
  bool _unwindQueued = false;

  /// The overlays open with an entry, bottom to top.
  @visibleForTesting
  List<String> get markers => [for (final e in _entries) if (e._open) e.marker];

  void _run(Future<void> Function() step) {
    _queue = _queue.then((_) => step()).catchError((Object _) {});
  }

  /// An overlay opened: a Back now calls [close] instead of leaving the
  /// page. Null when switched off. Hand the result to [closed] once the
  /// overlay is closed, however that happened.
  OverlayBackEntry? open(VoidCallback close) {
    if (!enabled) return null;
    final e = OverlayBackEntry._('$_session-${_next++}', close, _history.page);
    _entries.add(e);
    _run(() async {
      // Opened and closed before its turn: it never needs an entry.
      if (!e._open) {
        _entries.remove(e);
        return;
      }
      await _history.push(e.marker);
      e._pushed = true;
    });
    return e;
  }

  /// [entry]'s overlay closed. When it closed some other way than a Back,
  /// its history entry (and those of overlays closed above it) goes.
  void closed(OverlayBackEntry? entry) {
    if (entry == null || !entry._open) return;
    entry._open = false;
    if (!_entries.contains(entry) || _unwindQueued) return;
    _unwindQueued = true;
    _run(_unwind);
  }

  Future<void> _unwind() async {
    _unwindQueued = false;
    var back = 0;
    for (var i = _entries.length - 1; i >= 0; i--) {
      final e = _entries[i];
      if (e._open) break;
      if (e._pushed) back++;
      _entries.removeAt(i);
    }
    if (back == 0) return;
    final landing = _landing = Completer<void>();
    _history.go(-back);
    // A browser that ignores the move (no entry to go to) never answers.
    await landing.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    _landing = null;
    await _history.settled();
  }

  /// The browser moved to the entry carrying [marker] (null for a page's
  /// own entry) at address [page]. True when that was a Back over open
  /// overlays, now closed, and the router should not move.
  bool onPop(String? marker, String page) {
    final landing = _landing;
    if (landing != null && !landing.isCompleted) {
      // The move [_unwind] made: nothing to do for anyone.
      landing.complete();
      return true;
    }
    if (!enabled || _entries.isEmpty) return false;
    final at = marker == null ? -1 : _entries.indexWhere((e) => e.marker == marker);
    // Another visit's entry (one from before a reload): the router's.
    if (marker != null && at < 0) return false;
    final above = _entries.sublist(at + 1);
    if (above.isEmpty) return false;
    _entries.removeRange(at + 1, _entries.length);
    for (final e in above.reversed) {
      if (!e._open) continue;
      e._open = false;
      e._close();
    }
    // Back to the page under them, or further (the browser's history
    // list): then the router goes there too.
    return at >= 0 || page == above.first.page;
  }
}

/// A side menu or drawer's entry, for one that opens and closes in place.
class OverlayBackSlot {
  OverlayBackSlot(this._stack);

  final OverlayBackStack Function() _stack;
  OverlayBackEntry? _entry;

  /// The menu opened ([open]) or closed; [close] closes it on a Back.
  void set(bool open, VoidCallback close) {
    final e = _entry;
    if (open) {
      if (e == null || !e.isOpen) _entry = _stack().open(close);
    } else {
      _entry = null;
      _stack().closed(e);
    }
  }
}
