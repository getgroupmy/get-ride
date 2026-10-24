// Partner registration (0288): the text on a document's photo, for the
// readers in core/document_text.dart. The phone's own text recognizer
// first (Android, iOS); when it reads nothing (the web, desktops, a hard
// photo) the id-read function reads the uploaded file, as Admin > Dispatch >
// Accounts > ID card reading allows ("On the phone only" never sends it).
// Null when nothing could be read: the fields open empty for typing.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/live_selfie/on_device.dart' show readImageText;
import 'identity_repository.dart';

/// Reads [bytes] (already uploaded as [fileUrl], for the server's read).
typedef DocumentTextRead = Future<String?> Function(Uint8List bytes, {String? fileUrl});

final documentTextReaderProvider = Provider<DocumentTextRead>((ref) {
  return (bytes, {fileUrl}) async {
    try {
      final phone = await readImageText(bytes);
      if (phone != null && phone.trim().isNotEmpty) return phone;
    } catch (_) {}
    if (fileUrl == null || fileUrl.isEmpty) return null;
    final identity = ref.read(identityRepositoryProvider);
    if ((await identity.config()).idRead == 'phone') return null;
    return identity.readRegistrationText(fileUrl);
  };
});
