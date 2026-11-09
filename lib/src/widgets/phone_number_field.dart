import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart' show AppConfig;
import '../core/dial_countries.dart' show DialCountry;
import '../core/contact_phone.dart' show composeContactPhone, splitContactPhone;
import '../core/phone_input.dart' show NoTrunkZeroFormatter;
import 'dial_country_picker.dart';

/// The one phone input used across the app: a country-code picker beside the
/// national number, the same shape as the sign-in screen. The national number's
/// trunk `0` is dropped before it is joined to the dial code, and [onChanged]
/// fires the composed E.164 (empty string when there is no number). Seed it with
/// a stored number through [initialPhone] — it splits the dial code back off so
/// the picker and field show the right parts. A value already starting with `+`
/// (another country's code keyed in by hand) is kept whole.
///
/// Pass [keyPrefix] when more than one field sits on a screen so the inner
/// picker / field / clear button get distinct keys (`<prefix>-dial-country`,
/// `<prefix>-number`, `<prefix>-clear`).
class PhoneNumberField extends StatefulWidget {
  const PhoneNumberField({
    super.key,
    this.initialPhone,
    this.label,
    this.hintText = '123456789',
    this.autofocus = false,
    this.enabled = true,
    this.defaultDialCode,
    this.keyPrefix,
    required this.onChanged,
  });

  /// The stored number to pre-fill from (E.164 like `+60123456789`, or a bare
  /// local number); null or empty starts on the default country, empty field.
  final String? initialPhone;

  /// An optional label shown above the field.
  final String? label;
  final String hintText;
  final bool autofocus;
  final bool enabled;

  /// The country to start on when [initialPhone] has no `+` code; defaults to
  /// [AppConfig.defaultDialCode].
  final String? defaultDialCode;

  /// Prefix for the inner widgets' keys, for screens with several phone fields.
  final String? keyPrefix;

  /// Fires the composed E.164 on every change (`''` when the number is blank).
  final ValueChanged<String> onChanged;

  @override
  State<PhoneNumberField> createState() => _PhoneNumberFieldState();
}

class _PhoneNumberFieldState extends State<PhoneNumberField> {
  late DialCountry _country;
  late final TextEditingController _number;

  @override
  void initState() {
    super.initState();
    final split = splitContactPhone(
        widget.initialPhone, defaultDialCode: widget.defaultDialCode ?? AppConfig.defaultDialCode);
    _country = split.country;
    _number = TextEditingController(text: split.local);
    _number.addListener(_onNumber);
  }

  @override
  void dispose() {
    _number.removeListener(_onNumber);
    _number.dispose();
    super.dispose();
  }

  void _onNumber() {
    setState(() {});
    widget.onChanged(composeContactPhone(_country.dialCode, _number.text));
  }

  Future<void> _pick() async {
    final picked = await showDialCountryPicker(context, selected: _country);
    if (picked != null && mounted) {
      setState(() => _country = picked);
      widget.onChanged(composeContactPhone(_country.dialCode, _number.text));
    }
  }

  Key? _k(String suffix) => widget.keyPrefix == null ? null : ValueKey('${widget.keyPrefix}-$suffix');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final row = Container(
      padding: const EdgeInsets.only(left: 6, right: 4),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.colorScheme.outline),
      ),
      child: Row(children: [
        Semantics(
          button: true,
          label: DialCountryButton.semanticsLabelFor(_country),
          excludeSemantics: true,
          onTap: widget.enabled ? _pick : null,
          child: InkWell(
            key: _k('dial-country'),
            borderRadius: BorderRadius.circular(10),
            onTap: widget.enabled ? _pick : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                DialCountryFlag(_country),
                const Icon(Icons.arrow_drop_down),
              ]),
            ),
          ),
        ),
        Text(_country.dialCode, style: t.textTheme.titleMedium),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            key: _k('number'),
            controller: _number,
            autofocus: widget.autofocus,
            enabled: widget.enabled,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d\s-]')), const NoTrunkZeroFormatter()],
            style: t.textTheme.titleMedium,
            decoration: InputDecoration(
              hintText: widget.hintText,
              border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
              filled: false, isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        if (_number.text.isNotEmpty && widget.enabled)
          IconButton(
            key: _k('clear'),
            tooltip: 'Clear',
            icon: Icon(Icons.cancel, color: t.colorScheme.onSurfaceVariant),
            onPressed: _number.clear,
          ),
      ]),
    );
    if (widget.label == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(widget.label!, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
        row,
      ],
    );
  }
}
