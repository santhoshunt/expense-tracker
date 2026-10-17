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

/// Lakh grouping as Indian banks write amounts: "1,25,000" (decimals only
/// when the amount has them) and "1,25,000.00".
final NumberFormat _indianWhole = NumberFormat.decimalPattern('en_IN');
final NumberFormat _indianFixed = NumberFormat('#,##,##0.00', 'en_IN');

/// Thousands grouping, "125,000.00", for a query typed that way.
final NumberFormat _westernFixed = NumberFormat('#,##0.00', 'en_US');
