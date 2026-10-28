// Account › Business › Apply (migration 0313): the company's SSM document,
// read as the partner company step reads one (a photo, or a PDF's first
// page; on the phone, then the cloud reader), then its details checked by
// the applicant. get.ride approves it in Admin › People › Business accounts;
// the applicant is its first Admin.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_accounts.dart';
import '../../core/document_text.dart' show CompanyRead, readCompanyText;
import '../../data/business_repository.dart';
import '../../data/document_text_reader.dart';
import '../../widgets/common.dart';
import '../../widgets/search_select.dart';
import '../partner/registration_steps.dart' show pickRegistrationDocument;

class BusinessApplyScreen extends ConsumerStatefulWidget {
  const BusinessApplyScreen({super.key});

  @override
  ConsumerState<BusinessApplyScreen> createState() => _BusinessApplyScreenState();
}

class _BusinessApplyScreenState extends ConsumerState<BusinessApplyScreen> {
  final _name = TextEditingController();
  final _reg = TextEditingController();
  final _type = TextEditingController();
  final _address = TextEditingController();
  final _country = TextEditingController(text: 'Malaysia');
  final _stateText = TextEditingController();
  final _city = TextEditingController();
  String _state = '';
  String? _documentUrl;
  bool _reading = false;
  bool _busy = false;
  bool? _read;

  @override
  void dispose() {
    for (final c in [_name, _reg, _type, _address, _country, _stateText, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _malaysia => _country.text.trim().toLowerCase() == 'malaysia';
  String get _stateValue => _malaysia ? _state : _stateText.text.trim();

  Future<void> _upload({bool pdf = false}) async {
    final file = await pickRegistrationDocument(context, ref, pdf: pdf);
    if (file == null || !mounted) return;
    setState(() => _reading = true);
    try {
      final url = await ref.read(businessRepositoryProvider).uploadDocument(file.bytes, file.name);
      CompanyRead r = const CompanyRead();
      try {
        final text = await ref.read(documentTextReaderProvider)(file.bytes, fileUrl: url);
        if (text != null) r = readCompanyText(text);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _documentUrl = url;
        _read = !r.isEmpty;
        if (r.name != null) _name.text = r.name!;
        if (r.regNo != null) _reg.text = r.regNo!;
        if (r.type != null) _type.text = r.type!;
        if (r.address != null) {
          _address.text = r.address!;
          final up = r.address!.toUpperCase();
          for (final s in malaysiaStates) {
            if (up.contains(s.toUpperCase())) _state = s;
          }
        }
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _submit() async {
    if (_name.text.trim().length < 2 || _reg.text.trim().length < 3) {
      return showInfo(context, 'Enter the company name and its SSM number.');
    }
    if (_stateValue.isEmpty) return showInfo(context, 'Pick the state the company is registered in.');
    final doc = _documentUrl;
    if (doc == null) return showInfo(context, "Upload the company's SSM document.");
    setState(() => _busy = true);
    try {
      await ref.read(businessRepositoryProvider).apply(
        name: _name.text.trim(),
        regNo: _reg.text.trim(),
        companyType: _type.text.trim().isEmpty ? null : _type.text.trim(),
        address: _address.text.trim().isEmpty ? null : _address.text.trim(),
        country: _country.text.trim().isEmpty ? 'Malaysia' : _country.text.trim(),
        state: _stateValue,
        city: _city.text.trim(),
        documentUrl: doc,
      );
      ref.invalidate(myBusinessAccountsProvider);
      if (!mounted) return;
      await showNotice(
        context,
        title: 'Application sent',
        message: "get.ride checks the company's documents and tells you when the account is ready. You are its Admin.",
      );
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, String key, {int maxLines = 1, bool caps = true}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: ValueKey(key),
      controller: c,
      enabled: !_busy,
      maxLines: maxLines,
      textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.words,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final busy = _busy || _reading;
    return Scaffold(
      appBar: AppBar(title: const Text('Apply for a business account')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ResponsiveCenter(
          maxWidth: 640,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Company registration', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Upload the SSM certificate or company profile (Form 9, Section 17, or an e-Info printout). '
              'We read the company details from it; check them below.',
              style: t.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                key: const ValueKey('business-doc-photo'),
                leading: Icon(_documentUrl == null ? Icons.upload_file : Icons.check_circle,
                    color: _documentUrl == null ? null : t.colorScheme.primary),
                title: Text(_documentUrl == null ? 'Photo of the document' : 'Document uploaded'),
                subtitle: _reading ? const LinearProgressIndicator() : null,
                trailing: Text(_documentUrl == null ? '' : 'Replace'),
                onTap: busy ? null : _upload,
              ),
            ),
            Card(
              child: ListTile(
                key: const ValueKey('business-doc-pdf'),
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Or upload the PDF'),
                onTap: busy ? null : () => _upload(pdf: true),
              ),
            ),
            if (_read != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _read! ? 'Read from your document. Check the details.' : "We couldn't read the document. Type the details as they are on it.",
                  key: const ValueKey('business-read'),
                ),
              ),
            const SizedBox(height: 12),
            _field(_name, 'Company name', 'business-name'),
            _field(_reg, 'Registration no. (SSM)', 'business-reg'),
            _field(_type, 'Type (optional)', 'business-type', caps: false),
            _field(_address, 'Registered address', 'business-address', maxLines: 3),
            _field(_country, 'Country', 'business-country', caps: false),
            if (_malaysia)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SearchableDropdownFormField<String>(
                  key: ValueKey('business-state-$_state'),
                  initialValue: _state.isEmpty ? null : _state,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'State', border: OutlineInputBorder()),
                  items: [for (final s in malaysiaStates) DropdownMenuItem(value: s, child: Text(s))],
                  onChanged: busy ? null : (v) => setState(() => _state = v ?? ''),
                ),
              )
            else
              _field(_stateText, 'State or province', 'business-state-text', caps: false),
            _field(_city, 'City (optional)', 'business-city', caps: false),
            Text(
              "The company's state sets its starting credit limit and terms. You become its Admin and invite the others by phone.",
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('business-apply-send'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: busy ? null : _submit,
              child: const Text('Send application'),
            ),
          ]),
        ),
      ]),
    );
  }
}
