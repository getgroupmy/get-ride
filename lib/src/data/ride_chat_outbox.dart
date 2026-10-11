// The chat messages waiting on this phone for a connection (reliability
// Phase C): kept across restarts, sent in order when the connection is
// back, each under its own id so it is never stored twice.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ride_chat_outbox.dart';
import 'ride_chat_repository.dart';

const _key = 'ride_chat_outbox_v1';

class RideChatOutbox extends Notifier<List<PendingRideMessage>> {
  final _inFlight = <String>{};
  DateTime Function() now = DateTime.now;

  @override
  List<PendingRideMessage> build() {
    unawaited(_load());
    return const [];
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final stored = [for (final j in jsonDecode(raw) as List) ?PendingRideMessage.fromJson(j)];
      final kept = prunePending(stored, onServer: const {}, now: now());
      // Anything queued while this was loading stays queued.
      state = [
        ...kept,
        for (final p in state)
          if (!kept.any((k) => k.clientMsgId == p.clientMsgId)) p,
      ];
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode([for (final p in state) p.toJson()]));
    } catch (_) {}
  }

  void _remove(String clientMsgId) {
    state = [
      for (final p in state)
        if (p.clientMsgId != clientMsgId) p,
    ];
    unawaited(_save());
  }

  /// Queues [p] and tries to send it now. Returns whether it got there.
  /// Throws (and drops it) only when the server refused it: that is not
  /// something waiting can fix.
  Future<bool> send(PendingRideMessage p) async {
    state = [...state, p];
    // Kept on the phone alongside the send, not before it: the send is
    // what the person is waiting for.
    unawaited(_save());
    return _trySend(p);
  }

  /// Tries every waiting message of [requestId] (or of every ride), oldest
  /// first. A refusal drops that message quietly here.
  Future<void> flush({String? requestId}) async {
    for (final p in [...state]) {
      if (requestId != null && p.requestId != requestId) continue;
      try {
        if (!await _trySend(p)) return; // still offline: the rest would fail too
      } catch (_) {}
    }
  }

  /// Drops what the server already has (it arrived another way) and what
  /// is too old to send.
  void reconcile(Iterable<String?> onServer) {
    final ids = {for (final id in onServer) ?id};
    final kept = prunePending(state, onServer: ids, now: now());
    if (kept.length == state.length) return;
    state = kept;
    unawaited(_save());
  }

  Future<bool> _trySend(PendingRideMessage p) async {
    if (!_inFlight.add(p.clientMsgId)) return false;
    try {
      await ref.read(rideChatRepositoryProvider).sendQueued(p);
      _remove(p.clientMsgId);
      return true;
    } on PostgrestException {
      _remove(p.clientMsgId);
      rethrow;
    } catch (_) {
      return false; // no connection: it waits
    } finally {
      _inFlight.remove(p.clientMsgId);
    }
  }
}

final rideChatOutboxProvider = NotifierProvider<RideChatOutbox, List<PendingRideMessage>>(RideChatOutbox.new);
