import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import 'recurring_detector.dart';
import 'reminder_schedule.dart';
import 'safe_to_spend.dart';
import 'upcoming_items.dart' show hitMarkedPaid, reminderCoversHit;

/// The days ahead, one by one: the bills safe to spend and the Month-end
/// forecast count, the savings subscriptions, the money expected in, and
/// the balance each day leaves. The Ahead projection reads it, and the This
/// month vs chart reads its bills.

/// What an item does to the balance.
enum ForwardKind { spend, savings, income }

/// One payment expected on a day.
class ForwardItem {
  /// Its own due date; an overdue one keeps the past date.
  final DueBill bill;
  final ForwardKind kind;
  final String categoryId;

  const ForwardItem(this.bill, this.kind, this.categoryId);

  /// Plus for income, minus otherwise.
  double get signed => kind == ForwardKind.income ? bill.amount : -bill.amount;
}

/// One day of the series.
class ForwardDay {
  /// Midnight.
  final DateTime date;

  /// Larger amount first; day 0 also holds overdue items.
  final List<ForwardItem> items;

  /// 0 on day 0, else the per-day figure.
  final double everyday;

  /// The expected balance after this day.
  final double balance;

  const ForwardDay({
    required this.date,
    required this.items,
    required this.everyday,
    required this.balance,
  });

  /// Spend items plus everyday spending; savings and income left out.
  double get expectedSpend =>
      items
          .where((i) => i.kind == ForwardKind.spend)
          .fold(0.0, (s, i) => s + i.bill.amount) +
      everyday;
}

/// The whole series from today.
class ForwardSeries {
  final double start;
  final double perDay;

  /// days[0] is today.
  final List<ForwardDay> days;

  const ForwardSeries(this.start, this.perDay, this.days);

  ForwardDay get last => days.last;

  /// The lowest balance; the earliest such day on a tie.
  ForwardDay get lowest {
    var low = days.first;
    for (final d in days.skip(1)) {
      if (d.balance < low.balance) low = d;
    }
    return low;
  }

  Iterable<ForwardItem> get _items => days.expand((d) => d.items);

  double _sum(bool Function(ForwardItem) test) =>
      _items.where(test).fold(0.0, (s, i) => s + i.bill.amount);

  /// Spend items from a detected or marked payment.
  double get spendSubscriptions =>
      _sum((i) => i.kind == ForwardKind.spend && i.bill.patternKey != null);

  /// Spend items from a reminder.
  double get spendReminders =>
      _sum((i) => i.kind == ForwardKind.spend && i.bill.reminderId != null);

  double get savings => _sum((i) => i.kind == ForwardKind.savings);
  double get income => _sum((i) => i.kind == ForwardKind.income);

  /// Everyday spending over the days after today.
  double get everyday => perDay * (days.length - 1);
}

/// The series from [now]'s day through [to], starting at [start].
///
/// Spending is [billsDue] from [kReminderGraceDays] back, so over a window
/// that ends on the month's last day it equals `MonthForecast.bills`; a
/// payment repeats only past this month. [savings] (the active savings
/// subscriptions) and the income patterns in [patterns] add one item per
/// date, as do reminders [billsDue] leaves out: an income reminder from
/// tomorrow, a money-out transfer reminder (not a Card bill) as savings.
/// Every day after today also spends [perDay].
ForwardSeries buildForwardSeries(
  FinanceProvider finance, {
  required List<RecurringHit> patterns,
  List<RecurringHit> savings = const [],
  required Set<String> hidden,
  required DateTime now,
  required DateTime to,
  required double perDay,
  double start = 0,
}) {
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
  final today = day(now);
  final end = day(to);
  final from = today.subtract(const Duration(days: kReminderGraceDays));
  final monthEnd = DateTime(now.year, now.month + 1, 0);
  final byKey = <String, RecurringHit>{
    for (final h in patterns) h.key: h,
    for (final h in savings) h.key: h,
  };
  DateTime step(RecurringHit h, DateTime d) =>
      h.cycle?.nextAfter(d) ??
      DateTime(d.year, d.month, d.day + h.intervalDays);
  final reminderCategory = {
    for (final r in finance.reminders) r.id: r.categoryId,
  };
  String catOf(DueBill b) => b.reminderId != null
      ? reminderCategory[b.reminderId] ?? 'other_expense'
      : byKey[b.patternKey]!.categoryId;

  final items = <ForwardItem>[];
  // A spend pattern's dates after [due], only past this month so the This
  // month vs chart still ends at the forecast total.
  void repeatSpend(RecurringHit h, DateTime due) {
    for (var d = step(h, due); !d.isAfter(end); d = step(h, d)) {
      if (!d.isAfter(monthEnd)) continue;
      items.add(
        ForwardItem(
          DueBill(
            due: d,
            label: h.label,
            amount: h.expectedAmount,
            patternKey: h.key,
          ),
          ForwardKind.spend,
          h.categoryId,
        ),
      );
    }
  }

  // The bills safe to spend and the forecast count, then their repeats.
  final listed = <String>{};
  for (final b in billsDue(
    finance,
    patterns: patterns,
    hidden: hidden,
    from: from,
    to: end,
    now: now,
  )) {
    items.add(ForwardItem(b, ForwardKind.spend, catOf(b)));
    final key = b.patternKey;
    if (key == null) continue;
    listed.add(key);
    repeatSpend(byKey[key]!, day(b.due));
  }
  // A pattern billsDue would list but for its current date being paid (by
  // hand, or by an alert waiting for review) still repeats after it.
  for (final h in patterns) {
    if (h.type != TxType.expense ||
        hidden.contains(h.key) ||
        listed.contains(h.key) ||
        isTransferCategory(h.categoryId)) {
      continue;
    }
    final due = day(h.nextDue);
    if (due.isBefore(from) || due.isAfter(end)) continue;
    if (finance.reminders.any(
      (r) =>
          r.expectedAmount != null &&
          !isTransferCategory(r.categoryId) &&
          reminderCoversHit(r, h, now),
    )) {
      continue;
    }
    repeatSpend(h, due);
  }

  // A pattern's first date still owed; null when hidden or stopped (past
  // its date by more than the grace days).
  DateTime? startOf(RecurringHit h) {
    if (hidden.contains(h.key)) return null;
    var d = day(h.nextDue);
    if (hitMarkedPaid(finance, h)) d = step(h, d);
    return d.isBefore(from) ? null : d;
  }

  void addPattern(RecurringHit h, ForwardKind kind) {
    final first = startOf(h);
    if (first == null) return;
    for (var d = first; !d.isAfter(end); d = step(h, d)) {
      items.add(
        ForwardItem(
          DueBill(
            due: d,
            label: h.label,
            amount: h.expectedAmount,
            patternKey: h.key,
          ),
          kind,
          h.categoryId,
        ),
      );
    }
  }

  bool moneyOutTransfer(String categoryId) =>
      isTransferCategory(categoryId) &&
      categoryId != kCardBillCategoryId &&
      categoryById(categoryId, fallbackType: TxType.expense).type ==
          TxType.expense;

  for (final h in savings) {
    // A chit with its own reminder counts once, as the reminder.
    if (finance.reminders.any(
      (r) =>
          r.expectedAmount != null &&
          moneyOutTransfer(r.categoryId) &&
          reminderCoversHit(r, h, now),
    )) {
      continue;
    }
    addPattern(h, ForwardKind.savings);
  }
  for (final h in patterns) {
    if (h.type == TxType.income) addPattern(h, ForwardKind.income);
  }

  // The reminders billsDue leaves out.
  final tomorrow = DateTime(today.year, today.month, today.day + 1);
  for (final r in finance.reminders) {
    final amount = r.expectedAmount;
    if (amount == null) continue;
    final ForwardKind kind;
    final DateTime since;
    if (reminderIsIncome(r)) {
      // A salary the app already spots counts once, as its pattern; a
      // stopped one leaves the reminder to stand in.
      if (patterns.any(
        (h) =>
            h.type == TxType.income &&
            h.categoryId == r.categoryId &&
            startOf(h) != null,
      )) {
        continue;
      }
      kind = ForwardKind.income;
      // Money already in today is in the balance.
      since = tomorrow;
    } else if (moneyOutTransfer(r.categoryId)) {
      kind = ForwardKind.savings;
      since = from;
    } else {
      continue;
    }
    for (final due in reminderDueDatesBetween(r, since, end)) {
      if (reminderOccurrenceDone(r, due)) continue;
      items.add(
        ForwardItem(
          DueBill(due: due, label: r.name, amount: amount, reminderId: r.id),
          kind,
          r.categoryId,
        ),
      );
    }
  }

  final days = <ForwardDay>[];
  var balance = start;
  for (var i = 0; ; i++) {
    final date = DateTime(today.year, today.month, today.day + i);
    if (date.isAfter(end)) break;
    final onDay = [
      for (final it in items)
        if (i == 0
            ? !day(it.bill.due).isAfter(today)
            : day(it.bill.due) == date)
          it,
    ]..sort((a, b) => b.bill.amount.compareTo(a.bill.amount));
    final everyday = i == 0 ? 0.0 : perDay;
    balance += onDay.fold(0.0, (s, it) => s + it.signed) - everyday;
    days.add(
      ForwardDay(
        date: date,
        items: onDay,
        everyday: everyday,
        balance: balance,
      ),
    );
  }
  return ForwardSeries(start, perDay, days);
}
