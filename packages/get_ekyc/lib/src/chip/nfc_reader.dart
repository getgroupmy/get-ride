// Reads an ePassport / eMRTD card's chip over the phone's NFC: opens it with
// BAC (keyed by the printed MRZ) and reads EF.SOD, DG1 and DG2. get.ekyc then
// checks them (passive authentication) — the phone proves nothing itself.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';

import 'bac.dart';

class ChipFiles {
  ChipFiles(this.sod, this.dg1, this.dg2);
  final Uint8List sod, dg1;
  final Uint8List? dg2;

  /// The body of get.ekyc's PUT …/chip.
  Map<String, dynamic> toJson() => {
    'sod': base64Encode(sod),
    'dg1': base64Encode(dg1),
    if (dg2 != null) 'dg2': base64Encode(dg2!),
    'access': 'BAC',
  };
}

class ChipReader {
  /// Whether this phone has NFC switched on.
  static Future<bool> available() async {
    try {
      return await FlutterNfcKit.nfcAvailability == NFCAvailability.available;
    } catch (_) {
      return false;
    }
  }

  /// Waits for the document on the phone, then reads it. [prompt] is what iOS
  /// shows on its own NFC sheet. Throws a [ChipException] with a message a
  /// person can act on.
  static Future<ChipFiles> read({
    required String documentNumber,
    required String birth,
    required String expiry,
    String prompt = 'Hold your phone against the passport',
    String done = 'Chip read',
  }) async {
    final tag = await FlutterNfcKit.poll(
      timeout: const Duration(seconds: 45),
      iosAlertMessage: prompt,
      androidCheckNDEF: false, // a passport has no NDEF; probing only slows the link
      readIso14443A: true,
      readIso14443B: true,
      readIso18092: false,
      readIso15693: false,
    );
    try {
      if (tag.type != NFCTagType.iso7816) {
        throw ChipException('this is not a passport chip');
      }
      final session = ChipSession((apdu) async => Uint8List.fromList(await FlutterNfcKit.transceive(apdu)));
      await session.openWithBac(documentNumber, birth, expiry);
      final dg1 = await session.readFile(EF.dg1);
      final sod = await session.readFile(EF.sod);
      Uint8List? dg2;
      try {
        dg2 = await session.readFile(EF.dg2);
      } catch (_) {
        dg2 = null; // a chip that will not give its photo: the printed one is matched instead
      }
      await FlutterNfcKit.finish(iosAlertMessage: done);
      return ChipFiles(sod, dg1, dg2);
    } on ChipException catch (e) {
      await FlutterNfcKit.finish(iosErrorMessage: e.message);
      rethrow;
    } catch (e) {
      await FlutterNfcKit.finish(iosErrorMessage: 'The chip connection was lost');
      throw ChipException('the chip connection was lost, hold the phone still');
    }
  }
}
