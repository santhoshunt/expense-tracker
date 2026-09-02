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
/// Beyond the note, SMS body and sender this carries the category label, the
/// account name, the merchant label (plus any user alias) and the amount in
/// three spellings — "1250", "1250.00" and the formatted "₹1,250.00" — so a
/// typed "1250" or "1,250" both land.
String searchHaystack(Tx t, {String? accountName, String? merchantAlias}) {
  final parts = <String>[
    t.note,
    t.smsBody,
    t.sender,
    t.category.label,
    accountName ?? '',
    merchantDisplayLabel(t),
    merchantAlias ?? '',
    t.amount.toStringAsFixed(2),
    t.amount.round().toString(),
    fmtMoney(t.amount),
  ];
  return normalizeSearchText(parts.join(' '));
}
