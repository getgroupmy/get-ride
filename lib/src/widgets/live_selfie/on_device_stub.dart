// The web build: no face detector and no text reader on the phone. The
// selfie is taken plain ('not_checked') and the ID is not read.
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation;

import '../../core/liveness.dart';
import '../../core/signin_checks.dart';

abstract class FrameFaces {
  Future<FaceSample?> sample(CameraImage image, CameraDescription camera, DeviceOrientation orientation);
  Future<void> close();
}

FrameFaces? openFrameFaces() => null;

ImageFormatGroup? streamFormat() => null;

Future<CardRead?> readCardPhoto(Uint8List bytes) async => null;

Future<String?> readImageText(Uint8List bytes) async => null;
