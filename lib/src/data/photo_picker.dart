import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// A picked or snapped photo.
typedef PickedPhoto = ({Uint8List bytes, String name});

enum PhotoSource { gallery, camera }

/// Picks a photo from the gallery or snaps one with the camera, scaled down
/// for a chat (overridden in tests). Null when the person backs out.
final photoPickerProvider = Provider<Future<PickedPhoto?> Function(PhotoSource)>(
  (ref) => (source) async {
    final f = await ImagePicker().pickImage(
      source: source == PhotoSource.camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 80,
    );
    if (f == null) return null;
    return (bytes: await f.readAsBytes(), name: f.name);
  },
);

/// Whether this device can snap a photo (phones and mobile browsers can;
/// desktops can't).
final photoCameraAvailableProvider = Provider<bool>((ref) {
  try {
    return ImagePicker().supportsImageSource(ImageSource.camera);
  } catch (_) {
    return false;
  }
});
