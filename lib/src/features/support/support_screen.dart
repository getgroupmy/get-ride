import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/side_menu_host.dart';

final ticketsProvider = FutureProvider.autoDispose<List<SupportTicket>>(
  (ref) => ref.watch(accountRepositoryProvider).tickets(),
);

class SupportScreen extends ConsumerWidget {
  const SupportScreen({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    try {
      final ticket = await ref.read(accountRepositoryProvider).openTicket('Support request');
      ref.invalidate(ticketsProvider);
      if (context.mounted) context.go('/account/support/${ticket.id}');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(leading: sideMenuLeading(context), title: const Text('Help & support')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(context, ref),
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('Chat with us'),
      ),
      body: AsyncView(
        value: ref.watch(ticketsProvider),
        onRetry: () => ref.invalidate(ticketsProvider),
        data: (tickets) => tickets.isEmpty
            ? const EmptyState(
                icon: Icons.support_agent,
                title: 'How can we help?',
                message: 'Start a chat and our support team will reply here.',
              )
            : ListView(children: [
                ResponsiveCenter(
                  maxWidth: 760,
                  child: Column(children: [
                    for (final tk in tickets)
                      Card(
                        child: ListTile(
                          leading: Badge(
                            isLabelVisible: tk.unreadUser > 0,
                            label: Text('${tk.unreadUser}'),
                            child: const Icon(Icons.forum_outlined),
                          ),
                          title: Text('${tk.number != null ? '#${tk.number} · ' : ''}${tk.subject}'),
                          subtitle: Text(tk.lastMessage ?? 'No messages yet',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(formatTime(tk.lastMessageAt)),
                              Text(tk.status, style: Theme.of(context).textTheme.labelSmall),
                            ],
                          ),
                          onTap: () => context.go('/account/support/${tk.id}'),
                        ),
                      ),
                  ]),
                ),
              ]),
      ),
    );
  }
}
