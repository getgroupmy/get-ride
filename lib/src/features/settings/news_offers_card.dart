// Settings › Notifications › News and offers (migration 0333): whether
// Admin › Push Notification's broadcasts (announcements and promotions)
// reach this account. Trip, safety, payment and account messages always do.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../widgets/common.dart';

/// The account's switch: profiles.news_offers, off until chosen (opt-in).
bool newsOffersOn(Map<String, dynamic>? profile) => profile?['news_offers'] == true;

class NewsOffersCard extends ConsumerStatefulWidget {
  const NewsOffersCard({super.key, this.save});

  /// Saves the switch (set_news_offers); a stand-in in tests.
  final Future<void> Function(bool on)? save;

  @override
  ConsumerState<NewsOffersCard> createState() => _NewsOffersCardState();
}

class _NewsOffersCardState extends ConsumerState<NewsOffersCard> {
  bool? _on;
  bool _saving = false;

  Future<void> _set(bool on) async {
    final before = _on;
    setState(() {
      _on = on;
      _saving = true;
    });
    try {
      await (widget.save ?? (v) => ref.read(supabaseProvider).rpc('set_news_offers', params: {'p_on': v}))(on);
      ref.invalidate(profileProvider);
      if (mounted) showInfo(context, on ? 'News and offers turned on.' : 'News and offers turned off.');
    } catch (e) {
      if (mounted) {
        setState(() => _on = before);
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stored = newsOffersOn(ref.watch(profileProvider).value?.raw);
    final on = _on ?? stored;
    return Card(
      key: const ValueKey('settings-notifications'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('Notifications', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          ),
          SwitchListTile(
            key: const ValueKey('news-offers-switch'),
            value: on,
            onChanged: _saving ? null : _set,
            secondary: const Icon(Icons.campaign_outlined),
            title: const Text('News and offers'),
            subtitle: const Text(
              'Announcements and promotions from GET.ride. Trip, safety, payment and account messages always come.',
            ),
          ),
        ],
      ),
    );
  }
}
