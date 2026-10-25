import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/document_ai.dart';
import '../core/document_reading.dart' show DocReaderId;
import '../providers.dart';
import 'document_reading_repository.dart';

/// Calls the `document-ai-verify` edge function. The photos go to the
/// server, which holds the AI provider's keys; nothing is sent from the
/// phone to a third party.
class DocumentAiRepository {
  DocumentAiRepository(this._db, [this._cloudOn]);
  final SupabaseClient _db;

  /// Whether the cloud reader is switched on (Admin › Settings › Document
  /// reading); unasked, it is.
  final Future<bool> Function()? _cloudOn;

  static const _function = 'document-ai-verify';

  /// Photos over this are scaled down before sending (the function caps at
  /// [docAiMaxImageBytes]; a document stays legible at this width).
  static const _shrinkAbove = 2 * 1024 * 1024;
  static const _shrinkWidth = 1600;

  /// A data URL the function accepts, or null when the photo can't be sent.
  Future<String?> prepare(Uint8List bytes, String name) async {
    final mime = imageMimeFor(name);
    if (mime != null && bytes.length <= _shrinkAbove) return imageDataUrl(bytes, mime);
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: _shrinkWidth);
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (png == null || png.lengthInBytes > docAiMaxImageBytes) return null;
      return imageDataUrl(png.buffer.asUint8List(), 'image/png');
    } catch (_) {
      return null;
    }
  }

  /// The verdict, or null with a reason ([docAiUnavailableText] words it).
  Future<({DocumentAiResult? result, String? reason})> verify(Map<String, dynamic> body) async {
    if (_cloudOn != null && !await _cloudOn()) return (result: null, reason: 'off');
    try {
      final res = await _db.functions.invoke(_function, body: body);
      return parseDocAiResponse(res.data);
    } on FunctionException catch (e) {
      return (
        result: null,
        reason: switch (e.status) {
          404 => 'not_deployed',
          401 => 'signed_out',
          _ => 'failed',
        },
      );
    } catch (_) {
      return (result: null, reason: 'failed');
    }
  }
}

final documentAiRepositoryProvider = Provider(
  (ref) => DocumentAiRepository(
    ref.watch(supabaseProvider),
    () async => (await ref.read(documentReadingConfigProvider.future)).isOn(DocReaderId.cloud),
  ),
);
