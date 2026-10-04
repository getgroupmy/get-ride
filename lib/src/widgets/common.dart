import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  });
  final TextEditingController controller;
  final int length;
  final bool obscure;
  final bool autofocus;
  final String? label;
  final ValueChanged<String>? onCompleted;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        autofocus: autofocus,
        obscureText: obscure,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: length,
        autofillHints: obscure ? null : const [AutofillHints.oneTimeCode],
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 12),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(counterText: '', labelText: label),
        onChanged: (v) {
          if (v.length == length) onCompleted?.call(v);
        },
      );
}

/// Human-readable message for an exception from Supabase or elsewhere.
String errorText(Object e) => switch (e) {
      AuthException(:final message) => message,
      PostgrestException(:final message) => message,
      StateError(:final message) => message,
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

/// Loading / error / data switch for a Riverpod [AsyncValue].
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.data, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => value.when(
        data: data,
        loading: () => const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: 'Something went wrong',
          message: errorText(e),
          action: onRetry == null ? null : TextButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
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
          if (action != null) ...[const SizedBox(height: 12), action!],
        ]),
      ),
    );
  }
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
