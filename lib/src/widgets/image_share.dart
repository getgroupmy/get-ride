import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/image_share.dart';
import '../platform/web_download.dart';
import 'busy.dart';
import 'common.dart';

/// A PNG the app drew, ready for the share sheet or a save.
class ShareableImage {
  const ShareableImage({required this.png, required this.fileName, this.text, this.subject, this.origin});

  final Uint8List png;
  final String fileName;

  /// Sent beside the image (a link, a code), where the target app takes text.
  final String? text;
  final String? subject;

  /// Where the share sheet points from on an iPad (the button pressed).
  final Rect? origin;

  XFile get file => XFile.fromData(png, mimeType: 'image/png', name: fileName);
}

/// The rectangle of the widget [context] belongs to, for the iPad share
/// popover; null when it is not laid out.
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Said when sharing fell back to the clipboard.
const copiedForSharing = 'Copied — paste it anywhere';

/// Opens the system share sheet with plain text; on a platform without
/// one (a browser with no Web Share) the text goes on the clipboard and the
/// answer is true, so the caller can say so. Overridden in tests.
final textSharerProvider = Provider<Future<bool> Function(String text, {String? subject, Rect? origin})>(
  (ref) => (text, {subject, origin}) async {
    try {
      final r = await SharePlus.instance.share(ShareParams(text: text, subject: subject, sharePositionOrigin: origin));
      if (r.status != ShareResultStatus.unavailable) return false;
    } catch (_) {
      // No share sheet at all: the clipboard below.
    }
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  },
);

/// Opens the system share sheet with an image (and its text). Where the
/// platform cannot share files the image is saved instead and the text
/// copied; the answer is then true. Overridden in tests.
final imageSharerProvider = Provider<Future<bool> Function(ShareableImage image)>(
  (ref) => (image) async {
    try {
      final r = await SharePlus.instance.share(
        ShareParams(
          files: [image.file],
          fileNameOverrides: [image.fileName],
          text: image.text,
          subject: image.subject,
          sharePositionOrigin: image.origin,
        ),
      );
      if (r.status != ShareResultStatus.unavailable) return false;
    } catch (_) {
      // No share sheet at all: saved and copied below.
    }
    await saveImageDefault(image);
    if (image.text != null) await Clipboard.setData(ClipboardData(text: image.text!));
    return true;
  },
);

/// Saves an image: the browser downloads it, a computer writes it to its
/// Downloads folder, and a phone (no gallery plugin in this build) opens the
/// share sheet, whose "Save image" puts it in Photos. Overridden in tests.
final imageSaverProvider = Provider<Future<ImageSaveResult> Function(ShareableImage image)>((ref) => saveImageDefault);

Future<ImageSaveResult> saveImageDefault(ShareableImage image) async {
  if (kIsWeb) {
    return webDownload(image.png, fileName: image.fileName, mimeType: 'image/png')
        ? const ImageSaveResult(ImageSaveOutcome.downloaded)
        : const ImageSaveResult(ImageSaveOutcome.failed);
  }
  final desktop = switch (defaultTargetPlatform) {
    TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => true,
    _ => false,
  };
  try {
    if (desktop) {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      final path = '${dir.path}/${image.fileName}';
      await File(path).writeAsBytes(image.png);
      return ImageSaveResult(ImageSaveOutcome.savedToFile, path: path);
    }
    await SharePlus.instance.share(
      ShareParams(files: [image.file], fileNameOverrides: [image.fileName], sharePositionOrigin: image.origin),
    );
    return const ImageSaveResult(ImageSaveOutcome.shareSheet);
  } catch (_) {
    return const ImageSaveResult(ImageSaveOutcome.failed);
  }
}

/// Draws [data] as a QR code PNG on white with a four-module quiet zone, so
/// it scans wherever it is shown, a dark-mode chat included. [caption]
/// (a name, an account number) is printed under it.
Future<Uint8List> renderQrPng(String data, {Color color = Colors.black, double size = 720, String? caption}) async {
  final v = QrValidator.validate(data: data, errorCorrectionLevel: QrErrorCorrectLevel.M);
  final code = v.qrCode;
  if (!v.isValid || code == null) throw ArgumentError('Not encodable as a QR code');
  const quiet = 4;
  final unit = size / (code.moduleCount + 2 * quiet);
  TextPainter? text;
  if (caption != null && caption.trim().isNotEmpty) {
    text = TextPainter(
      text: TextSpan(
        text: caption.trim(),
        style: TextStyle(color: Colors.black, fontSize: size / 22, fontWeight: FontWeight.w700),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 3,
    )..layout(maxWidth: size - 2 * quiet * unit);
  }
  final height = size + (text == null ? 0 : text.height + quiet * unit);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, size, height), Paint()..color = Colors.white);
  canvas.save();
  canvas.translate(quiet * unit, quiet * unit);
  QrPainter.withQr(
    qr: code,
    gapless: true,
    eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: color),
    dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: color),
  ).paint(canvas, Size.square(unit * code.moduleCount));
  canvas.restore();
  text?.paint(canvas, Offset((size - text.width) / 2, size - quiet * unit / 2));
  final image = await recorder.endRecording().toImage(size.round(), height.round());
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Renders a QR code to PNG ([renderQrPng]). Overridden in tests, where
/// drawing to an image needs real async.
final qrPngRendererProvider = Provider<Future<Uint8List> Function(String data, {Color color, String? caption})>(
  (ref) =>
      (data, {color = Colors.black, caption}) => renderQrPng(data, color: color, caption: caption),
);

/// Captures what a [RepaintBoundary] keyed [key] shows as a PNG, at
/// [pixelRatio] times its size; null when it is not on screen. Overridden in
/// tests.
final boundaryPngProvider = Provider<Future<Uint8List?> Function(GlobalKey key, {double pixelRatio})>(
  (ref) => (key, {pixelRatio = 3}) async {
    final boundary = key.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  },
);

/// Share and Save buttons for an image built on demand by [image] (null:
/// nothing to share right now). [keyPrefix] names them `<prefix>-share` and
/// `<prefix>-save` for tests.
class ShareSaveImageButtons extends ConsumerWidget {
  const ShareSaveImageButtons({
    super.key,
    required this.image,
    required this.keyPrefix,
    this.enabled = true,
    this.shareLabel = 'Share',
    this.saveLabel = 'Save image',
  });

  final Future<ShareableImage?> Function(Rect? origin) image;
  final String keyPrefix;
  final bool enabled;
  final String shareLabel;
  final String saveLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        Builder(
          builder: (bc) => BusyButton.outlined(
            key: ValueKey('$keyPrefix-share'),
            icon: const Icon(Icons.share_outlined),
            onPressed: !enabled
                ? null
                : () async {
                    try {
                      final img = await image(shareOriginOf(bc));
                      if (img == null) return;
                      final copied = await ref.read(imageSharerProvider)(img);
                      if (copied && context.mounted) {
                        showInfo(context, img.text == null ? 'Saved the image' : 'Saved the image. $copiedForSharing');
                      }
                    } catch (_) {
                      if (context.mounted) showInfo(context, "Couldn't share the image. Please try again.");
                    }
                  },
            child: Text(shareLabel),
          ),
        ),
        Builder(
          builder: (bc) => BusyButton.outlined(
            key: ValueKey('$keyPrefix-save'),
            icon: Icon(kIsWeb ? Icons.download_outlined : Icons.save_alt_outlined),
            onPressed: !enabled
                ? null
                : () async {
                    ImageSaveResult result;
                    try {
                      final img = await image(shareOriginOf(bc));
                      if (img == null) return;
                      result = await ref.read(imageSaverProvider)(img);
                    } catch (_) {
                      result = const ImageSaveResult(ImageSaveOutcome.failed);
                    }
                    final message = imageSaveMessage(result);
                    if (message != null && context.mounted) showInfo(context, message);
                  },
            child: Text(kIsWeb ? 'Download' : saveLabel),
          ),
        ),
      ],
    );
  }
}
