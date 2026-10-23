// The full message of an admin push (push_message.dart): the picture on
// top, then its headings, paragraphs, bullet lists, buttons and pictures.
// Used by the page a push opens and by the composer's preview.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/push_message.dart';
import 'media_image.dart';

class PushMessageView extends StatefulWidget {
  const PushMessageView({
    super.key,
    required this.blocks,
    this.imageUrl,
    this.onLink,
    this.padding = const EdgeInsets.all(16),
  });

  final List<PushBlock> blocks;

  /// The push's picture, shown full width on top.
  final String? imageUrl;

  /// A link or a button was tapped: an in-app route or an http(s) address
  /// (isSafePushLink). Null shows them without opening anything (preview).
  final ValueChanged<String>? onLink;
  final EdgeInsets padding;

  @override
  State<PushMessageView> createState() => _PushMessageViewState();
}

class _PushMessageViewState extends State<PushMessageView> {
  final _taps = <TapGestureRecognizer>[];

  void _dropTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _dropTaps();
    super.dispose();
  }

  TextSpan _span(PushSpan s, ThemeData t) {
    final dark = t.brightness == Brightness.dark;
    final link = s.link;
    TapGestureRecognizer? tap;
    if (link != null && widget.onLink != null) {
      tap = TapGestureRecognizer()..onTap = () => widget.onLink!(link);
      _taps.add(tap);
    }
    return TextSpan(
      text: s.text,
      recognizer: tap,
      style: TextStyle(
        fontWeight: s.bold ? FontWeight.w700 : null,
        fontStyle: s.italic ? FontStyle.italic : null,
        color: s.color != null
            ? Color(pushColorValue(s.color!, dark: dark))
            : link != null
            ? t.colorScheme.primary
            : null,
        decoration: link != null ? TextDecoration.underline : null,
      ),
    );
  }

  Widget _text(List<PushSpan> spans, TextStyle? style, ThemeData t, {Key? key}) =>
      Text.rich(TextSpan(children: [for (final s in spans) _span(s, t)]), key: key, style: style);

  Widget _picture(String url, ThemeData t, {double radius = 0}) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: AspectRatio(
      aspectRatio: 2,
      child: ColoredBox(
        color: t.colorScheme.surfaceContainerHighest,
        child: MediaImage(
          url,
          fit: BoxFit.cover,
          fallback: Icon(Icons.image_outlined, color: t.colorScheme.onSurfaceVariant, size: 40),
        ),
      ),
    ),
  );

  Widget _block(PushBlock b, int i, ThemeData t) => switch (b.type) {
    PushBlockType.heading => _text(
      b.spans,
      t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      t,
      key: ValueKey('push-message-heading-$i'),
    ),
    PushBlockType.paragraph => _text(b.spans, t.textTheme.bodyLarge, t, key: ValueKey('push-message-paragraph-$i')),
    PushBlockType.bullets => Column(
      key: ValueKey('push-message-bullets-$i'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in b.items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('•', style: t.textTheme.bodyLarge),
              ),
              Expanded(child: _text(item, t.textTheme.bodyLarge, t)),
            ]),
          ),
      ],
    ),
    PushBlockType.button => Align(
      alignment: AlignmentDirectional.centerStart,
      child: FilledButton(
        key: ValueKey('push-message-button-$i'),
        onPressed: widget.onLink == null ? null : () => widget.onLink!(b.link!),
        child: Text(b.label),
      ),
    ),
    PushBlockType.image => _picture(b.url!, t, radius: 12),
  };

  @override
  Widget build(BuildContext context) {
    _dropTaps();
    final t = Theme.of(context);
    final image = widget.imageUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (image != null && image.isNotEmpty) KeyedSubtree(key: const ValueKey('push-message-image'), child: _picture(image, t)),
        Padding(
          padding: widget.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.blocks.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                _block(widget.blocks[i], i, t),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
