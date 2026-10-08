// Admin → Settings → App Release (Expo `admin-settings-app-release`).
//
// Starts an App Store / Google Play build of this app (published as
// com.taxxee.teksi) through the `ios-release` / `android-release` edge
// functions, which hold the GitHub token and dispatch
// .github/workflows/{ios,android}-release.yml in this repository. The
// console never sees a signing key or a token. The Expo admin has the same
// screen over the same functions.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../providers.dart';
import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../../widgets/in_app_page.dart';
import '../../../widgets/loading_skeleton.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';

const appReleasePage = 'admin-settings-app-release';

enum ReleasePlatform { ios, android }

class ReleaseDestination {
  const ReleaseDestination(this.value, this.label, this.detail);
  final String value;
  final String label;

  /// What happens after the upload, said plainly: no button skips review.
  final String detail;
}

const releaseDestinations = <ReleasePlatform, List<ReleaseDestination>>{
  ReleasePlatform.ios: [
    ReleaseDestination('testflight', 'TestFlight',
        'Reaches your TestFlight testers once Apple finishes processing, usually within minutes.'),
    ReleaseDestination('appstore', 'App Store',
        "Uploads a build ready to submit. You still submit it for review in App Store Connect, and Apple's review takes hours to days."),
  ],
  ReleasePlatform.android: [
    ReleaseDestination('internal', 'Internal testing', 'Reaches internal testers once Play has processed it.'),
    ReleaseDestination('alpha', 'Closed testing (alpha)',
        'Goes to the alpha track. Play reviews closed-testing releases before testers get them.'),
    ReleaseDestination('beta', 'Open testing (beta)', 'Goes to the beta track. Play reviews it before it is available.'),
    ReleaseDestination('production', 'Production',
        "Rolls out to everybody once Play's review approves it, which takes hours to days."),
  ],
};

String releaseFunction(ReleasePlatform p) => p == ReleasePlatform.ios ? 'ios-release' : 'android-release';
String releaseInput(ReleasePlatform p) => p == ReleasePlatform.ios ? 'lane' : 'track';

class ReleaseRun {
  const ReleaseRun({
    required this.id,
    required this.number,
    required this.status,
    this.conclusion,
    this.startedAt,
    this.url = '',
  });

  factory ReleaseRun.fromJson(Map<String, dynamic> j) => ReleaseRun(
        id: (j['id'] as num?)?.toInt() ?? 0,
        number: (j['number'] as num?)?.toInt() ?? 0,
        status: '${j['status'] ?? 'unknown'}',
        conclusion: j['conclusion'] as String?,
        startedAt: DateTime.tryParse('${j['startedAt'] ?? ''}'),
        url: '${j['url'] ?? ''}',
      );

  final int id;
  final int number;
  final String status;
  final String? conclusion;
  final DateTime? startedAt;
  final String url;
}

enum RunTone { success, danger, warning, neutral }

/// A run as one word plus a tone (mirrors `describeRun` in storeReleaseStore.ts).
({String label, RunTone tone}) describeRun(String status, String? conclusion) {
  if (status != 'completed') {
    return (label: status == 'queued' ? 'Queued' : 'Building', tone: RunTone.warning);
  }
  switch (conclusion) {
    case 'success':
      // A run that stopped at "not set up yet" also concludes success; the
      // run page says which, so do not claim it uploaded.
      return (label: 'Finished', tone: RunTone.success);
    case 'failure':
      return (label: 'Failed', tone: RunTone.danger);
    case 'cancelled':
      return (label: 'Cancelled', tone: RunTone.neutral);
    case null:
      return (label: 'Done', tone: RunTone.neutral);
    default:
      final words = conclusion.replaceAll('_', ' ');
      return (label: words[0].toUpperCase() + words.substring(1), tone: RunTone.neutral);
  }
}

enum ReleaseStateKind { ok, notConfigured, forbidden, error }

class ReleaseState {
  const ReleaseState(this.kind, {this.runs = const [], this.message = ''});
  final ReleaseStateKind kind;
  final List<ReleaseRun> runs;
  final String message;
}

/// A function's HTTP status and body as what the card shows. 503 is the
/// only "not set up yet" answer (plus 404, the function not deployed);
/// a 403 is a person without access and a 502 is GitHub.
ReleaseState releaseStateFrom(int status, Object? body) {
  final map = body is Map ? body : const {};
  final message = map['error'] is String ? map['error'] as String : '';
  if (status >= 200 && status < 300) {
    final runs = map['runs'];
    return ReleaseState(ReleaseStateKind.ok,
        runs: runs is List
            ? [for (final r in runs.whereType<Map>()) ReleaseRun.fromJson(Map<String, dynamic>.from(r))]
            : const []);
  }
  if (status == 503) {
    return ReleaseState(ReleaseStateKind.notConfigured,
        message: message.isNotEmpty ? message : 'Store releases are not set up yet.');
  }
  if (status == 404) {
    return const ReleaseState(ReleaseStateKind.notConfigured,
        message: "The release functions aren't deployed to Supabase yet.");
  }
  if (status == 401 || status == 403) {
    return ReleaseState(ReleaseStateKind.forbidden,
        message: message.isNotEmpty ? message : "You don't have access to store releases.");
  }
  return ReleaseState(ReleaseStateKind.error,
      message: message.isNotEmpty ? message : 'The release function answered $status.');
}

class AppReleaseStore {
  AppReleaseStore(this._db);
  final SupabaseClient _db;

  Future<(int, Object?)> _invoke(ReleasePlatform p, Map<String, dynamic> body) async {
    try {
      final res = await _db.functions.invoke(releaseFunction(p), body: body);
      return (res.status, res.data);
    } on FunctionException catch (e) {
      return (e.status, e.details);
    }
  }

  Future<ReleaseState> runs(ReleasePlatform p) async {
    try {
      final (status, body) = await _invoke(p, const {});
      return releaseStateFrom(status, body);
    } catch (e) {
      return ReleaseState(ReleaseStateKind.error, message: '$e');
    }
  }

  /// Null on success, otherwise what went wrong.
  Future<String?> start(ReleasePlatform p, String destination, String notes) async {
    final (status, body) =
        await _invoke(p, {'action': 'release', releaseInput(p): destination, 'notes': notes.trim()});
    if (status >= 200 && status < 300 && body is Map && body['started'] == true) return null;
    final state = releaseStateFrom(status, body);
    return state.kind == ReleaseStateKind.ok ? 'The build did not start.' : state.message;
  }
}

final appReleaseStoreProvider = Provider((ref) => AppReleaseStore(ref.watch(supabaseProvider)));

final releaseRunsProvider =
    FutureProvider.autoDispose.family<ReleaseState, ReleasePlatform>((ref, p) => ref.watch(appReleaseStoreProvider).runs(p));

class AdminAppReleaseScreen extends ConsumerWidget {
  const AdminAppReleaseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminPage(
      title: 'App Release',
      page: appReleasePage,
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ResponsiveCenter(
          maxWidth: 760,
          padding: EdgeInsets.zero,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'Each release builds this app from GitHub, signs it and uploads it as com.taxxee.teksi, '
              "replacing whatever was last published in that store. Uploading never skips Apple's or Google's review.",
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            const _ReleaseCard(ReleasePlatform.ios),
            const SizedBox(height: 16),
            const _ReleaseCard(ReleasePlatform.android),
          ]),
        ),
      ]),
    );
  }
}

class _ReleaseCard extends ConsumerStatefulWidget {
  const _ReleaseCard(this.platform);
  final ReleasePlatform platform;

  @override
  ConsumerState<_ReleaseCard> createState() => _ReleaseCardState();
}

class _ReleaseCardState extends ConsumerState<_ReleaseCard> {
  final _notes = TextEditingController();
  late String _destination = releaseDestinations[widget.platform]!.first.value;
  bool _starting = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  bool get _ios => widget.platform == ReleasePlatform.ios;

  Future<void> _start(ReleaseDestination chosen) async {
    final cost = _ios
        ? 'It runs on a macOS runner (about 25 minutes, billed at 10× a Linux runner).'
        : 'It runs on a Linux runner (about 8 minutes).';
    if (!await confirm(context, 'Release to ${chosen.label}?', '${chosen.detail}\n\n$cost', ok: 'Start build')) {
      return;
    }
    setState(() => _starting = true);
    final error = await ref.read(appReleaseStoreProvider).start(widget.platform, chosen.value, _notes.text);
    if (!mounted) return;
    setState(() => _starting = false);
    if (error != null) {
      showInfo(context, "Couldn't start the build: $error");
      return;
    }
    _notes.clear();
    showInfo(context, 'Build started. It appears below in a few seconds.');
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) ref.invalidate(releaseRunsProvider(widget.platform));
    });
  }

  Color _toneColor(RunTone tone, ColorScheme scheme) => switch (tone) {
        RunTone.success => Colors.green.shade700,
        RunTone.danger => scheme.error,
        RunTone.warning => Colors.orange.shade800,
        RunTone.neutral => scheme.onSurfaceVariant,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = ref.watch(pageAccessProvider(appReleasePage)) == AccessLevel.edit;
    final destinations = releaseDestinations[widget.platform]!;
    final chosen = destinations.firstWhere((d) => d.value == _destination, orElse: () => destinations.first);
    final runs = ref.watch(releaseRunsProvider(widget.platform));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(_ios ? Icons.phone_iphone : Icons.android),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_ios ? 'iOS — App Store' : 'Android — Google Play', style: theme.textTheme.titleMedium),
            ),
            IconButton(
              tooltip: 'Refresh builds',
              onPressed: () => ref.invalidate(releaseRunsProvider(widget.platform)),
              icon: const Icon(Icons.refresh),
            ),
          ]),
          const SizedBox(height: 8),
          runs.when(
            loading: () => const LoadingSkeleton(rows: 3),
            error: (e, _) => Text('$e', style: TextStyle(color: theme.colorScheme.error)),
            data: (state) {
              if (state.kind != ReleaseStateKind.ok) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(state.kind == ReleaseStateKind.error ? Icons.error_outline : Icons.info_outline),
                  title: Text(switch (state.kind) {
                    ReleaseStateKind.notConfigured => 'Not set up yet',
                    ReleaseStateKind.forbidden => 'No access',
                    _ => "Couldn't load builds",
                  }),
                  subtitle: Text(state.message),
                );
              }
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final d in destinations)
                    ChoiceChip(
                      label: Text(d.label),
                      selected: d.value == _destination,
                      onSelected: (_) => setState(() => _destination = d.value),
                    ),
                ]),
                const SizedBox(height: 8),
                Text(chosen.detail, style: theme.textTheme.bodySmall),
                const SizedBox(height: 12),
                TextField(
                  controller: _notes,
                  enabled: canEdit,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: 'What changed (optional)'),
                ),
                BusyButton.filled(
                  onPressed: canEdit && !_starting ? () => _start(chosen) : null,
                  icon: const Icon(Icons.rocket_launch_outlined),
                  child: Text('Release to ${chosen.label}'),
                ),
                const SizedBox(height: 16),
                Text('Recent builds', style: theme.textTheme.titleSmall),
                if (state.runs.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Nothing yet.'))
                else
                  for (final run in state.runs)
                    Builder(builder: (context) {
                      final d = describeRun(run.status, run.conclusion);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('#${run.number}'),
                        subtitle: Text(run.startedAt != null ? dateText(run.startedAt!.toIso8601String()) : '—'),
                        trailing: Text(d.label,
                            style: TextStyle(color: _toneColor(d.tone, theme.colorScheme), fontWeight: FontWeight.w700)),
                        onTap: run.url.isEmpty
                            ? null
                            : () => openInApp(context, run.url, title: 'Build #${run.number}'),
                      );
                    }),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}
