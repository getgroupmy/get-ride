import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ride_draft.dart';

/// The booking left on the confirm step, kept on this phone per account
/// (ride_draft.dart). Nothing is sent anywhere: a failed read or write
/// only means nothing is offered next time.
class RideDraftStore {
  const RideDraftStore();

  Future<RideDraft?> read(String uid) async {
    try {
      return RideDraft.decode((await SharedPreferences.getInstance()).getString(rideDraftKey(uid)));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String uid, RideDraft draft) async {
    try {
      await (await SharedPreferences.getInstance()).setString(rideDraftKey(uid), draft.encode());
    } catch (_) {}
  }

  Future<void> clear(String uid) async {
    try {
      await (await SharedPreferences.getInstance()).remove(rideDraftKey(uid));
    } catch (_) {}
  }
}

final rideDraftStoreProvider = Provider<RideDraftStore>((ref) => const RideDraftStore());

/// Whether this run of the app has already offered (or passed over) the
/// saved booking: "Welcome back" shows once per launch.
bool rideDraftOfferedThisRun = false;
