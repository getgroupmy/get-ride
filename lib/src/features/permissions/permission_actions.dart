// What fixes each [PermissionBlock]: the phone's own question where it can
// still be shown, its Settings where only they can change it. Shared by the
// rider's permissions page and the partner's go-online check.
import 'package:flutter/material.dart';

import '../../core/app_permissions.dart';
import '../../data/permission_probe.dart';

/// The button that fixes [block].
String permissionBlockAction(PermissionBlock block) => switch (block) {
  PermissionBlock.serviceOff => 'Open Location settings',
  PermissionBlock.locationNotAsked => 'Allow location',
  PermissionBlock.notAlways => 'Allow Always',
  PermissionBlock.notificationsNotAsked => 'Allow notifications',
  PermissionBlock.locationOff || PermissionBlock.notificationsOff => 'Open Settings',
};

IconData permissionBlockIcon(PermissionBlock block) =>
    block.isLocation ? Icons.location_on_outlined : Icons.notifications_active_outlined;

/// How a fix went: asked here ([asked]), sent to the phone's Settings
/// ([settings], the answer comes when the app is in front again), or
/// Settings could not be opened ([failed]).
enum PermissionFix { asked, settings, failed }

/// Tries to fix [block].
Future<PermissionFix> resolvePermissionBlock(PermissionProbe probe, PermissionBlock block) async {
  Future<PermissionFix> open(Future<bool> opening) async =>
      await opening ? PermissionFix.settings : PermissionFix.failed;
  switch (block) {
    case PermissionBlock.serviceOff:
      return open(probe.openLocationSettings());
    case PermissionBlock.locationNotAsked:
      await probe.requestLocation();
      return PermissionFix.asked;
    case PermissionBlock.notAlways:
      // iOS offers "Change to Always Allow" once; after that only Settings can.
      if (await probe.requestLocation() == PermState.granted) return PermissionFix.asked;
      return open(probe.openAppSettings());
    case PermissionBlock.locationOff:
      return open(probe.openAppSettings());
    case PermissionBlock.notificationsNotAsked:
    case PermissionBlock.notificationsOff:
      // Android asks again until refused twice; iOS answers at once.
      await probe.request(AppPermission.notifications);
      final now = await probe.notifications();
      if (now != PermState.denied || block == PermissionBlock.notificationsNotAsked) return PermissionFix.asked;
      return open(probe.openAppSettings());
  }
}
