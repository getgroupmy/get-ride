import 'dart:async';

import 'package:getride_gateway/src/backend.dart';
import 'package:getride_gateway/src/core.dart';
import 'package:getride_gateway/src/permissions.dart';
import 'package:getride_gateway/src/sms_platform.dart';

class FakeBackend implements GatewayBackend {
  final heartbeats = <String>[];
  final queue = <SmsJob>[];
  final reports = <(String, bool, String?)>[];
  final received = <IncomingSms>[];

  /// Thrown by the next call(s) while set.
  Object? failWith;

  /// Fails only report calls while set.
  Object? failReports;

  void _maybeFail() {
    final f = failWith;
    if (f != null) throw f;
  }

  @override
  Future<String> heartbeat({required String deviceId, String? label, String? simNumber, String? appVersion}) async {
    _maybeFail();
    heartbeats.add(deviceId);
    return 'dev-1';
  }

  @override
  Future<List<SmsJob>> claim(String device, {int limit = 10}) async {
    _maybeFail();
    final jobs = queue.take(limit).toList();
    queue.removeRange(0, jobs.length);
    return jobs;
  }

  @override
  Future<void> report(String device, String jobId, {required bool ok, String? error}) async {
    _maybeFail();
    final f = failReports;
    if (f != null) throw f;
    reports.add((jobId, ok, error));
  }

  @override
  Future<void> receive(String device, IncomingSms sms) async {
    _maybeFail();
    received.add(sms);
  }
}

class FakeSms implements SmsPlatform {
  final sent = <(String, String, int?)>[];
  final acked = <String>[];
  final pendingList = <IncomingSms>[];
  final _incoming = StreamController<IncomingSms>.broadcast();
  final failTo = <String>{};
  String? serviceText;
  bool serviceRunning = false;
  bool optimized = true;
  List<SimCard> simList = const [];

  void receive(IncomingSms s) => _incoming.add(s);

  @override
  Future<SmsSendResult> send(String to, String body, {int? subscriptionId}) async {
    sent.add((to, body, subscriptionId));
    return failTo.contains(to) ? const SmsSendResult.failed('Radio off') : const SmsSendResult.sent();
  }

  @override
  Stream<IncomingSms> get incoming => _incoming.stream;

  @override
  Future<List<IncomingSms>> pending() async => List.of(pendingList);

  @override
  Future<void> acknowledge(List<String> ids) async {
    acked.addAll(ids);
    pendingList.removeWhere((s) => ids.contains(s.id));
  }

  @override
  Future<List<SimCard>> sims() async => simList;

  @override
  Future<void> startService(String text) async {
    serviceRunning = true;
    serviceText = text;
  }

  @override
  Future<void> stopService() async => serviceRunning = false;

  @override
  Future<bool> batteryOptimized() async => optimized;

  @override
  Future<void> requestBatteryExemption() async => optimized = false;
}

class FakePermissions implements GatewayPermissions {
  FakePermissions([Map<GatewayPermission, bool>? state]) : state = {...?state};

  final Map<GatewayPermission, bool> state;
  final requested = <GatewayPermission>[];

  /// What a request grants.
  bool grantOnRequest = true;

  @override
  Future<bool> granted(GatewayPermission p) async => state[p] ?? false;

  @override
  Future<bool> request(GatewayPermission p) async {
    requested.add(p);
    if (grantOnRequest) state[p] = true;
    return state[p] ?? false;
  }

  @override
  Future<void> openSettings() async {}
}
