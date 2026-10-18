import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'loading_skeleton.dart';
import 'page_style_host.dart';

/// Centres content and caps its width so forms and lists read well on
/// desktop and web as well as phones.
class ResponsiveCenter extends StatelessWidget {
  const ResponsiveCenter({super.key, required this.child, this.maxWidth = 560, this.padding});
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Padding(padding: padding ?? const EdgeInsets.symmetric(horizontal: 16), child: child),
        ),
      );
}

/// Secondary text that still reads (4.5:1) on the page: the theme's
/// onSurfaceVariant, unless an admin colour or a light grey would fail on
/// [background] (the theme's surface by default); then a grey that passes,
/// #6B7280 in light mode and #B4BAC4 in dark.
Color mutedTextColor(ThemeData t, {Color? background}) {
  final c = t.colorScheme.onSurfaceVariant;
  final bg = background ?? t.colorScheme.surface;
  if (contrastRatio(c, bg) >= 4.5) return c;
  return t.brightness == Brightness.light ? const Color(0xFF6B7280) : const Color(0xFFB4BAC4);
}

/// WCAG contrast ratio between two opaque colours (1 to 21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Large single-field numeric code input (OTP / PIN).
class CodeField extends StatelessWidget {
  const CodeField({
    super.key,
    required this.controller,
    required this.length,
    this.obscure = false,
    this.onCompleted,
    this.autofocus = true,
    this.label,
    this.textInputAction,
    this.errorText,
    this.focusNode,
    this.onChanged,
  });
  final TextEditingController controller;
  final int length;
  final bool obscure;
  final bool autofocus;
  final String? label;
  final ValueChanged<String>? onCompleted;

  /// The keyboard's action key (Next to the following field of a form).
  final TextInputAction? textInputAction;

  /// Why the code can't be used, under the field (a PIN that doesn't match).
  final String? errorText;
  final FocusNode? focusNode;

  /// Every change, besides [onCompleted] once all digits are in.
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // No caret over the placeholder dots until the first digit: in their
    // middle it read as three digits already typed.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        showCursor: !obscure || value.text.isNotEmpty,
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        obscureText: obscure,
        keyboardType: TextInputType.number,
        textInputAction: textInputAction,
        textAlign: TextAlign.center,
        maxLength: length,
        autofillHints: obscure ? null : const [AutofillHints.oneTimeCode],
        style: t.textTheme.headlineMedium?.copyWith(letterSpacing: 12),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        // What goes in, while it is empty: dots for a PIN, words for a code.
        decoration: InputDecoration(
          counterText: '',
          labelText: label,
          errorText: errorText,
          errorMaxLines: 2,
          hintText: obscure ? '•' * length : '$length-digit code',
          hintStyle: obscure
              ? t.textTheme.headlineMedium?.copyWith(letterSpacing: 12, color: t.colorScheme.outline)
              : t.textTheme.titleMedium?.copyWith(color: t.colorScheme.outline),
        ),
        onChanged: (v) {
          onChanged?.call(v);
          if (v.length == length) onCompleted?.call(v);
        },
      ),
    );
  }
}

/// Human-readable message for an exception from Supabase or elsewhere.
/// No network: the same words wherever it happens.
const noConnectionMessage = "Couldn't reach GET.ride. Check your connection and try again.";

/// The server didn't answer in time.
const timedOutMessage = 'GET.ride took too long to answer. Try again in a moment.';

/// A fault in the app itself (a type error, an unreadable reply): nothing
/// the user can act on, so a plain line; the detail stays under "Show details".
const genericErrorMessage = 'Something went wrong. Try again.';

bool _isNoConnection(Object e) {
  final s = '$e';
  return s.contains('SocketException') ||
      s.contains('Failed host lookup') ||
      s.contains('ClientException') ||
      s.contains('AuthRetryableFetchException') ||
      s.contains('Connection refused') ||
      s.contains('Network is unreachable');
}

String errorText(Object e) => _isNoConnection(e) ? noConnectionMessage : _errorText(e);

/// Whether [e] is a programming fault or an unreadable reply rather than a
/// message meant for people.
bool _isFault(Object e) =>
    (e is Error && e is! StateError) || e is FormatException || '$e'.startsWith('Instance of ');

/// The technical text behind [errorText], for "Show details"; null when it
/// would only repeat the message. In a release build a bare
/// `Instance of 'minified:…'` says nothing, so it is left out.
String? errorDetails(Object e) {
  final raw = '$e';
  if (kReleaseMode && raw.startsWith('Instance of ')) return null;
  return raw == errorText(e) ? null : raw;
}

String _errorText(Object e) => switch (e) {
      AuthException(:final message) => message,
      // A database refusal named by code (GET_CREDIT_TOO_LOW) says it in its hint.
      PostgrestException(:final message, :final hint)
          when RegExp(r'^[A-Z][A-Z0-9_]+$').hasMatch(message) && (hint ?? '').trim().isNotEmpty =>
        hint!.trim(),
      PostgrestException(:final message) => message,
      StateError(:final message) => message,
      TimeoutException() => timedOutMessage,
      _ when _isFault(e) => genericErrorMessage,
      _ => e.toString().replaceFirst('Exception: ', ''),
    };

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(errorText(e))));
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// A message the rider has to acknowledge: a modal with one OK.
Future<void> showNotice(BuildContext context, {String? title, required String message}) => showAppDialog<void>(id: 'common.show-info',
  context: context,
  builder: (c) => AlertDialog(
    key: const ValueKey('notice'),
    title: title == null ? null : Text(title),
    content: Text(message),
    actions: [
      FilledButton(key: const ValueKey('notice-ok'), onPressed: () => Navigator.pop(c), child: const Text('OK')),
    ],
  ),
);

/// Booking a ride is locked while the driver is online.
Future<void> showGoOfflineToBook(BuildContext context) => showNotice(
  context,
  title: "You're online",
  message: 'Go offline to book a ride.',
);

/// Loading / error / data switch for a Riverpod [AsyncValue].
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.data, this.onRetry, this.errorTitle});
  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;

  /// Said instead of "Something went wrong" and the error's own words
  /// ("Couldn't load the report"); the raw error stays under details.
  final String? errorTitle;

  @override
  Widget build(BuildContext context) => value.when(
        // A live settings change re-reads in place: the screen keeps what it
        // shows until the fresh data lands instead of flashing a spinner.
        skipLoadingOnReload: true,
        data: data,
        loading: () => const LoadingSkeletonPage(),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: errorTitle ?? 'Something went wrong',
          message: errorTitle == null ? errorText(e) : null,
          details: errorDetails(e),
          action: onRetry == null ? null : TextButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.details, this.action});
  final IconData icon;
  final String title;
  final String? message;

  /// Technical text kept behind "Show details" (an error's raw form).
  final String? details;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Scrolls where it is short (a phone on its side, the keyboard up).
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: t.colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center),
          ],
          if (details != null) _ErrorDetails(details!),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ]),
      ),
    );
  }
}

/// "Show details": the raw error, folded away until asked for.
class _ErrorDetails extends StatefulWidget {
  const _ErrorDetails(this.details);
  final String details;

  @override
  State<_ErrorDetails> createState() => _ErrorDetailsState();
}

class _ErrorDetailsState extends State<_ErrorDetails> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      TextButton(
        key: const ValueKey('error-details'),
        onPressed: () => setState(() => _open = !_open),
        child: Text(_open ? 'Hide details' : 'Show details'),
      ),
      if (_open)
        SelectableText(
          widget.details,
          textAlign: TextAlign.center,
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
    ]);
  }
}

/// The status bar's icons for a page with no app bar to set them (a map
/// under the status bar, the welcome page): dark on a light theme, light on
/// a dark one, so they stay readable after coming back from other pages.
class ThemedStatusBar extends StatelessWidget {
  const ThemedStatusBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: Theme.of(context).brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    child: child,
  );
}

/// A [NavigationRail] that scrolls when its destinations don't fit the
/// height (a tablet on its side, a short window) instead of overflowing,
/// and fills the height as usual when they do.
class ScrollableRail extends StatelessWidget {
  const ScrollableRail({super.key, required this.rail});

  final NavigationRail rail;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: box.maxHeight),
        child: IntrinsicHeight(child: rail),
      ),
    ),
  );
}

/// A [SegmentedButton] segment's label on one line, shrunk to fit rather
/// than broken mid-word at large text or on a narrow phone.
class SegmentLabel extends StatelessWidget {
  const SegmentLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Text.rich(
      TextSpan(children: [
        const TextSpan(text: 'GET'),
        TextSpan(text: '.ride', style: TextStyle(color: const Color(0xFF2DABE2), fontWeight: FontWeight.w400)),
      ]),
      style: t.textTheme.headlineMedium?.copyWith(fontSize: size, fontWeight: FontWeight.w800),
    );
  }
}
