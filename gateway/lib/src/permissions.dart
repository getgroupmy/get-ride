// The Android permissions the gateway needs, behind an interface so the
// screen can be tested without a phone.
import 'package:permission_handler/permission_handler.dart';

enum GatewayPermission {
  /// Send and receive SMS: without it the gateway cannot work.
  sms('SMS', 'Send and receive SMS from this phone\'s SIM.', required: true),

  /// Read the phone state: lists the SIMs so a dual-SIM phone can pick one.
  phone('SIM cards', 'See this phone\'s SIMs so you can choose the one that sends.'),

  /// Post notifications: the ongoing "Gateway online" notification.
  notification('Notifications', 'Show that the gateway is running.');

  const GatewayPermission(this.label, this.why, {this.required = false});
  final String label;
  final String why;
  final bool required;
}

abstract class GatewayPermissions {
  Future<bool> granted(GatewayPermission p);
  Future<bool> request(GatewayPermission p);
  Future<void> openSettings();
}

class PluginGatewayPermissions implements GatewayPermissions {
  Permission _of(GatewayPermission p) => switch (p) {
    GatewayPermission.sms => Permission.sms,
    GatewayPermission.phone => Permission.phone,
    GatewayPermission.notification => Permission.notification,
  };

  @override
  Future<bool> granted(GatewayPermission p) => _of(p).isGranted;

  @override
  Future<bool> request(GatewayPermission p) async {
    final status = await _of(p).request();
    return status.isGranted;
  }

  @override
  Future<void> openSettings() => openAppSettings();
}
