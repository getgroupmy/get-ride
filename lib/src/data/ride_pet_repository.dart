// Pet photos for "Pet with me": uploaded by the rider into their own folder
// of the private `ride-pets` bucket, and opened through short-lived signed
// links by the rider, the driver who takes the ride and admins (migration
// 0247 decides who may sign one).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/ride_chat.dart' show RideMessageType, rideChatContentType;
import '../core/ride_pets.dart';
import '../core/support_media.dart' show fileExt;
import '../providers.dart';
import 'app_display_repository.dart' show displaySettingsBlobProvider;
import 'storage_links.dart' show cachedSignedLink;

class RidePetRepository {
  RidePetRepository(this._db);
  final SupabaseClient _db;

  /// Uploads a pet's photo into the rider's folder; its path.
  Future<String> upload(Uint8List bytes, String name) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('Sign in to add a photo.');
    final ext = fileExt(name);
    final path = ridePetPhotoPath(uid, const Uuid().v4(), ext);
    await _db.storage
        .from(ridePetsBucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: rideChatContentType(RideMessageType.image, ext)));
    return path;
  }

  /// A short-lived link to a pet's photo; storage signs it only for the
  /// rider, the ride's driver and admins.
  Future<String> photoUrl(String path) => cachedSignedLink(
    '$ridePetsBucket/$path',
    ttl: ridePetLinkTtl,
    sign: () => _db.storage.from(ridePetsBucket).createSignedUrl(path, ridePetLinkTtl.inSeconds),
  );
}

final ridePetRepositoryProvider = Provider((ref) => RidePetRepository(ref.watch(supabaseProvider)));

/// Uploads a picked pet photo (bytes, file name); its storage path.
/// Overridden in tests.
final ridePetPhotoUploadProvider = Provider<Future<String> Function(Uint8List bytes, String name)>(
  (ref) => ref.watch(ridePetRepositoryProvider).upload,
);

/// The signed link to a pet's photo, renewed before it runs out.
final ridePetPhotoUrlProvider = FutureProvider.autoDispose.family<String, String>((ref, path) async {
  final url = await ref.watch(ridePetRepositoryProvider).photoUrl(path);
  final keep = ref.keepAlive();
  final timer = Timer(ridePetLinkTtl - const Duration(minutes: 10), () {
    keep.close();
    ref.invalidateSelf();
  });
  ref.onDispose(timer.cancel);
  return url;
});

/// What the Your pets sheet offers, from Admin → Display Settings (the
/// defaults until an admin sets them; see [PetConfig.fromSettings]).
final petConfigProvider = Provider<PetConfig>(
  (ref) => PetConfig.fromSettings(ref.watch(displaySettingsBlobProvider).value ?? const <String, dynamic>{}),
);
