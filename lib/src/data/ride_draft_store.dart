import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ride_draft.dart';
import '../core/saved_drafts.dart';

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

  // ---- Freight, Courier and a vehicle being added (saved_drafts.dart) ----

  Future<SavedDraft?> readSaved(SavedDraftKind kind, String uid) async {
    try {
      return SavedDraft.decode(kind, (await SharedPreferences.getInstance()).getString(kind.key(uid)));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSaved(String uid, SavedDraft draft) async {
    try {
      await (await SharedPreferences.getInstance()).setString(draft.kind.key(uid), draft.encode());
    } catch (_) {}
  }

  Future<void> clearSaved(SavedDraftKind kind, String uid) async {
    try {
      await (await SharedPreferences.getInstance()).remove(kind.key(uid));
    } catch (_) {}
  }
}

/// Keeps one screen's form on the phone as it changes: [now] is what it
/// holds (null: nothing worth keeping), saved a moment after the last
/// change and forgotten once there is none. [forget] after the form is
/// sent: the same form still on screen is not saved again.
class DraftSaver {
  DraftSaver(this.kind, this._store, this._uid);

  final SavedDraftKind kind;
  final RideDraftStore _store;
  final String? Function() _uid;
  String? _last;
  Timer? _timer;

  void changed(Map<String, Object?>? now) {
    final key = now == null ? '' : jsonEncode(now);
    if (key == _last) return;
    _last = key;
    _timer?.cancel();
    _pending = () {
      _pending = null;
      final uid = _uid();
      if (uid == null) return;
      unawaited(now == null
          ? _store.clearSaved(kind, uid)
          : _store.saveSaved(uid, SavedDraft(kind: kind, savedAt: DateTime.now(), data: now)));
    };
    _timer = Timer(const Duration(milliseconds: 800), () => _pending?.call());
  }

  void Function()? _pending;

  void forget(Map<String, Object?>? now) {
    _timer?.cancel();
    _pending = null;
    _last = now == null ? '' : jsonEncode(now);
    final uid = _uid();
    if (uid != null) unawaited(_store.clearSaved(kind, uid));
  }

  /// The screen is closing: a change still waiting is saved now.
  void dispose() {
    _timer?.cancel();
    _pending?.call();
  }
}

final rideDraftStoreProvider = Provider<RideDraftStore>((ref) => const RideDraftStore());

/// Whether this run of the app has already offered (or passed over) the
/// saved booking: "Welcome back" shows once per launch.
bool rideDraftOfferedThisRun = false;

/// The same for a vehicle being added, offered on Drive.
bool vehicleDraftOfferedThisRun = false;
