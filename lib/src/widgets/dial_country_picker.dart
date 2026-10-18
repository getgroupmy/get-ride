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

/// The button beside a phone field: the country's flag and dial code.
class DialCountryButton extends StatelessWidget {
  const DialCountryButton({super.key, required this.country, required this.onPressed, this.height = 52});

  final DialCountry country;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    style: OutlinedButton.styleFrom(minimumSize: Size(0, height), padding: const EdgeInsets.symmetric(horizontal: 12)),
    onPressed: onPressed,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(country.flag, style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 6),
        Text(country.dialCode),
        const Icon(Icons.arrow_drop_down),
      ],
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
                          leading: Text(list[i].flag, style: const TextStyle(fontSize: 24)),
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
