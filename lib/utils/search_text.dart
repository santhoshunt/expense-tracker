import 'package:intl/intl.dart';

import '../models/transaction.dart';
import '../services/recurring_detector.dart';
import 'format.dart';

/// Lowercases and flattens every run of punctuation/whitespace to one
/// space, so "NETFLIX.COM", "netflix com" and the Top-merchants identity
/// (`recurringKeyOf` uses the same rule) all compare equal.
String normalizeSearchText(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Everything a free-text search may match on one row, already normalized.
///
/// Beyond the note, the payee, SMS body and sender this carries the category
/// label, the account name, the merchant label (plus any user alias), the tags, the
/// people on a split or the payer of a repayment, and the amount in
/// several spellings: "125000", "125000.00", the formatted "₹1,25,000.00",
/// the Indian grouping "1,25,000" and the Western "125,000.00", so a typed
/// "125000", "125,000" or "1,25,000" all land.
String searchHaystack(Tx t, {String? accountName, String? merchantAlias}) {
  final parts = <String>[
    t.note,
    t.payee,
    t.smsBody,
    t.sender,
    t.category.label,
    accountName ?? '',
    merchantDisplayLabel(t),
    merchantAlias ?? '',
    ...t.tags,
    for (final p in t.people) p.name,
    t.repaidBy ?? '',
    t.amount.toStringAsFixed(2),
    t.amount.round().toString(),
    fmtMoney(t.amount),
    _indianWhole.format(t.amount),
    _indianFixed.format(t.amount),
    _westernFixed.format(t.amount),
  ];
  return normalizeSearchText(parts.join(' '));
}

/// Why [t] matched the normalized query [q] when the row's visible text
/// does not show it: "paid to SWIGGY", "note says …", "account …",
/// "alert says …" or "alert from …". Null when the title, category label,
/// first note line, tags, people, payer or amount already shows the match,
/// or when no field explains it. [title] is the row's title as the tile
/// draws it and [accountName] its account's name.
String? searchMatchNote(Tx t, String q, {String? title, String? accountName}) {
  if (q.isEmpty) return null;
  bool has(String? s) => s != null && normalizeSearchText(s).contains(q);
  final visible = <String?>[
    title,
    t.category.label,
    t.note.split('\n').first,
    ...t.tags,
    for (final p in t.people) p.name,
    t.repaidBy,
    ..._amountSpellings(t.amount),
  ];
  if (visible.any(has)) return null;
  final fields = <(String, String?)>[
    ('paid to', t.payee),
    ('note says', t.note),
    ('account', accountName),
    ('alert says', t.smsBody),
    ('alert from', t.sender),
  ];
  for (final (prefix, raw) in fields) {
    if (raw == null || !has(raw)) continue;
    final excerpt = _matchExcerpt(raw, q);
    if (excerpt != null) return '$prefix $excerpt';
  }
  return null;
}

/// The six amount spellings [searchHaystack] carries.
List<String> _amountSpellings(double a) => [
  a.toStringAsFixed(2),
  a.round().toString(),
  fmtMoney(a),
  _indianWhole.format(a),
  _indianFixed.format(a),
  _westernFixed.format(a),
];

/// The words of [raw] that hold the normalized query [q], as written there,
/// cut to 23 characters plus "…" when longer than 24.
String? _matchExcerpt(String raw, String q) {
  final pattern =
      '[A-Za-z0-9]*'
      '${q.split(' ').map(RegExp.escape).join('[^A-Za-z0-9]+')}'
      '[A-Za-z0-9]*';
  final m = RegExp(pattern, caseSensitive: false).firstMatch(raw);
  if (m == null) return null;
  final text = m.group(0)!;
  return text.length > 24 ? '${text.substring(0, 23)}…' : text;
}

/// Lakh grouping as Indian banks write amounts: "1,25,000" (decimals only
/// when the amount has them) and "1,25,000.00".
final NumberFormat _indianWhole = NumberFormat.decimalPattern('en_IN');
final NumberFormat _indianFixed = NumberFormat('#,##,##0.00', 'en_IN');

/// Thousands grouping, "125,000.00", for a query typed that way.
final NumberFormat _westernFixed = NumberFormat('#,##0.00', 'en_US');
