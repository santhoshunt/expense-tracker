import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/services/card_bill.dart';

void main() {
  Account card({
    int? dueDay = 10,
    int? stmtDay,
    String? paid,
    DateTime? closedAt,
  }) => Account(
    id: 'c1',
    name: 'Card',
    type: AccountType.creditCard,
    keys: const {},
    statementDay: stmtDay,
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

  test('urgency boundary sits at $kCardUrgentWindowDays days', () {
    final inside = cardBillStatus(card(), DateTime(2026, 9, 5))!;
    expect(inside.daysUntil, kCardUrgentWindowDays);
    expect(inside.urgent, isTrue);

    final outside = cardBillStatus(card(), DateTime(2026, 9, 4))!;
    expect(outside.daysUntil, kCardUrgentWindowDays + 1);
    expect(outside.urgent, isFalse);
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

  group('statement date and phase', () {
    test('no statement day: billed with no date — the old behavior', () {
      final s = cardBillStatus(card(), DateTime(2026, 9, 7))!;
      expect(s.statementDate, isNull);
      expect(s.phase, CardBillPhase.billed);
      expect(s.urgent, isTrue);
    });

    test('statement day below the due day lands in the due month', () {
      // Statement 1st, due 10th: the 1 Sep statement precedes the 10 Sep due.
      final s = cardBillStatus(card(stmtDay: 1), DateTime(2026, 9, 7))!;
      expect(s.statementDate, DateTime(2026, 9, 1));
      expect(s.phase, CardBillPhase.billed);
    });

    test('statement day above the due day lands in the previous month', () {
      final s = cardBillStatus(card(stmtDay: 24), DateTime(2026, 9, 7))!;
      expect(s.due, DateTime(2026, 9, 10));
      expect(s.statementDate, DateTime(2026, 8, 24));
      expect(s.phase, CardBillPhase.billed);
    });

    test('before the statement generates: notBilled, never urgent', () {
      // Statement 8th, due 10th; on the 7th the due is 3 days out (inside
      // the urgency window) but the bill does not exist yet.
      final s = cardBillStatus(card(stmtDay: 8), DateTime(2026, 9, 7))!;
      expect(s.due, DateTime(2026, 9, 10));
      expect(s.statementDate, DateTime(2026, 9, 8));
      expect(s.phase, CardBillPhase.notBilled);
      expect(s.daysUntil, 3);
      expect(s.urgent, isFalse, reason: 'nothing is owed pre-statement');

      // On the statement day itself the bill exists.
      final billed = cardBillStatus(card(stmtDay: 8), DateTime(2026, 9, 8))!;
      expect(billed.phase, CardBillPhase.billed);
      expect(billed.urgent, isTrue);
    });

    test('paid: phase paid, statement date is the NEXT cycle\'s', () {
      final s = cardBillStatus(
        card(stmtDay: 24, paid: '2026-09'),
        DateTime(2026, 9, 7),
      )!;
      expect(s.phase, CardBillPhase.paid);
      expect(s.due, DateTime(2026, 10, 10));
      expect(s.statementDate, DateTime(2026, 9, 24));
      expect(s.urgent, isFalse);
    });

    test('day-31 statement clamps to the short month\'s last day', () {
      // Due 10 Mar; the statement before it is "31 Feb" → 28 Feb 2026.
      final s = cardBillStatus(card(stmtDay: 31), DateTime(2026, 3, 5))!;
      expect(s.due, DateTime(2026, 3, 10));
      expect(s.statementDate, DateTime(2026, 2, 28));
    });

    test('subtitle copy per phase', () {
      String sub(CardBillStatus s) => cardBillSubtitle(s);
      expect(
        sub(cardBillStatus(card(), DateTime(2026, 9, 7))!),
        'Due 10 Sep · in 3 days',
      );
      expect(
        sub(cardBillStatus(card(stmtDay: 24), DateTime(2026, 9, 7))!),
        'Billed 24 Aug · due 10 Sep · in 3 days',
      );
      expect(
        sub(cardBillStatus(card(stmtDay: 8), DateTime(2026, 9, 7))!),
        'Bill generates 8 Sep · due 10 Sep',
      );
      expect(
        sub(cardBillStatus(card(paid: '2026-09'), DateTime(2026, 9, 7))!),
        'Paid · next bill 10 Oct',
      );
      expect(
        sub(
          cardBillStatus(
            card(stmtDay: 24, paid: '2026-09'),
            DateTime(2026, 9, 7),
          )!,
        ),
        'Paid · next bill 24 Sep · due 10 Oct',
      );
      expect(
        sub(cardBillStatus(card(), DateTime(2026, 9, 10))!),
        'Due 10 Sep · today',
      );
    });
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
