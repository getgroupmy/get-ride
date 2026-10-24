// Android and iOS: ML Kit on the phone itself. Faces in the camera's frames
// (eyes open, head turn) for the live selfie, and the text on an ID photo
// for its name, IC number and expiry. Nothing leaves the phone. Desktops
// build this too and get null: ML Kit is for phones only.
import 'dart:io';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/liveness.dart';
import '../../core/signin_checks.dart';

bool get _phone =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

abstract class FrameFaces {
  Future<FaceSample?> sample(CameraImage image, CameraDescription camera, DeviceOrientation orientation);
  Future<void> close();
}

FrameFaces? openFrameFaces() => _phone ? _MlKitFaces() : null;

/// The frame format ML Kit reads from the camera stream.
ImageFormatGroup? streamFormat() => !_phone
    ? null
    : defaultTargetPlatform == TargetPlatform.android
    ? ImageFormatGroup.nv21
    : ImageFormatGroup.bgra8888;

const _turns = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

class _MlKitFaces implements FrameFaces {
  final _detector = FaceDetector(
    options: FaceDetectorOptions(enableClassification: true, performanceMode: FaceDetectorMode.fast, minFaceSize: 0.15),
  );

  @override
  Future<FaceSample?> sample(CameraImage image, CameraDescription camera, DeviceOrientation orientation) async {
    final input = _input(image, camera, orientation);
    if (input == null) return null;
    final faces = await _detector.processImage(input);
    if (faces.isEmpty) return const FaceSample(faces: 0);
    final f = faces.first;
    final across = (image.width < image.height ? image.width : image.height).toDouble();
    return FaceSample(
      faces: faces.length,
      leftEyeOpen: f.leftEyeOpenProbability,
      rightEyeOpen: f.rightEyeOpenProbability,
      yaw: f.headEulerAngleY,
      width: across <= 0 ? 0.5 : f.boundingBox.width / across,
    );
  }

  /// The frame as ML Kit takes it: one plane, NV21 on Android, BGRA on iOS,
  /// turned as the sensor sits.
  InputImage? _input(CameraImage image, CameraDescription camera, DeviceOrientation orientation) {
    final sensor = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensor);
    } else if (Platform.isAndroid) {
      final turn = _turns[orientation];
      if (turn == null) return null;
      final degrees = camera.lensDirection == CameraLensDirection.front
          ? (sensor + turn) % 360
          : (sensor - turn + 360) % 360;
      rotation = InputImageRotationValue.fromRawValue(degrees);
    }
    if (rotation == null) return null;
    final format = InputImageFormatValue.fromRawValue(image.format.raw as int);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  @override
  Future<void> close() => _detector.close();
}

/// The name, IC number and expiry on an ID photo; null where it can't be
/// read here.
Future<CardRead?> readCardPhoto(Uint8List bytes) async {
  if (!_phone) return null;
  final recognizer = TextRecognizer();
  File? file;
  try {
    final dir = await getTemporaryDirectory();
    file = File('${dir.path}/id_read_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes, flush: true);
    final text = await recognizer.processImage(InputImage.fromFilePath(file.path));
    return readCard(text.text);
  } catch (_) {
    return null;
  } finally {
    await recognizer.close();
    try {
      await file?.delete();
    } catch (_) {}
  }
}

/// All the text on a document photo, as the phone reads it; null where it
/// can't be read here (partner registration, 0288).
Future<String?> readImageText(Uint8List bytes) async {
  if (!_phone) return null;
  final recognizer = TextRecognizer();
  File? file;
  try {
    final dir = await getTemporaryDirectory();
    file = File('${dir.path}/doc_read_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes, flush: true);
    final text = await recognizer.processImage(InputImage.fromFilePath(file.path));
    return text.text;
  } catch (_) {
    return null;
  } finally {
    await recognizer.close();
    try {
      await file?.delete();
    } catch (_) {}
  }
}
