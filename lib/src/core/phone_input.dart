import 'package:flutter/services.dart';

/// The local part of a number with its trunk `0` (and any spaces before it)
/// taken off: the dial code beside the field already stands for it, so
/// `0123456789` is keyed as `123456789`.
String withoutTrunkZero(String local) => local.replaceFirst(RegExp(r'^[\s-]*0+'), '');

/// Drops a leading `0` from a phone field as it is typed or pasted, keeping
/// the cursor where it was relative to the digits that stay.
class NoTrunkZeroFormatter extends TextInputFormatter {
  const NoTrunkZeroFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = withoutTrunkZero(newValue.text);
    if (text == newValue.text) return newValue;
    final removed = newValue.text.length - text.length;
    final offset = (newValue.selection.baseOffset - removed).clamp(0, text.length);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
