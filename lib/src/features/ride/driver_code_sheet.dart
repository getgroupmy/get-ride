// Asking for a driver by their code (migration 0198): the My Ride code typed
// in, or their GET.me QR scanned or pasted. Used to hand a scheduled ride to
// another driver and by a passenger choosing a driver for a booking.
import 'package:flutter/material.dart';

import '../my_ride/my_ride_screen.dart' show MyRideScanScreen;

/// The code, or null when closed. The server works out which kind it is.
Future<String?> askDriverCode(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _DriverCodeSheet(title: title, message: message, action: action),
);

class _DriverCodeSheet extends StatefulWidget {
  const _DriverCodeSheet({required this.title, required this.message, required this.action});

  final String title;
  final String message;
  final String action;

  @override
  State<_DriverCodeSheet> createState() => _DriverCodeSheetState();
}

class _DriverCodeSheetState extends State<_DriverCodeSheet> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _done([String? raw]) {
    final code = (raw ?? _code.text).trim();
    if (code.isEmpty) return;
    Navigator.pop(context, code);
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const MyRideScanScreen(), fullscreenDialog: true));
    if (raw != null && mounted) _done(raw);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          key: const ValueKey('driver-code-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(widget.message, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('driver-code-field'),
              controller: _code,
              autofocus: true,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: "Driver's code",
                helperText: 'Their My Ride code (8 characters), or their GET.me link',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: _done,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('driver-code-scan'),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan their QR'),
                  onPressed: _scan,
                ),
                FilledButton(
                  key: const ValueKey('driver-code-done'),
                  onPressed: _code.text.trim().isEmpty ? null : () => _done(),
                  child: Text(widget.action),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
