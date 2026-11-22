import '../models/transaction.dart';
import 'refund_matching.dart';
import 'transfer_pairing.dart';

/// Why an SMS import waits in review instead of counting at once. A row
/// with two reasons has the one FinanceProvider tests first: spam, then a
/// possible duplicate, a possible transfer leg, no account, a new account,
/// a transfer category, a refund.
enum HoldReason {
  /// A suspected spam message.
  spam,

  /// The alert named no account.
  noAccount,

  /// Its account has no confirmed row yet.
  newAccount,

  /// Its category is a transfer.
  transfer,

  /// A refund that may pay back a purchase.
  refund,

  /// Another row of the same direction and amount sits within a day of it.
  duplicate,

  /// A row on another account could be the other leg of one move.
  transferLeg,

  /// None of the above: a row sent back to review that would count now.
  other,
}

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

  /// Pending ATM withdrawals the sheet asks to move to Cash, in no transfer
  /// suggestion.
  final List<Tx> atm;

  /// [rows] by why each waits, newest first in every list. Every row of
  /// [rows] is in exactly one list; a reason nothing waits for has no entry.
  final Map<HoldReason, List<Tx>> held;

  const ReviewQueue({
    required this.pending,
    required this.spam,
    required this.pairs,
    required this.refunds,
    required this.rows,
    this.atm = const [],
    this.held = const {},
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
