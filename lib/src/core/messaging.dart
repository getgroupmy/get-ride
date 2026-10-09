// SMS / WhatsApp routing (Admin → Settings → SMS / WhatsApp, migration
// 0120): which signed-in device carries each channel, each way. Pure.
//
// - OTP, marketing blasts and support messages go by SMS (a GET.ride Gateway
//   phone's SIM) or WhatsApp (the Business Cloud API number);
// - a support call is the in-app VoIP call: its devices are the ones that
//   ring (inbound) or place the call (outbound).

enum MessagingChannel {
  otp('otp', 'OTP', 'Sign-in codes'),
  marketing('marketing', 'Marketing blast', 'Promotions sent to many users'),
  supportCall('support_call', 'Support call', 'In-app VoIP calls with support'),
  supportMessage('support_message', 'Support message', 'Text conversations with support');

  const MessagingChannel(this.id, this.label, this.description);
  final String id;
  final String label;
  final String description;

  bool get isCall => this == MessagingChannel.supportCall;

  /// The transports this channel can use.
  List<MessagingTransport> get transports =>
      isCall ? const [MessagingTransport.voip] : const [MessagingTransport.sms, MessagingTransport.whatsapp];

  static MessagingChannel? fromId(Object? id) => values.where((c) => c.id == id).firstOrNull;
}

enum MessagingDirection {
  inbound('inbound', 'Inbound'),
  outbound('outbound', 'Outbound');

  const MessagingDirection(this.id, this.label);
  final String id;
  final String label;

  static MessagingDirection? fromId(Object? id) => values.where((d) => d.id == id).firstOrNull;
}

enum MessagingTransport {
  sms('sms', 'SMS'),
  whatsapp('whatsapp', 'WhatsApp'),
  voip('voip', 'VoIP');

  const MessagingTransport(this.id, this.label);
  final String id;
  final String label;

  /// The device capability that carries it; WhatsApp is the Cloud API's.
  String? get capability => switch (this) {
    MessagingTransport.sms => 'sms',
    MessagingTransport.voip => 'voip',
    MessagingTransport.whatsapp => null,
  };

  static MessagingTransport? fromId(Object? id) => values.where((t) => t.id == id).firstOrNull;
}

/// How long a device counts as online after its last heartbeat.
const messagingOnlineWindow = Duration(minutes: 3);

/// How often a device says it is here.
const messagingHeartbeatEvery = Duration(minutes: 1);

/// A device that can carry a channel (`messaging_devices`).
class MessagingDevice {
  const MessagingDevice({
    required this.id,
    required this.userId,
    required this.deviceId,
    required this.kind,
    this.label,
    this.platform,
    this.capabilities = const [],
    this.simNumber,
    this.appVersion,
    this.lastSeenAt,
  });

  final String id;
  final String userId;
  final String deviceId;

  /// `gateway` (the GET.ride Gateway app) or `app` (an admin's app install).
  final String kind;
  final String? label, platform, simNumber, appVersion;
  final List<String> capabilities;
  final DateTime? lastSeenAt;

  bool get isGateway => kind == 'gateway';
  bool can(String capability) => capabilities.contains(capability);

  bool onlineAt(DateTime now) => lastSeenAt != null && now.difference(lastSeenAt!) <= messagingOnlineWindow;

  String get title {
    final l = label?.trim() ?? '';
    if (l.isNotEmpty) return l;
    return isGateway ? 'Gateway phone' : '${platform ?? 'App'} device';
  }

  static MessagingDevice fromRow(Map<String, dynamic> r) => MessagingDevice(
    id: '${r['id']}',
    userId: '${r['user_id']}',
    deviceId: '${r['device_id']}',
    kind: r['kind'] == 'gateway' ? 'gateway' : 'app',
    label: r['label'] as String?,
    platform: r['platform'] as String?,
    capabilities: [
      if (r['capabilities'] is List)
        for (final c in r['capabilities'] as List) '$c',
    ],
    simNumber: r['sim_number'] as String?,
    appVersion: r['app_version'] as String?,
    lastSeenAt: DateTime.tryParse('${r['last_seen_at'] ?? ''}'),
  );
}

/// "Online", "Seen 5 min ago", "Seen 3 h ago", "Seen 2 d ago", "Never seen".
String deviceSeenLabel(MessagingDevice d, DateTime now) {
  final seen = d.lastSeenAt;
  if (seen == null) return 'Never seen';
  if (d.onlineAt(now)) return 'Online';
  final ago = now.difference(seen);
  if (ago.inMinutes < 60) return 'Seen ${ago.inMinutes} min ago';
  if (ago.inHours < 48) return 'Seen ${ago.inHours} h ago';
  return 'Seen ${ago.inDays} d ago';
}

/// One channel, one way (`messaging_routes`).
class MessagingRoute {
  const MessagingRoute({
    required this.channel,
    required this.direction,
    required this.transport,
    this.deviceIds = const [],
    this.whatsappNumber,
    this.enabled = true,
  });

  final MessagingChannel channel;
  final MessagingDirection direction;
  final MessagingTransport transport;

  /// For SMS, the gateways (the first online one sends); for VoIP, the
  /// devices that ring or call.
  final List<String> deviceIds;
  final String? whatsappNumber;
  final bool enabled;

  /// A channel's default before the admin has set it.
  factory MessagingRoute.unset(MessagingChannel c, MessagingDirection d) =>
      MessagingRoute(channel: c, direction: d, transport: c.transports.first, enabled: false);

  MessagingRoute copyWith({
    MessagingTransport? transport,
    List<String>? deviceIds,
    String? Function()? whatsappNumber,
    bool? enabled,
  }) => MessagingRoute(
    channel: channel,
    direction: direction,
    transport: transport ?? this.transport,
    deviceIds: deviceIds ?? this.deviceIds,
    whatsappNumber: whatsappNumber == null ? this.whatsappNumber : whatsappNumber(),
    enabled: enabled ?? this.enabled,
  );

  static MessagingRoute? fromRow(Map<String, dynamic> r) {
    final c = MessagingChannel.fromId(r['channel']);
    final d = MessagingDirection.fromId(r['direction']);
    final t = MessagingTransport.fromId(r['transport']);
    if (c == null || d == null || t == null || !c.transports.contains(t)) return null;
    return MessagingRoute(
      channel: c,
      direction: d,
      transport: t,
      deviceIds: [
        if (r['device_ids'] is List)
          for (final id in r['device_ids'] as List) '$id',
      ],
      whatsappNumber: r['whatsapp_number'] as String?,
      enabled: r['enabled'] != false,
    );
  }

  Map<String, dynamic> toRow() => {
    'channel': channel.id,
    'direction': direction.id,
    'transport': transport.id,
    // Devices only for a transport that runs on one; a number only for WhatsApp.
    'device_ids': transport.capability == null ? <String>[] : deviceIds,
    'whatsapp_number': transport == MessagingTransport.whatsapp ? whatsappNumber?.trim() : null,
    'enabled': enabled,
  };
}

/// The devices that can carry [t]: gateways with SMS for SMS, devices with
/// VoIP for a call; none for WhatsApp (the Cloud API sends).
List<MessagingDevice> devicesFor(MessagingTransport t, List<MessagingDevice> devices) {
  final cap = t.capability;
  return cap == null ? const [] : devices.where((d) => d.can(cap)).toList();
}

final _phone = RegExp(r'^\+?[0-9 ]{6,20}$');

/// Why [r] can't be saved as it stands, or null. A switched-off route can
/// always be saved.
String? messagingRouteProblem(MessagingRoute r, List<MessagingDevice> devices) {
  if (!r.enabled) return null;
  switch (r.transport) {
    case MessagingTransport.whatsapp:
      final n = r.whatsappNumber?.trim() ?? '';
      if (!_phone.hasMatch(n)) return 'Enter the WhatsApp Business number, e.g. +60 12 345 6789.';
    case MessagingTransport.sms:
    case MessagingTransport.voip:
      final usable = devicesFor(r.transport, devices).map((d) => d.id).toSet();
      if (!r.deviceIds.any(usable.contains)) {
        return r.transport == MessagingTransport.sms
            ? 'Pick a GET.ride Gateway phone to carry these SMS.'
            : 'Pick the device(s) that take these calls.';
      }
  }
  return null;
}

/// Every channel and direction, with the stored route or its default.
List<MessagingRoute> messagingRouteTable(List<MessagingRoute> stored) => [
  for (final c in MessagingChannel.values)
    for (final d in MessagingDirection.values)
      stored.where((r) => r.channel == c && r.direction == d).firstOrNull ?? MessagingRoute.unset(c, d),
];

/// A phone number as the SMS queue takes it: digits with a leading +, or null.
String? normalizeSmsNumber(String raw) {
  final t = raw.replaceAll(RegExp(r'[\s()-]'), '');
  return RegExp(r'^\+?[0-9]{6,20}$').hasMatch(t) ? t : null;
}
