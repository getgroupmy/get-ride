import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../core/doc_photo.dart' show fitWithin;

/// [bytes] as a JPEG of at most [maxSide] px on its long side and [quality]
/// (0-100), drawn upright on white by the browser; null when the browser
/// can't read it (the caller then keeps the original or tries in Dart).
Future<Uint8List?> browserShrinkImage(Uint8List bytes, {required int maxSide, required int quality}) async {
  web.ImageBitmap? bitmap;
  try {
    final blob = web.Blob([bytes.toJS].toJS);
    bitmap = await web.window
        .createImageBitmap(blob, web.ImageBitmapOptions(imageOrientation: 'from-image'))
        .toDart;
    final size = fitWithin(bitmap.width, bitmap.height, maxSide);
    if (size.width <= 0 || size.height <= 0) return null;
    final canvas = web.HTMLCanvasElement()
      ..width = size.width
      ..height = size.height;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    if (ctx == null) return null;
    ctx
      ..fillStyle = 'white'.toJS
      ..fillRect(0, 0, size.width, size.height)
      ..imageSmoothingEnabled = true
      ..imageSmoothingQuality = 'high'
      ..drawImage(bitmap, 0, 0, size.width, size.height);
    final done = Completer<web.Blob?>();
    canvas.toBlob(((web.Blob? b) => done.complete(b)).toJS, 'image/jpeg', (quality / 100).toJS);
    final out = await done.future;
    if (out == null || !out.type.startsWith('image/jpeg')) return null;
    return (await out.arrayBuffer().toDart).toDart.asUint8List();
  } catch (_) {
    return null;
  } finally {
    bitmap?.close();
  }
}
