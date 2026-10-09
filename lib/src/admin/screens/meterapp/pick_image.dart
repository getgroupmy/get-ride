import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/image_crop.dart';

/// One picked image: its bytes, file name and a content type guessed from the
/// extension (the same guess the Expo `brandingStore` makes).
typedef PickedImage = ({Uint8List bytes, String name, String ext, String contentType});

String imageExt(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'jpg';
  if (lower.endsWith('.webp')) return 'webp';
  if (lower.endsWith('.gif')) return 'gif';
  return 'png';
}

String imageContentType(String ext) => switch (ext) {
      'jpg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/png',
    };

PickedImage _picked(Uint8List bytes, String name) {
  final ext = imageExt(name);
  return (bytes: bytes, name: name, ext: ext, contentType: imageContentType(ext));
}

/// Where a phone's photo comes from.
enum PhotoSource { camera, gallery }

/// Whether to offer the camera: on a phone or tablet. The web and desktop
/// builds keep the file picker (Expo's `ImagePicker` sheet is native-only).
bool offersCamera({bool web = kIsWeb, TargetPlatform? platform}) {
  if (web) return false;
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.android || p == TargetPlatform.iOS;
}

/// "Take photo" / "Choose from gallery"; null when dismissed.
Future<PhotoSource?> choosePhotoSource(BuildContext context) => showModalBottomSheet<PhotoSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const ValueKey('photo-source-camera'),
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take photo'),
            onTap: () => Navigator.pop(ctx, PhotoSource.camera),
          ),
          ListTile(
            key: const ValueKey('photo-source-gallery'),
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(ctx, PhotoSource.gallery),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );

/// A photo from the camera or the gallery. Scaled down by the OS: a
/// document stays legible at this size and the upload stays small.
Future<PickedImage?> pickImageFrom(PhotoSource source) async {
  final x = await ImagePicker().pickImage(
    source: source == PhotoSource.camera ? ImageSource.camera : ImageSource.gallery,
    maxWidth: 2560,
    maxHeight: 2560,
    imageQuality: 90,
  );
  if (x == null) return null;
  return _picked(await x.readAsBytes(), x.name.isEmpty ? 'photo.jpg' : x.name);
}

/// Picks one image. With [context], a phone first asks whether to take the
/// photo or choose one from the gallery; the web and desktop (or a caller
/// without a context) open the file picker.
Future<PickedImage?> pickImage([BuildContext? context]) async {
  if (context != null && offersCamera()) {
    final source = await choosePhotoSource(context);
    if (source == null) return null;
    return pickImageFrom(source);
  }
  final files = await FilePicker.pickFiles(type: FileType.image);
  final f = files.firstOrNull;
  if (f == null) return null;
  return _picked(await f.readAsBytes(), f.name);
}

/// [photo] cut to its centred square as a JPEG (a profile photo is shown in
/// a circle; Expo crops it 1:1 when it is picked). A photo [crop] can't read
/// is kept as it is: the upload still goes ahead.
Future<PickedImage> squarePickedImage(
  PickedImage photo, {
  Future<Uint8List?> Function(Uint8List bytes)? crop,
}) async {
  Uint8List? out;
  try {
    out = await (crop ?? (b) => compute(squareCropImageJob, b))(photo.bytes);
  } catch (_) {}
  if (out == null) return photo;
  final base = photo.name.replaceFirst(RegExp(r'\.[A-Za-z0-9]+$'), '');
  return _picked(out, '${base.isEmpty ? 'photo' : base}.jpg');
}

/// A profile photo: [pickImage], then cut square.
Future<PickedImage?> pickAvatarImage([BuildContext? context]) async {
  final photo = await pickImage(context);
  return photo == null ? null : squarePickedImage(photo);
}
