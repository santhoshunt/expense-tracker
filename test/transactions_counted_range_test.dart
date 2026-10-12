import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Paid on 31 March, counted in April: FY 2026-27 by the date it counts in,
  // FY 2025-26 by the date it happened.
  final salary = Tx(
    id: 'a',
    type: TxType.income,
    categoryId: 'salary',
    amount: 1000,
    note: 'Salary',
    date: DateTime(2026, 3, 31, 18, 30),
    countIn: DateTime(2026, 4, 1),
  );
  final fy2627 = DateTimeRange(
    start: DateTime(2026, 4, 1),
    end: DateTime(2027, 3, 31),
  );
  final fy2526 = DateTimeRange(
    start: DateTime(2025, 4, 1),
    end: DateTime(2026, 3, 31),
  );

  test('a counted range matches the date the row counts in', () {
    expect(txInRange(salary, fy2627, counted: true), isTrue);
    expect(txInRange(salary, fy2526, counted: true), isFalse);
  });

  test('a plain range still matches the date the row happened', () {
    expect(txInRange(salary, fy2526, counted: false), isTrue);
    expect(txInRange(salary, fy2627, counted: false), isFalse);
  });

  test('both ends are whole days', () {
    final lastEvening = Tx(
      id: 'b',
      type: TxType.expense,
      categoryId: 'food',
      amount: 50,
      note: 'Tea',
      date: DateTime(2027, 3, 31, 23, 59),
    );
    final firstMorning = Tx(
      id: 'c',
      type: TxType.expense,
      categoryId: 'food',
      amount: 50,
      note: 'Tea',
      date: DateTime(2026, 4, 1, 0, 1),
    );
    final nextYear = Tx(
      id: 'd',
      type: TxType.expense,
      categoryId: 'food',
      amount: 50,
      note: 'Tea',
      date: DateTime(2027, 4, 1),
    );
    for (final counted in [true, false]) {
      expect(txInRange(lastEvening, fy2627, counted: counted), isTrue);
      expect(txInRange(firstMorning, fy2627, counted: counted), isTrue);
      expect(txInRange(nextYear, fy2627, counted: counted), isFalse);
    }
  });
}
