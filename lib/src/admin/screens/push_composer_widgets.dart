// The pieces of Admin -> Push Notification's composer (migration 0279): the
// emoji grid, the full-message editor, the partner type chips and the phone
// preview. The logic is in push_composer.dart and core/push_message.dart.
import 'package:flutter/material.dart';

import '../../core/push_message.dart';
import '../../widgets/common.dart' show mutedTextColor;
import '../../widgets/media_image.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/push_message_view.dart';
import '../../widgets/search_select.dart';
import '../push_composer.dart';

/// The emoji button at the end of a field.
class EmojiButton extends StatelessWidget {
  const EmojiButton({super.key, required this.onPressed, this.open = false});

  final VoidCallback onPressed;

  /// Whether its grid is showing.
  final bool open;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: open ? 'Close emoji' : 'Add emoji',
    isSelected: open,
    icon: const Icon(Icons.emoji_emotions_outlined),
    selectedIcon: const Icon(Icons.emoji_emotions),
    onPressed: onPressed,
  );
}

/// A small grid of [pushEmojis]; a tap hands one to [onPick].
class EmojiGrid extends StatelessWidget {
  const EmojiGrid({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerLow,
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Wrap(spacing: 2, runSpacing: 2, children: [
          for (var i = 0; i < pushEmojis.length; i++)
            InkWell(
              key: ValueKey('push-emoji-$i'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => onPick(pushEmojis[i]),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(pushEmojis[i], style: const TextStyle(fontSize: 22)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A link the admin typed, and a button's label ('' for a link).
typedef PushLink = ({String label, String link});

/// Asks for a link (and with [withLabel] a button's label): an in-app
/// route like /wallet, or an http(s) address. Null when cancelled.
Future<PushLink?> askPushLink(BuildContext context, {bool withLabel = false}) => withLabel
    ? showAppDialog<PushLink>(id: 'admin.push-button', context: context, builder: (_) => const _LinkDialog(withLabel: true))
    : showAppDialog<PushLink>(id: 'admin.push-link', context: context, builder: (_) => const _LinkDialog(withLabel: false));

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.withLabel});
  final bool withLabel;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final _label = TextEditingController();
  final _link = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _label.dispose();
    _link.dispose();
    super.dispose();
  }

  void _done() {
    final label = _label.text.trim(), link = _link.text.trim();
    if (widget.withLabel && label.isEmpty) {
      setState(() => _problem = 'Add the button text.');
      return;
    }
    if (!isSafePushLink(link)) {
      setState(() => _problem = 'Use a page of the app, like /wallet, or an address starting with https://');
      return;
    }
    Navigator.of(context).pop((label: label, link: link));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.withLabel ? 'Add a button' : 'Add a link'),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      if (widget.withLabel) ...[
        TextField(
          key: const ValueKey('push-link-label'),
          controller: _label,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Button text'),
        ),
        const SizedBox(height: 8),
      ],
      TextField(
        key: const ValueKey('push-link-target'),
        controller: _link,
        autofocus: !widget.withLabel,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: 'Opens',
          helperText: 'A page of the app (/wallet, /drive) or a web address',
          errorText: _problem,
          errorMaxLines: 3,
        ),
        onSubmitted: (_) => _done(),
      ),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(key: const ValueKey('push-link-done'), onPressed: _done, child: const Text('Add')),
    ],
  );
}

/// The full message's editor: a toolbar that types the markup
/// (push_message.dart) into [controller], which the preview draws.
class PushRichEditor extends StatelessWidget {
  const PushRichEditor({super.key, required this.controller, required this.onEmoji, this.emojiOpen = false});

  final TextEditingController controller;
  final VoidCallback onEmoji;
  final bool emojiOpen;

  void _set(TextEditingValue v) => controller.value = v;

  Future<void> _link(BuildContext context, {required bool button}) async {
    final r = await askPushLink(context, withLabel: button);
    if (r == null) return;
    if (button) {
      // A button is a line of its own, after the line the cursor is on.
      final v = controller.value;
      final cursor = v.selection.isValid ? v.selection.end.clamp(0, v.text.length) : v.text.length;
      final nl = v.text.indexOf('\n', cursor);
      final at = nl < 0 ? v.text.length : nl;
      final lead = at == 0 ? '' : '\n';
      _set(insertAtCursor(v.copyWith(selection: TextSelection.collapsed(offset: at)), '$lead[[${r.label}]](${r.link})${nl < 0 ? '\n' : ''}'));
    } else {
      _set(wrapSelection(controller.value, '[', '](${r.link})', placeholder: 'link text'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget tool(String key, String tip, Widget icon, VoidCallback onTap) =>
        IconButton(key: ValueKey('push-rich-$key'), tooltip: tip, icon: icon, onPressed: onTap);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 2, children: [
        tool('bold', 'Bold', const Icon(Icons.format_bold), () => _set(wrapSelection(controller.value, '**', '**'))),
        tool('italic', 'Italic', const Icon(Icons.format_italic), () => _set(wrapSelection(controller.value, '_', '_'))),
        tool('heading', 'Heading', const Icon(Icons.title), () => _set(prefixLines(controller.value, '# '))),
        tool('list', 'Bullet list', const Icon(Icons.format_list_bulleted), () => _set(prefixLines(controller.value, '- '))),
        PopupMenuButton<PushColor>(
          key: const ValueKey('push-rich-color'),
          tooltip: 'Colour',
          icon: const Icon(Icons.format_color_text),
          onSelected: (c) => _set(wrapSelection(controller.value, '{${c.name}:', '}')),
          itemBuilder: (_) => [
            for (final c in PushColor.values)
              PopupMenuItem(
                key: ValueKey('push-rich-color-${c.name}'),
                value: c,
                child: Row(children: [
                  Icon(Icons.circle, color: Color(pushColorValue(c, dark: t.brightness == Brightness.dark))),
                  const SizedBox(width: 8),
                  Text(pushColorLabel(c)),
                ]),
              ),
          ],
        ),
        tool('link', 'Link', const Icon(Icons.link), () => _link(context, button: false)),
        tool('button', 'Button', const Icon(Icons.smart_button_outlined), () => _link(context, button: true)),
        tool('emoji', emojiOpen ? 'Close emoji' : 'Emoji',
            Icon(emojiOpen ? Icons.emoji_emotions : Icons.emoji_emotions_outlined), onEmoji),
      ]),
      TextField(
        key: const ValueKey('push-rich'),
        controller: controller,
        minLines: 4,
        maxLines: 12,
        keyboardType: TextInputType.multiline,
        decoration: const InputDecoration(
          hintText: 'What they read after tapping the notification',
          alignLabelWithHint: true,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'The notification itself shows the title and message (phones show plain text there). '
        'Tapping it opens this in the app, with the picture on top.',
        style: t.textTheme.bodySmall?.copyWith(color: mutedTextColor(t)),
      ),
    ]);
  }
}

/// "Which partners": a chip per partner type with how many partners have
/// it; none chosen is every partner.
class PartnerTypeChips extends StatelessWidget {
  const PartnerTypeChips({
    super.key,
    required this.counts,
    required this.selected,
    required this.onToggle,
    required this.approvedOnly,
    required this.onApprovedOnly,
    this.loading = false,
  });

  final List<({String type, int count})> counts;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final bool approvedOnly;
  final ValueChanged<bool> onApprovedOnly;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = mutedTextColor(t);
    final chosen = {for (final s in selected) s.toLowerCase()};
    return Container(
      key: const ValueKey('push-partner-types'),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(border: BorderDirectional(start: BorderSide(color: t.colorScheme.outlineVariant, width: 3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Which partners', style: t.textTheme.titleSmall),
          Text('None chosen: all partners', style: t.textTheme.bodySmall?.copyWith(color: muted)),
        ]),
        const SizedBox(height: 8),
        if (loading && counts.isEmpty) const LinearProgressIndicator(),
        if (!loading && counts.isEmpty)
          Text('No partner types are set up yet.', style: t.textTheme.bodySmall?.copyWith(color: muted)),
        ListSearchFilter(
          count: counts.length,
          hint: 'Search partner types',
          fieldKey: const ValueKey('push-partner-type-search'),
          builder: (context, q) => Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in counts)
              if (q.isEmpty || c.type.toLowerCase().contains(q.toLowerCase()))
                FilterChip(
                  key: ValueKey('push-ptype-${c.type}'),
                  label: Text('${c.type}  ${c.count}'),
                  selected: chosen.contains(c.type.toLowerCase()),
                  onSelected: (_) => onToggle(c.type),
                ),
          ]),
        ),
        CheckboxListTile(
          key: const ValueKey('push-approved-only'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: const Text('Approved partners only'),
          value: approvedOnly,
          onChanged: (v) => onApprovedOnly(v ?? true),
        ),
      ]),
    );
  }
}

/// What the phone shows: the notification, then the page its tap opens.
class PushPreview extends StatelessWidget {
  const PushPreview({super.key, required this.title, required this.body, this.imageUrl, this.blocks = const []});

  final String title;
  final String body;
  final String? imageUrl;
  final List<PushBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final muted = mutedTextColor(t);
    final image = imageUrl;
    return Container(
      key: const ValueKey('push-preview'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Preview on a phone', style: t.textTheme.bodySmall?.copyWith(color: muted)),
        const SizedBox(height: 8),
        Material(
          color: cs.surface,
          elevation: 1,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('GET.ride · now', style: t.textTheme.labelSmall?.copyWith(color: muted)),
              const SizedBox(height: 4),
              Text(title.trim().isEmpty ? 'Title' : title,
                  key: const ValueKey('push-preview-title'),
                  style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(body.trim().isEmpty ? 'Message' : body,
                  key: const ValueKey('push-preview-body'), style: t.textTheme.bodyMedium),
              if (image != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: 2,
                    child: ColoredBox(
                      color: cs.surfaceContainerHighest,
                      child: MediaImage(image,
                          key: const ValueKey('push-preview-image'),
                          fit: BoxFit.cover,
                          fallback: Icon(Icons.image_outlined, color: cs.onSurfaceVariant)),
                    ),
                  ),
                ),
              ],
            ]),
          ),
        ),
        if (blocks.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('After the tap, in the app', style: t.textTheme.bodySmall?.copyWith(color: muted)),
          const SizedBox(height: 8),
          Material(
            color: cs.surface,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Text('‹ Notifications', style: t.textTheme.bodySmall?.copyWith(color: muted)),
              ),
              Divider(height: 1, color: cs.outlineVariant),
              PushMessageView(
                key: const ValueKey('push-preview-message'),
                blocks: blocks,
                imageUrl: image,
                padding: const EdgeInsets.all(12),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}
