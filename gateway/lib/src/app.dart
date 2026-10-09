// The app: signed out → sign in; signed in but not an admin → say so;
// an admin → the gateway.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend.dart';
import 'engine.dart';
import 'home_screen.dart';
import 'permissions.dart';
import 'settings.dart';
import 'sign_in_screen.dart';
import 'sms_platform.dart';

/// Kept with `version:` in pubspec.yaml (a test checks); the admin page
/// shows it beside the device.
const gatewayVersion = '1.0.0';

ThemeData gatewayTheme(Brightness b) => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2DABE2), brightness: b),
);

class GatewayApp extends StatefulWidget {
  const GatewayApp({super.key, required this.db, required this.settings, this.platform, this.permissions});

  final SupabaseClient db;
  final GatewaySettings settings;
  final SmsPlatform? platform;
  final GatewayPermissions? permissions;

  @override
  State<GatewayApp> createState() => _GatewayAppState();
}

class _GatewayAppState extends State<GatewayApp> {
  late final SmsPlatform _platform = widget.platform ?? MethodChannelSmsPlatform();
  late final GatewayPermissions _permissions = widget.permissions ?? PluginGatewayPermissions();
  late final GatewayEngine _engine = GatewayEngine(
    backend: SupabaseGatewayBackend(widget.db),
    platform: _platform,
    config: widget.settings.config,
    appVersion: gatewayVersion,
  );
  StreamSubscription<AuthState>? _authSub;
  Session? _session;

  /// Whether the signed-in account is an admin; null while checking.
  Future<bool>? _admin;

  @override
  void initState() {
    super.initState();
    _session = widget.db.auth.currentSession;
    if (_session != null) _admin = _checkAdmin();
    _authSub = widget.db.auth.onAuthStateChange.listen((s) {
      final signedIn = s.session != null;
      final wasSignedIn = _session != null;
      if (signedIn == wasSignedIn && s.session?.user.id == _session?.user.id) {
        _session = s.session;
        return;
      }
      if (!signedIn) unawaited(_engine.stop());
      setState(() {
        _session = s.session;
        _admin = signedIn ? _checkAdmin() : null;
      });
    });
  }

  Future<bool> _checkAdmin() async => await widget.db.rpc('caller_is_admin') == true;

  @override
  void dispose() {
    unawaited(_authSub?.cancel());
    _engine.dispose();
    super.dispose();
  }

  Future<void> _signOut() async {
    widget.settings.wantOnline = false;
    await _engine.stop();
    await widget.db.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GET.ride Gateway',
      debugShowCheckedModeBanner: false,
      theme: gatewayTheme(Brightness.light),
      darkTheme: gatewayTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: _home(),
    );
  }

  Widget _home() {
    final session = _session;
    if (session == null) return SignInScreen(auth: widget.db.auth);
    return FutureBuilder<bool>(
      future: _admin,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return _Notice(
            icon: Icons.cloud_off,
            title: 'Could not reach GET.ride',
            body: 'Check this phone\'s connection and try again.',
            action: 'Try again',
            onAction: () => setState(() => _admin = _checkAdmin()),
            onSignOut: _signOut,
          );
        }
        if (snap.data != true) {
          return _Notice(
            icon: Icons.admin_panel_settings_outlined,
            title: 'Not an admin account',
            body: 'Only a GET.ride admin can run a gateway. Sign out and sign in with an admin account.',
            onSignOut: _signOut,
          );
        }
        return HomeScreen(
          engine: _engine,
          settings: widget.settings,
          platform: _platform,
          permissions: _permissions,
          account: session.user.phone?.isNotEmpty == true ? '+${session.user.phone}' : (session.user.email ?? 'admin'),
          onSignOut: _signOut,
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.body,
    required this.onSignOut,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 56, color: t.colorScheme.primary),
                const SizedBox(height: 16),
                Text(title, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(body, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                if (action != null) ...[
                  FilledButton(onPressed: onAction, child: Text(action!)),
                  const SizedBox(height: 8),
                ],
                TextButton(onPressed: onSignOut, child: const Text('Sign out')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
