import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers.dart';
import '../../widgets/common.dart';

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final email = _email.text.trim();
    if (email.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      showInfo(context, 'Enter a valid email address.');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(accountRepositoryProvider).updateProfile(
            name: _name.text.trim(),
            email: email.isEmpty ? null : email,
          );
      ref.invalidate(profileProvider);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(profileProvider).value;
    if (!_loaded && p != null) {
      _name.text = p.name ?? '';
      _email.text = p.email ?? '';
      _loaded = true;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: ListView(children: [
        ResponsiveCenter(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email (optional)'),
            ),
            const SizedBox(height: 16),
            TextField(
              enabled: false,
              controller: TextEditingController(text: p?.phone ?? ''),
              decoration: const InputDecoration(labelText: 'Mobile number'),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          ]),
        ),
      ]),
    );
  }
}
