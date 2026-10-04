import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

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

Future<PickedImage?> pickImage() async {
  final files = await FilePicker.pickFiles(type: FileType.image);
  final f = files.firstOrNull;
  if (f == null) return null;
  final ext = imageExt(f.name);
  return (bytes: await f.readAsBytes(), name: f.name, ext: ext, contentType: imageContentType(ext));
}
