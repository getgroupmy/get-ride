// The app: not paired → pair with a code from Admin; paired → the gateway.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend.dart';
import 'engine.dart';
import 'home_screen.dart';
import 'pair_screen.dart';
import 'permissions.dart';
import 'settings.dart';
import 'sms_platform.dart';

/// Kept with `version:` in pubspec.yaml (a test checks); the admin page
/// shows it beside the device.
const gatewayVersion = '1.2.0';

ThemeData gatewayTheme(Brightness b) => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2DABE2), brightness: b),
);

class GatewayApp extends StatefulWidget {
  const GatewayApp({super.key, required this.db, required this.settings, this.platform, this.permissions, this.engine});

  final SupabaseClient db;
  final GatewaySettings settings;
  final SmsPlatform? platform;
  final GatewayPermissions? permissions;

  /// The process's gateway (main.dart), which outlives this screen; made
  /// here when not given (tests).
  final GatewayEngine? engine;

  @override
  State<GatewayApp> createState() => _GatewayAppState();
}

class _GatewayAppState extends State<GatewayApp> {
  late final SmsPlatform _platform = widget.platform ?? MethodChannelSmsPlatform();
  late final GatewayPermissions _permissions = widget.permissions ?? PluginGatewayPermissions();
  late final GatewayEngine _engine =
      widget.engine ??
      GatewayEngine(
        backend: SupabaseGatewayBackend(widget.db, key: () => widget.settings.gatewayKey),
        platform: _platform,
        config: widget.settings.config,
        appVersion: gatewayVersion,
      );

  @override
  void initState() {
    super.initState();
    // Before 1.2.0 the gateway ran on an admin's sign-in; that session is
    // not used any more, so it is ended rather than left on the phone.
    if (widget.db.auth.currentSession != null) unawaited(widget.db.auth.signOut().catchError((_) {}));
  }

  @override
  void dispose() {
    if (widget.engine == null) _engine.dispose();
    super.dispose();
  }

  Future<String?> _pair(String code) async {
    final error = await pairGateway(widget.db, widget.settings, code, appVersion: gatewayVersion);
    if (error == null && mounted) setState(() {});
    return error;
  }

  Future<void> _unpair() async {
    widget.settings.wantOnline = false;
    await _engine.stop();
    widget.settings.gatewayKey = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GET.ride Gateway',
      debugShowCheckedModeBanner: false,
      theme: gatewayTheme(Brightness.light),
      darkTheme: gatewayTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: widget.settings.paired
          ? HomeScreen(
              engine: _engine,
              settings: widget.settings,
              platform: _platform,
              permissions: _permissions,
              account: 'Paired gateway${widget.settings.label == null ? '' : ' · ${widget.settings.label}'}',
              onSignOut: _unpair,
            )
          : PairScreen(pair: _pair),
    );
  }
}
