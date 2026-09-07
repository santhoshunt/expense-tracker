import '../models/account.dart';
import '../utils/dates.dart';

/// Card-bill due bookkeeping, shared by the dashboard Upcoming card, the
/// due-date notification and the account detail's bill line — the one place
/// that decides WHICH cycle a card is in and whether it was marked paid.
/// Pure date math; the live outstanding stays a provider concern.

/// Bills render as urgent (and the reminder fires) within this many days
/// of the due date.
const int kCardUrgentWindowDays = 3;

class CardBillStatus {
  /// Effective due date: the natural one, or the NEXT cycle's when the
  /// natural one was marked paid.
  final DateTime due;

  /// Calendar days from today to [due]; 0 = due today, negative = overdue.
  final int daysUntil;

  /// The user marked the current cycle's bill paid
  /// ([Account.billPaidMonth] matches the natural due's [monthKey]).
  final bool paidThisCycle;

  /// Unpaid and due within [kCardUrgentWindowDays].
  final bool urgent;

  const CardBillStatus({
    required this.due,
    required this.daysUntil,
    required this.paidThisCycle,
    required this.urgent,
  });
}

/// Null unless [account] is an open card with a due day set.
CardBillStatus? cardBillStatus(Account account, DateTime now) {
  if (!account.isCard || account.isClosed || account.dueDay == null) {
    return null;
  }
  final today = DateTime(now.year, now.month, now.day);
  final natural = nextMonthlyOccurrence(account.dueDay!, now);
  final paid = account.billPaidMonth == monthKey(natural);
  final due = paid
      ? nextMonthlyOccurrence(
          account.dueDay!,
          natural.add(const Duration(days: 1)),
        )
      : natural;
  final days = due.difference(today).inDays;
  return CardBillStatus(
    due: due,
    daysUntil: days,
    paidThisCycle: paid,
    urgent: !paid && days <= kCardUrgentWindowDays,
  );
}
