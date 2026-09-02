import '../models/account.dart';
import '../models/transaction.dart';

/// Transfer pairing: recognising the two SMS legs of one own-account move
/// (bank debit + savings/card credit) so they can be linked and both booked
/// as transfers instead of one expense plus one income. Pure functions; the
/// provider supplies rows and accounts and persists the accepted link.

/// What kind of own-account move a pair is, decided by the RECEIVING account.
enum PairKind {
  /// Bank to bank (or unknown receiver): `transfer_out` / `transfer_in`.
  transfer,

  /// Into a savings/asset account: `savings_out` ("To savings") /
  /// `transfer_in`.
  savings,

  /// Credit-card bill payment: `card_bill` / `card_payment`.
  cardPayment,
}

/// Stable, order-independent identity of a suggested pair, used for the
/// "Not a transfer" dismissal list.
String pairSuggestionKey(String a, String b) => ([a, b]..sort()).join('|');

/// Legs must be dated within this window of each other.
const Duration kPairDateWindow = Duration(days: 2);

class PairSuggestion {
  final Tx out;
  final Tx incoming;
  final PairKind kind;
  const PairSuggestion({
    required this.out,
    required this.incoming,
    required this.kind,
  });

  String get key => pairSuggestionKey(out.id, incoming.id);
}

/// Null when the move is not a transfer at all: a debit on a CARD followed
/// by a credit elsewhere is a refund or cashback, never a self-transfer.
PairKind? pairKindFor({required Account? send, required Account? recv}) {
  if (send?.isCard == true) return null;
  if (recv?.type == AccountType.creditCard) return PairKind.cardPayment;
  if (recv?.type == AccountType.savings) return PairKind.savings;
  return PairKind.transfer;
}

/// Built-in transfer categories for each leg of a [kind].
({String out, String incoming}) pairCategoriesFor(PairKind kind) =>
    switch (kind) {
      PairKind.cardPayment => (out: 'card_bill', incoming: 'card_payment'),
      PairKind.savings => (
        out: kSavingsTransferCategoryId,
        incoming: 'transfer_in',
      ),
      PairKind.transfer => (out: 'transfer_out', incoming: 'transfer_in'),
    };

/// Candidate pairs among [rows]: one expense and one income of the same
/// amount, dated within [kPairDateWindow], on different accounts (at least
/// one known), neither already paired nor spam, at least one still pending
/// (the review queue is where the suggestion renders), the sending account
/// not a card, and not previously dismissed. Greedy by date distance so each
/// row appears in at most one suggestion.
List<PairSuggestion> suggestTransferPairs(
  List<Tx> rows, {
  required Set<String> dismissed,
  required Account? Function(String? acctKey) accountFor,
}) {
  final byAmount = <int, List<Tx>>{};
  for (final t in rows) {
    if (t.pairId != null || t.suspectedSpam) continue;
    (byAmount[(t.amount * 100).round()] ??= []).add(t);
  }
  final candidates = <(int distance, PairSuggestion s)>[];
  for (final bucket in byAmount.values) {
    final outs = bucket.where((t) => t.type == TxType.expense);
    final ins = bucket.where((t) => t.type == TxType.income).toList();
    for (final out in outs) {
      for (final inn in ins) {
        if (!out.pending && !inn.pending) continue;
        if (out.acctKey == inn.acctKey) continue; // same or both unknown
        final gap = out.date.difference(inn.date).abs();
        if (gap > kPairDateWindow) continue;
        final kind = pairKindFor(
          send: accountFor(out.acctKey),
          recv: accountFor(inn.acctKey),
        );
        if (kind == null) continue;
        if (dismissed.contains(pairSuggestionKey(out.id, inn.id))) continue;
        candidates.add((
          gap.inMinutes,
          PairSuggestion(out: out, incoming: inn, kind: kind),
        ));
      }
    }
  }
  candidates.sort((a, b) => a.$1.compareTo(b.$1));
  final used = <String>{};
  final result = <PairSuggestion>[];
  for (final (_, s) in candidates) {
    if (used.contains(s.out.id) || used.contains(s.incoming.id)) continue;
    used.add(s.out.id);
    used.add(s.incoming.id);
    result.add(s);
  }
  return result;
}
