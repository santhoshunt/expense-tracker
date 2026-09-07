import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/services/card_bill.dart';

void main() {
  Account card({int? dueDay = 10, String? paid, DateTime? closedAt}) => Account(
    id: 'c1',
    name: 'Card',
    type: AccountType.creditCard,
    keys: const {},
    dueDay: dueDay,
    billPaidMonth: paid,
    closedAt: closedAt,
  );

  test('unpaid: natural due, day count, urgency window', () {
    final s = cardBillStatus(card(), DateTime(2026, 9, 7, 15, 30))!;
    expect(s.due, DateTime(2026, 9, 10));
    expect(s.daysUntil, 3);
    expect(s.paidThisCycle, isFalse);
    expect(s.urgent, isTrue, reason: '3 days is inside the window');

    final relaxed = cardBillStatus(card(), DateTime(2026, 9, 1))!;
    expect(relaxed.daysUntil, 9);
    expect(relaxed.urgent, isFalse);
  });

  test('past the due day the cycle rolls to next month', () {
    final s = cardBillStatus(card(), DateTime(2026, 9, 11))!;
    expect(s.due, DateTime(2026, 10, 10));
    expect(s.paidThisCycle, isFalse);
  });

  test('paid this cycle: due moves to next month, urgency drops', () {
    final s = cardBillStatus(card(paid: '2026-09'), DateTime(2026, 9, 7))!;
    expect(s.paidThisCycle, isTrue);
    expect(s.due, DateTime(2026, 10, 10));
    expect(s.daysUntil, 33);
    expect(s.urgent, isFalse);
  });

  test('paid and overdue-adjacent: even due today stays calm', () {
    final s = cardBillStatus(card(paid: '2026-09'), DateTime(2026, 9, 10))!;
    expect(s.paidThisCycle, isTrue);
    expect(s.due, DateTime(2026, 10, 10));
    expect(s.urgent, isFalse);
  });

  test('stale flag from a previous cycle is ignored', () {
    final s = cardBillStatus(card(paid: '2026-08'), DateTime(2026, 9, 7))!;
    expect(s.paidThisCycle, isFalse);
    expect(s.due, DateTime(2026, 9, 10));
    expect(s.urgent, isTrue);
  });

  test('month-end clamp: dueDay 31 lands on Feb 28 and next on Mar 31', () {
    final feb = cardBillStatus(card(dueDay: 31), DateTime(2026, 2, 25))!;
    expect(feb.due, DateTime(2026, 2, 28));

    final paidFeb = cardBillStatus(
      card(dueDay: 31, paid: '2026-02'),
      DateTime(2026, 2, 25),
    )!;
    expect(paidFeb.paidThisCycle, isTrue);
    expect(paidFeb.due, DateTime(2026, 3, 31));
  });

  test('non-card, missing dueDay, and closed cards return null', () {
    final bank = Account(
      id: 'b1',
      name: 'Bank',
      type: AccountType.bank,
      keys: const {},
      dueDay: 10,
    );
    expect(cardBillStatus(bank, DateTime(2026, 9, 7)), isNull);
    expect(cardBillStatus(card(dueDay: null), DateTime(2026, 9, 7)), isNull);
    expect(
      cardBillStatus(
        card(closedAt: DateTime(2026, 1, 1)),
        DateTime(2026, 9, 7),
      ),
      isNull,
    );
  });
}
