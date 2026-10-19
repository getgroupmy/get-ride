import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';

import '../core/dial_countries.dart';
import 'page_style_host.dart';

/// Opens the country picker (Expo's): search by name, ISO code or dial
/// code, with [selected] ticked and scrolled to. Null when it was dismissed.
Future<DialCountry?> showDialCountryPicker(BuildContext context, {DialCountry? selected}) =>
    showAppSheet<DialCountry>(id: 'dial-country-picker',
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => DialCountrySheet(selected: selected),
);

/// Set in tests to draw flags as on the web (true) or on a phone (false).
@visibleForTesting
bool? debugFlagsAsCodes;

/// Whether flags are drawn as their ISO code: on the web, where the emoji
/// flag would fetch a ~700 KB colour emoji font just for itself.
bool get flagsAsCodes => debugFlagsAsCodes ?? kIsWeb;

/// [country]'s flag: the emoji on Android and iOS; on the web its ISO code
/// ("MY") in a small rounded chip. Left to the caller's label for screen
/// readers (the country's name), so it says nothing itself.
class DialCountryFlag extends StatelessWidget {
  const DialCountryFlag(this.country, {super.key, this.size = 24});

  final DialCountry country;

  /// The emoji's font size; the chip is about as tall.
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!flagsAsCodes) return ExcludeSemantics(child: Text(country.flag, style: TextStyle(fontSize: size)));
    final t = Theme.of(context);
    return ExcludeSemantics(
      child: Container(
        key: ValueKey('flag-code-${country.code}'),
        constraints: BoxConstraints(minWidth: size * 1.3, minHeight: size * 0.95),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: t.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        // As small as the code, at least the chip's size: not the row's width.
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Text(
            country.code,
            style: TextStyle(
              fontSize: size * 0.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: t.colorScheme.onSurface,
              height: 1.1,
            ),
          ),
        ),
      ),
    );
  }
}

/// The button beside a phone field: the country's flag and dial code.
class DialCountryButton extends StatelessWidget {
  const DialCountryButton({super.key, required this.country, required this.onPressed, this.height = 52});

  final DialCountry country;
  final VoidCallback? onPressed;
  final double height;

  /// What a screen reader says: "Country code +60, Malaysia", not the flag.
  static String semanticsLabelFor(DialCountry c) => 'Country code ${c.dialCode}, ${c.name}';

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: semanticsLabelFor(country),
    excludeSemantics: true,
    onTap: onPressed,
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: Size(0, height), padding: const EdgeInsets.symmetric(horizontal: 12)),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DialCountryFlag(country, size: 20),
          const SizedBox(width: 6),
          Text(country.dialCode),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    ),
  );
}

/// Pick a country by name, code or dial code.
class DialCountrySheet extends StatefulWidget {
  const DialCountrySheet({super.key, this.selected});

  /// The country chosen now: ticked, and the list opens on it.
  final DialCountry? selected;

  @override
  State<DialCountrySheet> createState() => _DialCountrySheetState();
}

class _DialCountrySheetState extends State<DialCountrySheet> {
  String _query = '';
  ScrollController? _scroll;

  bool _isSelected(DialCountry c) =>
      widget.selected != null && c.code == widget.selected!.code && c.dialCode == widget.selected!.dialCode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Opens with the chosen country in view, two rows down from the top; a
    // row is about 56 px, more at large text.
    if (_scroll == null) {
      final i = searchDialCountries('').indexWhere(_isSelected);
      final row = MediaQuery.textScalerOf(context).scale(56);
      _scroll = ScrollController(initialScrollOffset: i <= 2 ? 0 : (i - 2) * row);
    }
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = searchDialCountries(_query);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                key: const ValueKey('country-search'),
                // The sheet is there to search: typing goes straight in.
                autofocus: true,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search country or code'),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('No country found'))
                  : ListView.builder(
                      controller: _query.isEmpty ? _scroll : null,
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: list.length,
                      itemBuilder: (c, i) {
                        final on = _isSelected(list[i]);
                        return ListTile(
                          key: ValueKey('country-${list[i].code}'),
                          selected: on,
                          selectedTileColor: scheme.secondaryContainer,
                          selectedColor: scheme.onSecondaryContainer,
                          leading: DialCountryFlag(list[i]),
                          title: Text(list[i].name),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(list[i].dialCode),
                              if (on) ...[
                                const SizedBox(width: 8),
                                Icon(Icons.check, key: const ValueKey('country-selected'), color: scheme.primary),
                              ],
                            ],
                          ),
                          onTap: () => Navigator.pop(c, list[i]),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
