// Partner registration (0288): the text on a document's photo, for the
// readers in core/document_text.dart. The phone's own text recognizer and
// the id-read function (Google Vision on the uploaded file) read in the
// order set in Admin › Settings › Document reading (0293), each only while
// switched on there; the cloud read also as Admin > Dispatch > Accounts >
// ID card reading allows ("On the phone only" never sends it).
// Null when nothing could be read: the fields open empty for typing.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/document_reading.dart';
import '../widgets/live_selfie/on_device.dart' show readImageText;
import 'document_reading_repository.dart';
import 'identity_repository.dart';

/// Reads [bytes] (already uploaded as [fileUrl], for the server's read).
typedef DocumentTextRead = Future<String?> Function(Uint8List bytes, {String? fileUrl});

final documentTextReaderProvider = Provider<DocumentTextRead>((ref) {
  return (bytes, {fileUrl}) async {
    Future<String?> phone() async {
      try {
        return await readImageText(bytes);
      } catch (_) {
        return null;
      }
    }

    Future<String?> cloud() async {
      if (fileUrl == null || fileUrl.isEmpty) return null;
      final identity = ref.read(identityRepositoryProvider);
      if (!(await identity.config()).visionOn) return null;
      return identity.readRegistrationText(fileUrl);
    }

    final cfg = await ref.read(documentReadingConfigProvider.future);
    for (final id in cfg.order) {
      final text = switch (id) {
        DocReaderId.phone => await phone(),
        DocReaderId.cloud => await cloud(),
        // The NAS and a GPU PC read in the background, after the upload.
        DocReaderId.nas || DocReaderId.gpu => null,
      };
      if (text != null && text.trim().isNotEmpty) return text;
    }
    return null;
  };
});
