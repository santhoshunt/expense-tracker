import '../models/account.dart';
import '../models/reminder.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import 'card_bill.dart';
import 'recurring_detector.dart';
import 'reminder_schedule.dart';

/// Where an Upcoming row comes from.
enum UpcomingKind { cardBill, recurring, reminder }

/// One Upcoming row as data: the dashboard card and the home-screen widget
/// both render from [buildUpcomingItems], so they list the same things.
class UpcomingItem {
  final UpcomingKind kind;
  final DateTime due;

  /// Calendar days from today to [due]; negative is overdue.
  final int days;
  final String label;
  final double? amount;

  /// Asks for attention: a card bill due soon or overdue, an overdue
  /// repeat, a reminder due today or earlier.
  final bool urgent;

  /// A card cycle that owes nothing right now (not billed yet, or paid):
  /// its amount is the live figure building toward the next statement.
  final bool muted;

  /// Null for card bills, which show a card icon.
  final String? categoryId;
  final TxType type;
  final CardBillStatus? cardStatus;
  final Account? card;
  final Reminder? reminder;

  /// The recurring pattern's key, which the hide list uses.
  final String? hideKey;

  const UpcomingItem({
    required this.kind,
    required this.due,
    required this.days,
    required this.label,
    required this.amount,
    required this.urgent,
    required this.muted,
    this.categoryId,
    required this.type,
    this.cardStatus,
    this.card,
    this.reminder,
    this.hideKey,
  });
}

/// Card bills with something outstanding, detected repeats the user has not
/// hidden, and reminders from a week before their due day, soonest first.
List<UpcomingItem> buildUpcomingItems(
  FinanceProvider finance, {
  required List<RecurringHit> hits,
  required Set<String> hidden,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final items = <UpcomingItem>[];
  for (final a in finance.openAccounts) {
    final s = cardBillStatus(a, now);
    if (s == null) continue;
    final out = finance.accountOutstanding(a);
    if (out == null || out <= 0) continue;
    items.add(
      UpcomingItem(
        kind: UpcomingKind.cardBill,
        due: s.due,
        days: DateTime(
          s.due.year,
          s.due.month,
          s.due.day,
        ).difference(today).inDays,
        label: '${a.name} bill',
        amount: out,
        urgent: s.urgent,
        muted: s.phase != CardBillPhase.billed,
        type: TxType.expense,
        cardStatus: s,
        card: a,
      ),
    );
  }
  for (final h in hits) {
    if (hidden.contains(h.key)) continue;
    final days = h.daysUntil(now);
    items.add(
      UpcomingItem(
        kind: UpcomingKind.recurring,
        due: h.nextDue,
        days: days,
        label: h.label,
        amount: h.expectedAmount,
        urgent: days < 0,
        muted: false,
        categoryId: h.categoryId,
        type: h.type,
        hideKey: h.key,
      ),
    );
  }
  for (final r in finance.reminders) {
    final days = reminderDaysUntil(r, now);
    if (days > 7) continue;
    items.add(
      UpcomingItem(
        kind: UpcomingKind.reminder,
        due: reminderNextDue(r, now),
        days: days,
        label: r.name,
        amount: r.expectedAmount,
        urgent: days <= 0,
        muted: false,
        categoryId: r.categoryId,
        type: TxType.expense,
        reminder: r,
      ),
    );
  }
  items.sort((a, b) => a.due.compareTo(b.due));
  return items;
}
