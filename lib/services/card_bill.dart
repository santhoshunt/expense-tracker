import 'dart:ui' show Color;

import '../models/account.dart';
import '../utils/dates.dart';
import '../utils/format.dart';

/// Card-bill due bookkeeping, shared by the dashboard Upcoming card, the
/// due-date notification and the account detail's bill line — the one place
/// that decides WHICH cycle a card is in and whether it was marked paid.
/// Date math and presentation; the live outstanding stays a provider concern.

/// Bills render as urgent (and the reminder fires) within this many days
/// of the due date.
const int kCardUrgentWindowDays = 5;

/// Where the shown cycle stands. Only [billed] deserves attention: the
/// statement exists and the money is owed by the due date.
enum CardBillPhase {
  /// The statement hasn't been generated yet — what's accruing belongs to a
  /// bill that doesn't exist. Never urgent, never notifies.
  notBilled,

  /// Statement generated, not marked paid. Urgency and the due notification
  /// live here.
  billed,

  /// This cycle was marked paid; [CardBillStatus.due] already points at the
  /// next cycle (whose statement is always still in the future while the
  /// paid flag holds).
  paid,
}

class CardBillStatus {
  /// Effective due date: the natural one, or the NEXT cycle's when the
  /// natural one was marked paid.
  final DateTime due;

  /// When the bill for [due] is (or was) generated: the last occurrence of
  /// [Account.statementDay] strictly before [due]. Null when the account has
  /// no statement day — the phase then falls back to [CardBillPhase.billed].
  final DateTime? statementDate;

  /// Calendar days from today to [due]; 0 = due today, negative = overdue.
  final int daysUntil;

  final CardBillPhase phase;

  /// The user marked the current cycle's bill paid
  /// ([Account.billPaidMonth] matches the natural due's [monthKey]).
  final bool paidThisCycle;

  /// Billed (generated, unpaid) and due within [kCardUrgentWindowDays].
  final bool urgent;

  const CardBillStatus({
    required this.due,
    required this.statementDate,
    required this.daysUntil,
    required this.phase,
    required this.paidThisCycle,
    required this.urgent,
  });
}

/// The last occurrence of day-of-month [day] strictly before [due]; [day]
/// beyond a month's length clamps to that month's last day (a "31st"
/// statement lands on 28/29 Feb).
DateTime _statementBefore(int day, DateTime due) {
  final sameMonth = DateTime(
    due.year,
    due.month,
    day.clamp(1, daysInMonth(due.year, due.month)),
  );
  if (sameMonth.isBefore(due)) return sameMonth;
  return DateTime(
    due.year,
    due.month - 1,
    day.clamp(1, daysInMonth(due.year, due.month - 1)),
  );
}

String _inDays(int days) => days == 0
    ? 'today'
    : days == 1
    ? 'tomorrow'
    : 'in $days days';

/// The one-line story of the shown cycle, shared by the dashboard Upcoming
/// row, its actions sheet and the account tile's bill line. Dates are only
/// as compact as the data allows: the statement date appears when the
/// account has one.
String cardBillSubtitle(CardBillStatus s) {
  final stmt = s.statementDate;
  final due = fmtDateCompact(s.due);
  switch (s.phase) {
    case CardBillPhase.paid:
      return stmt == null
          ? 'Paid · next bill $due'
          : 'Paid · next bill ${fmtDateCompact(stmt)} · due $due';
    case CardBillPhase.notBilled:
      return 'Bill generates ${fmtDateCompact(stmt!)} · due $due';
    case CardBillPhase.billed:
      final when = _inDays(s.daysUntil);
      return stmt == null
          ? 'Due $due · $when'
          : 'Billed ${fmtDateCompact(stmt)} · due $due · $when';
  }
}

/// Icon color for the shown cycle: green = nothing owed right now (not
/// billed yet, or paid), orange = billed with time to spare, red = billed
/// and due within [kCardUrgentWindowDays] or overdue. The caller supplies
/// its theme's colors.
Color cardBillColor(
  CardBillStatus s, {
  required Color green,
  required Color orange,
  required Color red,
}) => switch (s.phase) {
  CardBillPhase.notBilled || CardBillPhase.paid => green,
  CardBillPhase.billed => s.urgent ? red : orange,
};

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
  final stmt = account.statementDay == null
      ? null
      : _statementBefore(account.statementDay!, due);
  final phase = paid
      ? CardBillPhase.paid
      // No statement day recorded: assume billed, the pre-statement-day
      // behavior — a bare due day keeps its urgency and notification.
      : (stmt == null || !today.isBefore(stmt))
      ? CardBillPhase.billed
      : CardBillPhase.notBilled;
  final days = due.difference(today).inDays;
  return CardBillStatus(
    due: due,
    statementDate: stmt,
    daysUntil: days,
    phase: phase,
    paidThisCycle: paid,
    urgent: phase == CardBillPhase.billed && days <= kCardUrgentWindowDays,
  );
}
