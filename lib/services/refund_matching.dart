import '../models/transaction.dart';
import 'recurring_detector.dart';

/// Refund matching: finding the purchase an incoming refund pays back, so
/// the two can be linked ([Tx.refundOf]) and the refund taken off that
/// purchase's spend instead of counting as income. Pure functions; the
/// provider supplies rows and the figures, and persists an accepted link.

/// A refund looks for its purchase at most this many days back.
const int kRefundWindowDays = 60;

final RegExp _cashbackRe = RegExp(r'\bcash\s*back\b', caseSensitive: false);

final RegExp _refundWordRe = RegExp(
  r'\b(?:refund|refunded|reversal|reversed|credited\s+back)\b',
  caseSensitive: false,
);

/// Whether [smsText] reads as a refund or a reversal. A cashback is a
/// reward, never a refund, even when "credited back" appears beside it.
bool isRefundWorded(String smsText) {
  if (smsText.isEmpty || _cashbackRe.hasMatch(smsText)) return false;
  return _refundWordRe.hasMatch(smsText);
}

/// Calendar days from [purchase]'s day to [refund]'s day: 0 on the same
/// day whatever the times, negative when the refund is dated before. The
/// one date rule candidates and FinanceProvider.linkRefund share.
int refundDayGap(Tx purchase, Tx refund) {
  final p = purchase.date;
  final r = refund.date;
  return DateTime.utc(
    r.year,
    r.month,
    r.day,
  ).difference(DateTime.utc(p.year, p.month, p.day)).inDays;
}

/// A purchase a refund could pay back.
class RefundCandidate {
  final Tx purchase;

  /// Both rows name the same merchant ([merchantIdentityOf]).
  final bool sameMerchant;

  /// The refund is the purchase's whole amount, to the paisa.
  final bool exactAmount;

  const RefundCandidate({
    required this.purchase,
    required this.sameMerchant,
    required this.exactAmount,
  });
}

/// Purchases among [confirmed] that [refund] could pay back: expense rows,
/// confirmed, outside the transfer categories, not a split, counted
/// ([counts]), dated on the refund's day or up to [kRefundWindowDays]
/// before it, with at least the refund's amount still unrefunded
/// ([remainingOf]). Each must name the refund's merchant, or sit on the
/// refund's account when the refund is worded as one ([isRefundWorded]).
/// Same merchant first, then the exact amount, then the closest date. None
/// for a cashback: a reward, never a refund.
List<RefundCandidate> refundCandidatesFor(
  Tx refund,
  Iterable<Tx> confirmed, {
  required double Function(Tx) remainingOf,
  required bool Function(Tx) counts,
}) {
  if (refund.type != TxType.income || _cashbackRe.hasMatch(refund.smsText)) {
    return const [];
  }
  final refundMerchant = merchantIdentityOf(refund);
  final sameAccountOk =
      refund.acctKey != null && isRefundWorded(refund.smsText);
  if (refundMerchant == null && !sameAccountOk) return const [];
  final found = <(int gap, RefundCandidate c)>[];
  for (final p in confirmed) {
    if (p.type != TxType.expense ||
        p.pending ||
        p.id == refund.id ||
        p.myShare != null ||
        isTransferCategory(p.categoryId)) {
      continue;
    }
    final gap = refundDayGap(p, refund);
    if (gap < 0 || gap > kRefundWindowDays) continue;
    if (!counts(p)) continue;
    if (remainingOf(p) < refund.amount - 0.005) continue;
    // The merchant lookup runs a regex over the alert: last, on the few
    // rows the cheap checks above let through.
    final sameMerchant =
        refundMerchant != null && merchantIdentityOf(p) == refundMerchant;
    if (!sameMerchant && !(sameAccountOk && p.acctKey == refund.acctKey)) {
      continue;
    }
    found.add((
      gap,
      RefundCandidate(
        purchase: p,
        sameMerchant: sameMerchant,
        exactAmount: (p.amount - refund.amount).abs() < 0.005,
      ),
    ));
  }
  found.sort((a, b) {
    if (a.$2.sameMerchant != b.$2.sameMerchant) {
      return a.$2.sameMerchant ? -1 : 1;
    }
    if (a.$2.exactAmount != b.$2.exactAmount) {
      return a.$2.exactAmount ? -1 : 1;
    }
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, c) in found) c];
}

/// The purchase [refund] surely pays back, or null: the refund is an SMS
/// import worded as a refund, and exactly one of [c] has the same merchant
/// and the exact amount. Anything less is only a suggestion.
Tx? sureRefundPurchase(Tx refund, List<RefundCandidate> c) {
  if (refund.source != TxSource.sms || !isRefundWorded(refund.smsText)) {
    return null;
  }
  Tx? match;
  for (final x in c) {
    if (!x.sameMerchant || !x.exactAmount) continue;
    if (match != null) return null;
    match = x.purchase;
  }
  return match;
}

/// A refund and the purchase it likely pays back, offered for review.
class RefundSuggestion {
  final Tx refund;
  final Tx purchase;

  const RefundSuggestion({required this.refund, required this.purchase});

  /// Identity in the dismissal list ("Not a refund"), beside the transfer
  /// pair keys.
  String get key => 'refund|${refund.id}|${purchase.id}';
}
