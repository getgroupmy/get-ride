/// Sharing and saving an image the app drew (a wallet QR, the referral
/// card): the file name it travels under and what the driver or rider is
/// told once it is saved.
library;

/// How a save went. A phone has no gallery-save plugin in this build, so
/// there it is the share sheet (whose "Save image" puts it in Photos).
enum ImageSaveOutcome {
  /// The browser downloaded it.
  downloaded,

  /// Written to a file on this computer ([ImageSaveResult.path]).
  savedToFile,

  /// Handed to the system share sheet to save from.
  shareSheet,

  /// Nothing could take it.
  failed,
}

class ImageSaveResult {
  const ImageSaveResult(this.outcome, {this.path});
  final ImageSaveOutcome outcome;
  final String? path;
}

/// A file name safe on every platform: lower-case letters, digits and
/// dashes, ending in `.png`.
String pngFileName(String base) {
  final stem = base
      .toLowerCase()
      .replaceAll(RegExp(r'\.png$'), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return '${stem.isEmpty ? 'getride' : stem}.png';
}

/// What to tell the person after a save; null when the share sheet is
/// already on screen and says it itself.
String? imageSaveMessage(ImageSaveResult r) => switch (r.outcome) {
  ImageSaveOutcome.downloaded => 'Image saved to your downloads',
  ImageSaveOutcome.savedToFile => r.path == null ? 'Image saved' : 'Image saved to ${r.path}',
  ImageSaveOutcome.shareSheet => null,
  ImageSaveOutcome.failed => "Couldn't save the image. Try Share instead.",
};
