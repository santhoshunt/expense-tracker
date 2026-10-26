import '../models/transaction.dart';
import '../utils/search_text.dart';
import 'recurring_detector.dart';

/// Guesses a category for an imported alert no rule placed, from the
/// user's own rows. Two steps: a merchant always filed under one category
/// gives that category; otherwise the words of the merchant name vote, and
/// a clear winner is the guess. Nothing leaves the phone and no model is
/// trained: it is a word count over the ledger.
///
/// Evidence is confirmed rows the user has seen whose category was not
/// itself a guess, outside the transfer, Other and To sort categories.
class CategoryGuesser {
  /// Merchant key ([recurringKeyOf]) to the categories its evidence carries.
  final Map<String, Set<String>> _merchants;

  /// Direction and word to category to the number of evidence rows that
  /// carry the word.
  final Map<String, Map<String, int>> _votes;

  CategoryGuesser._(this._merchants, this._votes);

  /// Words that name no merchant: payment channels, banks and fillers.
  static const Set<String> stopWords = {
    'upi',
    'pos',
    'ref',
    'txn',
    'ltd',
    'pvt',
    'india',
    'payment',
    'paid',
    'bank',
    'card',
    'the',
    'and',
    'from',
    'ach',
    'neft',
    'imps',
    'rtgs',
    'debit',
    'credit',
  };

  /// A winner needs this many votes...
  static const int minVotes = 2;

  /// ...and at least this share of all the votes cast.
  static const double minShare = 0.8;

  factory CategoryGuesser.from(Iterable<Tx> rows) {
    final merchants = <String, Set<String>>{};
    final votes = <String, Map<String, int>>{};
    for (final t in rows) {
      if (!_isEvidence(t)) continue;
      final key = recurringKeyOf(t);
      if (key != null) (merchants[key] ??= {}).add(t.categoryId);
      for (final w in wordsOf(t)) {
        final byCat = votes['${t.type.name}|$w'] ??= {};
        byCat[t.categoryId] = (byCat[t.categoryId] ?? 0) + 1;
      }
    }
    return CategoryGuesser._(merchants, votes);
  }

  static bool _isEvidence(Tx t) =>
      !t.pending && !t.unseen && !t.categoryGuessed && _guessable(t.categoryId);

  /// A category a guess may give: one that exists, outside the transfer,
  /// Other and To sort categories.
  static bool _guessable(String id) =>
      !isTransferCategory(id) &&
      id != 'other_expense' &&
      id != 'other_income' &&
      !isToSortCategory(id) &&
      allCategories.any((c) => c.id == id);

  /// The merchant name's words that can vote: 3 letters or more, not all
  /// digits, not in [stopWords]. Each word once.
  static Set<String> wordsOf(Tx t) => {
    for (final w in normalizeSearchText(merchantDisplayLabel(t)).split(' '))
      if (w.length >= 3 && !stopWords.contains(w) && !_digits.hasMatch(w)) w,
  };

  static final RegExp _digits = RegExp(r'^\d+$');

  /// The category [row] most likely belongs in, or null when the evidence
  /// is too thin or split.
  String? guess(Tx row) {
    final key = recurringKeyOf(row);
    final known = key == null ? null : _merchants[key];
    if (known != null && known.length == 1) {
      final id = known.single;
      if (_fits(id, row)) return id;
    }
    final tally = <String, int>{};
    var all = 0;
    for (final w in wordsOf(row)) {
      final byCat = _votes['${row.type.name}|$w'];
      if (byCat == null) continue;
      byCat.forEach((cat, n) {
        tally[cat] = (tally[cat] ?? 0) + n;
        all += n;
      });
    }
    String? best;
    var bestVotes = 0;
    tally.forEach((cat, n) {
      if (n > bestVotes) {
        best = cat;
        bestVotes = n;
      }
    });
    final winner = best;
    if (winner == null ||
        bestVotes < minVotes ||
        bestVotes < all * minShare ||
        !_fits(winner, row)) {
      return null;
    }
    return winner;
  }

  /// [id] is still a category a guess may give, in [row]'s direction.
  static bool _fits(String id, Tx row) =>
      _guessable(id) && categoryById(id).type == row.type;
}
