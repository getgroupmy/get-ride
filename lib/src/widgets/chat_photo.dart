// Photos in the chats: where to get one from, a look at it (with a caption)
// before it goes, and the full-screen view of one that was sent. All in the
// app's light or dark theme.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/photo_picker.dart';
import 'net_image.dart';

/// Gallery or camera; straight to the gallery where there is no camera.
Future<PhotoSource?> choosePhotoSource(BuildContext context, {required bool camera}) async {
  if (!camera) return PhotoSource.gallery;
  return showModalBottomSheet<PhotoSource>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('photo-camera'),
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(c, PhotoSource.camera),
          ),
          ListTile(
            key: const ValueKey('photo-gallery'),
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(c, PhotoSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// The photo about to be sent, with a caption field: the caption ('' for
/// none) when sent, null when it was put back.
Future<String?> confirmPhoto(BuildContext context, Uint8List bytes, {int maxCaption = 1000}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => _PhotoConfirm(bytes: bytes, maxCaption: maxCaption),
    );

class _PhotoConfirm extends StatefulWidget {
  const _PhotoConfirm({required this.bytes, required this.maxCaption});
  final Uint8List bytes;
  final int maxCaption;

  @override
  State<_PhotoConfirm> createState() => _PhotoConfirmState();
}

class _PhotoConfirmState extends State<_PhotoConfirm> {
  final _caption = TextEditingController();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          key: const ValueKey('photo-confirm'),
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  widget.bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox(height: 120, child: Icon(Icons.image_outlined, size: 48)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('photo-caption'),
                    controller: _caption,
                    maxLength: widget.maxCaption,
                    minLines: 1,
                    maxLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(hintText: 'Add a caption', counterText: ''),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const ValueKey('photo-send'),
                  tooltip: 'Send photo',
                  onPressed: () => Navigator.pop(context, _caption.text.trim()),
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// A sent photo, full screen and zoomable.
void openPhotoViewer(BuildContext context, String url, {String? caption}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (c) {
        final t = Theme.of(c);
        return Scaffold(
          key: const ValueKey('photo-viewer'),
          backgroundColor: t.colorScheme.surfaceContainerLowest,
          appBar: AppBar(title: const Text('Photo'), backgroundColor: t.colorScheme.surfaceContainerLowest),
          body: Column(
            children: [
              Expanded(
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      frameBuilder: boneUntilPainted(width: 240, height: 240),
                      errorBuilder: (_, _, _) =>
                          Icon(Icons.broken_image_outlined, size: 48, color: t.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
              if (caption != null)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(caption, style: t.textTheme.bodyLarge),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
