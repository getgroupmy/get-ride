import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'geo_data.dart';
import 'geo_logic.dart';

/// Debounced OpenStreetMap place search (≥ 3 letters, 450 ms) used by the
/// airport form and the multi-gate places screen. Replaces the Expo
/// Google/assigned-provider search; no API key involved.
class PlaceSearchField extends ConsumerStatefulWidget {
  const PlaceSearchField({
    super.key,
    required this.onPicked,
    this.hint = 'Search places',
    this.nameKeys = placeNameKeys,
    this.dedupeDigits = 4,
    this.maxResults = 8,
    this.isAdded,
    this.inline = true,
  });

  final ValueChanged<PlaceResult> onPicked;
  final String hint;
  final List<String> nameKeys;
  final int dedupeDigits;
  final int maxResults;

  /// Marks results that already exist (shown disabled with a tick).
  final bool Function(PlaceResult r)? isAdded;

  /// Clears the query after a pick (form use); list use keeps it.
  final bool inline;

  @override
  ConsumerState<PlaceSearchField> createState() => _PlaceSearchFieldState();
}

class _PlaceSearchFieldState extends ConsumerState<PlaceSearchField> {
  final _c = TextEditingController();
  Timer? _debounce;
  int _seq = 0;
  bool _searching = false;
  String _error = '';
  List<PlaceResult> _results = [];

  @override
  void dispose() {
    _debounce?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    final q = v.trim();
    final seq = ++_seq;
    if (q.length < 3) {
      setState(() {
        _results = [];
        _searching = false;
        _error = '';
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = '';
    });
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final list = await ref.read(osmLookupProvider).places(q, nameKeys: widget.nameKeys);
        if (!mounted || seq != _seq) return;
        setState(() => _results = dedupePlaces(list, digits: widget.dedupeDigits));
      } catch (_) {
        if (mounted && seq == _seq) setState(() => _error = 'Search failed. Try again.');
      } finally {
        if (mounted && seq == _seq) setState(() => _searching = false);
      }
    });
  }

  void _clear() {
    _c.clear();
    _changed('');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = _c.text.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _c,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: widget.hint,
          isDense: true,
          suffixIcon: _searching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : q.isEmpty
                  ? null
                  : IconButton(icon: const Icon(Icons.close), onPressed: _clear),
        ),
        onChanged: _changed,
      ),
      if (_error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_error, style: TextStyle(color: t.colorScheme.error)),
        ),
      if (q.length >= 3 && !_searching && _error.isEmpty && _results.isEmpty)
        const Padding(padding: EdgeInsets.only(top: 6), child: Text('No places found.')),
      for (final r in _results.take(widget.maxResults))
        Builder(builder: (_) {
          final added = widget.isAdded?.call(r) ?? false;
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined),
            title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(r.address, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: added
                ? Icon(Icons.check_circle, color: t.colorScheme.primary)
                : const Text('OSM', style: TextStyle(fontSize: 11)),
            enabled: !added,
            onTap: () {
              widget.onPicked(r);
              if (widget.inline) _clear();
            },
          );
        }),
    ]);
  }
}
