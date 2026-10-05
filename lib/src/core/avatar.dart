/// Profile photos (Expo `app/edit-profile.tsx` avatar upload). The photo goes
/// to the public `avatars` bucket under a folder named after the account, so
/// its path can be tied to its owner, and its public URL is saved on
/// `profiles.avatar_url`.
library;

/// Largest photo accepted, in bytes.
const avatarMaxBytes = 5 * 1024 * 1024;

/// `<user id>/avatar_<ms>.<ext>`: a new name per upload, so a cached old
/// photo is never served under the new one's URL.
String avatarStoragePath(String userId, String ext, DateTime now) =>
    '$userId/avatar_${now.millisecondsSinceEpoch}.$ext';

/// Why a picked photo can't be used, or null.
String? avatarProblem(int bytes) {
  if (bytes <= 0) return "That photo couldn't be read.";
  if (bytes > avatarMaxBytes) return 'Choose a photo under 5 MB.';
  return null;
}
