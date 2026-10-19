/// A date typed in three boxes — day, month, year — in the order the user's
/// country writes dates (`core/date_order.dart`), with the calendar as a
/// shortcut. Every date the user enters in the app goes through
/// [DateBoxesField]; `test/date_boxes_test.dart` fails on a new single-box
/// date field or a bare `showDatePicker`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/date_order.dart';

export '../core/date_order.dart'
    show DateOrder, formatDateForUser, formatStoredDateForUser, isoDate, parseIsoDate, userDateOrder;

/// Opens the calendar on [initial] (kept within [firstDate]..[lastDate])
/// and returns the picked day. The one place the app calls `showDatePicker`
/// for a date the user enters; the calendar alone, since the boxes are the
/// typed way in.
Future<DateTime?> pickDateFromCalendar(
  BuildContext context, {
  DateTime? initial,
  DateTime? firstDate,
  DateTime? lastDate,
  String? helpText,
}) {
  final first = firstDate ?? DateTime(1900);
  final last = lastDate ?? DateTime(2200, 12, 31);
  var at = initial ?? DateTime.now();
  if (at.isBefore(first)) at = first;
  if (at.isAfter(last)) at = last;
  return showDatePicker(
    context: context,
    initialDate: at,
    firstDate: first,
    lastDate: last,
    helpText: helpText,
    initialEntryMode: DatePickerEntryMode.calendarOnly,
  );
}

/// A date in three boxes, in a [Form] or on its own.
///
/// Typing fills a box and moves to the next; backspace in an empty box goes
/// back. Pasting a whole date ("12/05/2027", "2027-05-12") into any box
/// fills all three. Under the boxes it says what is wrong: a box left
/// blank, 31 February, or a day outside [firstDate]..[lastDate].
///
/// With a [controller] the date is kept there as `yyyy-mm-dd` (blank when
/// the boxes are, the typed text when it is not a date yet), as the fields
/// these replace stored it; setting its text fills the boxes.
class DateBoxesField extends StatefulWidget {
  const DateBoxesField({
    super.key,
    required this.label,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.onSaved,
    this.validator,
    this.firstDate,
    this.lastDate,
    this.beforeFirstText,
    this.afterLastText,
    this.isRequired = false,
    this.order,
    this.calendarButton = true,
    this.enabled = true,
    this.helperText,
    this.autovalidateMode = AutovalidateMode.onUserInteraction,
  });

  /// What the date is: "Expiry date". Shown above the boxes and read out
  /// with each box ("Expiry date, day").
  final String label;
  final TextEditingController? controller;
  final DateTime? initialValue;

  /// Each edit, with the date, or null while it is not a whole valid date.
  final ValueChanged<DateTime?>? onChanged;
  final FormFieldSetter<DateTime>? onSaved;

  /// A further check of a valid date.
  final FormFieldValidator<DateTime>? validator;
  final DateTime? firstDate, lastDate;

  /// Replace "The date can't be in the past" and the like.
  final String? beforeFirstText, afterLastText;
  final bool isRequired;

  /// The box order; the user's country's when null.
  final DateOrder? order;

  /// The calendar shortcut beside the boxes.
  final bool calendarButton;
  final bool enabled;
  final String? helperText;
  final AutovalidateMode autovalidateMode;

  @override
  State<DateBoxesField> createState() => DateBoxesFieldState();
}

class DateBoxesFieldState extends State<DateBoxesField> {
  final _field = GlobalKey<FormFieldState<DateTime>>();
  late final Map<DatePart, TextEditingController> _boxes = {
    for (final p in DatePart.values) p: TextEditingController(),
  };
  late final Map<DatePart, FocusNode> _nodes = {
    for (final p in DatePart.values) p: FocusNode(debugLabel: 'date-${p.name}', onKeyEvent: (_, e) => _onKey(p, e)),
  };
  final Map<DatePart, String> _was = {for (final p in DatePart.values) p: ''};

  /// What this field last wrote to [DateBoxesField.controller].
  String? _wrote;
  bool _pasted = false;

  DateOrder get _order => widget.order ?? userDateOrder();
  List<DatePart> get _parts => datePartsIn(_order);

  /// The date in the boxes, or null while it is not a valid one.
  DateTime? get value => _check().date;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    if (c != null) {
      _fill(c.text);
      c.addListener(_external);
    } else if (widget.initialValue != null) {
      _fillDate(widget.initialValue!);
    }
    for (final p in DatePart.values) {
      _nodes[p]!.addListener(() => _onFocus(p));
    }
  }

  @override
  void didUpdateWidget(DateBoxesField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_external);
      widget.controller?.addListener(_external);
      if (widget.controller != null) _external();
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_external);
    for (final c in _boxes.values) {
      c.dispose();
    }
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _external() {
    final c = widget.controller!;
    if (c.text == _wrote) return;
    _wrote = c.text;
    setState(() => _fill(c.text));
  }

  /// Fills the boxes from stored or typed text.
  void _fill(String text) {
    final parts = text.trim().isEmpty ? <DatePart, String>{} : splitDateText(text, _order);
    if (parts == null) return;
    for (final p in DatePart.values) {
      _set(p, parts[p] ?? '');
    }
  }

  void _fillDate(DateTime d) => _fill(isoDate(d));

  void _set(DatePart p, String text) {
    _boxes[p]!.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _was[p] = text;
  }

  DateBoxesCheck _check() => checkDateBoxes(
        day: _boxes[DatePart.day]!.text,
        month: _boxes[DatePart.month]!.text,
        year: _boxes[DatePart.year]!.text,
        firstDate: widget.firstDate,
        lastDate: widget.lastDate,
        required: widget.isRequired,
        beforeFirst: widget.beforeFirstText,
        afterLast: widget.afterLastText,
        order: _order,
      );

  String? _validate(DateTime? _) {
    final c = _check();
    if (c.error != null) return c.error;
    return widget.validator?.call(c.date);
  }

  /// After any change: the controller, the form and [DateBoxesField.onChanged].
  void _changed() {
    final c = _check();
    final c0 = widget.controller;
    if (c0 != null) {
      final allBlank = DatePart.values.every((p) => _boxes[p]!.text.isEmpty);
      final text = c.date != null
          ? isoDate(c.date!)
          : allBlank
              ? ''
              : _parts.map((p) => _boxes[p]!.text).join('/');
      _wrote = text;
      if (c0.text != text) c0.text = text;
    }
    _field.currentState?.didChange(c.date);
    widget.onChanged?.call(c.date);
  }

  void _focus(DatePart p, {required bool selectAll}) {
    final c = _boxes[p]!;
    _nodes[p]!.requestFocus();
    c.selection = selectAll
        ? TextSelection(baseOffset: 0, extentOffset: c.text.length)
        : TextSelection.collapsed(offset: c.text.length);
  }

  DatePart? _next(DatePart p) {
    final i = _parts.indexOf(p);
    return i + 1 < _parts.length ? _parts[i + 1] : null;
  }

  DatePart? _prev(DatePart p) {
    final i = _parts.indexOf(p);
    return i > 0 ? _parts[i - 1] : null;
  }

  void _onBoxChanged(DatePart p, String text) {
    final was = _was[p]!;
    _was[p] = text;
    if (_pasted) {
      _pasted = false;
      _focus(_parts.last, selectAll: false);
    } else if (text.length >= datePartLength(p) && text != was) {
      final n = _next(p);
      if (n != null) _focus(n, selectAll: true);
    } else if (text.isEmpty && was.isNotEmpty) {
      final b = _prev(p);
      if (b != null) _focus(b, selectAll: false);
    }
    setState(_changed);
  }

  KeyEventResult _onKey(DatePart p, KeyEvent e) {
    if (e is KeyUpEvent || e.logicalKey != LogicalKeyboardKey.backspace) return KeyEventResult.ignored;
    if (_boxes[p]!.text.isNotEmpty) return KeyEventResult.ignored;
    final b = _prev(p);
    if (b == null) return KeyEventResult.ignored;
    _focus(b, selectAll: false);
    return KeyEventResult.handled;
  }

  /// Leaving a day or month box with one digit writes it as two ("5" → "05").
  void _onFocus(DatePart p) {
    if (_nodes[p]!.hasFocus || p == DatePart.year) return;
    final t = _boxes[p]!.text;
    if (t.length == 1 && t != '0') {
      _set(p, '0$t');
      if (mounted) setState(_changed);
    }
  }

  /// A whole date pasted (or typed by a keyboard that sends it at once)
  /// into one box: every box takes its part.
  bool _paste(DatePart into, String text) {
    final parts = splitDateText(text, _order);
    if (parts == null) return false;
    for (final p in DatePart.values) {
      if (p != into) _set(p, parts[p]!);
    }
    _pasted = true;
    // When the box's own part is what it already held, no change comes.
    Future.microtask(() {
      if (!mounted || !_pasted) return;
      _pasted = false;
      _focus(_parts.last, selectAll: false);
      setState(_changed);
    });
    return true;
  }

  Future<void> _calendar() async {
    final picked = await pickDateFromCalendar(
      context,
      initial: value,
      firstDate: widget.firstDate,
      lastDate: widget.lastDate,
      helpText: widget.label,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _fillDate(picked);
      _changed();
    });
  }

  @override
  Widget build(BuildContext context) => FormField<DateTime>(
        key: _field,
        initialValue: value,
        enabled: widget.enabled,
        autovalidateMode: widget.autovalidateMode,
        validator: _validate,
        onSaved: (_) => widget.onSaved?.call(value),
        builder: (field) => _build(context, field.errorText),
      );

  Widget _build(BuildContext context, String? error) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final parts = _parts;
    // A gap rather than a slash: the boxes' own labels say which is which.
    const sep = SizedBox(width: 8);
    final below = error ?? widget.helperText;
    final calendar = widget.calendarButton
        ? IconButton(
            key: const ValueKey('date-box-calendar'),
            tooltip: 'Choose from calendar',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: widget.enabled ? _calendar : null,
          )
        : null;
    final title = ExcludeSemantics(
      child: Text(
        widget.label,
        style: t.textTheme.bodyMedium?.copyWith(color: error != null ? cs.error : cs.onSurfaceVariant),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: LayoutBuilder(builder: (context, size) {
        // On a narrow dialog the calendar sits beside the name, leaving the
        // whole width to the boxes.
        final inline = size.maxWidth >= 320;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (inline || calendar == null)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: title)
            else
              Row(children: [Expanded(child: title), calendar]),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var i = 0; i < parts.length; i++) ...[
                  if (i > 0) sep,
                  Flexible(
                    flex: parts[i] == DatePart.year ? 8 : 5,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: parts[i] == DatePart.year ? 120 : 80),
                      child: _box(context, parts[i], error != null),
                    ),
                  ),
                ],
                if (inline && calendar != null) calendar,
              ],
            ),
            if (below != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  below,
                  key: error != null ? const ValueKey('date-box-error') : null,
                  style: t.textTheme.bodySmall?.copyWith(color: error != null ? cs.error : cs.onSurfaceVariant),
                ),
              ),
          ],
        );
      }),
    );
  }

  Widget _box(BuildContext context, DatePart p, bool hasError) {
    final cs = Theme.of(context).colorScheme;
    OutlineInputBorder border(Color c, [double w = 1]) =>
        OutlineInputBorder(borderSide: BorderSide(color: c, width: w), borderRadius: BorderRadius.circular(8));
    final label = datePartLabel(p);
    return Semantics(
      label: '${widget.label}, ${datePartName(p)}',
      child: TextField(
        key: ValueKey('date-box-${p.name}'),
        controller: _boxes[p],
        focusNode: _nodes[p],
        enabled: widget.enabled,
        keyboardType: TextInputType.number,
        textInputAction: p == _parts.last ? TextInputAction.done : TextInputAction.next,
        textAlign: TextAlign.center,
        inputFormatters: [_BoxInput(this, p)],
        onChanged: (v) => _onBoxChanged(p, v),
        onSubmitted: (_) {
          final n = _next(p);
          if (n != null) _focus(n, selectAll: true);
        },
        decoration: InputDecoration(
          labelText: label,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          floatingLabelAlignment: FloatingLabelAlignment.center,
          hintText: p == DatePart.year ? '0000' : '00',
          hintStyle: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.45)),
          labelStyle: TextStyle(color: hasError ? cs.error : null),
          floatingLabelStyle: TextStyle(color: hasError ? cs.error : null),
          isDense: true,
          counterText: '',
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          enabledBorder: border(hasError ? cs.error : cs.outline),
          focusedBorder: border(hasError ? cs.error : cs.primary, 2),
          disabledBorder: border(cs.outline.withValues(alpha: 0.38)),
          border: border(cs.outline),
        ),
      ),
    );
  }
}

/// Digits only, as many as the box holds; a whole date pasted in fills
/// every box. A first day digit of 4–9 or month digit of 2–9 can only be
/// one number, so it is written with its leading zero ("7" → "07").
class _BoxInput extends TextInputFormatter {
  _BoxInput(this.state, this.part);
  final DateBoxesFieldState state;
  final DatePart part;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue now) {
    final max = datePartLength(part);
    final text = now.text;
    final digits = text.replaceAll(RegExp(r'\D'), '');
    if ((text.length - old.text.length > 1 || digits.length > max) && state._paste(part, text)) {
      final own = splitDateText(text, state._order)![part]!;
      return TextEditingValue(text: own, selection: TextSelection.collapsed(offset: own.length));
    }
    var out = digits.length > max ? digits.substring(0, max) : digits;
    final replacing = old.text.isEmpty || (old.selection.start == 0 && old.selection.end == old.text.length);
    if (replacing && out.length == 1) {
      final n = int.parse(out);
      if ((part == DatePart.day && n > 3) || (part == DatePart.month && n > 1)) out = '0$out';
    }
    if (out == now.text) return now;
    return TextEditingValue(text: out, selection: TextSelection.collapsed(offset: out.length));
  }
}
