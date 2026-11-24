import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'api.dart';
import 'face_camera.dart';
import 'pose.dart';
import 'result.dart';
import 'strings.dart';

/// The native capture flow: every screen is in the app; the server only
/// receives the photos. Push it as a full-screen route; it pops an [EkycResult].
class EkycNativeFlow extends StatefulWidget {
  const EkycNativeFlow({super.key, required this.hostedUrl, this.language = 'en', this.api});

  final String hostedUrl;
  final String language;
  final EkycApi? api; // for tests

  @override
  State<EkycNativeFlow> createState() => _EkycNativeFlowState();
}

enum _Step { loading, welcome, front, back, face, sending, done, failed }

class _EkycNativeFlowState extends State<EkycNativeFlow> {
  late final EkycApi api = widget.api ?? EkycApi(widget.hostedUrl);
  late final EkycStrings t = EkycStrings(widget.language);
  _Step step = _Step.loading;
  EkycSessionInfo? info;
  EkycDocument? doc;
  bool agreed = false;
  String? message;
  EkycOutcome? outcome;
  Object? error;
  VoidCallback? retry;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (widget.api == null) api.close();
    super.dispose();
  }

  void _finish(EkycOutcome o) => Navigator.of(context).pop(EkycResult(o, verificationId: info?.verificationId, error: error));

  Future<void> _load() async {
    try {
      info = await api.info();
    } on EkycApiException catch (e) {
      error = e;
      return _end(e.statusCode == 404 ? EkycOutcome.invalid : EkycOutcome.error, e.statusCode == 404 ? t('invalid') : t('error', {'e': e.message}));
    } catch (e) {
      error = e;
      return _fail(e, _load);
    }
    final s = info!.state;
    if (s == 'expired') return _end(EkycOutcome.expired, t('expired'));
    if (s != 'created') return _end(EkycResult.outcomeOf(s), t('doneMsg'));
    agreed = !info!.consentNeeded;
    setState(() => step = _Step.welcome);
  }

  void _end(EkycOutcome o, String msg) => setState(() {
        outcome = o;
        message = msg;
        step = _Step.done;
      });

  void _fail(Object e, VoidCallback again) => setState(() {
        error = e;
        message = t('error', {'e': e is EkycApiException ? e.message : '$e'});
        retry = again;
        step = _Step.failed;
      });

  Future<void> _start() async {
    try {
      if (info!.consentNeeded) await api.consent(widget.language);
      setState(() => step = _Step.front);
    } catch (e) {
      _fail(e, _start);
    }
  }

  void _afterDocument(String kind, EkycDocument? d) {
    if (kind == 'document_front') doc = d;
    if (kind == 'document_front' && (doc?.needsBack ?? false)) return setState(() => step = _Step.back);
    final person = doc?.needsSelfie ?? info!.needsSelfie ?? true;
    person ? setState(() => step = _Step.face) : _send();
  }

  Future<void> _send() async {
    setState(() => step = _Step.sending);
    try {
      await api.submit();
      final until = DateTime.now().add(const Duration(seconds: 60));
      while (mounted && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final st = await api.status().catchError((_) => EkycStatus('processing', false));
        if (st.finished) return _end(EkycResult.outcomeOf(st.state), st.state == 'review' ? t('reviewMsg') : t('doneMsg'));
      }
      _end(EkycOutcome.submitted, t('stillChecking'));
    } catch (e) {
      _fail(e, _send);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(outcome ?? EkycOutcome.cancelled);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(info?.client ?? t('title')),
          leading: IconButton(icon: const Icon(Icons.close), onPressed: () => _finish(outcome ?? EkycOutcome.cancelled)),
          actions: [if (info?.test ?? false) const Padding(padding: EdgeInsets.all(16), child: Text('TEST'))],
        ),
        body: SafeArea(child: _body()),
      ),
    );
  }

  Widget _body() {
    switch (step) {
      case _Step.loading:
      case _Step.sending:
        return _Centered(
          children: [
            const CircularProgressIndicator(),
            if (step == _Step.sending) ...[
              const SizedBox(height: 20),
              Text(t('checking'), style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              Text(t('checkingMsg'), textAlign: TextAlign.center),
            ],
          ],
        );
      case _Step.welcome:
        return _Page(
          title: t('welcome'),
          content: [
            Text(t('welcomeMsg', {'c': info!.client ?? ''})),
            if (info!.consentNeeded) ...[
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(10)),
                  child: SingleChildScrollView(child: Text(info!.consentText(widget.language))),
                ),
              ),
              CheckboxListTile(
                value: agreed,
                onChanged: (v) => setState(() => agreed = v ?? false),
                title: Text(t('agree')),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ] else
              const Spacer(),
          ],
          primary: (t('start'), agreed ? _start : null),
          secondary: (t('cancel'), () => _finish(EkycOutcome.cancelled)),
        );
      case _Step.front:
      case _Step.back:
        final kind = step == _Step.front ? 'document_front' : 'document_back';
        return _DocumentCapture(key: ValueKey(kind), kind: kind, api: api, t: t, onDone: (d) => _afterDocument(kind, d));
      case _Step.face:
        return _FaceCapture(
          cues: ['selfie', ...info!.livenessChallenge],
          api: api,
          t: t,
          onDone: _send,
          onError: (e) => _fail(e, () => setState(() => step = _Step.face)),
        );
      case _Step.done:
        return _Page(
          title: t('done'),
          icon: outcome == EkycOutcome.expired || outcome == EkycOutcome.invalid ? Icons.link_off : Icons.check_circle,
          content: [Text(message ?? ''), const Spacer()],
          primary: (t('ok'), () => _finish(outcome ?? EkycOutcome.submitted)),
        );
      case _Step.failed:
        return _Page(
          title: '⚠️',
          content: [Text(message ?? ''), const Spacer()],
          primary: (t('tryAgain'), retry),
          secondary: (t('cancel'), () => _finish(EkycOutcome.error)),
        );
    }
  }
}

// --- document ---------------------------------------------------------------------------
class _DocumentCapture extends StatefulWidget {
  const _DocumentCapture({super.key, required this.kind, required this.api, required this.t, required this.onDone});
  final String kind;
  final EkycApi api;
  final EkycStrings t;
  final void Function(EkycDocument?) onDone;

  @override
  State<_DocumentCapture> createState() => _DocumentCaptureState();
}

class _DocumentCaptureState extends State<_DocumentCapture> {
  CameraController? cam;
  Uint8List? shot;
  EkycDocument? doc;
  String? busy, note, problem;

  EkycStrings get t => widget.t;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.veryHigh, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await c.initialize();
      await c.setFlashMode(FlashMode.off).catchError((_) {});
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => cam = c);
    } on CameraException catch (e) {
      setState(() => problem = e.code.contains('Denied') ? t('camDenied') : t('error', {'e': e.description ?? e.code}));
    }
  }

  @override
  void dispose() {
    cam?.dispose();
    super.dispose();
  }

  Future<void> _take() async {
    final c = cam;
    if (c == null || c.value.isTakingPicture) return;
    try {
      final f = await c.takePicture();
      final bytes = await f.readAsBytes();
      setState(() {
        shot = bytes;
        busy = widget.kind == 'document_front' ? t('reading') : t('uploading');
        note = null;
      });
      doc = await widget.api.upload(widget.kind, bytes);
      setState(() {
        busy = null;
        if (doc?.readable == false) {
          note = t('unclear');
        } else if (doc?.name != null) {
          note = '✓ ${t('seen', {'d': doc!.name!})}';
        }
      });
    } catch (e) {
      setState(() {
        busy = null;
        shot = null;
        note = t('error', {'e': e is EkycApiException ? e.message : '$e'});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final front = widget.kind == 'document_front';
    final c = cam;
    return _Page(
      title: t(front ? 'front' : 'back'),
      content: [
        Text(t(front ? 'frontMsg' : 'backMsg')),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 1.586,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: shot != null
                ? Image.memory(shot!, fit: BoxFit.cover)
                : c != null && c.value.isInitialized
                    ? FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(width: c.value.previewSize!.height, height: c.value.previewSize!.width, child: CameraPreview(c)),
                      )
                    : Container(color: Colors.black12, alignment: Alignment.center, child: Text(problem ?? '')),
          ),
        ),
        if (note != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(note!)),
        const Spacer(),
        if (busy != null) ...[const Center(child: CircularProgressIndicator()), const SizedBox(height: 8), Center(child: Text(busy!))],
      ],
      primary: busy != null ? null : (shot == null ? (t('shutter'), cam == null ? null : _take) : (t('useIt'), () => widget.onDone(doc))),
      secondary: busy != null || shot == null ? null : (t('retake'), () => setState(() { shot = null; note = null; doc = null; })),
    );
  }
}

// --- face and head turns -------------------------------------------------------------------
class _FaceCapture extends StatefulWidget {
  const _FaceCapture({required this.cues, required this.api, required this.t, required this.onDone, required this.onError});
  final List<String> cues;
  final EkycApi api;
  final EkycStrings t;
  final VoidCallback onDone;
  final void Function(Object) onError;

  @override
  State<_FaceCapture> createState() => _FaceCaptureState();
}

class _FaceCaptureState extends State<_FaceCapture> {
  CameraController? cam;
  FaceDetector? detector;
  late final PoseSteps steps = PoseSteps(widget.cues);
  final shots = <Uint8List>[];
  bool started = false, busy = false, manual = false, uploading = false;
  double? yaw;
  String? problem;
  Timer? manualTimer;

  EkycStrings get t => widget.t;

  @override
  void dispose() {
    manualTimer?.cancel();
    final c = cam;
    if (c != null && c.value.isStreamingImages) c.stopImageStream().catchError((_) {});
    c?.dispose();
    detector?.close();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() => started = true);
    try {
      final cams = await availableCameras();
      final front = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      final c = CameraController(front, ResolutionPreset.high, enableAudio: false, imageFormatGroup: streamFormat);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      detector = newFaceDetector();
      setState(() => cam = c);
      await _stream();
    } on CameraException catch (e) {
      setState(() => problem = e.code.contains('Denied') ? t('camDenied') : t('error', {'e': e.description ?? e.code}));
    }
  }

  Future<void> _stream() async {
    final c = cam!;
    _armManual();
    await c.startImageStream((image) async {
      if (busy || !mounted) return;
      busy = true;
      try {
        final input = toInputImage(image, c.description);
        final y = input == null ? null : await yawOf(detector!, input);
        if (!mounted) return;
        setState(() => yaw = y);
        if (steps.feed(y, DateTime.now())) await _capture(y);
      } catch (_) {
        // a bad frame: wait for the next one
      } finally {
        busy = false;
      }
    });
  }

  // If the automatic capture cannot see the pose (light, old phone), offer a shutter.
  void _armManual() {
    manualTimer?.cancel();
    manual = false;
    manualTimer = Timer(const Duration(seconds: 10), () => mounted ? setState(() => manual = true) : null);
  }

  Future<void> _capture(double? y) async {
    final c = cam!;
    if (c.value.isStreamingImages) await c.stopImageStream();
    final f = await c.takePicture();
    shots.add(await f.readAsBytes());
    steps.captured(y);
    if (steps.done) {
      manualTimer?.cancel();
      return _upload();
    }
    if (mounted) setState(() {});
    await _stream();
  }

  Future<void> _upload() async {
    setState(() => uploading = true);
    try {
      for (var i = 0; i < widget.cues.length; i++) {
        await widget.api.upload(widget.cues[i] == 'selfie' ? 'selfie' : 'liveness_$i', shots[i]);
      }
      widget.onDone();
    } catch (e) {
      widget.onError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!started) {
      return _Page(
        title: t('face'),
        icon: Icons.face,
        content: [Text(t('faceMsg')), const Spacer()],
        primary: (t('go'), _open),
      );
    }
    if (uploading) return _Centered(children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text(t('uploading'))]);
    final c = cam;
    final cue = steps.cue;
    final hint = yaw == null ? t('noFace') : (steps.matches(yaw) ? t('hold') : t(cue ?? 'selfie'));
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (c != null && c.value.isInitialized)
                ClipRect(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(width: c.value.previewSize!.height, height: c.value.previewSize!.width, child: CameraPreview(c)),
                  ),
                )
              else
                Center(child: Text(problem ?? '', textAlign: TextAlign.center)),
              IgnorePointer(child: CustomPaint(painter: _OvalMask(steps.matches(yaw)))),
              Positioned(
                left: 16,
                right: 16,
                bottom: 24,
                child: Column(
                  children: [
                    Text(t(cue ?? 'selfie'), textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 4)])),
                    Text(hint, style: const TextStyle(color: Colors.white70, shadows: [Shadow(blurRadius: 4)])),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: steps.index / widget.cues.length),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (manual && c != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: double.infinity, child: FilledButton(onPressed: () => _capture(yaw), child: Text(t('shutter')))),
          ),
      ],
    );
  }
}

class _OvalMask extends CustomPainter {
  _OvalMask(this.good);
  final bool good;

  @override
  void paint(Canvas canvas, Size size) {
    final oval = Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.42), width: size.width * 0.68, height: size.height * 0.52);
    final shade = Path()
      ..addRect(Offset.zero & size)
      ..addOval(oval)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.45));
    canvas.drawOval(oval, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = good ? Colors.greenAccent : Colors.white);
  }

  @override
  bool shouldRepaint(_OvalMask old) => old.good != good;
}

// --- layout ---------------------------------------------------------------------------------
class _Page extends StatelessWidget {
  const _Page({required this.title, required this.content, this.primary, this.secondary, this.icon});
  final String title;
  final List<Widget> content;
  final (String, VoidCallback?)? primary, secondary;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (icon != null) Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          ...content,
          if (primary != null) ...[
            const SizedBox(height: 12),
            FilledButton(onPressed: primary!.$2, style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), child: Text(primary!.$1)),
          ],
          if (secondary != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: secondary!.$2, style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)), child: Text(secondary!.$1)),
          ],
        ],
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) =>
      Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: children)));
}
