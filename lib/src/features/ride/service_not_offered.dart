// The rider's modal when the server refuses a booking whose service is off
// at the pickup (SERVICE_NOT_OFFERED_HERE, migration 0302).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/region_service_switches.dart';
import '../../widgets/app_notice.dart';

/// When [e] is the server's SERVICE_NOT_OFFERED_HERE: shows "Premium
/// isn't offered here" with the reason and an OK, and returns true. Else
/// false, for the caller's own error.
bool showServiceNotOffered(BuildContext context, Object e, {String? service}) {
  final r = serviceNotOfferedOf(e, service: service);
  if (r == null) return false;
  unawaited(showAppNotice(
    id: 'notice.ride-service',
    context: context,
    title: r.title,
    message: r.message,
    key: const ValueKey('service-not-offered'),
  ));
  return true;
}
