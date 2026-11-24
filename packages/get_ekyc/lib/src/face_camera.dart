import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// A camera frame in the form ML Kit reads (NV21 on Android, BGRA on iOS).
InputImage? toInputImage(CameraImage image, CameraDescription camera) {
  final rotation = InputImageRotationValue.fromRawValue(Platform.isIOS ? 0 : camera.sensorOrientation);
  final format = InputImageFormatValue.fromRawValue(image.format.raw as int);
  if (rotation == null || format == null) return null;
  if (Platform.isAndroid && format != InputImageFormat.nv21) return null;
  if (Platform.isIOS && format != InputImageFormat.bgra8888) return null;
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

/// The image format ML Kit wants from the camera stream on this platform.
ImageFormatGroup get streamFormat => Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21;

/// Head yaw (degrees) of the largest face in the frame, or null when none.
Future<double?> yawOf(FaceDetector detector, InputImage input) async {
  final faces = await detector.processImage(input);
  if (faces.isEmpty) return null;
  faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(a.boundingBox.width * a.boundingBox.height));
  return faces.first.headEulerAngleY;
}

FaceDetector newFaceDetector() => FaceDetector(
      options: FaceDetectorOptions(performanceMode: FaceDetectorMode.fast, minFaceSize: 0.25),
    );
