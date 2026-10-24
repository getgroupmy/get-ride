// Every selfie in the app (0281): the front camera, and while it is open the
// person blinks or turns their head, checked on the phone by its face
// detector (core/liveness.dart, live_selfie/on_device.dart). On a phone
// (Android, iOS) with a camera the photo is only taken once that check
// passes: no shutter without it and no photo from a file. If the check can't
// start there, a modal says so and offers to try again. Where there is no
// detector (the web, desktops) the photo is taken plain and recorded as
// 'not_checked'; with no camera at all, a photo is chosen from a file, also
// 'not_checked'; the admin sees both. Sign-up, Edit profile, partner
// registration and the dispatch sign-in steps all take their selfie here.
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../admin/screens/meterapp/pick_image.dart';
import '../core/liveness.dart';
import 'page_style_host.dart';
import 'live_selfie/on_device.dart';

/// A selfie and how it was taken.
class LiveSelfie {
  const LiveSelfie({required this.bytes, this.name = 'selfie.jpg', this.liveness = 'not_checked', this.detail});

  final Uint8List bytes;
  final String name;

  /// 'passed' (blinked or turned while the camera was open) or 'not_checked'.
  final String liveness;

  /// 'blink' or 'turn' when passed.
  final String? detail;

  bool get live => liveness == 'passed';

  PickedImage get picked {
    final ext = imageExt(name);
    return (bytes: bytes, name: name, ext: ext, contentType: imageContentType(ext));
  }
}

/// Opens the live selfie camera; null when the person backs out.
Future<LiveSelfie?> takeLiveSelfie(BuildContext context) => Navigator.of(context).push<LiveSelfie>(
  AppPageRoute(id: 'selfie.live', fullscreenDialog: true, builder: (_) => const LiveSelfieScreen()),
);

/// A profile photo through the live camera, cut square (a profile photo is
/// shown in a circle); null when the person backs out.
Future<LiveSelfie?> takeLiveAvatar(BuildContext context) async {
  final s = await takeLiveSelfie(context);
  if (s == null) return null;
  final square = await squarePickedImage(s.picked);
  return LiveSelfie(bytes: square.bytes, name: square.name, liveness: s.liveness, detail: s.detail);
}

/// After this long without the check passing, a tip on how to pass it.
/// There is no way round the check on a phone.
const liveSelfieGiveUpAfter = Duration(seconds: 25);

/// Whether this is a phone, where the live check is required.
bool get liveSelfieOnPhone =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

class LiveSelfieScreen extends StatefulWidget {
  const LiveSelfieScreen({super.key, this.cameras, this.pickFile, this.challenge, this.onPhone, this.openFaces});

  /// The cameras (overridden in tests); the phone's by default.
  final Future<List<CameraDescription>> Function()? cameras;

  /// A photo from a file, where there is no camera (overridden in tests).
  final Future<PickedImage?> Function()? pickFile;

  /// What to ask (random by default).
  final LiveChallenge? challenge;

  /// Whether the live check is required (a phone; overridden in tests).
  final bool? onPhone;

  /// The face detector (overridden in tests); the phone's by default.
  final FrameFaces? Function()? openFaces;

  @override
  State<LiveSelfieScreen> createState() => _LiveSelfieScreenState();
}

enum _Mode { starting, live, plain, noCamera, checkFailed }

class _LiveSelfieScreenState extends State<LiveSelfieScreen> {
  CameraController? _cam;
  FrameFaces? _faces;
  late final LivenessTracker _tracker = LivenessTracker(widget.challenge ?? LiveChallenge.pick());
  _Mode _mode = _Mode.starting;
  bool _busyFrame = false;
  bool _taking = false;
  bool _giveUp = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _giveUpTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  bool get _phone => widget.onPhone ?? liveSelfieOnPhone;

  Future<void> _start() async {
    if (_mode != _Mode.starting) {
      setState(() {
        _mode = _Mode.starting;
        _error = null;
      });
    }
    List<CameraDescription> cams;
    try {
      cams = await (widget.cameras ?? availableCameras)();
    } catch (_) {
      cams = const [];
    }
    if (!mounted) return;
    if (cams.isEmpty) return setState(() => _mode = _Mode.noCamera);
    final front = cams.where((c) => c.lensDirection == CameraLensDirection.front).firstOrNull ?? cams.first;
    final faces = (widget.openFaces ?? openFrameFaces)();
    if (faces == null && _phone) return _checkFailed();
    final cam = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: faces == null ? null : streamFormat(),
    );
    try {
      await cam.initialize();
    } catch (_) {
      await cam.dispose();
      await faces?.close();
      // A phone has a camera: the check is what failed to start.
      if (_phone) return _checkFailed();
      if (mounted) setState(() => _mode = _Mode.noCamera);
      return;
    }
    if (!mounted) {
      await cam.dispose();
      await faces?.close();
      return;
    }
    _cam = cam;
    _faces = faces;
    if (faces != null) {
      try {
        await cam.startImageStream(_onFrame);
        _giveUpTimer = Timer(liveSelfieGiveUpAfter, () {
          if (mounted) setState(() => _giveUp = true);
        });
        setState(() => _mode = _Mode.live);
        return;
      } catch (_) {
        await faces.close();
        _faces = null;
      }
    }
    if (_phone) {
      _cam = null;
      await cam.dispose();
      return _checkFailed();
    }
    setState(() => _mode = _Mode.plain);
  }

  /// On a phone the check couldn't start: a modal says so, with Try again.
  Future<void> _checkFailed() async {
    if (!mounted) return;
    setState(() => _mode = _Mode.checkFailed);
    final retry = await showAppDialog<bool>(
      id: 'selfie.check-failed',
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        key: const ValueKey('selfie-check-failed'),
        icon: const Icon(Icons.face_retouching_off),
        title: const Text("The face check couldn't start"),
        content: const Text(
          'The selfie is taken once you blink or turn your head, checked on this phone. Close other apps '
          'using the camera, allow camera access for GET.ride, then try again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('selfie-check-retry'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (retry == true) {
      await _start();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// A few frames a second to the detector, one at a time.
  Future<void> _onFrame(CameraImage image) async {
    final cam = _cam, faces = _faces;
    if (cam == null || faces == null || _busyFrame || _taking) return;
    final now = DateTime.now();
    if (now.difference(_lastFrame) < const Duration(milliseconds: 250)) return;
    _lastFrame = now;
    _busyFrame = true;
    try {
      final s = await faces.sample(image, cam.description, cam.value.deviceOrientation);
      if (s == null || !mounted) return;
      final before = _tracker.hint;
      final passed = _tracker.feed(s);
      if (passed) {
        unawaited(_take(live: true));
      } else if (_tracker.hint != before) {
        setState(() {});
      }
    } catch (_) {
      // A frame the detector can't read: the next one.
    } finally {
      _busyFrame = false;
    }
  }

  Future<void> _take({required bool live}) async {
    final cam = _cam;
    if (cam == null || _taking) return;
    setState(() => _taking = true);
    try {
      if (cam.value.isStreamingImages) await cam.stopImageStream();
      final x = await cam.takePicture();
      final bytes = await x.readAsBytes();
      if (!mounted) return;
      Navigator.of(context).pop(LiveSelfie(
        bytes: bytes,
        name: x.name.isEmpty ? 'selfie.jpg' : x.name,
        liveness: live ? 'passed' : 'not_checked',
        detail: live ? _tracker.challenge.detail : null,
      ));
    } catch (_) {
      if (mounted) {
        setState(() {
          _taking = false;
          _error = "Couldn't take the photo. Try again.";
        });
      }
    }
  }

  Future<void> _fromFile() async {
    final photo = await (widget.pickFile ?? pickImage)();
    if (photo == null || !mounted) return;
    Navigator.of(context).pop(LiveSelfie(bytes: photo.bytes, name: photo.name));
  }

  @override
  void dispose() {
    _giveUpTimer?.cancel();
    final cam = _cam;
    _cam = null;
    cam?.dispose();
    _faces?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cam = _cam;
    final hint = switch (_mode) {
      _Mode.starting => 'Opening the camera',
      _Mode.live => _taking ? 'Hold still' : _tracker.text,
      _Mode.plain => 'Look at the camera, then take the photo',
      _Mode.noCamera => "This device has no camera we can use. Choose a clear photo of your face.",
      _Mode.checkFailed => "The face check couldn't start.",
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Take a selfie')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 3 / 4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: t.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: _tracker.passed ? Colors.green : t.colorScheme.outlineVariant,
                              width: 3,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(21),
                            child: cam != null && cam.value.isInitialized
                                ? CameraPreview(cam)
                                : Center(
                                    child: _mode == _Mode.starting
                                        ? const CircularProgressIndicator()
                                        : Icon(Icons.face_outlined, size: 96, color: t.colorScheme.onSurfaceVariant),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    hint,
                    key: const ValueKey('selfie-hint'),
                    textAlign: TextAlign.center,
                    style: t.textTheme.titleMedium,
                  ),
                  if (_mode == _Mode.live)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Checked on this phone, to show it is really you.',
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: t.colorScheme.error)),
                    ),
                  const SizedBox(height: 16),
                  if (_mode == _Mode.plain)
                    FilledButton.icon(
                      key: const ValueKey('selfie-take'),
                      onPressed: _taking ? null : () => _take(live: false),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Take photo'),
                    ),
                  // No way round the check on a phone: a tip instead.
                  if (_mode == _Mode.live && _giveUp)
                    Text(
                      'Face the light, hold the phone at eye level and keep your whole face in the frame.',
                      key: const ValueKey('selfie-tip'),
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyMedium,
                    ),
                  if (_mode == _Mode.checkFailed)
                    FilledButton.icon(
                      key: const ValueKey('selfie-retry'),
                      onPressed: _start,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  if (_mode == _Mode.noCamera)
                    FilledButton.icon(
                      key: const ValueKey('selfie-file'),
                      onPressed: _fromFile,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Choose a photo'),
                    ),
                  if (kIsWeb && _mode != _Mode.noCamera)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        "The live check isn't available in a browser. The photo is marked as not checked.",
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
