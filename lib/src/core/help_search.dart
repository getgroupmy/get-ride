/// The help assistant's on-device ranker, used when the `help_search` RPC
/// cannot be reached (offline, or a database before migration 0130). Pure:
/// no model and no network, just words.
///
/// A question and every article are reduced to the same terms: lower-cased,
/// punctuation stripped, English and Malay stop words dropped, common
/// suffixes cut ("cancelling" → "cancel"), and synonyms folded onto one word
/// ("password" → "pin", "batal" → "cancel", "pemandu" → "driver"). Articles
/// are then scored with BM25 over their title and question variants, keywords
/// and answer, weighted in that order. A question word that matches no
/// article word is given the nearest one within one edit, so "walet" still
/// finds the wallet.
library;

import 'dart:math' as math;

import 'help_article.dart';

/// A ranked article.
class HelpHit {
  const HelpHit(this.article, this.score);
  final HelpArticle article;
  final double score;

  @override
  String toString() => 'HelpHit(${article.title}, ${score.toStringAsFixed(2)})';
}

const _stopWords = {
  // English
  'a', 'about', 'am', 'an', 'and', 'any', 'are', 'as', 'at', 'be', 'been', 'but', 'by', 'can', 'could', 'did', 'do',
  'does', 'doing', 'for', 'from', 'get', 'got', 'had', 'has', 'have', 'hi', 'hello', 'how', 'i', 'if', 'im', 'in',
  'into',
  'is',
  'it',
  'its',
  'just',
  'let',
  'me',
  'my',
  'need',
  'no',
  'not',
  'of',
  'on',
  'or',
  'please',
  'pls',
  'should',
  'so',
  'some', 'that', 'the', 'their', 'them', 'then', 'there', 'this', 'to', 'up', 'us', 'was', 'way', 'we', 'what',
  'when', 'where', 'which', 'who', 'why', 'will', 'with', 'would', 'you', 'your', 'want', 'wanna',
  // Malay
  'saya', 'aku', 'awak', 'anda', 'nak', 'hendak', 'mahu', 'macam', 'mana', 'cara', 'bagaimana', 'apa', 'untuk',
  'yang', 'di', 'ke', 'dan', 'ini', 'itu', 'boleh', 'ada', 'dengan', 'kenapa', 'mengapa', 'bila', 'perlu', 'kah',
  'tak', 'tidak', 'dari', 'pada', 'sudah', 'dah', 'ya', 'je', 'lah', 'tolong',
};

/// Phrases folded into one word before the text is split.
const _phrases = {
  'sign in': 'signin',
  'log in': 'signin',
  'log masuk': 'signin',
  'sign up': 'signup',
  'top up': 'topup',
  'tambah nilai': 'topup',
  'kata laluan': 'pin',
  'e hailing': 'ehailing',
  'e-hailing': 'ehailing',
  'get.wallet': 'wallet',
  'get.credit': 'credit',
  'get.coin': 'coin',
  'obd-ii': 'obd',
  'obd ii': 'obd',
  'obd2': 'obd',
};

/// Each group's words, folded onto its first.
const _synonymGroups = [
  ['pin', 'password', 'passcode', 'passwd'],
  ['cancel', 'batal', 'pembatalan', 'cancellation'],
  ['wallet', 'dompet'],
  ['driver', 'partner', 'pemandu', 'rakan', 'chauffeur'],
  ['fare', 'price', 'tambang', 'harga', 'cost'],
  ['ride', 'trip', 'perjalanan', 'journey'],
  ['book', 'tempah', 'tempahan', 'order', 'pesan'],
  ['taxi', 'teksi', 'cab'],
  ['car', 'vehicle', 'kereta', 'kenderaan'],
  ['topup', 'reload', 'deposit', 'isi'],
  ['coin', 'syiling', 'coins'],
  ['signin', 'login', 'logon', 'masuk'],
  ['signup', 'register', 'registration', 'daftar', 'pendaftaran'],
  ['phone', 'telefon', 'mobile', 'handphone', 'hp'],
  ['receipt', 'resit', 'invoice'],
  ['history', 'sejarah'],
  ['forgot', 'forget', 'lupa'],
  ['change', 'tukar', 'update', 'ubah'],
  ['support', 'help', 'bantuan', 'sokongan', 'helpdesk'],
  ['emergency', 'kecemasan', 'sos'],
  ['photo', 'picture', 'pic', 'gambar', 'avatar'],
  ['share', 'kongsi'],
  ['stop', 'singgah'],
  ['contact', 'hubungi'],
  ['pay', 'bayar', 'payment', 'pembayaran'],
  ['cash', 'tunai'],
  ['document', 'dokumen'],
  ['notification', 'notifikasi', 'pemberitahuan', 'alert'],
  ['dark', 'gelap'],
  ['theme', 'tema', 'appearance'],
  ['referral', 'rujukan', 'invite', 'jemput'],
  ['raise', 'increase', 'naik', 'naikkan'],
  ['offer', 'bid', 'tawar', 'tawaran', 'bargain'],
  ['print', 'printer', 'pencetak', 'cetak'],
  ['approve', 'approval', 'lulus', 'kelulusan'],
  ['delete', 'padam', 'remove'],
  ['friend', 'kawan'],
  ['family', 'keluarga'],
  ['meter', 'taximeter'],
  ['address', 'alamat'],
  ['home', 'rumah'],
  ['account', 'akaun'],
  ['complaint', 'aduan', 'report'],
  ['lost', 'tertinggal', 'hilang'],
  ['expire', 'tamat'],
];

/// Cuts a common English (or Malay) suffix: enough that "cancelled",
/// "cancelling" and "cancel" meet, without a full stemmer.
String helpStem(String w) {
  if (w.length <= 3 || RegExp(r'\d').hasMatch(w)) return w;
  var s = w;
  String undouble(String x) =>
      x.length > 3 && x[x.length - 1] == x[x.length - 2] && !'aeiousz'.contains(x[x.length - 1])
      ? x.substring(0, x.length - 1)
      : x;
  if (s.endsWith('ies') && s.length > 4) return '${s.substring(0, s.length - 3)}y';
  for (final suffix in const ['ation', 'ment', 'ness', 'ing', 'ed', 'ly']) {
    if (s.endsWith(suffix) && s.length - suffix.length >= 3) return undouble(s.substring(0, s.length - suffix.length));
  }
  // Malay: -kan / -nya ("batalkan", "tambangnya").
  for (final suffix in const ['kan', 'nya']) {
    if (s.endsWith(suffix) && s.length - suffix.length >= 4) return s.substring(0, s.length - suffix.length);
  }
  if (s.endsWith('es') && s.length > 4 && RegExp(r'(s|x|z|ch|sh)es$').hasMatch(s)) return s.substring(0, s.length - 2);
  if (s.endsWith('s') && !s.endsWith('ss') && !s.endsWith('us') && s.length > 3) s = s.substring(0, s.length - 1);
  return s;
}

final Map<String, String> _synonyms = {
  for (final g in _synonymGroups)
    for (final w in g) helpStem(w): helpStem(g.first),
};

/// [text] as search terms (see the library comment), in order, repeats kept.
List<String> helpTerms(String text) {
  var t = text.toLowerCase();
  for (final e in _phrases.entries) {
    t = t.replaceAll(e.key, ' ${e.value} ');
  }
  final out = <String>[];
  for (final raw in t.split(RegExp(r'[^a-z0-9]+'))) {
    if (raw.isEmpty || _stopWords.contains(raw)) continue;
    if (raw.length < 2 && !RegExp(r'\d').hasMatch(raw)) continue;
    final stem = helpStem(raw);
    if (_stopWords.contains(stem)) continue;
    out.add(_synonyms[stem] ?? stem);
  }
  return out;
}

/// Optimal-string-alignment distance, stopping early once it passes [max]
/// (so "cancle" is one edit from "cancel").
int helpEditDistance(String a, String b, {int max = 1}) {
  if ((a.length - b.length).abs() > max) return max + 1;
  final rows = List.generate(a.length + 1, (_) => List<int>.filled(b.length + 1, 0));
  for (var i = 0; i <= a.length; i++) {
    rows[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    rows[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    var best = max + 1;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var d = math.min(math.min(rows[i - 1][j] + 1, rows[i][j - 1] + 1), rows[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) d = math.min(d, rows[i - 2][j - 2] + 1);
      rows[i][j] = d;
      best = math.min(best, d);
    }
    if (best > max) return max + 1;
  }
  return rows[a.length][b.length];
}

/// Field weights: what an article is about counts most.
const _titleBoost = 3.0, _keywordBoost = 2.0, _answerBoost = 0.6;

/// How much a word reached only by a typo counts against an exact match.
const _fuzzyWeight = 0.75;

class _Doc {
  _Doc(this.article)
    : tf = {},
      title = [helpTerms(article.title), for (final v in article.questionVariants) helpTerms(v)] {
    void add(Iterable<String> terms, double boost) {
      for (final t in terms) {
        tf[t] = (tf[t] ?? 0) + boost;
      }
    }

    for (final t in title) {
      add(t, _titleBoost);
    }
    for (final k in article.keywords) {
      add(helpTerms(k), _keywordBoost);
    }
    add(helpTerms(article.answer), _answerBoost);
    length = tf.values.fold(0.0, (a, b) => a + b);
  }

  final HelpArticle article;

  /// Weighted term frequencies over every field.
  final Map<String, double> tf;

  /// The title's and each variant's terms, for the coverage bonus.
  final List<List<String>> title;
  late final double length;
}

/// BM25 over [articles], built once and asked many times.
class HelpIndex {
  HelpIndex(Iterable<HelpArticle> articles) : _docs = [for (final a in articles) _Doc(a)] {
    for (final d in _docs) {
      for (final t in d.tf.keys) {
        _df[t] = (_df[t] ?? 0) + 1;
      }
    }
    _avgLength = _docs.isEmpty ? 1 : _docs.map((d) => d.length).reduce((a, b) => a + b) / _docs.length;
  }

  final List<_Doc> _docs;
  final Map<String, int> _df = {};
  late final double _avgLength;

  static const _k1 = 1.2, _b = 0.75;

  double _idf(String t) {
    final n = _docs.length, df = _df[t] ?? 0;
    return math.log(1 + (n - df + 0.5) / (df + 0.5));
  }

  /// The vocabulary word [t] stands for, with its weight: itself when some
  /// article has it, else the closest word one edit away (words of four
  /// letters or more only, so "pin" never becomes "pen"); null when none.
  (String, double)? _resolve(String t) {
    if (_df.containsKey(t)) return (t, 1);
    if (t.length < 4) return null;
    String? best;
    var bestDf = -1;
    for (final e in _df.entries) {
      if (e.key.length < 3 || helpEditDistance(t, e.key) > 1) continue;
      // Prefer the commoner word: a typo is likelier of a word people use.
      if (e.value > bestDf) {
        best = e.key;
        bestDf = e.value;
      }
    }
    if (best != null) return (best, _fuzzyWeight);
    // The typo may be of a synonym ("pasword" for "password" → "pin").
    for (final e in _synonyms.entries) {
      if (e.key.length >= 4 && helpEditDistance(t, e.key) <= 1 && _df.containsKey(e.value)) {
        return (e.value, _fuzzyWeight);
      }
    }
    return null;
  }

  /// The articles that match [query] for [viewer] ('rider', 'partner' or
  /// 'admin'; see [helpAudienceAllows]), best first, at most [limit].
  List<HelpHit> search(String query, {String viewer = 'rider', int limit = 5}) {
    final terms = <String, double>{};
    for (final t in helpTerms(query)) {
      final r = _resolve(t);
      if (r == null) continue;
      terms[r.$1] = math.max(terms[r.$1] ?? 0, r.$2);
    }
    if (terms.isEmpty) return const [];
    final hits = <HelpHit>[];
    for (final d in _docs) {
      if (!d.article.active || !helpAudienceAllows(d.article.audience, viewer)) continue;
      var score = 0.0;
      for (final e in terms.entries) {
        final f = d.tf[e.key];
        if (f == null) continue;
        final norm = f * (_k1 + 1) / (f + _k1 * (1 - _b + _b * d.length / _avgLength));
        score += e.value * _idf(e.key) * norm;
      }
      if (score <= 0) continue;
      // A title or variant that is mostly the question itself: the article
      // was written for exactly this.
      var coverage = 0.0;
      for (final t in d.title) {
        if (t.isEmpty) continue;
        final shared = t.toSet().intersection(terms.keys.toSet()).length;
        coverage = math.max(coverage, shared / math.max(t.toSet().length, terms.length));
      }
      hits.add(HelpHit(d.article, score * (1 + coverage)));
    }
    hits.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.article.sort.compareTo(b.article.sort);
    });
    return hits.take(limit).toList();
  }
}
