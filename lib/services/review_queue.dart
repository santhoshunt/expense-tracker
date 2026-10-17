import '../models/transaction.dart';
import 'refund_matching.dart';
import 'transfer_pairing.dart';

/// Everything the review sheet lists, built once per ledger change by
/// FinanceProvider.reviewQueue: imports waiting for review, suspected spam,
/// and the transfer and refund suggestions over them. The message icon
/// badge, the Transactions nav badge and the sheet header all count from it.
class ReviewQueue {
  /// Non-spam pending rows, newest first.
  final List<Tx> pending;

  /// Suspected spam pending rows, newest first.
  final List<Tx> spam;

  /// Every transfer suggestion.
  final List<PairSuggestion> pairs;

  /// Refund suggestions whose refund row is in no transfer suggestion.
  final List<RefundSuggestion> refunds;

  /// [pending] less the rows a suggestion already shows.
  final List<Tx> rows;

  const ReviewQueue({
    required this.pending,
    required this.spam,
    required this.pairs,
    required this.refunds,
    required this.rows,
  });

  static const empty = ReviewQueue(
    pending: [],
    spam: [],
    pairs: [],
    refunds: [],
    rows: [],
  );

  /// Counted refunds offered for a link: they wait in the sheet with no
  /// import behind them.
  int get pastRefunds => refunds.where((s) => !s.refund.pending).length;

  /// What the sheet header counts as "to review".
  int get reviewCount => pending.length + pastRefunds;

  /// What the badges show: everything waiting, spam included.
  int get badgeCount => pending.length + spam.length + pastRefunds;

  /// Something other than spam waits.
  bool get hasReview => pending.isNotEmpty || pastRefunds > 0;

  /// Nothing waits at all.
  bool get isEmpty => !hasReview && spam.isEmpty;
}
