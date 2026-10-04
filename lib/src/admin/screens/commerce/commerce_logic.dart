/// Pure logic for the Payments & commerce admin screens, ported from the
/// Expo screens (payment type/gateway, EV order fee, finance options,
/// vehicle details and inventory). Value keys and JSON shapes match Expo so
/// both apps edit the same rows.
library;

import 'dart:convert';
import 'dart:math' as math;

String _s(Object? v) => v == null ? '' : '$v';

/// Every key whose value is a primitive matches the query (Expo list search).
bool valuesMatch(Map<String, dynamic> values, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return values.values.any((v) => _s(v).toLowerCase().contains(q));
}

/// `1,234` / `1,234.5` like JS `toLocaleString()` (en).
String groupedNumber(num? n) {
  final v = (n ?? 0).toDouble();
  final neg = v < 0;
  final abs = v.abs();
  final whole = abs.truncate();
  var frac = '';
  if (abs != whole) {
    frac = (abs - whole).toStringAsFixed(3).substring(1).replaceFirst(RegExp(r'0+$'), '');
    if (frac == '.') frac = '';
  }
  final s = whole.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${neg ? '-' : ''}$b$frac';
}

double toNum(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse(_s(v).trim()) ?? 0;
}

// ===========================================================================
// Payment gateways (settings_entries category `payment-gateway`)
// ===========================================================================

const paymentGatewayCategory = 'payment-gateway';
const paymentTypeCategory = 'payment-type';

class CredentialField {
  const CredentialField(this.key, this.label, {this.placeholder, this.secret = false, this.optional = false});
  final String key;
  final String label;
  final String? placeholder;
  final bool secret;
  final bool optional;
}

class GatewayProvider {
  const GatewayProvider(this.id, this.name, this.description, this.fields, {this.website});
  final String id;
  final String name;
  final String description;
  final String? website;
  final List<CredentialField> fields;

  List<CredentialField> get publicFields => fields.where((f) => !f.secret).toList();
  List<CredentialField> get secretFields => fields.where((f) => f.secret).toList();
}

const gatewayModes = ['Live', 'Sandbox'];

/// Provider catalogue, identical to Expo `GATEWAY_PROVIDERS`.
const gatewayProviders = <GatewayProvider>[
  GatewayProvider('stripe', 'Stripe', 'Cards, wallets and global payments', website: 'https://stripe.com', [
    CredentialField('publishableKey', 'Publishable Key', placeholder: 'pk_live_...'),
    CredentialField('secretKey', 'Secret Key', placeholder: 'sk_live_...', secret: true),
    CredentialField('webhookSecret', 'Webhook Signing Secret', placeholder: 'whsec_...', secret: true, optional: true),
    CredentialField('accountId', 'Account ID', placeholder: 'acct_...', optional: true),
  ]),
  GatewayProvider('fiuu', 'Fiuu (Razer Merchant Services)', 'Malaysian merchant payments (FPX, cards, e-wallets)',
      website: 'https://fiuu.com', [
    CredentialField('merchantId', 'Merchant ID', placeholder: 'Your merchant ID'),
    CredentialField('verifyKey', 'Verify Key', placeholder: 'Verify key', secret: true),
    CredentialField('secretKey', 'Secret Key', placeholder: 'Secret key', secret: true),
    CredentialField('callbackUrl', 'Callback URL', placeholder: 'https://...', optional: true),
  ]),
  GatewayProvider('adaptis', 'ADAPTIS (iPay88 + eGHL)', 'Unified gateway over iPay88 and eGHL',
      website: 'https://adaptis.my', [
    CredentialField('merchantCode', 'Merchant Code', placeholder: 'Merchant code'),
    CredentialField('merchantKey', 'Merchant Key', placeholder: 'Merchant key', secret: true),
    CredentialField('ipay88MerchantCode', 'iPay88 Merchant Code', placeholder: 'iPay88 merchant code', optional: true),
    CredentialField('eghlPaymentId', 'eGHL Payment ID', placeholder: 'eGHL payment ID', optional: true),
    CredentialField('eghlPassword', 'eGHL Password', placeholder: 'eGHL password', secret: true, optional: true),
  ]),
  GatewayProvider('senangpay', 'SenangPay', 'Malaysian card & FPX payments', website: 'https://senangpay.my', [
    CredentialField('merchantId', 'Merchant ID', placeholder: 'Merchant ID'),
    CredentialField('secretKey', 'Secret Key', placeholder: 'Secret key', secret: true),
  ]),
  GatewayProvider('billplz', 'Billplz', 'FPX, cards & e-wallets', website: 'https://billplz.com', [
    CredentialField('apiKey', 'API Secret Key', placeholder: 'Bearer key', secret: true),
    CredentialField('collectionId', 'Collection ID', placeholder: 'Collection ID'),
    CredentialField('xSignatureKey', 'X-Signature Key', placeholder: 'X-Signature key', secret: true, optional: true),
  ]),
  GatewayProvider('hitpay', 'HitPay', 'Cards, PayNow, GrabPay (SG/MY)', website: 'https://hit-pay.com', [
    CredentialField('apiKey', 'API Key', placeholder: 'API key', secret: true),
    CredentialField('salt', 'Salt', placeholder: 'Webhook salt', secret: true, optional: true),
  ]),
  GatewayProvider('paypal', 'PayPal', 'Global PayPal payments', website: 'https://developer.paypal.com', [
    CredentialField('clientId', 'Client ID', placeholder: 'PayPal client ID'),
    CredentialField('clientSecret', 'Client Secret', placeholder: 'PayPal secret', secret: true),
    CredentialField('webhookId', 'Webhook ID', placeholder: 'Webhook ID', optional: true),
  ]),
  GatewayProvider('airwallex', 'Airwallex', 'Global cards & APMs', website: 'https://www.airwallex.com', [
    CredentialField('clientId', 'Client ID', placeholder: 'Airwallex client ID'),
    CredentialField('apiKey', 'API Key', placeholder: 'API key', secret: true),
    CredentialField('webhookSecret', 'Webhook Secret', placeholder: 'Webhook secret', secret: true, optional: true),
  ]),
  GatewayProvider('payhalal', 'PayHalal', 'Shariah-compliant payment gateway', website: 'https://payhalal.my', [
    CredentialField('merchantId', 'Merchant ID', placeholder: 'Merchant ID'),
    CredentialField('appId', 'App ID', placeholder: 'App ID'),
    CredentialField('secretKey', 'Secret Key', placeholder: 'Secret key', secret: true),
  ]),
  GatewayProvider('toyyibpay', 'ToyyibPay', 'Low-fee MY payment gateway (FPX, cards)', website: 'https://toyyibpay.com', [
    CredentialField('userSecretKey', 'User Secret Key', placeholder: 'User secret key', secret: true),
    CredentialField('categoryCode', 'Category Code', placeholder: 'Category code'),
  ]),
  GatewayProvider('paydibs', 'Paydibs', 'Multi-channel payments (cards, FPX, e-wallets)',
      website: 'https://v3api-docs.paydibs.com', [
    CredentialField('merchantId', 'Merchant ID', placeholder: 'Merchant ID'),
    CredentialField('merchantPassword', 'Merchant Password', placeholder: 'Merchant password', secret: true),
    CredentialField('paymentUrl', 'Payment URL', placeholder: 'https://...'),
    CredentialField('apiVersion', 'API Version', placeholder: '3.8', optional: true),
  ]),
];

GatewayProvider? providerById(String? id) => gatewayProviders.where((p) => p.id == id).firstOrNull;

/// Every stored value key that holds a secret credential
/// (`<providerId>_<fieldKey>` for each secret field).
final Set<String> secretCredentialKeys = {
  for (final p in gatewayProviders)
    for (final f in p.secretFields) '${p.id}_${f.key}',
};

/// Secret keys actually present (non-empty) on a stored gateway entry.
List<String> storedSecretKeys(Map<String, dynamic> values) =>
    values.entries.where((e) => secretCredentialKeys.contains(e.key) && _s(e.value).isNotEmpty).map((e) => e.key).toList();

/// Copy of [values] without any secret credential keys.
Map<String, dynamic> stripSecrets(Map<String, dynamic> values) =>
    {for (final e in values.entries) if (!secretCredentialKeys.contains(e.key)) e.key: e.value};

class GatewayForm {
  GatewayForm({
    required this.providerId,
    this.accountName = '',
    this.mode = 'Live',
    this.active = true,
    this.isDefault = false,
    Map<String, String>? credentials,
  }) : credentials = credentials ?? {};

  /// Editor state from a stored entry (public credentials only).
  factory GatewayForm.fromValues(Map<String, dynamic> v) {
    final provider = providerById(_s(v['providerId']));
    return GatewayForm(
      providerId: _s(v['providerId']),
      accountName: _s(v['accountName']),
      mode: v['mode'] == 'Sandbox' ? 'Sandbox' : 'Live',
      active: v['active'] != false,
      isDefault: v['isDefault'] == true,
      credentials: {
        if (provider != null)
          for (final f in provider.publicFields) f.key: _s(v['${provider.id}_${f.key}']),
      },
    );
  }

  String providerId;
  String accountName;
  String mode;
  bool active;
  bool isDefault;
  final Map<String, String> credentials;
}

/// Validates and builds the values to write. Only the provider's
/// *non-secret* fields are collected; secret fields are never written from
/// this client (see the report on secret handling). [existing] values are
/// kept underneath, so editing never silently drops other keys.
({Map<String, dynamic>? values, String? error}) buildGatewayValues(
  GatewayForm form, {
  Map<String, dynamic>? existing,
}) {
  final provider = providerById(form.providerId);
  if (provider == null) return (values: null, error: 'Please select a payment gateway provider.');
  if (form.accountName.trim().isEmpty) {
    return (values: null, error: 'Please enter an account name to identify this configuration.');
  }
  for (final f in provider.publicFields) {
    if (!f.optional && (form.credentials[f.key] ?? '').trim().isEmpty) {
      return (values: null, error: 'Please fill in “${f.label}”.');
    }
  }
  return (
    values: {
      ...?existing,
      'providerId': provider.id,
      'providerName': provider.name,
      'accountName': form.accountName.trim(),
      'mode': form.mode,
      'active': form.active,
      'isDefault': form.isDefault,
      for (final f in provider.publicFields) '${provider.id}_${f.key}': (form.credentials[f.key] ?? '').trim(),
    },
    error: null,
  );
}

/// A gateway account as referenced by payment types, order fees and finance
/// options (`gatewayId`, `gatewayProviderId`, … on those entries).
class SelectedGateway {
  const SelectedGateway({
    required this.id,
    required this.providerId,
    required this.providerName,
    required this.accountName,
    required this.mode,
  });

  final String id;
  final String providerId;
  final String providerName;
  final String accountName;
  final String mode;

  String get label => '$providerName · $accountName${mode.isNotEmpty ? ' ($mode)' : ''}';

  /// Reads the `gateway*` reference stored on an entry; null when unset.
  static SelectedGateway? fromReference(Map<String, dynamic> v) {
    final id = _s(v['gatewayId']);
    if (id.isEmpty) return null;
    return SelectedGateway(
      id: id,
      providerId: _s(v['gatewayProviderId']),
      providerName: _s(v['gatewayProviderName']),
      accountName: _s(v['gatewayAccountName']),
      mode: v['gatewayMode'] == null ? 'Live' : _s(v['gatewayMode']),
    );
  }
}

/// The `gateway*` reference keys written by Expo (empty strings for none).
Map<String, dynamic> gatewayReference(SelectedGateway? g) => {
      'gatewayId': g?.id ?? '',
      'gatewayProviderId': g?.providerId ?? '',
      'gatewayProviderName': g?.providerName ?? '',
      'gatewayAccountName': g?.accountName ?? '',
      'gatewayMode': g?.mode ?? '',
    };

/// Active gateway accounts for the picker, sorted by provider then account.
List<SelectedGateway> pickableGateways(List<({String id, Map<String, dynamic> values})> entries) {
  final list = [
    for (final e in entries)
      if (e.values['active'] != false)
        SelectedGateway(
          id: e.id,
          providerId: _s(e.values['providerId']),
          providerName: _s(e.values['providerName']),
          accountName: _s(e.values['accountName']),
          mode: e.values['mode'] == null ? 'Live' : _s(e.values['mode']),
        ),
  ];
  list.sort((a, b) =>
      a.providerName == b.providerName ? a.accountName.compareTo(b.accountName) : a.providerName.compareTo(b.providerName));
  return list;
}

/// Active default gateway, else the first active one (Expo
/// `resolveDefaultGateway`).
({String id, Map<String, dynamic> values})? resolveDefaultGateway(
    List<({String id, Map<String, dynamic> values})> entries) {
  final active = entries.where((e) => e.values['active'] != false).toList();
  if (active.isEmpty) return null;
  return active.where((e) => e.values['isDefault'] == true).firstOrNull ?? active.first;
}

/// Payment type values (`settings_entries` category `payment-type`).
({Map<String, dynamic>? values, String? error}) buildPaymentTypeValues({
  required String name,
  required String code,
  required bool enabled,
  SelectedGateway? gateway,
  Map<String, dynamic>? existing,
}) {
  if (name.trim().isEmpty) return (values: null, error: 'Please fill in Name.');
  return (
    values: {
      ...?existing,
      'name': name.trim(),
      'code': code.trim(),
      'enabled': enabled,
      ...gatewayReference(gateway),
    },
    error: null,
  );
}

// ===========================================================================
// EV order fee (table ev_order_fee)
// ===========================================================================

const defaultOrderFeeCountry = 'Malaysia';
const defaultOrderFeeAmount = 3000;
const defaultOrderFeeCurrency = 'RM';

/// Seed row Expo writes when the table is empty.
const orderFeeSeed = {
  'country': defaultOrderFeeCountry,
  'currency': defaultOrderFeeCurrency,
  'amount': defaultOrderFeeAmount,
  'isDefault': true,
  'active': true,
};

/// Default first, then by country.
List<T> sortOrderFees<T>(List<T> entries, Map<String, dynamic> Function(T) valuesOf) {
  final list = [...entries];
  list.sort((a, b) {
    final va = valuesOf(a), vb = valuesOf(b);
    final ad = va['isDefault'] == true ? 0 : 1, bd = vb['isDefault'] == true ? 0 : 1;
    if (ad != bd) return ad - bd;
    return _s(va['country']).compareTo(_s(vb['country']));
  });
  return list;
}

({Map<String, dynamic>? values, String? error}) buildOrderFeeValues({
  required String country,
  required String currency,
  required String amount,
  required bool isDefault,
  required bool active,
  SelectedGateway? gateway,
  required List<({String id, Map<String, dynamic> values})> others,
  String? editingId,
  Map<String, dynamic>? existing,
}) {
  if (country.trim().isEmpty) return (values: null, error: 'Please select a Country.');
  final amt = double.tryParse(amount.trim());
  if (amt == null || !amt.isFinite || amt < 0) {
    return (values: null, error: 'Please enter a valid order fee amount.');
  }
  final dupe = others.any(
      (e) => e.id != editingId && _s(e.values['country']).trim().toLowerCase() == country.trim().toLowerCase());
  if (dupe) {
    return (
      values: null,
      error: 'An order fee for ${country.trim()} already exists. Edit the existing entry instead.',
    );
  }
  return (
    values: {
      ...?existing,
      'country': country.trim(),
      'currency': currency.trim().isEmpty ? defaultOrderFeeCurrency : currency.trim(),
      'amount': amt == amt.roundToDouble() ? amt.toInt() : amt,
      'isDefault': isDefault,
      'active': active,
      ...gatewayReference(gateway),
    },
    error: null,
  );
}

bool canDeleteOrderFee(Map<String, dynamic> values) => values['country'] != defaultOrderFeeCountry;

/// Currency for a country: an admin-saved country-level
/// `country-states-cities` entry's symbol/name first, then the built-in
/// world list (Expo used the `country-state-city` library's ISO code).
String resolveCurrencyForCountry(
  String name,
  List<Map<String, dynamic>> countryStatesCities,
  Map<String, String> worldCurrencies,
) {
  if (name.isEmpty) return '';
  String norm(Object? s) => _s(s).trim().toLowerCase();
  final saved = countryStatesCities.where((v) =>
      norm(v['country']) == norm(name) &&
      _s(v['state']).isEmpty &&
      _s(v['city']).isEmpty &&
      _s(v['suburb']).isEmpty);
  final first = saved.firstOrNull;
  final sym = _s(first?['currencySymbol']).trim();
  if (sym.isNotEmpty) return sym;
  final cname = _s(first?['currencyName']).trim();
  if (cname.isNotEmpty) return cname;
  return worldCurrencies[name] ?? '';
}

// ===========================================================================
// EV finance options (table ev_finance_options)
// ===========================================================================

const financeOptionTypes = ['Cash', 'Leasing', 'Hire Purchase', 'Rental'];
const financeTermUnits = ['Day', 'Month', 'Year'];
const financePaymentModes = ['Full Balance', 'Custom'];

/// Seeds Expo writes when the table is empty (with `isDefault: true`).
const financeOptionSeeds = <Map<String, dynamic>>[
  {'name': 'Full Cash', 'type': 'Cash', 'country': 'Malaysia', 'paymentMode': 'Full Balance', 'paymentAmount': '', 'rate': '', 'termValue': '', 'termUnit': 'Month', 'details': 'Pay total VSO in full to TEKSI account', 'active': true, 'displayPriority': 1, 'isDefault': true},
  {'name': 'Leasing 24 months', 'type': 'Leasing', 'country': 'Malaysia', 'paymentMode': 'Custom', 'paymentAmount': '850', 'rate': '', 'termValue': '24', 'termUnit': 'Month', 'details': '24-month flexible lease with end-of-term return option', 'active': true, 'displayPriority': 2, 'isDefault': true},
  {'name': 'Hire Purchase 60m', 'type': 'Hire Purchase', 'country': 'Malaysia', 'paymentMode': 'Custom', 'paymentAmount': '1200', 'rate': '2.85', 'termValue': '60', 'termUnit': 'Month', 'details': 'Partnered banks · 10% downpayment', 'active': true, 'displayPriority': 3, 'isDefault': true},
  {'name': 'Daily Rental', 'type': 'Rental', 'country': 'Malaysia', 'paymentMode': 'Custom', 'paymentAmount': '120', 'rate': '', 'termValue': '1', 'termUnit': 'Day', 'details': 'Pay-per-day rental for trial drivers', 'active': true, 'displayPriority': 4, 'isDefault': true},
];

double priorityOf(Map<String, dynamic> v) {
  final p = v['displayPriority'];
  if (p == null) return 9999;
  final n = p is num ? p.toDouble() : double.tryParse('$p');
  return n ?? double.nan;
}

/// Sorted by `displayPriority` (missing → 9999).
List<T> sortByPriority<T>(List<T> entries, Map<String, dynamic> Function(T) valuesOf) {
  final list = [...entries];
  list.sort((a, b) {
    final pa = priorityOf(valuesOf(a)), pb = priorityOf(valuesOf(b));
    if (pa.isNaN || pb.isNaN) return 0;
    return pa.compareTo(pb);
  });
  return list;
}

/// Ids whose `displayPriority` must change after moving [id] by [dir], with
/// the new 1-based priority (Expo `moveEntry`). Empty when the move is out of
/// range.
Map<String, int> reorderPriorities(List<({String id, Map<String, dynamic> values})> sorted, String id, int dir) {
  final ids = sorted.map((e) => e.id).toList();
  final from = ids.indexOf(id);
  if (from == -1) return const {};
  final to = from + dir;
  if (to < 0 || to >= ids.length) return const {};
  final moved = ids.removeAt(from);
  ids.insert(to, moved);
  final out = <String, int>{};
  for (var i = 0; i < ids.length; i++) {
    final e = sorted.firstWhere((x) => x.id == ids[i]);
    if (priorityOf(e.values) != i + 1) out[ids[i]] = i + 1;
  }
  return out;
}

double _parseOr0(String s) => s.trim().isEmpty ? 0 : (double.tryParse(s.trim()) ?? 0);

num _compact(double v) => v == v.roundToDouble() ? v.toInt() : v;

({Map<String, dynamic>? values, String? error}) buildFinanceOptionValues({
  required String name,
  required String type,
  required String country,
  required String paymentMode,
  required String paymentAmount,
  required String rate,
  required String termValue,
  required String termUnit,
  required String details,
  required bool active,
  required num displayPriority,
  SelectedGateway? gateway,
  Map<String, dynamic>? existing,
}) {
  if (name.trim().isEmpty) return (values: null, error: 'Please fill in Plan Name.');
  if (country.trim().isEmpty) return (values: null, error: 'Please select a Country.');
  if (paymentMode == 'Custom') {
    final n = double.tryParse(paymentAmount.trim());
    if (n == null || !n.isFinite || n <= 0) {
      return (values: null, error: 'Please enter a valid custom payment amount.');
    }
  }
  return (
    values: {
      ...?existing,
      'name': name.trim(),
      'type': type,
      'country': country.trim(),
      'paymentMode': paymentMode,
      'paymentAmount': paymentMode == 'Custom' ? _compact(_parseOr0(paymentAmount)) : 0,
      'rate': _compact(_parseOr0(rate)),
      'termValue': _compact(_parseOr0(termValue)),
      'termUnit': termUnit,
      'details': details.trim(),
      'active': active,
      'displayPriority': displayPriority,
      ...gatewayReference(gateway),
    },
    error: null,
  );
}

/// "Pay: 850 • Rate: 2.85% • Term: 24 Months" line.
String financeOptionMeta(Map<String, dynamic> v) {
  final pay = v['paymentMode'] == 'Custom' ? _s(v['paymentAmount']) : 'Full Balance';
  final rate = toNum(v['rate']) > 0 ? '${v['rate']}%' : '—';
  final tv = toNum(v['termValue']);
  final term = tv > 0 ? '${v['termValue']} ${_s(v['termUnit'])}${tv > 1 ? 's' : ''}' : '—';
  return 'Pay: $pay • Rate: $rate • Term: $term';
}

// ===========================================================================
// EV vehicle details (table ev_vehicle_details)
// ===========================================================================

/// Gallery slots per key.
const galleryLimits = {'exteriorImages': 4, 'interiorImages': 4, 'storageImages': 2};

/// Parses a JSON-string list of objects (colours, features, taxes) safely.
List<Map<String, dynamic>> parseItemList(Object? raw) {
  if (raw is! String || raw.isEmpty) return [];
  try {
    final v = jsonDecode(raw);
    if (v is! List) return [];
    return [for (final x in v) if (x is Map) Map<String, dynamic>.from(x)];
  } catch (_) {
    return [];
  }
}

final _rng = math.Random();

/// Item id like Expo's `uid()` (`i-xxxxxxx`).
String newItemId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return 'i-${List.generate(7, (_) => chars[_rng.nextInt(chars.length)]).join()}';
}

double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse(_s(v).trim());

num _priceOr0(Object? v) {
  final n = _num(v);
  return n == null || !n.isFinite ? 0 : _compact(n);
}

List<Map<String, dynamic>> normalizeColors(List<Map<String, dynamic>> items) => [
      for (final c in items)
        if (_s(c['name']).trim().isNotEmpty || _s(c['code']).trim().isNotEmpty)
          {'id': _s(c['id']), 'name': _s(c['name']).trim(), 'code': _s(c['code']).trim(), 'enabled': c['enabled'] != false},
    ];

List<Map<String, dynamic>> normalizePriced(List<Map<String, dynamic>> items) => [
      for (final c in items)
        if (_s(c['name']).trim().isNotEmpty)
          {'id': _s(c['id']), 'name': _s(c['name']).trim(), 'price': _priceOr0(c['price']), 'enabled': c['enabled'] != false},
    ];

List<Map<String, dynamic>> normalizeTaxes(List<Map<String, dynamic>> items) => [
      for (final c in items)
        if (_s(c['name']).trim().isNotEmpty)
          {
            'id': _s(c['id']),
            'name': _s(c['name']).trim(),
            'description': _s(c['description']).trim(),
            'amount': _priceOr0(c['amount']),
            'enabled': c['enabled'] != false,
          },
    ];

class VehicleDetailsForm {
  VehicleDetailsForm({
    this.imageUri = '',
    this.make = '',
    this.model = '',
    this.price = '',
    List<Map<String, dynamic>>? exteriorColors,
    List<Map<String, dynamic>>? interiorColors,
    List<Map<String, dynamic>>? taxes,
    List<Map<String, dynamic>>? features,
    List<Map<String, dynamic>>? accessories,
    Map<String, List<String>>? gallery,
  })  : exteriorColors = exteriorColors ?? [],
        interiorColors = interiorColors ?? [],
        taxes = taxes ?? [],
        features = features ?? [],
        accessories = accessories ?? [],
        gallery = gallery ?? {for (final k in galleryLimits.keys) k: <String>[]};

  factory VehicleDetailsForm.fromValues(Map<String, dynamic> v) => VehicleDetailsForm(
        imageUri: _s(v['imageUri']),
        make: _s(v['make']),
        model: _s(v['model']),
        price: v['price'] == null ? '' : _s(v['price']),
        exteriorColors: parseItemList(v['exteriorColors']),
        interiorColors: parseItemList(v['interiorColors']),
        taxes: parseItemList(v['taxes']),
        features: parseItemList(v['features']),
        accessories: parseItemList(v['accessories']),
        gallery: {for (final k in galleryLimits.keys) k: _stringList(v[k])},
      );

  String imageUri;
  String make;
  String model;
  String price;
  final List<Map<String, dynamic>> exteriorColors;
  final List<Map<String, dynamic>> interiorColors;
  final List<Map<String, dynamic>> taxes;
  final List<Map<String, dynamic>> features;
  final List<Map<String, dynamic>> accessories;
  final Map<String, List<String>> gallery;

  /// Puts [uri] in gallery [key] at [slot] (padding with blanks), capped at
  /// the key's limit.
  void setGallerySlot(String key, int slot, String uri) {
    final list = [...gallery[key] ?? <String>[]];
    while (list.length <= slot) {
      list.add('');
    }
    list[slot] = uri;
    gallery[key] = list.take(galleryLimits[key] ?? list.length).toList();
  }
}

List<String> _stringList(Object? raw) {
  if (raw is! String || raw.isEmpty) return [];
  try {
    final v = jsonDecode(raw);
    return v is List ? v.map((x) => '$x').toList() : [];
  } catch (_) {
    return [];
  }
}

({Map<String, dynamic>? values, String? error}) buildVehicleDetailsValues(
  VehicleDetailsForm f, {
  Map<String, dynamic>? existing,
}) {
  if (f.make.trim().isEmpty || f.model.trim().isEmpty) {
    return (values: null, error: 'Please fill in Make and Model.');
  }
  return (
    values: {
      ...?existing,
      'imageUri': f.imageUri,
      'make': f.make.trim(),
      'model': f.model.trim(),
      'price': _priceOr0(f.price),
      'exteriorColors': jsonEncode(normalizeColors(f.exteriorColors)),
      'interiorColors': jsonEncode(normalizeColors(f.interiorColors)),
      'taxes': jsonEncode(normalizeTaxes(f.taxes)),
      'features': jsonEncode(normalizePriced(f.features)),
      'accessories': jsonEncode(normalizePriced(f.accessories)),
      for (final k in galleryLimits.keys) k: jsonEncode((f.gallery[k] ?? []).where((s) => s.isNotEmpty).toList()),
    },
    error: null,
  );
}

// ===========================================================================
// EV vehicle inventory (table ev_vehicle_inventory)
// ===========================================================================

List<String> parseIdList(Object? raw) {
  if (raw is! String || raw.isEmpty) return [];
  try {
    final v = jsonDecode(raw);
    return v is List ? v.map((x) => '$x').toList() : [];
  } catch (_) {
    return [];
  }
}

/// Enabled items of a vehicle's JSON list (colours/features/accessories).
List<Map<String, dynamic>> enabledItems(Map<String, dynamic>? vehicle, String key) =>
    vehicle == null ? [] : parseItemList(vehicle[key]).where((c) => c['enabled'] != false && c['enabled'] != null).toList();

({Map<String, dynamic>? values, String? error}) buildInventoryValues({
  required String vehicleId,
  required Map<String, dynamic>? vehicle,
  required String vin,
  required List<String> exteriorColorIds,
  required List<String> interiorColorIds,
  required List<String> featureIds,
  required List<String> accessoryIds,
  Map<String, dynamic>? existing,
}) {
  if (vehicleId.isEmpty) return (values: null, error: 'Please select a vehicle.');
  if (vin.trim().isEmpty) return (values: null, error: 'Please enter a VIN number.');
  String snap(String key, List<String> ids) =>
      enabledItems(vehicle, key).where((c) => ids.contains(_s(c['id']))).map((c) => _s(c['name'])).join(', ');
  return (
    values: {
      ...?existing,
      'vehicleId': vehicleId,
      'make': _s(vehicle?['make']),
      'model': _s(vehicle?['model']),
      'vin': vin.trim(),
      'exteriorColorIds': jsonEncode(exteriorColorIds),
      'interiorColorIds': jsonEncode(interiorColorIds),
      'featureIds': jsonEncode(featureIds),
      'accessoryIds': jsonEncode(accessoryIds),
      'exteriorColor': snap('exteriorColors', exteriorColorIds),
      'interiorColor': snap('interiorColors', interiorColorIds),
      'features': snap('features', featureIds),
      'accessories': snap('accessories', accessoryIds),
    },
    error: null,
  );
}
