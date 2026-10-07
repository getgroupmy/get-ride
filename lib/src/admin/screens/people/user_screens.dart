import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../widgets/busy.dart';
import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../admin_providers.dart';
import '../../widgets/admin_widgets.dart';
import 'people_data.dart';
import 'people_logic.dart';
import 'people_widgets.dart';
import '../../../widgets/in_app_page.dart';

void _leave(BuildContext context) => context.canPop() ? context.pop(true) : context.go('/admin/users');

// ---- Edit user -------------------------------------------------------------

final _profileProvider = FutureProvider.autoDispose.family<Map<String, dynamic>?, String>(
    (ref, id) => ref.watch(peopleRepositoryProvider).profile(id));

/// `admin-user-edit`: profile details, images, status and documents flag.
class UserEditScreen extends ConsumerWidget {
  const UserEditScreen({super.key, required this.id});
  final String id;
  static const page = 'admin-user-edit';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(_profileProvider(id));
    return pagedAsync(
      title: 'Loading…',
      page: page,
      value: value,
      onRetry: () => ref.invalidate(_profileProvider(id)),
      data: (row) => row == null
          ? AdminPage(
              title: 'User not found',
              page: page,
              body: EmptyState(icon: Icons.person_off_outlined, title: "We couldn't find a user with ID $id."),
            )
          : _UserEditForm(row: row),
    );
  }
}

class _UserEditForm extends ConsumerStatefulWidget {
  const _UserEditForm({required this.row});
  final Map<String, dynamic> row;

  @override
  ConsumerState<_UserEditForm> createState() => _UserEditFormState();
}

class _UserEditFormState extends ConsumerState<_UserEditForm> {
  Map<String, dynamic> get r => widget.row;
  String _s(String k) => '${r[k] ?? ''}';

  late final _name = TextEditingController(text: _s('name'));
  late final _phone = TextEditingController(text: _s('phone'));
  late final _email = TextEditingController(text: _s('email') == '-' ? '' : _s('email'));
  late final _ic = TextEditingController(text: _s('ic'));
  late final _address = TextEditingController(text: _s('address'));
  late final _nationality = TextEditingController(text: _s('nationality'));
  late final _birth = TextEditingController(text: _s('birth_date'));
  late final _referral = TextEditingController(text: _s('referral_code'));
  late String? _gender = r['gender'] as String?;
  late String _status = editableUserStatus(r);
  late bool _docsOk = r['documents_ok'] == true;
  PickedPeopleFile? _profileFile, _idFile;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _ic, _address, _nationality, _birth, _referral]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final err = validateUserForm(name: _name.text, phone: _phone.text);
    if (err != null) return showError(context, err);
    if (_birth.text.trim().isNotEmpty && !isValidIsoDate(_birth.text)) {
      return showError(context, 'Birth date must be YYYY-MM-DD.');
    }
    setState(() => _saving = true);
    final repo = ref.read(peopleRepositoryProvider);
    final ok = await runAdminAction(context, () async {
      final country = _nationality.text.trim();
      var profileImage = _s('profile_image');
      var idImage = _s('id_image');
      if (_profileFile != null) {
        profileImage = await repo.upload(
          'avatars',
          avatarPath(country: country, phone: _phone.text.trim(), name: _name.text, ext: guessExt(_profileFile!.name)),
          _profileFile!,
        );
      }
      if (_idFile != null) {
        idImage = await repo.upload(
          'ID_Image',
          idImagePath(country: country, phone: _phone.text.trim(), idNumber: _ic.text.trim(), ext: guessExt(_idFile!.name)),
          _idFile!,
        );
      }
      await repo.updateProfile(
        r['id'] as String,
        userProfilePatch(
          name: _name.text,
          phone: _phone.text,
          email: _email.text,
          ic: _ic.text,
          address: _address.text,
          nationality: _nationality.text,
          birthDate: _birth.text,
          referralCode: _referral.text,
          gender: _gender,
          profileImage: profileImage,
          idImage: idImage,
          status: _status,
          documentsOk: _docsOk,
        ),
      );
    }, success: 'User updated successfully.');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) _leave(context);
  }

  Future<void> _delete() async {
    final name = _s('name').isEmpty ? 'this user' : _s('name');
    if (!await confirm(context, 'Delete user', 'Remove $name?', ok: 'Delete')) return;
    if (!mounted) return;
    final ok = await runAdminAction(context, () => ref.read(peopleRepositoryProvider).deleteProfile(r['id'] as String),
        success: 'User deleted');
    if (ok && mounted) _leave(context);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(UserEditScreen.page)) == AccessLevel.edit;
    final t = Theme.of(context);
    return AdminPage(
      title: 'Edit User',
      page: UserEditScreen.page,
      actions: [
        if (canEdit) BusyIconButton(tooltip: 'Delete user', icon: const Icon(Icons.delete_outline), onPressed: _delete),
      ],
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: ResponsiveCenter(
          maxWidth: 820,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${r['display_id'] ?? r['id']}', style: t.textTheme.bodySmall),
            const SectionTitle('Profile Image'),
            Align(
              alignment: Alignment.centerLeft,
              child: ImageSlot(
                label: 'Photo',
                url: (r['profile_image'] ?? r['avatar_url']) as String?,
                pending: _profileFile,
                width: 140,
                enabled: canEdit,
                onPick: () async {
                  final f = await pickPeopleFile();
                  if (f != null) setState(() => _profileFile = f);
                },
              ),
            ),
            const SectionTitle('Personal'),
            FormColumns(children: [
              PeopleField(controller: _name, label: 'Full name', hint: 'Jane Doe', icon: Icons.person_outline, enabled: canEdit),
              PeopleField(
                  controller: _phone,
                  label: 'Phone number',
                  hint: '+60 12-345 6789',
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  enabled: canEdit),
              PeopleField(
                  controller: _email,
                  label: 'Email',
                  hint: 'user@example.com',
                  icon: Icons.mail_outline,
                  keyboardType: TextInputType.emailAddress,
                  capitalization: TextCapitalization.none,
                  enabled: canEdit),
              PeopleField(controller: _ic, label: 'IC / Passport', hint: '990101-14-5678', icon: Icons.badge_outlined, enabled: canEdit),
            ]),
            ImageSlot(
              label: 'ID / Passport image',
              url: r['id_image'] as String?,
              pending: _idFile,
              enabled: canEdit,
              height: 180,
              onPick: () async {
                final f = await pickPeopleFile();
                if (f != null) setState(() => _idFile = f);
              },
            ),
            const SizedBox(height: 12),
            FormColumns(children: [
              PeopleField(controller: _nationality, label: 'Nationality', hint: 'Malaysian', icon: Icons.public, enabled: canEdit),
              PeopleField(
                  controller: _birth,
                  label: 'Birth date',
                  hint: 'YYYY-MM-DD',
                  icon: Icons.calendar_today_outlined,
                  keyboardType: TextInputType.datetime,
                  enabled: canEdit),
            ]),
            Text('Gender', style: t.textTheme.labelLarge),
            const SizedBox(height: 6),
            ChoiceChips(options: genders, value: _gender, enabled: canEdit, onChanged: (g) => setState(() => _gender = g)),
            const SizedBox(height: 16),
            PeopleField(
                controller: _address,
                label: 'Home address',
                hint: 'Jalan Tun Razak, Kuala Lumpur',
                icon: Icons.place_outlined,
                enabled: canEdit),
            PeopleField(
                controller: _referral,
                label: 'Referral code (optional)',
                hint: 'FRIEND123',
                icon: Icons.card_giftcard_outlined,
                capitalization: TextCapitalization.none,
                enabled: canEdit),
            const SectionTitle('Account Status'),
            ChoiceChips(
                options: userEditStatuses, value: _status, enabled: canEdit, onChanged: (s) => setState(() => _status = s)),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mark documents as reviewed and OK'),
              value: _docsOk,
              onChanged: canEdit ? (v) => setState(() => _docsOk = v ?? false) : null,
            ),
            const SizedBox(height: 16),
            if (canEdit)
              BusyButton.filled(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                child: Text(_saving ? 'Saving…' : 'Save Changes'),
              ),
            const SizedBox(height: 32),
          ]),
        ),
      ),
    );
  }
}

// ---- User ID documents -----------------------------------------------------

final _idDocsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
    (ref, tab) => ref.watch(peopleRepositoryProvider).idDocuments(tab));

/// `admin-documents-users`: review the ID images users uploaded.
class UserIdDocumentsScreen extends ConsumerStatefulWidget {
  const UserIdDocumentsScreen({super.key});
  static const page = 'admin-documents-users';

  @override
  ConsumerState<UserIdDocumentsScreen> createState() => _UserIdDocumentsScreenState();
}

class _UserIdDocumentsScreenState extends ConsumerState<UserIdDocumentsScreen> {
  String _tab = 'Pending';

  static Color _color(String s) => switch (s) {
        'Verified' => Colors.green,
        'Failed' => Colors.red,
        'Expired' => Colors.grey,
        _ => Colors.orange,
      };

  Widget _thumb(String? url) {
    if (url == null || isPdfUri(url) || !url.startsWith('http')) {
      return CircleAvatar(child: Icon(isPdfUri(url) ? Icons.picture_as_pdf_outlined : Icons.badge_outlined));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(url, width: 56, height: 40, fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined)),
    );
  }

  void _open(Map<String, dynamic> row) {
    showAdminSheet<void>(
      context,
      title: '${row['name'] ?? row['phone'] ?? 'User'}',
      builder: (ctx) => _IdReviewSheet(
        row: row,
        onChanged: () => ref.invalidate(_idDocsProvider(_tab)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(_idDocsProvider(_tab));
    final counts = idStatusCounts(value.value ?? const []);
    return AdminPage(
      title: 'User ID Documents',
      page: UserIdDocumentsScreen.page,
      actions: [
        IconButton(
            tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(_idDocsProvider(_tab))),
      ],
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${counts['Pending']} pending • ${counts['Verified']} verified',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final t in idStatusTabs)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(label: Text(t), selected: _tab == t, onSelected: (_) => setState(() => _tab = t)),
                  ),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: AsyncView(
            value: value,
            onRetry: () => ref.invalidate(_idDocsProvider(_tab)),
            data: (rows) => rows.isEmpty
                ? const EmptyState(icon: Icons.badge_outlined, title: 'No ID documents here')
                : RefreshIndicator(
                    onRefresh: () => ref.refresh(_idDocsProvider(_tab).future),
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final row = rows[i];
                        final s = idDisplayStatus(row);
                        final id = '${row['id']}';
                        return ListTile(
                          leading: _thumb(row['id_image'] as String?),
                          title: Text('${row['name'] ?? row['phone'] ?? row['email'] ?? id.substring(0, 8)}'),
                          subtitle: Text([
                            if (row['ic'] != null) 'IC ${row['ic']}' else '${row['phone'] ?? ''}',
                            'Updated ${dateText(row['updated_at']).split(' ').first}',
                          ].join('\n')),
                          isThreeLine: true,
                          trailing: Chip(
                            label: Text(s),
                            labelStyle: TextStyle(color: _color(s), fontSize: 12),
                            visualDensity: VisualDensity.compact,
                          ),
                          onTap: () => _open(row),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ]),
    );
  }
}

class _IdReviewSheet extends ConsumerStatefulWidget {
  const _IdReviewSheet({required this.row, required this.onChanged});
  final Map<String, dynamic> row;
  final VoidCallback onChanged;

  @override
  ConsumerState<_IdReviewSheet> createState() => _IdReviewSheetState();
}

class _IdReviewSheetState extends ConsumerState<_IdReviewSheet> {
  late Map<String, dynamic> _row = widget.row;
  final _notes = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  String get _id => _row['id'] as String;

  Future<void> _update(Map<String, dynamic> patch, String success, {bool close = false}) async {
    setState(() => _busy = true);
    Map<String, dynamic>? updated;
    final ok = await runAdminAction(context, () async {
      updated = await ref.read(peopleRepositoryProvider).updateProfile(_id, patch);
    }, success: success);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (updated != null) _row = updated!;
    });
    if (ok) {
      widget.onChanged();
      if (close) Navigator.pop(context);
    }
  }

  Future<void> _decide(String decision) async {
    final err = validateIdDecision(decision, _notes.text);
    if (err != null) return showError(context, err);
    await _update({'id_verified': decision}, decision == 'Verified' ? 'ID verified' : 'ID rejected', close: true);
  }

  Future<void> _removeImage() async {
    if (!await confirm(context, 'Remove ID image?', 'This clears the uploaded ID file from the user record.',
        ok: 'Remove')) {
      return;
    }
    await _update({'id_image': null, 'id_verified': null}, 'ID image removed');
  }

  Future<void> _edit() async {
    final c = {
      for (final k in ['name', 'phone', 'email', 'ic', 'nationality', 'id_expiry_date'])
        k: TextEditingController(text: '${_row[k] ?? ''}'),
    };
    var docsOk = _row['documents_ok'] == true;
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Edit user'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                PeopleField(controller: c['name']!, label: 'Name'),
                PeopleField(controller: c['phone']!, label: 'Phone', keyboardType: TextInputType.phone),
                PeopleField(
                    controller: c['email']!,
                    label: 'Email',
                    keyboardType: TextInputType.emailAddress,
                    capitalization: TextCapitalization.none),
                PeopleField(controller: c['ic']!, label: 'IC'),
                PeopleField(controller: c['nationality']!, label: 'Nationality'),
                PeopleField(controller: c['id_expiry_date']!, label: 'ID expiry', hint: 'YYYY-MM-DD'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Documents OK'),
                  value: docsOk,
                  onChanged: (v) => setState(() => docsOk = v),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    final expiry = c['id_expiry_date']!.text;
    final patch = idProfilePatch(
      name: c['name']!.text,
      phone: c['phone']!.text,
      email: c['email']!.text,
      ic: c['ic']!.text,
      nationality: c['nationality']!.text,
      documentsOk: docsOk,
      idExpiry: expiry,
    );
    for (final x in c.values) {
      x.dispose();
    }
    if (save != true || !mounted) return;
    if (expiry.trim().isNotEmpty && !isValidIsoDate(expiry)) return showError(context, 'ID expiry must be YYYY-MM-DD.');
    await _update(patch, 'Saved');
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(pageAccessProvider(UserIdDocumentsScreen.page)) == AccessLevel.edit;
    final img = _row['id_image'] as String?;
    final status = idDisplayStatus(_row);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('ID Verification • $status', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 12),
      if (img == null)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No ID image uploaded')))
      else
        InkWell(
          onTap: img.startsWith('http') ? () => openInApp(context, img) : null,
          child: isPdfUri(img) || !img.startsWith('http')
              ? const SizedBox(height: 120, child: Center(child: Icon(Icons.picture_as_pdf_outlined, size: 48)))
              : ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(img, height: 220, fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined)),
                ),
        ),
      if (img != null && canEdit)
        Align(
          alignment: Alignment.centerLeft,
          child: BusyButton.text(
            onPressed: _busy ? null : _removeImage,
            icon: const Icon(Icons.delete_outline),
            child: const Text('Remove ID image'),
          ),
        ),
      const SizedBox(height: 8),
      DetailTable({
        'Name': _row['name'] ?? '—',
        'Phone': _row['phone'] ?? '—',
        'Email': _row['email'] ?? '—',
        'IC': _row['ic'] ?? '—',
        'Nationality': _row['nationality'] ?? '—',
        'ID Expiry': _row['id_expiry_date'] ?? '—',
        'Documents OK': _row['documents_ok'] == true ? 'Yes' : 'No',
      }),
      if (canEdit) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: BusyButton.text(
              onPressed: _busy ? null : _edit, icon: const Icon(Icons.edit_outlined), child: const Text('Edit user details')),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _notes,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Reason / notes (required when rejecting)'),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: BusyButton.outlined(
              onPressed: _busy ? null : () => _decide('Failed'),
              icon: const Icon(Icons.cancel_outlined),
              child: const Text('Reject'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: BusyButton.filled(
              onPressed: _busy ? null : () => _decide('Verified'),
              icon: const Icon(Icons.check_circle_outline),
              child: const Text('Verify'),
            ),
          ),
        ]),
      ],
    ]);
  }
}
