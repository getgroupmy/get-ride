import 'package:flutter/material.dart';

import '../core/dial_countries.dart';

/// Opens the country picker (Expo's): search by name, ISO code or dial
/// code. Null when it was dismissed.
Future<DialCountry?> showDialCountryPicker(BuildContext context) => showModalBottomSheet<DialCountry>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const DialCountrySheet(),
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
  const DialCountrySheet({super.key});

  @override
  State<DialCountrySheet> createState() => _DialCountrySheetState();
}

class _DialCountrySheetState extends State<DialCountrySheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final list = searchDialCountries(_query);
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
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: list.length,
                      itemBuilder: (c, i) => ListTile(
                        key: ValueKey('country-${list[i].code}'),
                        leading: Text(list[i].flag, style: const TextStyle(fontSize: 24)),
                        title: Text(list[i].name),
                        trailing: Text(list[i].dialCode),
                        onTap: () => Navigator.pop(c, list[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
