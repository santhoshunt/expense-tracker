import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/services/recurring_detector.dart';

void main() {
  setUp(() {
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  var seq = 0;

  Tx sms({
    required double amount,
    required DateTime date,
    String merchant = 'NETFLIX',
    String categoryId = 'entertainment',
    bool spam = false,
  }) => Tx(
    id: 't${seq++}',
    type: TxType.expense,
    categoryId: categoryId,
    amount: amount,
    note: '',
    smsBody:
        'Rs.$amount debited from a/c XX1234 to $merchant on 01-01-26. '
        'Avl Bal Rs.5000.',
    date: date,
    source: TxSource.sms,
    sender: 'VM-HDFCBK',
    suspectedSpam: spam,
  );

  Tx manual({
    required double amount,
    required DateTime date,
    String note = 'Rent',
    String categoryId = 'bills',
  }) => Tx(
    id: 't${seq++}',
    type: TxType.expense,
    categoryId: categoryId,
    amount: amount,
    note: note,
    date: date,
  );

  group('recurringKeyOf', () {
    test('SMS rows key on the extracted merchant, not the bank sender', () {
      final t = sms(amount: 649, date: DateTime(2026, 8, 1));
      expect(recurringKeyOf(t), 'expense|netflix');
    });

    test('manual rows fall back to the normalized note', () {
      final t = manual(
        amount: 15000,
        date: DateTime(2026, 8, 1),
        note: ' Rent! ',
      );
      expect(recurringKeyOf(t), 'expense|rent');
    });

    test('SMS row without an extractable merchant falls back to the note', () {
      final t = Tx(
        id: 't${seq++}',
        type: TxType.expense,
        categoryId: 'bills',
        amount: 500,
        note: 'EB bill',
        smsBody: 'Rs.500 debited from a/c XX1234. Avl Bal Rs.100.',
        date: DateTime(2026, 8, 1),
        source: TxSource.sms,
        sender: 'VM-HDFCBK',
      );
      expect(recurringKeyOf(t), 'expense|eb bill');
      expect(merchantDisplayLabel(t), 'Eb Bill');
    });

    test('the extracted merchant wins over the note on SMS rows', () {
      final t = Tx(
        id: 't${seq++}',
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 649,
        note: 'my subscription',
        smsBody: 'Rs.649 debited from a/c XX1234 to NETFLIX on 01-01-26.',
        date: DateTime(2026, 8, 1),
        source: TxSource.sms,
        sender: 'VM-HDFCBK',
      );
      expect(recurringKeyOf(t), 'expense|netflix');
    });

    test('digits-only identities (phone/VPA numbers) yield null', () {
      expect(
        recurringKeyOf(
          sms(amount: 500, date: DateTime(2026, 8, 1), merchant: '9215676766'),
        ),
        isNull,
      );
      expect(
        recurringKeyOf(
          manual(amount: 500, date: DateTime(2026, 8, 1), note: '12345'),
        ),
        isNull,
      );
    });

    test('transfers, spam and identity-less rows yield null', () {
      expect(
        recurringKeyOf(
          manual(
            amount: 5000,
            date: DateTime(2026, 8, 1),
            categoryId: 'card_bill',
          ),
        ),
        isNull,
        reason: 'transfer categories are excluded',
      );
      expect(
        recurringKeyOf(
          sms(amount: 100, date: DateTime(2026, 8, 1), spam: true),
        ),
        isNull,
      );
      expect(
        recurringKeyOf(
          manual(amount: 100, date: DateTime(2026, 8, 1), note: ''),
        ),
        isNull,
      );
    });
  });

  group('detectRecurring', () {
    test('three monthly occurrences qualify and predict the next date', () {
      final now = DateTime(2026, 9, 1);
      final hits = detectRecurring([
        sms(amount: 649, date: DateTime(2026, 6, 1)),
        sms(amount: 649, date: DateTime(2026, 7, 1)),
        sms(amount: 649, date: DateTime(2026, 8, 1)),
      ], now: now);
      expect(hits, hasLength(1));
      final h = hits.single;
      expect(h.key, 'expense|netflix');
      expect(h.label, 'Netflix');
      expect(h.categoryId, 'entertainment');
      expect(h.expectedAmount, 649);
      expect(h.lastDate, DateTime(2026, 8, 1));
      // Gaps 30 and 31 → median 30.5 → 31 days.
      expect(h.nextDue, DateTime(2026, 9, 1));
      expect(h.daysUntil(now), 0);
    });

    test('two occurrences are not a pattern', () {
      final hits = detectRecurring([
        sms(amount: 649, date: DateTime(2026, 7, 1)),
        sms(amount: 649, date: DateTime(2026, 8, 1)),
      ], now: DateTime(2026, 9, 1));
      expect(hits, isEmpty);
    });

    test('weekly cadence is rejected (monthly only)', () {
      final hits = detectRecurring([
        for (var i = 0; i < 6; i++)
          sms(amount: 500, date: DateTime(2026, 8, 1 + 7 * i)),
      ], now: DateTime(2026, 9, 8));
      expect(hits, isEmpty);
    });

    test('irregular gaps are rejected', () {
      final hits = detectRecurring([
        sms(amount: 500, date: DateTime(2026, 5, 1)),
        sms(amount: 500, date: DateTime(2026, 5, 25)),
        sms(amount: 500, date: DateTime(2026, 8, 20)),
      ], now: DateTime(2026, 9, 1));
      expect(hits, isEmpty, reason: '87-day gap breaks the pattern');
    });

    test('same-day duplicates collapse to one occurrence', () {
      final now = DateTime(2026, 9, 1);
      final hits = detectRecurring([
        sms(amount: 649, date: DateTime(2026, 6, 1, 9)),
        sms(amount: 649, date: DateTime(2026, 6, 1, 10)), // retried payment
        sms(amount: 649, date: DateTime(2026, 7, 1)),
        sms(amount: 649, date: DateTime(2026, 8, 1)),
      ], now: now);
      expect(hits, hasLength(1));
    });

    test('expected amount is the median of the last three', () {
      final now = DateTime(2026, 9, 25);
      final hits = detectRecurring([
        manual(amount: 100, date: DateTime(2026, 6, 1)),
        manual(amount: 1200, date: DateTime(2026, 7, 1)),
        manual(amount: 1300, date: DateTime(2026, 8, 1)),
        manual(amount: 1400, date: DateTime(2026, 9, 1)),
      ], now: now);
      expect(hits, hasLength(1));
      // Last three are 1200/1300/1400 — the 100 outlier ages out.
      expect(hits.single.expectedAmount, 1300);
    });

    test('overdue up to 7 days stays visible, older drops', () {
      final rows = [
        manual(amount: 15000, date: DateTime(2026, 6, 1)),
        manual(amount: 15000, date: DateTime(2026, 7, 1)),
        manual(amount: 15000, date: DateTime(2026, 8, 1)),
      ];
      // nextDue ≈ 1 Sep. 5 Sep → overdue by 4 days, shown.
      final overdue = detectRecurring(rows, now: DateTime(2026, 9, 5));
      expect(overdue, hasLength(1));
      expect(overdue.single.daysUntil(DateTime(2026, 9, 5)), lessThan(0));
      // 15 Sep → 14 days past, dropped (pattern likely ended).
      expect(detectRecurring(rows, now: DateTime(2026, 9, 15)), isEmpty);
    });

    test('more than 14 days ahead is not yet upcoming', () {
      final hits = detectRecurring([
        manual(amount: 15000, date: DateTime(2026, 7, 1)),
        manual(amount: 15000, date: DateTime(2026, 8, 1)),
        manual(amount: 15000, date: DateTime(2026, 9, 1)),
      ], now: DateTime(2026, 9, 2));
      expect(hits, isEmpty, reason: 'next due ~1 Oct is 29 days out');
    });

    test('rows outside the 12-month horizon are ignored', () {
      final hits = detectRecurring([
        manual(amount: 500, date: DateTime(2024, 6, 1)),
        manual(amount: 500, date: DateTime(2024, 7, 1)),
        manual(amount: 500, date: DateTime(2024, 8, 1)),
      ], now: DateTime(2026, 9, 1));
      expect(hits, isEmpty);
    });

    test('spam and transfer rows never form patterns', () {
      final hits = detectRecurring([
        sms(amount: 500, date: DateTime(2026, 6, 1), spam: true),
        sms(amount: 500, date: DateTime(2026, 7, 1), spam: true),
        sms(amount: 500, date: DateTime(2026, 8, 1), spam: true),
        manual(
          amount: 900,
          date: DateTime(2026, 6, 5),
          categoryId: 'card_bill',
        ),
        manual(
          amount: 900,
          date: DateTime(2026, 7, 5),
          categoryId: 'card_bill',
        ),
        manual(
          amount: 900,
          date: DateTime(2026, 8, 5),
          categoryId: 'card_bill',
        ),
      ], now: DateTime(2026, 9, 1));
      expect(hits, isEmpty);
    });

    test('note-tagged anonymous SMS rows form a pattern', () {
      Tx tagged(int month) => Tx(
        id: 't${seq++}',
        type: TxType.expense,
        categoryId: 'bills',
        amount: 1200,
        note: 'EB bill',
        smsBody: 'Rs.1200 debited from a/c XX1234. Avl Bal Rs.100.',
        date: DateTime(2026, month, 1),
        source: TxSource.sms,
        sender: 'VM-HDFCBK',
      );
      final hits = detectRecurring([
        tagged(6),
        tagged(7),
        tagged(8),
      ], now: DateTime(2026, 9, 1));
      expect(hits, hasLength(1));
      expect(hits.single.key, 'expense|eb bill');
      expect(hits.single.label, 'Eb Bill');
    });

    test('hits sort soonest first', () {
      final now = DateTime(2026, 9, 1);
      final hits = detectRecurring([
        // Netflix due ~1 Sep.
        sms(amount: 649, date: DateTime(2026, 6, 1)),
        sms(amount: 649, date: DateTime(2026, 7, 1)),
        sms(amount: 649, date: DateTime(2026, 8, 1)),
        // Rent due ~10 Sep.
        manual(amount: 15000, date: DateTime(2026, 6, 10)),
        manual(amount: 15000, date: DateTime(2026, 7, 10)),
        manual(amount: 15000, date: DateTime(2026, 8, 10)),
      ], now: now);
      expect(hits, hasLength(2));
      expect(hits.first.key, 'expense|netflix');
      expect(hits.last.key, 'expense|rent');
    });
  });
}
